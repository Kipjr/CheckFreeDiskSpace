# -----------------------------------------------------------------------------############################
# Script Function: This sample Windows powershell script calculates free disk spaces
# in multiple servers and emails copy of  csv report. 
# ----------------------------------------------------------------------------- ############################

#Set-AuthenticodeSignature "<filename of ps script to sign.ps1>"  @(Get-ChildItem cert:\CurrentUser\My -codesign)[0] #needed if your code requires signing
#New-EventLog -LogName CheckFreeSpace -Source Application #create eventlog for this script.
############################################### VARS  ################################

$scriptPath = split-path -parent $MyInvocation.MyCommand.Definition
$hostname = hostname

## EMAIL VARS ##
#read-host -assecurestring | convertfrom-securestring | out-file $scriptPath\password.txt #needed to create password.txt file. (open as other user (service account) if you need it to run as service account in scheduled task)
$username = "username@domain.tld"
$password = Get-Content "$scriptPath\password.txt" | ConvertTo-SecureString -force
$cred = new-object -typename System.Management.Automation.PSCredential -argumentlist $username, $password
$from = "Disk Usage Script<diskusage.server@domain.tld>"                        
$to = "You <me@domain.tld>"
$SmtpServer = "mailserver@domain.tld" #assuming using port 587

## Threshold vars ##
$threshold_percentage = 10 #<10% disk free of total
$threshold_gb = 5 # <5GB free of total
$threshold_hv_gb = 150 #hyper-V machines should have a higher thresshold that would raise an 'alarm' / show in body email. less than 150GB of total
$threshold_change = 1000 #more change than 1000Mb created/removed

## delete reports vars ##
$delete_days = 365 #remove logs after 365 days.


############################################### PRE-check ################################
$t_server = Test-Path -Path "$scriptPath\Servers.txt" #check if list of servers is present
$t_reports = Test-Path -Path "$scriptPath\Reports"  #check if directory reports is present
$t_password = Test-Path -Path "$scriptPath\password.txt" #check if password.txt file is present

#script will stop if one of the above returnes false. 
if(($t_server -ne $true) -or ($t_reports -ne $true) -or ($t_password -ne $true)) {
    Write-EventLog -EventId 3001 -LogName Application -Message "$scriptPath\Servers.txt \Reports or \password.txt not available" -Source CheckFreeSpace -EntryType 1
    exit
}

############################################### SCRIPT ################################
#delete reports older than 365 days
$OldReports = (Get-Date).AddDays(0-$delete_days)
Get-ChildItem "$scriptPath\Reports\*.*" | Where-Object { $_.LastWriteTime -le $OldReports} | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue  #get all reports older than x days and remove them

#Create variable for log date
$LogDate = get-date -f yyyyMMddhhmm #generate string of current datetime

#get previous report files and select the newest
$previous = Get-ChildItem "$scriptPath\Reports\*.*" | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
$previousReport = Import-Csv -Path "$scriptPath\Reports\$($previous.Name)" #import newest file.

#Define location of text file containing your servers. It might also
#be stored on a local file system for example, now it is on the same level as the script.
$File = Get-Content -Path "$scriptPath\Servers.txt" 

#the disk $DiskReport variable checks all servers returned by the $File variable and returnes raw values for disk
$DiskReport = ForEach ($Servernames in ($File)) 
{Get-WmiObject win32_logicaldisk <#-Credential $RunAccount#> `
-ComputerName $Servernames -Filter "Drivetype=3" `
-ErrorAction SilentlyContinue 
}

#create array of objects with formatted info about disks
$Diskreport_2 = @()
foreach($item in $DiskReport) {

    $obj = New-Object -TypeName psobject
    $obj | Add-Member -MemberType NoteProperty -Name 'Server Name' -value $($item.SystemName)
    $obj | Add-Member -MemberType NoteProperty -Name 'Drive Letter' -value $($item.DeviceID)
    $obj | Add-Member -MemberType NoteProperty -Name 'Volume Name' -value $($item.VolumeName)
    $obj | Add-Member -MemberType NoteProperty -Name 'Total Capacity (GB)' -value $("{0:N1}" -f ( $item.Size / 1gb))
    $obj | Add-Member -MemberType NoteProperty -Name 'Free Space (%)' -value   ([math]::Round((($item.freespace/$item.size)*100),1))
    $obj | Add-Member -MemberType NoteProperty -Name 'Free Space (GB)' -value  ([math]::Round( $item.Freespace / 1gb ,1)) 
    $obj | Add-Member -MemberType NoteProperty -Name 'RAW Free (bytes)' -value $($item.FreeSpace)
    $obj | Add-Member -MemberType NoteProperty -Name 'RAW Size (bytes)' -value $($item.Size)
    $obj | Add-Member -MemberType NoteProperty -Name 'Change (MB)' -value   ([math]::Round(( 
     (($item.FreeSpace - ($previousReport | where { ($($_."server Name") -eq $($item.SystemName)) -and ($($_."Drive Letter") -eq $($item.DeviceID)) }  |  select -ExpandProperty "RAW Free (bytes)"))
    )/1mb),1))
    $obj | Add-Member -MemberType NoteProperty -Name 'Change (%)' -value   ([math]::Round((
    ($item.FreeSpace - ($previousReport | where { ($($_."server Name") -eq $($item.SystemName)) -and ($($_."Drive Letter") -eq $($item.DeviceID)) }  |  select -ExpandProperty "RAW Free (bytes)"))/$($item.Size)*100),1))  

    $Diskreport_2 +=$obj }

#Export report to CSV file (Disk Report) and create threshold version of this data to be added as body for email.
$Diskreport_2 | Export-Csv -path "$scriptPath\Reports\DiskReport_$logDate.csv" -NoTypeInformation
$Diskreport10_2 = $Diskreport_2 | where { 
    ( ($($_.'Server Name').Contains("HV")) -and ($Diskreport_2[0].'Drive Letter' -ne "C:") -and ($_."Free Space (GB)" -le $threshold_hv_gb) ) -or ($_."Free Space (%)" -le $threshold_percentage) -or ($_."Free Space (GB)" -le $threshold_gb) -or (  ([math]::Abs($_."Change (MB)") -ge $threshold_change)) 

}   -ErrorAction SilentlyContinue

# Attach and send CSV report (Most recent report will be attached)
$messageParameters = @{                        
                Subject = "Daily Server Storage Report"                        
                Body = "Attached is Daily Server Storage Report. All reports are located in \\$hostname\$scriptPath\, but the most recent is sent daily. Below are critical levels:`n $($DiskReport10_2 | ConvertTo-Html)"                   
                From = $from                
                To = $to
                Attachments = (Get-ChildItem "$scriptPath\Reports\*.*" | sort LastWriteTime | select -last 1)                   
                SmtpServer = $SmtpServer
                                    
            }   
Send-MailMessage @messageParameters -BodyAsHtml -Priority High -DeliveryNotificationOption OnSuccess, OnFailure -Credential $cred -Port 587 -UseSsl         


