<#
.SYNOPSIS
This script will attempt to check if there are new updates on the upsteam WSUS server. If there are new updates, the script will start a software update synchronization in SCCM.
.DESCRIPTION
Check if the specified Scheduled Task was completed successfully on the upstream WSUS Server and if it was completed more recently than the last time the script ran.
If the scheduled task check is successful, connect to the upstream WSUS Server and query the latest ArrivalDate of updates and check if it's more recent than the last time the script ran.
If the ArrivalDate check is successful:
    1) Start a SCCM software update synchronization and wait for its completion.
    2) If synchronization is successful:
        2.1) Update the record of the scheduled task completion date for the next script run.
        2.2) Update the the ArrivalDate value for the next script run.
.PARAMETER LogFile
    The full path and name of the log file. If no value is given, will write a lot file in the script path.
.PARAMETER MaxLogSize
    The max size of the log file before it rotates the log file. The old log file will be renamed to .lo_
.PARAMETER ScheduledTaskName
    The name of the scheduled task to check for a successful completion on the upstream WSUS server
.PARAMETER Force
    The script will not check/compare the date of the scheduled task or the ArrivalDate property of updates on the upstream WSUS before initiating a SCCM synchronization.
#>
[CmdletBinding(SupportsShouldProcess=$True)]
Param(
    #Set the log file.
    [Parameter(ParameterSetName='CheckScheduledTask')]
    [Parameter(ParameterSetName='SkipScheduledTask')]
    [Parameter(ParameterSetName='ForceOnly')]
    [string]$LogFile,

    #The maximum size of the log in bytes.
    [Parameter(ParameterSetName='CheckScheduledTask')]
    [Parameter(ParameterSetName='SkipScheduledTask')]
    [Parameter(ParameterSetName='ForceOnly')]
    [int]$MaxLogSize = 2621440,

    #Define the scheduled task to check on the upstream WSUS Server.
    [Parameter(
        ParameterSetName='CheckScheduledTask',
        Mandatory = $true
    )]
    [string]$ScheduledTaskName,

    #Define if the script should not check for a scheduled task on the upstream WSUS
    [Parameter(
        ParameterSetName='SkipScheduledTask',
        Mandatory = $true
    )]
    [switch]$SkipScheduledTaskCheck,

    #Define if the script should not check the dates for the scheduled task completion or ArrivalDate of updates on the upstream WSUS.
     [Parameter(ParameterSetName='CheckScheduledTask')]
     [Parameter(ParameterSetName='SkipScheduledTask')]
     [Parameter(ParameterSetName='ForceOnly')]
    [switch]$Force
)
#region Functions
Function Add-TextToCMLog {
##########################################################################################################
<#
.SYNOPSIS
   Log to a file in a format that can be read by Trace32.exe / CMTrace.exe

.DESCRIPTION
   Write a line of data to a script log file in a format that can be parsed by Trace32.exe / CMTrace.exe

   The severity of the logged line can be set as:

        1 - Information
        2 - Warning
        3 - Error

   Warnings will be highlighted in yellow. Errors are highlighted in red.

   The tools to view the log:

   SMS Trace - http://www.microsoft.com/en-us/download/details.aspx?id=18153
   CM Trace - Installation directory on Configuration Manager 2012 Site Server - <Install Directory>\tools\

.EXAMPLE
   Add-TextToCMLog c:\output\update.log "Application of MS15-031 failed" Apply_Patch 3

   This will write a line to the update.log file in c:\output stating that "Application of MS15-031 failed".
   The source component will be Apply_Patch and the line will be highlighted in red as it is an error
   (severity - 3).

#>
##########################################################################################################

#Define and validate parameters
[CmdletBinding()]
Param(
      #Path to the log file
      [parameter(Mandatory=$True)]
      [String]$LogFile,

      #The information to log
      [parameter(Mandatory=$True)]
      [String]$Value,

      #The source of the error
      [parameter(Mandatory=$True)]
      [String]$Component,

      #The severity (1 - Information, 2- Warning, 3 - Error)
      [parameter(Mandatory=$True)]
      [ValidateRange(1,3)]
      [Single]$Severity
      )


#Obtain UTC offset
$DateTime = New-Object -ComObject WbemScripting.SWbemDateTime
$DateTime.SetVarDate($(Get-Date))
$UtcValue = $DateTime.Value
$UtcOffset = $UtcValue.Substring(21, $UtcValue.Length - 21)


#Create the line to be logged
$LogLine =  "<![LOG[$Value]LOG]!>" +`
            "<time=`"$(Get-Date -Format HH:mm:ss.fff)$($UtcOffset)`" " +`
            "date=`"$(Get-Date -Format M-d-yyyy)`" " +`
            "component=`"$Component`" " +`
            "context=`"$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)`" " +`
            "type=`"$Severity`" " +`
            "thread=`"$($pid)`" " +`
            "file=`"`">"

#Write the line to the passed log file
Out-File -InputObject $LogLine -Append -NoClobber -Encoding Default -FilePath $LogFile -WhatIf:$False

}
##########################################################################################################

#Taken from https://stackoverflow.com/questions/5648931/test-if-registry-value-exists
Function Test-RegistryValue {
##########################################################################################################
<#
.NOTES
    Taken from https://stackoverflow.com/questions/5648931/test-if-registry-value-exists
#>
    Param(
        [Alias("PSPath")]
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [String]$Path,
        [Parameter(Position = 1, Mandatory = $true)]
        [String]$Value,
        [Switch]$PassThru
    )

    Process {
        If (Test-Path $Path) {
            $Key = Get-Item -LiteralPath $Path
            If ($Key.GetValue($Value, $null) -ne $null) {
                If ($PassThru) {
                    Get-ItemProperty $Path $Value
                } Else {
                    $True
                }
            } Else {
                $False
            }
        } Else {
            $False
        }
    }
}
##########################################################################################################

Function Get-SiteCode {
##########################################################################################################
<#
.SYNOPSIS
   Attempt to determine the current device's site code from the registry or PS drive.

.DESCRIPTION
   When ran this function will look for the client's site.  If not found it will look for a single PS drive.

.EXAMPLE
   Get-SiteCode

#>
##########################################################################################################

    #Try getting the site code from the client installed on this system.
    If (Test-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\SMS\Identification" -Value "Site Code"){
        $SiteCode =  Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\SMS\Identification" | Select-Object -ExpandProperty "Site Code"
    } ElseIf (Test-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\SMS\Mobile Client" -Value "AssignedSiteCode") {
        $SiteCode =  Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\SMS\Mobile Client" | Select-Object -ExpandProperty "AssignedSiteCode"
    }

    #If the client isn't installed try looking for the site code based on the PS drives.
    If (-Not ($SiteCode) ) {
        #See if a PSDrive exists with the CMSite provider
        $PSDrive = Get-PSDrive -PSProvider CMSite -ErrorAction SilentlyContinue

        #If PSDrive exists then get the site code from it.
        If ($PSDrive.Count -eq 1) {
            $SiteCode = $PSDrive.Name
        }
    }

    Return $SiteCode
}
##########################################################################################################

#endregion Functions

$scriptVersion = "0.3"
$component = 'Invoke-OfflineSUPSync'
$scriptPath = split-path -parent $MyInvocation.MyCommand.Definition

#region Parameter validation

#If log file is null then set it to the default and then make the provider type explicit.
If (!$LogFile) {
    $LogFile = Join-Path $scriptPath "offlinesupsync.log"
}

$LogFile = "filesystem::$($LogFile)"

#If the log file exists and is larger then the maximum then roll it over.
If (Test-path  $LogFile -PathType Leaf) {
    If ((Get-Item $LogFile).length -gt $MaxLogSize){
        Move-Item -Force $LogFile ($LogFile -replace ".$","_") -WhatIf:$False
    }
}
Add-TextToCMLog $LogFile "#############################################################################################" $component 1
Add-TextToCMLog $LogFile "$component started (Version $($scriptVersion))." $component 1

If(!$SkipScheduledTaskCheck -and !$ScheduledTaskName -and !$Force){
    Add-TextToCMLog $LogFile "Please specify the name of a scheduled task to check on the upstream WSUS Server or use the -SkipScheduledTaskCheck parameter to skip this requirement." $component 3
    Exit 1
}

#If -Force is used and no scheduled task is specified, skip the scheduled task check
If(!$SkipScheduledTaskCheck -and !$ScheduledTaskName){
    $SkipScheduledTaskCheck = $true
}

#endregion Parameter validation

$ErrorActionPreference = "Stop"

#Check to make sure we're running this on a primary site server that has the SMS namespace.
If (!(Get-Wmiobject -namespace "Root" -class "__Namespace" -Filter "Name = 'SMS'")){
    Add-TextToCMLog $LogFile "Currently, this script must run on a primary site server." $component 3
    Exit 1
}

#Change the directory to the site location.
$OriginalLocation = Get-Location

#Try to load the UpdateServices module.
Try {
    [reflection.assembly]::LoadWithPartialName("Microsoft.UpdateServices.Administration") | out-null
} Catch {
    Add-TextToCMLog $LogFile "Failed to load the UpdateServices module." $component 3
    Add-TextToCMLog $LogFile "Please make sure that WSUS Admin Console is installed on this machine" $component 3
    Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
    Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
}

#If the Configuration Manager module exists then load it.
    If (! $env:SMS_ADMIN_UI_PATH)
    {
        Add-TextToCMLog $LogFile "The SMS_ADMIN_UI_PATH environment variable is not set.  Make sure the Configuration Manager console it installed." $component 3
        Exit 1
    }
    $configManagerCmdLetpath = Join-Path $(Split-Path $env:SMS_ADMIN_UI_PATH) "ConfigurationManager.psd1"
    If (! (Test-Path $configManagerCmdLetpath -PathType Leaf) )
    {
        Add-TextToCMLog $LogFile "The ConfigurationManager Module file could not be found.  Make sure the Configuration Manager console it installed." $component 3
        Exit 1
    }

#You can't pass WhatIf to the Import-Module function and it spits out a lot of text, so work around it.
$WhatIf = $WhatIfPreference
$WhatIfPreference = $False
Import-Module $configManagerCmdLetpath -Force
$WhatIfPreference = $WhatIf

#Get the site code
If (!$SiteCode){$SiteCode = Get-SiteCode}

#Verify that the site code was determined
If (!$SiteCode){
    Add-TextToCMLog $LogFile "Could not determine the site code. If you are running CAS you must specify the site code. Exiting." $component 3
    Exit 1
}

#If the PS drive doesn't exist then try to create it.
If (! (Test-Path "$($SiteCode):")) {
    Try{
        Add-TextToCMLog $LogFile "Trying to create the PS Drive for site '$($SiteCode)'" $component 1
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root "." -WhatIf:$False | Out-Null
    } Catch {
        Add-TextToCMLog $LogFile "The site's PS drive doesn't exist nor could it be created." $component 3
        Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult): $($_.Exception.Message)" $component 3
        Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
        Exit $($_.Exception.HResult)
    }
}

#Set and verify the location.
Try{
    Add-TextToCMLog $LogFile "Connecting to site: $($SiteCode)" $component 1
    Set-Location "$($SiteCode):"  | Out-Null
} Catch {
    Add-TextToCMLog $LogFile "Could not set location to site: $($SiteCode)." $component 3
    Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
    Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
    Exit $($_.Exception.HResult)
}

#Make sure the site code exists on this server.
$CMSite = Get-CMSite -SiteCode $SiteCode
If (!$CMSite) {
    Add-TextToCMLog $LogFile "The site code $($SiteCode) could not be found." $component 3
    Return
}

Try{
    Add-TextToCMLog $LogFile "Retrieving Upstream WSUS Server information." $component 1
    $SUP_Props = Get-CMSoftwareUpdatePoint | Select-Object -ExpandProperty Props
    if(($SUP_Props | Where {$_.PropertyName -eq "UseParentWSUS"}).Value -eq 1){
        $SUPComponentProps = Get-CMSoftwareUpdatePointComponent | Select-Object -ExpandProperty Props
        $UpstreamWSUS = $SUPComponentProps | Where {$_.PropertyName -eq "ParentWSUS"} | Select-Object -ExpandProperty Value2
        $UpstreamWSUSPort = $SUPComponentProps | Where {$_.PropertyName -eq "ParentWSUSPort"} | Select-Object -ExpandProperty Value
        $UpstreamWSUSSSL = $SUPComponentProps | Where {$_.PropertyName -eq "SSLToParentWSUS"} | Select-Object -ExpandProperty Value
    
    }else{
        Add-TextToCMLog $LogFile "The software update point is not using a parent (upstream) WSUS server, script does not apply" $component 3
        Exit 1
    }
}Catch{
    Add-TextToCMLog $LogFile "Could not retrieve upstream WSUS Server information." $component 3
    Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
    Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
    Exit $($_.Exception.HResult)
}

If(!$SkipScheduledTaskCheck){
    Try{
        Add-TextToCMLog $LogFile "Getting scheduled task information for scheduled task `"$ScheduledTaskName`" on `"$UpstreamWSUS`"." $component 1
        $Session = New-CimSession -ComputerName $UpstreamWSUS
        $ScheduledTaskInfo = Get-ScheduledTaskInfo -TaskName $ScheduledTaskName -CimSession $Session -ErrorAction Stop

    }Catch{
        Add-TextToCMLog $LogFile "Could not verify status of the scheduled task `"$ScheduledTaskName`" on `"$UpstreamWSUS`"." $component 3
        Add-TextToCMLog $LogFile "Tip: Make sure the account running this script has access to the Upstream WSUS to get the scheduled task information." $component 3
        Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
        Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
        Exit $($_.Exception.HResult)
    }
    If($ScheduledTaskInfo.LastTaskResult -eq 0){
    
        Add-TextToCMLog $LogFile "Scheduled Task check: Checking if the recorded time for the last successful run of scheduled task `"$ScheduledTaskName`" is more recent than the last time the script ran." $component 1
        #Do we have a recorded time of the last successful time this scheduled task ran?
        $recordedScheduledTaskSuccessPath = "filesystem::$(Join-Path $scriptPath "lastsuccess_ST_$($ScheduledTaskName).xml")"
        If(Test-Path -Path $recordedScheduledTaskSuccessPath){
            Try{
                $recordedSTDate = Import-Clixml $recordedScheduledTaskSuccessPath -ErrorAction Stop
                Add-TextToCMLog $LogFile "Recorded successful scheduled task completion is `"$($recordedSTDate)`"." $component 1
            }Catch{
                Add-TextToCMLog $LogFile "Could not get the date of the last successful run of the scheduled task `"$ScheduledTaskName`"." $component 3
                Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
                Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
                Exit $($_.Exception.HResult)
            }
        }else{
            Add-TextToCMLog $LogFile "No recorded time found for the last successful time the scheduled task `"$ScheduledTaskName`" was run." $component 1
        }

        $lastScheduledTaskDate = Get-Date($ScheduledTaskInfo.LastRunTime)

        If(($lastScheduledTaskDate -gt $recordedSTDate) -or !($recordedSTDate) -or $Force){
            If($Force){
                Add-TextToCMLog $LogFile "Force parameter enabled, bypassing check..." $component 2
            }
            Add-TextToCMLog $LogFile "Scheduled Task check passed." $component 1
            [bool]$STCheckPassed = $true
           
        }else{
            Add-TextToCMLog $LogFile "The scheduled task `"$ScheduledTaskName`" did not run successfully more recently than last recorded." $component 2
            Add-TextToCMLog $LogFile "Recorded Date of scheduled: $($recordedSTDate), Upstream WSUS scheduled task `"$ScheduledTaskName`" last success date : $($lastScheduledTaskDate)" $component 2
            Add-TextToCMLog $LogFile "A software update synchronization is not needed." $component 2
            Exit 1
        }
    }else{
        if($ScheduledTaskInfo.LastTaskResult -eq 267009){
            Add-TextToCMLog $LogFile "The scheduled task `"$ScheduledTaskName`" on `"$UpstreamWSUS`" is currently running, exiting..." $component 2
            Exit 1
        }else{
            Add-TextToCMLog $LogFile "The scheduled task `"$ScheduledTaskName`" on `"$UpstreamWSUS`" has not ended successfully the last time it ran, exiting..." $component 3
            Exit 1
        }
    }

}else{
    Add-TextToCMLog $LogFile "Skipping scheduled task check." $component 1
}

If($STCheckPassed -or $SkipScheduledTaskCheck -or $Force){
     Add-TextToCMLog $LogFile "ArrivalDate check: Checking the latest ArrivalDate for updates on the upstream WSUS Server against the recorded ArrivalDate." $component 1
    $recordedArrivalDateSuccessPath = "filesystem::$(Join-Path $scriptPath "lastsuccess_WSUS_ArrivalDate.xml")"
    If(Test-Path -Path $recordedArrivalDateSuccessPath){
        Try{
            $recordedArrivalDate = Import-Clixml $recordedArrivalDateSuccessPath -ErrorAction Stop
            Add-TextToCMLog $LogFile "Recorded ArrivalDate is `"$($recordedArrivalDate)`"." $component 1
        }Catch{
            Add-TextToCMLog $LogFile "Could not get the last recorded ArrivalDate." $component 3
            Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
            Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
            Exit $($_.Exception.HResult)
        }
    }else{
        Add-TextToCMLog $LogFile "No recorded ArrivalDate found." $component 1
    }



    Add-TextToCMLog $LogFile "Connecting to Upstream WSUS to get the latest ArrivalTime" $component 1
    Try{
        $UpstreamWSUSServer = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer($UpstreamWSUS, $UpstreamWSUSSSL, $UpstreamWSUSPort)
    } Catch {

        Add-TextToCMLog $LogFile "Failed to connect to the upstream WSUS server $UpstreamWSUS on port $UpstreamWSUSPort with$(If(!$UpstreamWSUSSSL){"out"}) SSL." $component 3
        Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
        Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
        $UpstreamWSUSServer = $null
        Set-Location $OriginalLocation
        Exit $($_.Exception.HResult)
    }

    Try{
        $lastArrivalDate = $UpstreamWSUSServer.GetUpdates() | Sort-Object -Property ArrivalDate | Select-Object -ExpandProperty ArrivalDate -Last 1
        Add-TextToCMLog $LogFile "Latest ArrivalDate on the Upstream WSUS is $($lastArrivalDate)." $component 1
    }Catch{
        Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
        Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
        Exit $($_.Exception.HResult)
    }

    If(($lastArrivalDate -gt $recordedArrivalDate -or !($recordedArrivalDate)) -or $Force){
        If($Force){
        Add-TextToCMLog $LogFile "Force parameter enabled, bypassing check..." $component 2
        }else{
            Add-TextToCMLog $LogFile "ArrivalDate check passed." $component 1
        }
        [bool]$ADCheckPassed = $true
    }else{
        Add-TextToCMLog $LogFile "The newest ArrivalDate on the upstream WSUS is not newer than the last recorded ArrivalDate." $component 2
        Add-TextToCMLog $LogFile "Recorded ArrivalDate: $($recordedArrivalDate), Upstream WSUS latest ArrivalDate: $($lastArrivalDate)" $component 2
        Add-TextToCMLog $LogFile "A software update synchronization is not needed." $component 2
        Exit 1
    }
}
If((($STCheckPassed -or $SkipScheduledTaskCheck) -and $ADCheckPassed) -or $Force){
    Try{
        
        #Storing $OriginalLocation before running the sync script
        $location = $OriginalLocation

        . $scriptPath\Invoke-DGASoftwareUpdatePointSync.ps1 -LogFile $($logfile -replace "filesystem::","") -MaxLogSize $MaxLogSize -SiteCode $SiteCode -WhatIf:$WhatIfPreference -Wait -Force
        $component = "Invoke-OfflineSUPSync"
        $OriginalLocation = $location

        #Check if the sync was successful
        $SyncStatus = Get-CMSoftwareUpdateSyncStatus
        
        Set-Location $OriginalLocation
        If($SyncStatus.LastSyncErrorCode -eq 0){
            Add-TextToCMLog $LogFile "Software Update synchronization was successful." $component 1
        }else{
            Add-TextToCMLog $LogFile "Software Update synchronization failed." $component 3
            Add-TextToCMLog $LogFile "LastSyncErrorCode = $($SyncStatus.LastSyncErrorCode)" $component 3
            Add-TextToCMLog $LogFile "LastSyncState = $($SyncStatus.LastSyncState)" $component 3
            Exit 1
        }
    }
    Catch [System.Exception]{
        Add-TextToCMLog $LogFile "Failed to perform software update synchronization." $component 3
        Add-TextToCMLog $LogFile "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
        Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
        Exit $($_.Exception.HResult)
    }

    If(!$SkipScheduledTaskCheck -and ($null -ne $ScheduledTaskName)){
        Try{
            Add-TextToCMLog $LogFile "Recording date of last successful scheduled task `"$($ScheduledTaskName)`"." $component 1
            $lastScheduledTaskDate | Export-Clixml -Path $recordedScheduledTaskSuccessPath -WhatIf:$WhatIfPreference -ErrorAction Stop
        }Catch{
            Add-TextToCMLog $LogFile "Failed to save the new scheduled task recorded date." $component 3
            Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
            Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
            Exit $($_.Exception.HResult)
        }
    }

    Try{
        Add-TextToCMLog $LogFile "Recording date of newest ArrivalTime on upstream WSUS server `"$($UpstreamWSUS)`"." $component 1
        $lastArrivalDate | Export-Clixml -Path $recordedArrivalDateSuccessPath -WhatIf:$WhatIfPreference -ErrorAction Stop
    }Catch{
        Add-TextToCMLog $LogFile "Failed to save the new recorded ArrivalDate." $component 3
        Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
        Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
        Exit $($_.Exception.HResult)
    }
}
If($WhatIfPreference){
    Add-TextToCMLog $LogFile "WhatIf enabled, no changes were made." $component 2
}
Add-TextToCMLog $LogFile "$component finished." $component 1