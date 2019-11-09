<#
.SYNOPSIS
    TODO
.DESCRIPTION
.PARAMETER LogFile
    The full path and name of the log file. If no value is given, will write a lot file in the script path.
.PARAMETER MaxLogSize
    The max size of the log file before it rotates the log file. The old log file will be renamed to .lo_
.PARAMETER ADRPatterns
    An array of string patterns that will be compared to run ADRs in SCCM.
.PARAMETER Mode
    There are 2 modes of operation which will dictate which ADRs are run:
    IteratePatterns:    Will only run one pattern from the 'ADRPatterns' array per script execution. The ADRPatterns list and the position (which ADR Pattern) was used last execution is saved in a separate file.
                        If ADRPatterns is not exactly the same, the script will start at the beginning of this new list.
    RunAllPatterns:     Will run ADRs matching any of the patterns in 'ADRPatterns'.
#>
[CmdletBinding(SupportsShouldProcess=$True,DefaultParameterSetName="configfile")]
Param(
    #Set the log file.
    [Parameter(ParameterSetName='cmdline')]
    [string]$LogFile,

    #The maximum size of the log in bytes.
    [Parameter(ParameterSetName='cmdline')]
    [int]$MaxLogSize = 2621440,

    #Define a list of ADR patterns (ex: @('*Deployment A','*Deployment B'")
    [Parameter(ParameterSetName='cmdline')]
    [ValidateNotNullorEmpty()]
    [string[]]$ADRPatterns,

    #Define if the script should iterate through the different patterns by executing 1 pattern per script execution
    #IteratePatterns: Will only run one pattern from the ADRPatterns per script execution. The last pattern executed is saved at the end of the script execution.
    #RunAllPatterns: Will run ADRs matching any of the patterns in ADRPatterns.
    [Parameter(ParameterSetName='cmdline')]
    [ValidateSet("IteratePatternsBetweenExecutions","RunAllPatterns")]
    [ValidateNotNullorEmpty()]
    [string]$Mode = "IteratePatternsBetweenExecutions",

    [Parameter(ParameterSetName='cmdline')]
    [ValidateNotNull()]
    [switch]$DeleteSUGBeforeRunningADR,

    #Define a configuration file.
    [Parameter(ParameterSetName='configfile')]
    [string]$ConfigFile
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
Function Invoke-CMSyncCheck {
##########################################################################################################
<#
.SYNOPSIS
   Invoke a synchronization check on all software update points.

.DESCRIPTION
   When ran this function will wait for the software update point synchronization process to complete
   successfully before continuing.

.EXAMPLE
   Invoke-CMSyncCheck
   Check the ConfigMgr sync status with the default 5 minute lead time.

#>
##########################################################################################################
    [CmdletBinding()]
    Param(
        #The number of minutes to wait after the last sync to run the wizard.
        [int]$SyncLeadTime = 5
    )

    $WaitInterval = 0 #Used to skip the initial wait cycle if it isn't necessary.
    Do{

        #Wait until the loop has iterated once.
        If ($WaitInterval -gt 0){
            Add-TextToCMLog $LogFile "Waiting $TimeToWait minutes for lead time to pass before executing." $component 1
            Start-Sleep -Seconds ($WaitInterval)
        }

        #Loop through each SUP and wait until they are all done syncing.
        Do {
            #If synchronizing then wait.
            If($Synchronizing){
                Add-TextToCMLog $LogFile "Waiting for software update points to stop syncing." $component 1
                Start-Sleep -Seconds (300)
            }

            $Synchronizing = $False
            ForEach ($softwareUpdatePointSyncStatus in Get-CMSoftwareUpdateSyncStatus){
                If($softwareUpdatePointSyncStatus.LastSyncState -eq 6704){$Synchronizing = $True}
            }
        } Until(!$Synchronizing)


        #Loop through each SUP, calculate the last sync time, and make sure that they all synced successfully.
        $syncTimeStamp = Get-Date "1/1/2001 12:00 AM"
        ForEach ($softwareUpdatePointSyncStatus in Get-CMSoftwareUpdateSyncStatus){
            If ($softwareUpdatePointSyncStatus.LastSyncErrorCode -ne 0){
                Add-TextToCMLog $LogFile "The software update point $($softwareUpdatePointSyncStatus.WSUSServerName) failed its last synchronization with error code $($softwareUpdatePointSyncStatus.LastSyncErrorCode)." $component 3
                Add-TextToCMLog $LogFile "Aborting..." $component 3
                Exit 1
            }

            If ($syncTimeStamp -lt $softwareUpdatePointSyncStatus.LastSyncStateTime) {
                $syncTimeStamp = $softwareUpdatePointSyncStatus.LastSyncStateTime
            }
        }


        #Calculate the remaining time to wait for the lead time to expire.
        $TimeToWait = ($syncTimeStamp.AddMinutes($SyncLeadTime) - (Get-Date)).Minutes

        #Set the wait interval in seconds for subsequent loops.
        $WaitInterval = 300
    } Until ($TimeToWait -le 0)

    Add-TextToCMLog $LogFile "Software update point synchronization states confirmed." $component 1
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

Function Confirm-StringArray {
##########################################################################################################
<#
.SYNOPSIS
   Confirm that the string is not actually an array.

.DESCRIPTION
   If a string array is passed with a single element containing commas then split the string into an array.

#>
##########################################################################################################
    Param(
        [string[]] $StringArray
    )

    If ($StringArray){
        If ($StringArray.Count -eq 1){
            If ($StringArray[0] -ilike '*,*'){
                $StringArray = $StringArray[0].Split(",")
                Add-TextToCMLog $LogFile "The string array only had one element that contained commas.  It has been split into $($StringArray.Count) separate elements." $component 2
            }
        }
    }
    Return $StringArray
}
##########################################################################################################

Function Invoke-ADRWithPattern{
<#
.SYNOPSIS
   This function will run the automatic deployment rules with a name that contains the specified pattern

.DESCRIPTION
   The function will run each ADR matching the specified pattern one at a time and wait for its successful completion to prevent issues
   when mutliple ADRs run at the same time.

.PARAMETER Pattern
    A string value that the function will perform a -like against the name of all currently enabled ADR.

.PARAMETER WaitSeconds
    A number of seconds to wait to check if a running ADR has ended.
#>
    Param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$Pattern,
        [Parameter()]
        [int]$WaitSeconds = 60
    )

    Add-TextToCMLog $LogFile "Running Automatic Deployment Rules with names like `"$($Pattern)`"." $component 1
    $ADRs = Get-CMSoftwareUpdateAutoDeploymentRule -Fast | Where-Object {$_.Name -like $Pattern -and $_.AutoDeploymentEnabled -eq $True}
    if($ADRs){
        #If an ADR fails to run, retry for $MaxRetryCount times
        $MaxRetryCount = 10

        #Wait $SecondsBetweenRuns before retrying to run an ADR
        $SecondsBetweenRuns = 300

        foreach($adr in $ADRs){
            $RunCount = 0
            $RanSuccessfully = $false
            do{
                $RunCount++
                #Run the ADR
                Try{
                    Add-TextToCMLog $LogFile "Running Automatic Deployment Rule `"$($adr.Name)`"." $component 1
                    $Running = $true
                    #Getting LastRunTime before starting the ADR
                    Remove-Variable -Name "lastRunTime" -ErrorAction Ignore
                    $lastRunTime = (Get-CMSoftwareUpdateAutoDeploymentRule -Id ($adr.AutoDeploymentID) -Fast).LastRunTime

                    #Handle ADRs that never ran before
                    if($null -eq $lastRunTime){
                        [datetime]$lastRunTime = [datetime]"1970-01-01"
                    }else{
                        [datetime]$lastRunTime = $lastRunTime
                    }

                    If($DeleteSUGBeforeRunningADR){
                        Add-TextToCMLog $LogFile "Removing SUG `"$($adr.Name)`" before running the ADR." $component 1
                        Get-CMSoftwareUpdateGroup -Name ($adr.Name) | Remove-CMSoftwareUpdateGroup -Force
                    }

                    Invoke-CMSoftwareUpdateAutoDeploymentRule -Id ($adr.AutoDeploymentID)

                    #Wait until the ADR run successfully.
                    Do {
                        Remove-Variable -Name "newLastRunTime" -ErrorAction Ignore
                        $newLastRunTime = (Get-CMSoftwareUpdateAutoDeploymentRule -Id $adr.AutoDeploymentID -Fast).LastRunTime

                        if($null -ne $newLastRunTime){#Handle ADRs that never ran before
                            [datetime]$newLastRunTime = [datetime]$newLastRunTime
                            if($lastRunTime -ne $newLastRunTime){
                                $Running = $false
                            }
                        }

                        If($Running){
                            Add-TextToCMLog $LogFile "Waiting $($WaitSeconds) seconds for ADR `"$($adr.Name)`" to stop running..." $component 1
                            Start-Sleep -Seconds $WaitSeconds
                        }
                    } Until(!$Running)

                    $adr = Get-CMSoftwareUpdateAutoDeploymentRule -Id $adr.AutoDeploymentID -Fast
                    If($adr.LastErrorCode -eq 0){
                        Add-TextToCMLog $LogFile "Automatic Deployment Rule `"$($adr.Name)`" ran successfully." $component 1
                        $RanSuccessfully = $true
                    }Else{
                        Add-TextToCMLog $LogFile "Automatic Deployment Rule `"$($adr.Name)`" did not run successfully. Error code is `"$($adr.LastErrorCode)`"." $component 2
                        if($RunCount -lt $MaxRetryCount){
                            Add-TextToCMLog $LogFile "Waiting $($SecondsBetweenRuns) seconds before retrying to run ADR... (Run count = $($RunCount))" $component 2
                            Start-Sleep -Seconds $SecondsBetweenRuns
                        }
                    }
                }Catch{
                    Add-TextToCMLog $LogFile "Failed to run Automatic Deployment Rule." $component 3
                    Add-TextToCMLog $LogFile "Error: $($_.Exception.HResult): $($_.Exception.Message)" $component 3
                    Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
                    Exit $($_.Exception.HResult)
                }
            } until($RanSuccessfully -or ($RunCount -eq $MaxRetryCount))

            if(!$RanSuccessfully){
                Add-TextToCMLog $LogFile "Failed to run Automatic Deployment Rule." $component 3
                Exit 1
            }
        }
    }else{
        Add-TextToCMLog $LogFile "Could not find any enabled Automatic Deployment Rules with names like `"$($Pattern)`"." $component 2
    }
}
##########################################################################################################
#endregion Functions

$scriptVersion = "0.4"
$component = 'Invoke-RunADRs'
$scriptPath = split-path -parent $MyInvocation.MyCommand.Definition

#region Parameter validation

#If using a configuration file.
If ($PSCmdlet.ParameterSetName -eq 'configfile' -and [string]::IsNullOrEmpty($ConfigFile)){
        $ConfigFile = Join-Path $scriptPath 'config.ini'
        Write-Verbose "No parameters were found.  Using default configuration file"
}

#If a configuration file was specified the read the parameters from the file.
If ($ConfigFile){

    #Resolve the path if it's relative.
    Try{
        $ConfigFilePath = Resolve-Path ($ConfigFile) -ErrorAction Stop
        Write-Verbose "Configuration File: $ConfigFilePath"
        $ConfigFile=$ConfigFilePath
    }
    Catch{
        Write-Error "Could not resolve the the path to the configuration file '$ConfigFile'"
        Exit
    }

    If (Test-path  $ConfigFile -PathType Leaf) {

        #Try loading the configuration file content.
        Try{
            $FileContent = Get-Content $ConfigFile
        }
        Catch {
            Write-Error "The configuration file '$ConfigFile' cannot be read."
            Exit
        }

        #Loop through each line splitting on the first equal sign.
        ForEach ($Line in $FileContent){

            #Skip lines that are empty, INI comments, or INI sections.
            If ([string]::IsNullOrEmpty($Line) -or (@('[',';',' ') -contains $Line[0])){Continue}

            #Split the line on the first equal sign and clean up the name.
            $Data = $Line.Split("=",2)
            $Data[0]=$Data[0].Trim()

            #If there's no value then treat it like a switch.  Otherwise, process the value.
            If($Data.Count -eq 2){
                If ($Data[0] -eq 'SiteCode') { #force a numeric SiteCode to be a string
                    $Data[1]=[string]$Data[1].Trim()
                } Else {
                    $Data[1]=$Data[1].Trim()
                }
                #Try to evaluate the value as an expression otherwise use the value as-is.
		Write-Verbose -Message "trying to Set Variable [$($Data[0])] to [$($Data[1])]"
                Try{
                    If ($Data[0] -eq 'SiteCode') { #force a numeric SiteCode to be a string
                        Set-Variable -Name $Data[0] -Value ($Data[1] -as [string]) -Force -WhatIf:$False
                    } ElseIf ($Data[1] -match "^@.") {
                        Set-Variable -Name $Data[0] -Value (Invoke-Expression $Data[1]) -Force -WhatIf:$False
                    } ElseIf ($Data[1] -match "^[0-9]*$") { #case where entire value is numeric
                        Set-Variable -Name $Data[0] -Value ($Data[1] -as [int]) -Force -WhatIf:$False
                    } Else {
                        Set-Variable -Name $Data[0] -Value ($Data[1] -as [string]) -Force -WhatIf:$False
                    }                }
                Catch{
                    Set-Variable -Name $Data[0] -Value $Data[1] -Force -WhatIf:$False
                }
            }
            ElseIf ($Data.Count -eq 1) {
                Set-Variable -Name $Data[0] -Value $True -Force -WhatIf:$False
            }
            Write-Verbose "Parameter $((Get-Variable $Data[0]).Name) is set to $((Get-Variable $Data[0]).Value) and is of [$($((Get-Variable $Data[0]).Value.GetType()))] type."
        }
    }
    Else{
        Write-Error "The configuration file '$ConfigFile' cannot be found."
        Exit
    } #Config file exists.
} #If config file was passed.

#If log file is null then set it to the default and then make the provider type explicit.
If (!$LogFile) {
    $LogFile = Join-Path $scriptPath "runadrs.log"
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

#endregion Parameter validation

#Check to make sure we're running this on a primary site server that has the SMS namespace.
If (!(Get-Wmiobject -namespace "Root" -class "__Namespace" -Filter "Name = 'SMS'")){
    Add-TextToCMLog $LogFile "Currently, this script must be ran on a primary site server." $component 3
    Exit 1
}

#Change the directory to the site location.
$OriginalLocation = Get-Location

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

#1 - Check if the last SCCM software update sync was successful.
#Invoke-CMSyncCheck

#2 - Determine which pattern(s) will be used to run ADRs
$ADRPatterns = Confirm-StringArray $ADRPatterns

Add-TextToCMLog $LogFile "Mode selected is `"$($Mode)`"." $component 1
If($Mode -eq "IteratePatternsBetweenExecutions"){
    Add-TextToCMLog $LogFile "Script will try and find the next ADR Pattern to use to run ADRs." $component 1

    Add-TextToCMLog $LogFile "Checking if the last pattern used by script was recorded." $component 1
    $lastran_ADRPatternsPath = "filesystem::$(Join-Path $scriptPath "lastran_ADRPatterns.xml")"
    If(Test-Path -Path $lastran_ADRPatternsPath){
        Try{
            $lastran_ADRPatterns = Import-Clixml $lastran_ADRPatternsPath
        }Catch{
            Add-TextToCMLog $LogFile  "Could not load previous run information." $component 2
            Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 2
            Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 2
        }

        Try{
            $diff = Compare-Object -ReferenceObject $lastran_ADRPatterns.ADRPatterns -DifferenceObject $ADRPatterns -SyncWindow 0
            If($diff){
                Add-TextToCMLog $LogFile  "The lists of ADR patterns are different, using the first entry in `$ADRPatterns" $component 2
                $Position = 0
            }else{#The 2 lists are the same, they did not change between the last 2 runs.
                Add-TextToCMLog $LogFile "The lists of ADR patterns did not change since the last successful execution." $component 1
                Add-TextToCMLog $LogFile "The last pattern used was $(($lastran_ADRPatterns.ADRPatterns)[$($lastran_ADRPatterns.Position)])." $component 1
                $Position = $($lastran_ADRPatterns.Position+1) % $($ADRPatterns.Length)
            }
        }Catch{
            Add-TextToCMLog $LogFile  "Failed to compare previous list and the current list of patterns." $component 2
        }
    }
    If(($null -eq $diff) -and ($null -eq $Position)){
        Add-TextToCMLog $LogFile "Could not determine the last pattern used, will use the first pattern in the list." $component 2
        $Position = 0
    }

    $pattern = ($ADRPatterns)[$Position]
    Add-TextToCMLog $LogFile "The pattern that will be used to run ADRs on this run will be `"$pattern`"" $component 1

    Invoke-ADRWithPattern -Pattern $pattern -WaitSeconds 60

    $lastran_Patterns = New-Object -TypeName PSObject
    $lastran_Patterns | Add-Member -MemberType NoteProperty -Name Position -Value $Position
    $lastran_Patterns | Add-Member -MemberType NoteProperty -Name ADRPatterns -Value $ADRPatterns
    Try{
        Add-TextToCMLog $LogFile "Saving list of pattern and position of the last pattern used for next run." $component 1
        $lastran_Patterns | Export-Clixml -Path $lastran_ADRPatternsPath -WhatIf:$WhatIfPreference -ErrorAction Stop
    }Catch{
        Add-TextToCMLog $LogFile  "Failed to save last run information." $component 3
        Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
        Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
        Exit $($_.Exception.HResult)
    }


}ElseIf($Mode -eq "RunAllPatterns"){
    Add-TextToCMLog $LogFile "Script will run ADRs matching all patterns provided in `$ADRPatterns." $component 1

    Foreach($pattern in $ADRPatterns){
        Invoke-ADRWithPattern -Pattern $pattern -WaitSeconds 60
    }
    Add-TextToCMLog $LogFile "Not saving list of patterns used because we ran in `"RunAllPatterns`" mode." $component 1
}

Add-TextToCMLog $LogFile "$component finished." $component 1
Set-Location $OriginalLocation