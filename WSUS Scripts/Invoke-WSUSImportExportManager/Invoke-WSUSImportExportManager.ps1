<#
.SYNOPSIS
The purpose of this script is to handle the export/import process for WSUS without internet connectivity.
WSUS with Internet connectivity will use this script to perform an EXPORT to get: WSUS Content, WSUS Metadata, WSUS Configuration XML file
WSUS without internet connectivity will use this script to perform an IMPORT and get same updates, WSUS Configuration and update approvals as the internet connected WSUS


.DESCRIPTION
The script can be used to export and import the configuration, metadata and content from a WSUS server.
A simple metadata export does not include which updates were approved or not. By using this script, we can export this information too and "sync" which updates are approved to what computer groups in WSUS.
If you want a change to persist on your disconnected WSUS instances, you will have to make the changes on the internet-connected WSUS server where we perform the export.
#>

[CmdletBinding()]
Param(
    #Define a configuration file.
    [Parameter(Mandatory=$True, HelpMessage='Path to XML Configuration File')]
    [ValidateScript({Test-Path -Path $_ -PathType Leaf})]
    [ValidatePattern('.xml$')]
    [string]$ConfigFile
)

#region Functions

#Taken from https://damgoodadmin.com/2017/11/05/fully-automate-software-update-maintenance-in-cm/
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

#Taken from https://damgoodadmin.com/2017/11/05/fully-automate-software-update-maintenance-in-cm/
Function Invoke-WSUSSyncCheck {
##########################################################################################################
<#
.SYNOPSIS
   Invoke a synchronization check on the passed in WSUS server.
.DESCRIPTION
   When ran this function will wait for the WSUS synchronization process to complete
   successfully before continuing.

.EXAMPLE
   Invoke-WSUSSyncCheck -WSUSServer $WSUSServer -SyncLeadTime 0
   Check the WSUS server sync status with zero lead time.

#>
##########################################################################################################
    [CmdletBinding()]
    Param(
        #A WSUS server object.
        [Parameter(Mandatory=$true)]
        [Microsoft.UpdateServices.Administration.IUpdateServer] $WSUSServer,

        #The number of minutes to wait after the last sync to run the wizard.
        [int]$SyncLeadTime = 5
    )

    #Get the WSUS subscription.
    Try{
        $WSUSSubscription = $WSUSServer.GetSubscription()
    }
    Catch{
        Add-TextToCMLog $LogFile "Failed to get the subscription for the WSUS server to check the sync status." $component 3
        Add-TextToCMLog $LogFile "Error: $($_.Exception.Message)" $component 3
        Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
        Exit $($_.Exception.HResult)
    }

    If (!$WSUSSubscription)
    {
        Add-TextToCMLog $LogFile "Failed to get the subscription for the WSUS server to check the sync status." $component 3
        Exit 1
    }

    $WaitInterval = 0 #Used to skip the initial wait cycle if it isn't necessary.
    Do{

        #Wait until the loop has iterated once.
        If ($WaitInterval -gt 0){
            Add-TextToCMLog $LogFile "Waiting $TimeToWait minutes for lead time to pass before executing." $component 1
            Start-Sleep -Seconds ($WaitInterval)
        }

        #If the WSUS server is synchronizing then wait for it to finish.
        Do {
            #If syncronizing then wait.
            If($Syncronizing){
                Add-TextToCMLog $LogFile "Waiting for WSUS server to stop syncing." $component 1
                Start-Sleep -Seconds (300)
            }

            #Get the synchronization status.
            Try{
                $Syncronizing = ($WSUSSubscription.GetSynchronizationStatus() -eq [Microsoft.UpdateServices.Administration.SynchronizationStatus]::Running)
            }
            Catch{
                Add-TextToCMLog $LogFile "Failed to get the synchronization status for the WSUS server." $component 3
                Add-TextToCMLog $LogFile "Error: $($_.Exception.Message)" $component 3
                Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
                Exit $($_.Exception.HResult)
            }
        } Until(!$Syncronizing)


        #Determine if the sync status was successful.
        Try{
            $WSUSLastSyncInfo = $WSUSSubscription.GetLastSynchronizationInfo()
        }
        Catch{
            Add-TextToCMLog $LogFile "Failed to get the synchronization info for the WSUS server." $component 3
            Add-TextToCMLog $LogFile "Error: $($_.Exception.Message)" $component 3
            Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
            Exit $($_.Exception.HResult)
        }

        If(!$WSUSLastSyncInfo){
            Add-TextToCMLog $LogFile "Failed to get the synchronization info for the WSUS server." $component 3
            Exit 1
        }

        If ($WSUSLastSyncInfo.Result -eq [Microsoft.UpdateServices.Administration.SynchronizationResult]::Failed){
            Add-TextToCMLog $LogFile "The WSUS server failed its last synchronization with error code $($WSUSLastSyncInfo.Error): $($WSUSLastSyncInfo.ErrorText)" $component 3
            Add-TextToCMLog $LogFile "Synchronize successfully before running the script." $component 3
            Exit 1
        }

        #Calculate the remaining time to wait for the lead time to expire.
        $TimeToWait = (($WSUSLastSyncInfo.EndTime).AddMinutes($SyncLeadTime) - ((Get-Date).ToUniversalTime())).Minutes

        #Set the wait interval in seconds for subsequent loops.
        $WaitInterval = 300
    } Until ($TimeToWait -le 0)

    Add-TextToCMLog $LogFile "WSUS server synchronization state confirmed." $component 1
}
##########################################################################################################

#Taken from https://stackoverflow.com/questions/5648931/test-if-registry-value-exists
Function Test-RegistryValue {
##########################################################################################################
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
            If ($null -ne $Key.GetValue($Value, $null)) {
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

#Taken from https://damgoodadmin.com/2017/11/05/fully-automate-software-update-maintenance-in-cm/
Function Get-WSUSDB{
##########################################################################################################
<#
.SYNOPSIS
   Get the WSUS database configuration.

.DESCRIPTION
   Use the WSUS api to get the database configuration and verify that you can successfully connect to the DB.

#>
##########################################################################################################

    Param(
        [Parameter(Mandatory=$true)]
        [Microsoft.UpdateServices.Administration.IUpdateServer] $WSUSServer
    )

    Try{
        $WSUSServerDB = $WSUSServer.GetDatabaseConfiguration()
    }
    Catch{
        Add-TextToCMLog $LogFile "Failed to get the WSUS database details from the active SUP." $component 3
        Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
        Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
        Exit $($_.Exception.HResult)
    }

    If (!($WSUSServerDB)){
        Add-TextToCMLog $LogFile "Failed to get the WSUS database details from the active SUP." $component 3
        Exit 1
    }

    #This is a just a test built into the API, it's not actually making the connection we'll use.
    Try{
        $WSUSServerDB.ConnectToDatabase()
        Add-TextToCMLog $LogFile "Successfully tested the connection to the ($($WSUSServerDB.DatabaseName)) database on $($WSUSServerDB.ServerName)." $component 1
    }
    Catch{
        Add-TextToCMLog $LogFile "Failed to connect to the ($($WSUSServerDB.DatabaseName)) database on $($WSUSServerDB.ServerName)." $component 3
        Add-TextToCMLog $LogFile "Error ($($_.Exception.HResult)): $($_.Exception.Message)" $component 3
        Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
        Exit $($_.Exception.HResult)
    }

    Return $WSUSServerDB

}
##########################################################################################################

#Taken from https://damgoodadmin.com/2017/11/05/fully-automate-software-update-maintenance-in-cm/
Function Connect-WSUSDB{
##########################################################################################################
<#
.SYNOPSIS
   Connect to the WSUS database.

.DESCRIPTION
   Use the database configuration to connect to the DB.

.NOTE
    Function modified because PoshWSUS returns IsUsingWindowsInternalDatabase to $false even though it is.

#>
##########################################################################################################

    Param(
        [Parameter(Mandatory=$true)]
        [Microsoft.UpdateServices.Administration.IDatabaseConfiguration] $WSUSServerDB
    )

    #Determine the connection string based on the type of DB being used.
    If ($WSUSServerDB.IsUsingWindowsInternalDatabase){
        #Using the Windows Internal Database.  Come one dawg . just stop this insanity and migrate this to SQL.
        If($WSUSServerDB.ServerName -eq "MICROSOFT##WID"){
            $SqlConnectionString = "Data Source=\\.\pipe\MICROSOFT##WID\tsql\query;Integrated Security=True;Network Library=dbnmpntw"
        }
        Else{
            $SqlConnectionString = "Data Source=\\.\pipe\microsoft##ssee\sql\query;Integrated Security=True;Network Library=dbnmpntw"
        }
    }
    Else{
        #Connect to a real SQL database.
        $SqlConnectionString = "Server=$($WSUSServerDB.ServerName);Database=$($WSUSServerDB.DatabaseName);Integrated Security=True"
    }

    #Try to connect to the database.
    Try{
        $SqlConnection = New-Object System.Data.SqlClient.SqlConnection($SqlConnectionString)
	    $SqlConnection.Open()
        Add-TextToCMLog $LogFile "Successfully connected to the database." $component 1
    }
    Catch{
        Add-TextToCMLog $LogFile "Failed to connect to the database using the connection string $($SqlConnectionString)." $component 3
        Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
        Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
        Exit $($_.Exception.HResult)
    }

    Return $SqlConnection
}
##########################################################################################################

#Taken from https://damgoodadmin.com/2017/11/05/fully-automate-software-update-maintenance-in-cm/
Function Invoke-SQLCMD{
##########################################################################################################
<#
.SYNOPSIS
   Run the SQL query passed and return the resulting data table.

.DESCRIPTION
   Run the SQL query passed and return the resulting data table.

#>
##########################################################################################################
    [OutputType([System.Data.DataTable])]
    Param(
        [Parameter(Mandatory=$true)]
        [System.Data.SqlClient.SqlConnection] $SqlConnection,

        [Parameter(Mandatory=$true)]
        [string] $SqlCommand
    )

    Try{
        $SqlCmd = $SqlConnection.CreateCommand()
        $SqlCmd.CommandTimeout = 86400 #24 hours
        $SqlCmd.CommandText = $SqlCommand
        $SqlDataAdapter = New-Object System.Data.SqlClient.SqlDataAdapter($SqlCmd)
        [System.Data.DataTable] $DataTable = New-Object System.Data.DataTable
        [void]$SqlDataAdapter.Fill($DataTable)
        Return ,$DataTable #Force an array otherwise Powershell will return a DataRow instead of a DataTable if there's only one row.
    }
    Catch{
        Add-TextToCMLog $LogFile "Failed to run the sql command: $SqlCommand." $component 3
        Add-TextToCMLog $LogFile "Error ($($_.Exception.HResult)): $($_.Exception.Message)" $component 3
        Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
        Exit $($_.Exception.HResult)
    }
}
##########################################################################################################

Function Get-WSUSUpdates{
##########################################################################################################
<#
.SYNOPSIS
   Get all the updates from the WSUS Server and retries in case of an error when getting updates.

.DESCRIPTION
   Use the WSUS api to get all the updates and will retry according to $MaxRetries and wait $SecondsBetweenRetries.

#>
##########################################################################################################

    Param(
        [Parameter(Mandatory=$true)]
        [Microsoft.UpdateServices.Administration.IUpdateServer] $WSUSServer,
        [Parameter()]
        [int] $MaxRetries = 10, #How many time do we retry before we give up.
        [Parameter()]
        [int] $SecondsBetweenRetries = 300 #How much time do we wait between retries.
    )

    [bool]$RetrievedUpdates = $false

    [int]$RetryCount = 0
    While(!$RetrievedUpdates -and ($RetryCount -lt $MaxRetries)){
        Try{
            $updates = $WSUSServer.GetUpdates()
            if($Updates){
                $RetrievedUpdates = $true
            }
        }Catch{
            Add-TextToCMLog $LogFile "Failed to get updates from WSUS Server." $component 2
            Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 2
            Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 2
			Add-TextToCMLog $LogFile "Waiting $($SecondsBetweenRetries) seconds before retrying..." $component 2
            $RetryCount++
            Start-Sleep -Seconds $SecondsBetweenRetries
        }
    }
    If($RetrievedUpdates){
        Return $updates
    }Else{
        Add-TextToCMLog $LogFile "Failed to get updates from WSUS Server." $component 3
        Exit 1
    }
}
##########################################################################################################

function Invoke-Sqlcmd2 {
    <#
        .SYNOPSIS
            Runs a T-SQL script.

        .DESCRIPTION
            Runs a T-SQL script. Invoke-Sqlcmd2 runs the whole script and only captures the first selected result set, such as the output of PRINT statements when -verbose parameter is specified.
            Parameterized queries are supported.

            Help details below borrowed from Invoke-Sqlcmd

        .PARAMETER ServerInstance
            Specifies the SQL Server instance(s) to execute the query against.

        .PARAMETER Database
            Specifies the name of the database to execute the query against. If specified, this database will be used in the ConnectionString when establishing the connection to SQL Server.

            If a SQLConnection is provided, the default database for that connection is overridden with this database.

        .PARAMETER Query
            Specifies one or more queries to be run. The queries can be Transact-SQL, XQuery statements, or sqlcmd commands. Multiple queries in a single batch may be separated by a semicolon.

            Do not specify the sqlcmd GO separator (or, use the ParseGo parameter). Escape any double quotation marks included in the string.

            Consider using bracketed identifiers such as [MyTable] instead of quoted identifiers such as "MyTable".

        .PARAMETER InputFile
            Specifies the full path to a file to be used as the query input to Invoke-Sqlcmd2. The file can contain Transact-SQL statements, XQuery statements, sqlcmd commands and scripting variables.

        .PARAMETER Credential
            Login to the target instance using alternative credentials. Windows and SQL Authentication supported. Accepts credential objects (Get-Credential)

            SECURITY NOTE: If you use the -Debug switch, the connectionstring including plain text password will be sent to the debug stream.

        .PARAMETER Encrypt
            If this switch is enabled, the connection to SQL Server will be made using SSL.

            This requires that the SQL Server has been set up to accept SSL requests. For information regarding setting up SSL on SQL Server, see https://technet.microsoft.com/en-us/library/ms189067(v=sql.105).aspx

        .PARAMETER QueryTimeout
            Specifies the number of seconds before the queries time out.

        .PARAMETER ConnectionTimeout
            Specifies the number of seconds before Invoke-Sqlcmd2 times out if it cannot successfully connect to an instance of the Database Engine. The timeout value must be an integer between 0 and 65534. If 0 is specified, connection attempts do not time out.

        .PARAMETER As
            Specifies output type. Valid options for this parameter are 'DataSet', 'DataTable', 'DataRow', 'PSObject', and 'SingleValue'

            PSObject output introduces overhead but adds flexibility for working with results: http://powershell.org/wp/forums/topic/dealing-with-dbnull/

        .PARAMETER SqlParameters
            Specifies a hashtable of parameters for parameterized SQL queries.  http://blog.codinghorror.com/give-me-parameterized-sql-or-give-me-death/

            Example:

        .PARAMETER AppendServerInstance
            If this switch is enabled, the SQL Server instance will be appended to PSObject and DataRow output.

        .PARAMETER ParseGo
            If this switch is enabled, "GO" statements will be handled automatically.
            Every "GO" will effectively run in a separate query, like if you issued multiple Invoke-SqlCmd2 commands.
            "GO"s will be recognized if they are on a single line, as this covers
            the 95% of the cases "GO" parsing is needed
            Note:
                Queries will always target that database, e.g. if you have this Query:
                    USE DATABASE [dbname]
                    GO
                    SELECT * from sys.tables
                and you call it via
                    Invoke-SqlCmd2 -ServerInstance instance -Database msdb -Query .
                you'll get back tables from msdb, not dbname.


        .PARAMETER SQLConnection
            Specifies an existing SQLConnection object to use in connecting to SQL Server. If the connection is closed, an attempt will be made to open it.

        .PARAMETER ApplicationName
             If specified, adds the given string into the ConnectionString's Application Name property which is visible via SQL Server monitoring scripts/utilities to indicate where the query originated.

        .PARAMETER MessagesToOutput
            Use this switch to have on the output stream messages too (e.g. PRINT statements). Output will hold the resultset too. See examples for detail
            NB: only available from Powershell 3 onwards

        .INPUTS
            String[]
                You can only pipe strings to to Invoke-Sqlcmd2: they will be considered as passed -ServerInstance(s)

        .OUTPUTS
        As PSObject:     System.Management.Automation.PSCustomObject
        As DataRow:      System.Data.DataRow
        As DataTable:    System.Data.DataTable
        As DataSet:      System.Data.DataTableCollectionSystem.Data.DataSet
        As SingleValue:  Dependent on data type in first column.

        .EXAMPLE
            Invoke-Sqlcmd2 -ServerInstance "MyComputer\MyInstance" -Query "SELECT login_time AS 'StartTime' FROM sysprocesses WHERE spid = 1"

            Connects to a named instance of the Database Engine on a computer and runs a basic T-SQL query.

            StartTime
            -----------
            2010-08-12 21:21:03.593

        .EXAMPLE
            Invoke-Sqlcmd2 -ServerInstance "MyComputer\MyInstance" -InputFile "C:\MyFolder\tsqlscript.sql" | Out-File -filePath "C:\MyFolder\tsqlscript.rpt"

            Reads a file containing T-SQL statements, runs the file, and writes the output to another file.

        .EXAMPLE
            Invoke-Sqlcmd2  -ServerInstance "MyComputer\MyInstance" -Query "PRINT 'hello world'" -Verbose

            Uses the PowerShell -Verbose parameter to return the message output of the PRINT command.
            VERBOSE: hello world

        .EXAMPLE
            Invoke-Sqlcmd2 -ServerInstance MyServer\MyInstance -Query "SELECT ServerName, VCNumCPU FROM tblServerInfo" -as PSObject | ?{$_.VCNumCPU -gt 8}
            Invoke-Sqlcmd2 -ServerInstance MyServer\MyInstance -Query "SELECT ServerName, VCNumCPU FROM tblServerInfo" -as PSObject | ?{$_.VCNumCPU}

            This example uses the PSObject output type to allow more flexibility when working with results.

            If we used DataRow rather than PSObject, we would see the following behavior:
                Each row where VCNumCPU does not exist would produce an error in the first example
                Results would include rows where VCNumCPU has DBNull value in the second example

        .EXAMPLE
            'Instance1', 'Server1/Instance1', 'Server2' | Invoke-Sqlcmd2 -query "Sp_databases" -as psobject -AppendServerInstance

            This example lists databases for each instance.  It includes a column for the ServerInstance in question.
                DATABASE_NAME          DATABASE_SIZE REMARKS        ServerInstance
                -------------          ------------- -------        --------------
                REDACTED                       88320                Instance1
                master                         17920                Instance1
                .
                msdb                          618112                Server1/Instance1
                tempdb                        563200                Server1/Instance1
                .
                OperationsManager           20480000                Server2

        .EXAMPLE
            #Construct a query using SQL parameters
                $Query = "SELECT ServerName, VCServerClass, VCServerContact FROM tblServerInfo WHERE VCServerContact LIKE @VCServerContact AND VCServerClass LIKE @VCServerClass"

            #Run the query, specifying values for SQL parameters
                Invoke-Sqlcmd2 -ServerInstance SomeServer\NamedInstance -Database ServerDB -query $query -SqlParameters @{ VCServerContact="%cookiemonster%"; VCServerClass="Prod" }

                ServerName    VCServerClass VCServerContact
                ----------    ------------- ---------------
                SomeServer1   Prod          cookiemonster, blah
                SomeServer2   Prod          cookiemonster
                SomeServer3   Prod          blah, cookiemonster

        .EXAMPLE
            Invoke-Sqlcmd2 -SQLConnection $Conn -Query "SELECT login_time AS 'StartTime' FROM sysprocesses WHERE spid = 1"

            Uses an existing SQLConnection and runs a basic T-SQL query against it

            StartTime
            -----------
            2010-08-12 21:21:03.593

        .EXAMPLE
            Invoke-SqlCmd2 -SQLConnection $Conn -Query "SELECT ServerName FROM tblServerInfo WHERE ServerName LIKE @ServerName" -SqlParameters @{"ServerName = "c-is-hyperv-1"}

            Executes a parameterized query against the existing SQLConnection, with a collection of one parameter to be passed to the query when executed.

        .EXAMPLE
            Invoke-Sqlcmd2 -ServerInstance "MyComputer\MyInstance" -Query "PRINT 1;SELECT login_time AS 'StartTime' FROM sysprocesses WHERE spid = 1" -Verbose

            Sends "messages" to the Verbose stream, the output stream will hold the results

        .EXAMPLE
            Invoke-Sqlcmd2 -ServerInstance "MyComputer\MyInstance" -Query "PRINT 1;SELECT login_time AS 'StartTime' FROM sysprocesses WHERE spid = 1" -MessagesToOutput

            Sends "messages" to the output stream (irregardless of -Verbose). If you need to "separate" the results, inspecting the type gets really handy:
                    $results = Invoke-Sqlcmd2 -ServerInstance . -MessagesToOutput
                    $tableResults = $results | Where-Object { $_.GetType().Name -eq 'DataRow' }
                    $messageResults = $results | Where-Object { $_.GetType().Name -ne 'DataRow' }


        .NOTES
            Changelog moved to CHANGELOG.md:

            https://github.com/sqlcollaborative/Invoke-SqlCmd2/blob/master/CHANGELOG.md

        .LINK
            https://github.com/sqlcollaborative/Invoke-SqlCmd2

        .LINK
            https://github.com/RamblingCookieMonster/PowerShell

        .FUNCTIONALITY
            SQL
    #>

    [CmdletBinding(DefaultParameterSetName = 'Ins-Que')]
    [OutputType([System.Management.Automation.PSCustomObject], [System.Data.DataRow], [System.Data.DataTable], [System.Data.DataTableCollection], [System.Data.DataSet])]
    param (
        [Parameter(ParameterSetName = 'Ins-Que',
            Position = 0,
            Mandatory = $true,
            ValueFromPipeline = $true,
            ValueFromPipelineByPropertyName = $true,
            ValueFromRemainingArguments = $false,
            HelpMessage = 'SQL Server Instance required.')]
        [Parameter(ParameterSetName = 'Ins-Fil',
            Position = 0,
            Mandatory = $true,
            ValueFromPipeline = $true,
            ValueFromPipelineByPropertyName = $true,
            ValueFromRemainingArguments = $false,
            HelpMessage = 'SQL Server Instance required.')]
        [Alias('Instance', 'Instances', 'ComputerName', 'Server', 'Servers', 'SqlInstance')]
        [ValidateNotNullOrEmpty()]
        [string[]]$ServerInstance,
        [Parameter(Position = 1,
            Mandatory = $false,
            ValueFromPipelineByPropertyName = $true,
            ValueFromRemainingArguments = $false)]
        [string]$Database,
        [Parameter(ParameterSetName = 'Ins-Que',
            Position = 2,
            Mandatory = $true,
            ValueFromPipelineByPropertyName = $true,
            ValueFromRemainingArguments = $false)]
        [Parameter(ParameterSetName = 'Con-Que',
            Position = 2,
            Mandatory = $true,
            ValueFromPipelineByPropertyName = $true,
            ValueFromRemainingArguments = $false)]
        [string]$Query,
        [Parameter(ParameterSetName = 'Ins-Fil',
            Position = 2,
            Mandatory = $true,
            ValueFromPipelineByPropertyName = $true,
            ValueFromRemainingArguments = $false)]
        [Parameter(ParameterSetName = 'Con-Fil',
            Position = 2,
            Mandatory = $true,
            ValueFromPipelineByPropertyName = $true,
            ValueFromRemainingArguments = $false)]
        [ValidateScript( { Test-Path -LiteralPath $_ })]
        [string]$InputFile,
        [Parameter(ParameterSetName = 'Ins-Que',
            Position = 3,
            Mandatory = $false,
            ValueFromPipelineByPropertyName = $true,
            ValueFromRemainingArguments = $false)]
        [Parameter(ParameterSetName = 'Ins-Fil',
            Position = 3,
            Mandatory = $false,
            ValueFromPipelineByPropertyName = $true,
            ValueFromRemainingArguments = $false)]
        [Alias('SqlCredential')]
        [System.Management.Automation.PSCredential]$Credential,
        [Parameter(ParameterSetName = 'Ins-Que',
            Position = 4,
            Mandatory = $false,
            ValueFromRemainingArguments = $false)]
        [Parameter(ParameterSetName = 'Ins-Fil',
            Position = 4,
            Mandatory = $false,
            ValueFromRemainingArguments = $false)]
        [switch]$Encrypt,
        [Parameter(Position = 5,
            Mandatory = $false,
            ValueFromPipelineByPropertyName = $true,
            ValueFromRemainingArguments = $false)]
        [Int32]$QueryTimeout = 600,
        [Parameter(ParameterSetName = 'Ins-Fil',
            Position = 6,
            Mandatory = $false,
            ValueFromPipelineByPropertyName = $true,
            ValueFromRemainingArguments = $false)]
        [Parameter(ParameterSetName = 'Ins-Que',
            Position = 6,
            Mandatory = $false,
            ValueFromPipelineByPropertyName = $true,
            ValueFromRemainingArguments = $false)]
        [Int32]$ConnectionTimeout = 15,
        [Parameter(Position = 7,
            Mandatory = $false,
            ValueFromPipelineByPropertyName = $true,
            ValueFromRemainingArguments = $false)]
        [ValidateSet("DataSet", "DataTable", "DataRow", "PSObject", "SingleValue")]
        [string]$As = "DataRow",
        [Parameter(Position = 8,
            Mandatory = $false,
            ValueFromPipelineByPropertyName = $true,
            ValueFromRemainingArguments = $false)]
        [System.Collections.IDictionary]$SqlParameters,
        [Parameter(Position = 9,
            Mandatory = $false)]
        [switch]$AppendServerInstance,
        [Parameter(Position = 10,
            Mandatory = $false)]
        [switch]$ParseGO,
        [Parameter(ParameterSetName = 'Con-Que',
            Position = 11,
            Mandatory = $false,
            ValueFromPipeline = $false,
            ValueFromPipelineByPropertyName = $false,
            ValueFromRemainingArguments = $false)]
        [Parameter(ParameterSetName = 'Con-Fil',
            Position = 11,
            Mandatory = $false,
            ValueFromPipeline = $false,
            ValueFromPipelineByPropertyName = $false,
            ValueFromRemainingArguments = $false)]
        [Alias('Connection', 'Conn')]
        [ValidateNotNullOrEmpty()]
        [System.Data.SqlClient.SQLConnection]$SQLConnection,
        [Parameter(Position = 12,
            Mandatory = $false)]
        [Alias( 'Application', 'AppName' )]
        [String]$ApplicationName,
        [Parameter(Position = 13,
            Mandatory = $false)]
        [switch]$MessagesToOutput
    )

    begin {
        function Resolve-SqlError {
            param($Err)
            if ($Err) {
                if ($Err.Exception.GetType().Name -eq 'SqlException') {
                    # For SQL exception
                    #$Err = $_
                    Write-Debug -Message "Capture SQL Error"
                    if ($PSBoundParameters.Verbose) {
                        Write-Verbose -Message "SQL Error:  $Err"
                    } #Shiyang, add the verbose output of exception
                    switch ($ErrorActionPreference.ToString()) {
                        { 'SilentlyContinue', 'Ignore' -contains $_ } {   }
                        'Stop' { throw $Err }
                        'Continue' { throw $Err }
                        Default { Throw $Err }
                    }
                }
                else {
                    # For other exception
                    Write-Debug -Message "Capture Other Error"
                    if ($PSBoundParameters.Verbose) {
                        Write-Verbose -Message "Other Error:  $Err"
                    }
                    switch ($ErrorActionPreference.ToString()) {
                        { 'SilentlyContinue', 'Ignore' -contains $_ } { }
                        'Stop' { throw $Err }
                        'Continue' { throw $Err }
                        Default { throw $Err }
                    }
                }
            }

        }
        if ($InputFile) {
            $filePath = $(Resolve-Path -LiteralPath $InputFile).ProviderPath
            $Query = [System.IO.File]::ReadAllText("$filePath")
        }

        Write-Debug -Message "Running Invoke-Sqlcmd2 with ParameterSet '$($PSCmdlet.ParameterSetName)'.  Performing query '$Query'."

        if ($As -eq "PSObject") {
            #This code scrubs DBNulls.  Props to Dave Wyatt
            $cSharp = @'
                using System;
                using System.Data;
                using System.Management.Automation;

                public class DBNullScrubber
                {
                    public static PSObject DataRowToPSObject(DataRow row)
                    {
                        PSObject psObject = new PSObject();

                        if (row != null && (row.RowState & DataRowState.Detached) != DataRowState.Detached)
                        {
                            foreach (DataColumn column in row.Table.Columns)
                            {
                                Object value = null;
                                if (!row.IsNull(column))
                                {
                                    value = row[column];
                                }

                                psObject.Properties.Add(new PSNoteProperty(column.ColumnName, value));
                            }
                        }

                        return psObject;
                    }
                }
'@

            try {
                if ($PSEdition -ne 'Core'){
                    Add-Type -TypeDefinition $cSharp -ReferencedAssemblies 'System.Data', 'System.Xml' -ErrorAction stop
                } else {
                    Add-Type $cSharp -ErrorAction stop
                }


            }
            catch {
                if (-not $_.ToString() -like "*The type name 'DBNullScrubber' already exists*") {
                    Write-Warning "Could not load DBNullScrubber.  Defaulting to DataRow output: $_."
                    $As = "Datarow"
                }
            }
        }

        #Handle existing connections
        if ($PSBoundParameters.ContainsKey('SQLConnection')) {
            if ($SQLConnection.State -notlike "Open") {
                try {
                    Write-Debug -Message "Opening connection from '$($SQLConnection.State)' state."
                    $SQLConnection.Open()
                }
                catch {
                    throw $_
                }
            }

            if ($Database -and $SQLConnection.Database -notlike $Database) {
                try {
                    Write-Debug -Message "Changing SQLConnection database from '$($SQLConnection.Database)' to $Database."
                    $SQLConnection.ChangeDatabase($Database)
                }
                catch {
                    throw "Could not change Connection database '$($SQLConnection.Database)' to $Database`: $_"
                }
            }

            if ($SQLConnection.state -like "Open") {
                $ServerInstance = @($SQLConnection.DataSource)
            }
            else {
                throw "SQLConnection is not open"
            }
        }
        $GoSplitterRegex = [regex]'(?smi)^[\s]*GO[\s]*$'

    }
    process {
        foreach ($SQLInstance in $ServerInstance) {
            Write-Debug -Message "Querying ServerInstance '$SQLInstance'"

            if ($PSBoundParameters.Keys -contains "SQLConnection") {
                $Conn = $SQLConnection
            }
            else {
                $CSBuilder = New-Object -TypeName System.Data.SqlClient.SqlConnectionStringBuilder
                $CSBuilder["Server"] = $SQLInstance
                $CSBuilder["Database"] = $Database
                $CSBuilder["Connection Timeout"] = $ConnectionTimeout

                if ($Encrypt) {
                    $CSBuilder["Encrypt"] = $true
                }

                if ($Credential) {
                    $CSBuilder["Trusted_Connection"] = $false
                    $CSBuilder["User ID"] = $Credential.UserName
                    $CSBuilder["Password"] = $Credential.GetNetworkCredential().Password
                }
                else {
                    $CSBuilder["Integrated Security"] = $true
                }
                if ($ApplicationName) {
                    $CSBuilder["Application Name"] = $ApplicationName
                }
                else {
                    $ScriptName = (Get-PSCallStack)[-1].Command.ToString()
                    if ($ScriptName -ne "<ScriptBlock>") {
                        $CSBuilder["Application Name"] = $ScriptName
                    }
                }
                $conn = New-Object -TypeName System.Data.SqlClient.SQLConnection

                $ConnectionString = $CSBuilder.ToString()
                $conn.ConnectionString = $ConnectionString
                Write-Debug "ConnectionString $ConnectionString"

                try {
                    $conn.Open()
                }
                catch {
                    Write-Error $_
                    continue
                }
            }


            if ($ParseGO) {
                Write-Debug -Message "Stripping GOs from source"
                $Pieces = $GoSplitterRegex.Split($Query)
            }
            else {
                $Pieces = , $Query
            }
            # Only execute non-empty statements
            $Pieces = $Pieces | Where-Object { $_.Trim().Length -gt 0 }
            foreach ($piece in $Pieces) {
                $cmd = New-Object system.Data.SqlClient.SqlCommand($piece, $conn)
                $cmd.CommandTimeout = $QueryTimeout

                if ($null -ne $SqlParameters) {
                    $SqlParameters.GetEnumerator() |
                        ForEach-Object {
                        if ($null -ne $_.Value) {
                            $cmd.Parameters.AddWithValue($_.Key, $_.Value)
                        }
                        else {
                            $cmd.Parameters.AddWithValue($_.Key, [DBNull]::Value)
                        }
                    } > $null
                }

                $ds = New-Object system.Data.DataSet
                $da = New-Object system.Data.SqlClient.SqlDataAdapter($cmd)

                if ($MessagesToOutput) {
                    $pool = [RunspaceFactory]::CreateRunspacePool(1, [int]$env:NUMBER_OF_PROCESSORS + 1)
                    $pool.ApartmentState = "MTA"
                    $pool.Open()
                    $runspaces = @()
                    $scriptblock = {
                        Param ($da, $ds, $conn, $queue )
                        $conn.FireInfoMessageEventOnUserErrors = $false
                        $handler = [System.Data.SqlClient.SqlInfoMessageEventHandler] { $queue.Enqueue($_) }
                        $conn.add_InfoMessage($handler)
                        $Err = $null
                        try {
                            [void]$da.fill($ds)
                        }
                        catch {
                            $Err = $_
                        }
                        finally {
                            $conn.remove_InfoMessage($handler)
                        }
                        return $Err
                    }
                    $queue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
                    $runspace = [PowerShell]::Create()
                    $null = $runspace.AddScript($scriptblock)
                    $null = $runspace.AddArgument($da)
                    $null = $runspace.AddArgument($ds)
                    $null = $runspace.AddArgument($Conn)
                    $null = $runspace.AddArgument($queue)
                    $runspace.RunspacePool = $pool
                    $runspaces += [PSCustomObject]@{ Pipe = $runspace; Status = $runspace.BeginInvoke() }
                    # While streaming .
                    while ($runspaces.Status.IsCompleted -notcontains $true) {
                        $item = $null
                        if ($queue.TryDequeue([ref]$item)) {
                            "$item"
                        }
                    }
                    # Drain the stream as the runspace is closed, just to be safe
                    if ($queue.IsEmpty -ne $true) {
                        $item = $null
                        while ($queue.TryDequeue([ref]$item)) {
                            "$item"
                        }
                    }
                    foreach ($runspace in $runspaces) {
                        $results = $runspace.Pipe.EndInvoke($runspace.Status)
                        $runspace.Pipe.Dispose()
                        if ($null -ne $results) {
                            Resolve-SqlError $results[0]
                        }
                    }
                    $pool.Close()
                    $pool.Dispose()
                }
                else {
                    #Following EventHandler is used for PRINT and RAISERROR T-SQL statements. Executed when -Verbose parameter specified by caller and no -MessageToOutput
                    if ($PSBoundParameters.Verbose) {
                        $conn.FireInfoMessageEventOnUserErrors = $false
                        $handler = [System.Data.SqlClient.SqlInfoMessageEventHandler] { Write-Verbose "$($_)" }
                        $conn.add_InfoMessage($handler)
                    }
                    try {
                        [void]$da.fill($ds)
                    }
                    catch {
                        $Err = $_
                    }
                    finally {
                        if ($PSBoundParameters.Verbose) {
                            $conn.remove_InfoMessage($handler)
                        }
                    }
                    Resolve-SqlError $Err
                }
                #Close the connection
                if (-not $PSBoundParameters.ContainsKey('SQLConnection')) {
                    $Conn.Close()
                }
                if ($AppendServerInstance) {
                    #Basics from Chad Miller
                    $Column = New-Object Data.DataColumn
                    $Column.ColumnName = "ServerInstance"

                    if ($ds.Tables.Count -ne 0) {
                        $ds.Tables[0].Columns.Add($Column)
                        Foreach ($row in $ds.Tables[0]) {
                            $row.ServerInstance = $SQLInstance
                        }
                    }
                }

                switch ($As) {
                    'DataSet' {
                        $ds
                    }
                    'DataTable' {
                        $ds.Tables
                    }
                    'DataRow' {
                        if ($ds.Tables.Count -ne 0) {
                            $ds.Tables[0]
                        }
                    }
                    'PSObject' {
                        if ($ds.Tables.Count -ne 0) {
                            #Scrub DBNulls - Provides convenient results you can use comparisons with
                            #Introduces overhead (e.g. ~2000 rows w/ ~80 columns went from .15 Seconds to .65 Seconds - depending on your data could be much more!)
                            foreach ($row in $ds.Tables[0].Rows) {
                                [DBNullScrubber]::DataRowToPSObject($row)
                            }
                        }
                    }
                    'SingleValue' {
                        if ($ds.Tables.Count -ne 0) {
                            $ds.Tables[0] | Select-Object -ExpandProperty $ds.Tables[0].Columns[0].ColumnName
                        }
                    }
                }
            } #foreach ($piece in $Pieces)
        }
    }
} #Invoke-Sqlcmd2
##########################################################################################################

#Original function Invoke-WSUSDBMaintenance copied from https://gallery.technet.microsoft.com/scriptcenter/Invoke-WSUSDBMaintenance-af2a3a79
Function Invoke-WSUSDBReindex{
##########################################################################################################
<#
.SYNOPSIS
   Performs WSUS DB reindex maintenance script

.DESCRIPTION
   Uses the script originally from https://gallery.technet.microsoft.com/scriptcenter/Invoke-WSUSDBMaintenance-af2a3a79
   and adapted for this script.
#>
##########################################################################################################
    Param()

    Add-TextToCMLog $LogFile "Starting reindex of WSUS Database." $component 1

	$SqlConnection = Connect-WSUSDB $WSUSServerDB

    #T-SQL query used for reindexing
    $tSQL = @"
SET NOCOUNT ON;

-- Rebuild or reorganize indexes based on their fragmentation levels
DECLARE @work_to_do TABLE (
    objectid int
    , indexid int
    , pagedensity float
    , fragmentation float
    , numrows int
)

DECLARE @objectid int;
DECLARE @indexid int;
DECLARE @schemaname nvarchar(130);
DECLARE @objectname nvarchar(130);
DECLARE @indexname nvarchar(130);
DECLARE @numrows int
DECLARE @density float;
DECLARE @fragmentation float;
DECLARE @command nvarchar(4000);
DECLARE @fillfactorset bit
DECLARE @numpages int

-- Select indexes that need to be defragmented based on the following
-- * Page density is low
-- * External fragmentation is high in relation to index size
INSERT @work_to_do
SELECT
    f.object_id
    , index_id
    , avg_page_space_used_in_percent
    , avg_fragmentation_in_percent
    , record_count
FROM
    sys.dm_db_index_physical_stats (DB_ID(), NULL, NULL , NULL, 'SAMPLED') AS f
WHERE
    (f.avg_page_space_used_in_percent < 85.0 and f.avg_page_space_used_in_percent/100.0 * page_count < page_count - 1)
    or (f.page_count > 50 and f.avg_fragmentation_in_percent > 15.0)
    or (f.page_count > 10 and f.avg_fragmentation_in_percent > 80.0)


SELECT @numpages = sum(ps.used_page_count)
FROM
    @work_to_do AS fi
    INNER JOIN sys.indexes AS i ON fi.objectid = i.object_id and fi.indexid = i.index_id
    INNER JOIN sys.dm_db_partition_stats AS ps on i.object_id = ps.object_id and i.index_id = ps.index_id

-- Declare the cursor for the list of indexes to be processed.
DECLARE curIndexes CURSOR FOR SELECT * FROM @work_to_do

-- Open the cursor.
OPEN curIndexes

-- Loop through the indexes
WHILE (1=1)
BEGIN
    FETCH NEXT FROM curIndexes
    INTO @objectid, @indexid, @density, @fragmentation, @numrows;
    IF @@FETCH_STATUS < 0 BREAK;

    SELECT
        @objectname = QUOTENAME(o.name)
        , @schemaname = QUOTENAME(s.name)
    FROM
        sys.objects AS o
        INNER JOIN sys.schemas as s ON s.schema_id = o.schema_id
    WHERE
        o.object_id = @objectid;

    SELECT
        @indexname = QUOTENAME(name)
        , @fillfactorset = CASE fill_factor WHEN 0 THEN 0 ELSE 1 END
    FROM
        sys.indexes
    WHERE
        object_id = @objectid AND index_id = @indexid;

    IF ((@density BETWEEN 75.0 AND 85.0) AND @fillfactorset = 1) OR (@fragmentation < 30.0)
        SET @command = N'ALTER INDEX ' + @indexname + N' ON ' + @schemaname + N'.' + @objectname + N' REORGANIZE';
    ELSE IF @numrows >= 5000 AND @fillfactorset = 0
        SET @command = N'ALTER INDEX ' + @indexname + N' ON ' + @schemaname + N'.' + @objectname + N' REBUILD WITH (FILLFACTOR = 90)';
    ELSE
        SET @command = N'ALTER INDEX ' + @indexname + N' ON ' + @schemaname + N'.' + @objectname + N' REBUILD';
    EXEC (@command);
END

-- Close and deallocate the cursor.
CLOSE curIndexes;
DEALLOCATE curIndexes;

IF EXISTS (SELECT * FROM @work_to_do)
BEGIN
    SELECT @numpages = @numpages - sum(ps.used_page_count)
    FROM
        @work_to_do AS fi
        INNER JOIN sys.indexes AS i ON fi.objectid = i.object_id and fi.indexid = i.index_id
        INNER JOIN sys.dm_db_partition_stats AS ps on i.object_id = ps.object_id and i.index_id = ps.index_id
END

--Update all statistics
EXEC sp_updatestats
"@

    Try{
        Invoke-Sqlcmd2 -SQLConnection $SqlConnection -Database $($WSUSServerdb.DatabaseName) -Query $($tSQL) -ErrorAction Stop
    }Catch{
        Add-TextToCMLog $LogFile "Failed to reindex WSUS Database." $component 3
        Add-TextToCMLog $LogFile "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
        Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
        Exit $($_.Exception.HResult)
    }
    Add-TextToCMLog $LogFile "Reindex of WSUS Database done." $component 1
}
##########################################################################################################

#Taken from https://damgoodadmin.com/2017/11/05/fully-automate-software-update-maintenance-in-cm/
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

Function Add-ChildComputerGroupToParentXML{
##########################################################################################################
<#
.SYNOPSIS
   Adds the child computer group of the parent XML specified in the parameters.

.DESCRIPTION
   Adds the child computer group of the parent XML specified in the parameters.
   Function is recursive to handle multi-level hierarchies of computer groups.

#>
##########################################################################################################
    Param(
        [Parameter(Mandatory=$true)]
        [System.Xml.XmlDocument]$MainXMLDocument,
        [Parameter(Mandatory=$true)]
        [System.Xml.XmlElement]$ParentXMLElement,
        [Parameter(Mandatory=$true)]
        [Microsoft.UpdateServices.Internal.BaseApi.ComputerTargetGroup]$ComputerTargetGroup
    )

    #Create current group element
    If($ComputerTargetGroup.Id -eq 'b73ca6ed-5727-47f3-84de-015e03f6a88a'){#Handle Unassigned Computers group for different languages
        $currentGroupName = "Unassigned Computers"
    }Else{
        $currentGroupName = $ComputerTargetGroup.Name
    }

    $currentGroupElement = $MainXMLDocument.CreateElement("ComputerGroup")
    $currentGroupElement.InnerText = $($currentGroupName)

    $childGroups = $ComputerTargetGroup.GetChildTargetGroups()
    if($null -ne $childGroups){#Current group has childs, recurse
        foreach($childGroup in $childGroups){
            Add-ChildComputerGroupToParentXML $MainXMLDocument $currentGroupElement $childGroup
        }
    }

    #add current group to parent XML
    [void]$ParentXMLElement.AppendChild($currentGroupElement)
}
##########################################################################################################
Function Export-WSUSConfigurationToXML{
##########################################################################################################
<#
.SYNOPSIS
   Exports key parts of the current WSUS configuration to an XML file.

.DESCRIPTION
   Exports general configuration such as:
    -Update files preferences (download only when approved, languages, etc.)
    -Computer Groups (If $WSUSConfigOnly is false)
    -Update approvals (If $WSUSConfigOnly is false and $IncludeApprovals is true)
#>
##########################################################################################################
    Param(
        [Parameter(Mandatory=$true)]
        [string] $fileName,

        #Will only export configuration related to update files only
        #If $WSUSConfigOnly is false, the function will also import computer groups
        #If $WSUSConfigOnly is false and $IncludeApprovals is true, it will also export update approvals
        [Parameter(Mandatory=$false)]
        [bool] $WSUSConfigOnly=$false
    )

    Add-TextToCMLog $LogFile "Saving WSUS configuration." $component 1
    $WSUSConfig = $WSUSServer.GetConfiguration()

    [xml]$WSUSXMLConfig = New-Object System.Xml.XmlDocument
    $dec = $WSUSXMLConfig.CreateXmlDeclaration("1.0","UTF-8",$null)
    [void]$WSUSXMLConfig.AppendChild($dec)

    $WSUSXMLConfigRoot = $WSUSXMLConfig.CreateElement("WSUSConfiguration")
    [void]$WSUSXMLConfig.AppendChild($WSUSXMLConfigRoot)

    $WSUSXMLGeneralConfig = $WSUSXMLConfig.CreateElement("GeneralConfig")
    [void]$WSUSXMLConfigRoot.AppendChild($WSUSXMLGeneralConfig)

    #Add-TextToCMLog $LogFile "Saving targeting mode." $component 1
    $WSUSXMLTargetingMode = $WSUSXMLConfig.CreateElement("TargetingMode")
    $WSUSXMLTargetingMode.InnerText = $WSUSConfig.TargetingMode
    [void]$WSUSXMLGeneralConfig.AppendChild($WSUSXMLTargetingMode)

    $WSUSXMLUpdateFiles = $WSUSXMLConfig.CreateElement("UpdateFiles")
    [void]$WSUSXMLGeneralConfig.AppendChild($WSUSXMLUpdateFiles)

    #Add-TextToCMLog $LogFile "Saving WSUS `"Update files and languages`" options." $component 1

    $expressUpdates = $WSUSXMLConfig.CreateElement("DownloadExpressPackages")
    $expressUpdates.InnerText = $WSUSConfig.DownloadExpressPackages
    [void]$WSUSXMLUpdateFiles.AppendChild($expressUpdates)

    $downloadAsNeeded = $WSUSXMLConfig.CreateElement("DownloadUpdateBinariesAsNeeded")
    $downloadAsNeeded.InnerText = $WSUSConfig.DownloadUpdateBinariesAsNeeded
    [void]$WSUSXMLUpdateFiles.AppendChild($downloadAsNeeded)

    $WSUSXMLLanguages = $WSUSXMLConfig.CreateElement("EnabledUpdateLanguages")
    [void]$WSUSXMLUpdateFiles.AppendChild($WSUSXMLLanguages)

    #Add-TextToCMLog $LogFile "Saving selected languages." $component 1

    ($WSUSServer.GetConfiguration()).GetEnabledUpdateLanguages() | ForEach-Object{
       $element = $WSUSXMLConfig.CreateElement("Language")
       $element.InnerText = "$($_)"
       [void]$WSUSXMLLanguages.AppendChild($element)
    }

    if(!$WSUSConfigOnly){
        Add-TextToCMLog $LogFile "Saving computer groups." $component 1
        $WSUSXMLComputerGroups = $WSUSXMLConfig.CreateElement("ComputerGroups")
        [void]$WSUSXMLConfigRoot.AppendChild($WSUSXMLComputerGroups)

        $allComputersGroupElement = $WSUSXMLConfig.CreateElement("ComputerGroup")
        $allComputersGroupElement.InnerText = "All Computers" #Hardcoding the name of the group in english for the XML file

        $allGroups = $WSUSServer.GetComputerTargetGroups()
        
        #The 'All Computers' & 'Unassigned Computers' group Id are static as far as I know...
        $AllComputersGroupId = 'a0a08746-4dbe-4a37-9adf-9e7652c0b421'
        $UnassignedComputersGroupId = 'b73ca6ed-5727-47f3-84de-015e03f6a88a'

        $allComputersGroup = $allGroups | Where-Object{$_.Id -eq $allComputersGroupId}
        $childGroups = $allComputersGroup.GetChildTargetGroups()
        foreach($childgroup in $childGroups){
            Add-ChildComputerGroupToParentXML -MainXMLDocument $WSUSXMLConfig -ParentXMLElement $allComputersGroupElement -ComputerTargetGroup $childgroup
        }

        [void]$WSUSXMLComputerGroups.AppendChild($allComputersGroupElement)

        if($IncludeApprovals){
            Add-TextToCMLog $LogFile "Saving updates approvals." $component 1
            $WSUSXMLApprovedUpdates = $WSUSXMLConfig.CreateElement("ApprovedUpdates")
            [void]$WSUSXMLConfigRoot.AppendChild($WSUSXMLApprovedUpdates)


            #$WSUSServer.GetUpdates() | Where-Object {$_.IsApproved -eq $true} | ForEach-Object{
            Get-WSUSUpdates -WSUSServer $WSUSServer | Where-Object {$_.IsApproved -eq $true} | ForEach-Object{

                $updateElement = $WSUSXMLConfig.CreateElement("Update")
                $updateElement.SetAttribute("ID",$_.id.UpdateID.Guid)

                $computerGroups =  $WSUSXMLConfig.CreateElement("ComputerGroups")
                $approvals = $_.GetUpdateApprovals()
                foreach($approval in $approvals){
                    $computerGroupElement = $WSUSXMLConfig.CreateElement("ComputerGroup")
                    #Computer Group name
                    switch($approval.ComputerTargetGroupId){
                        $AllComputersGroupId{
                            $ComputerGroupName = "All Computers"
                        }
                        $UnassignedComputersGroupId{
                            $ComputerGroupName = "Unassigned Computers"
                        }
                        default{
                            $ComputerGroupName = $approval.getcomputertargetgroup() | Select-Object -ExpandProperty Name
                        }
                    }
                    $computerGroupElement.InnerText = $ComputerGroupName

                    $Action = $approval.Action
                    $computerGroupElement.SetAttribute("Action",$Action)

                    $IsOptional = $approval.IsOptional
                    $computerGroupElement.SetAttribute("IsOptional",$IsOptional)

                    
                    If($($approval.Deadline).Year -ne '9999'){#Assuming no deadline if year is 9999
                        #Saving date in epoch time to avoid timezone/culture issues
                        $Deadline = [int64](Get-Date($approval.Deadline) -UFormat %s -Millisecond 0)
                        $computerGroupElement.SetAttribute("Deadline",$Deadline)
                    }
                    [void]$computerGroups.AppendChild($computerGroupElement)
                }
                [void]$updateElement.AppendChild($computerGroups)
                [void]$WSUSXMLApprovedUpdates.AppendChild($updateElement)
            }
        }
    }


    Add-TextToCMLog $LogFile "Saving information to XML file." $component 1
    Try{
        $WSUSXMLConfig.Save($fileName)
    } Catch{
        Add-TextToCMLog $LogFile  "Could not save XML file at $($filename)" $component 3
        Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
        Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
        Exit $($_.Exception.HResult)
    }
}
##########################################################################################################

Function New-ComputerGroupFromXML{
##########################################################################################################
<#
.SYNOPSIS
   Creates the computer group under the parent group specified in the parameters.

.DESCRIPTION
   Creates the computer group under the parent group specified in the parameters.
   Also recurses if an XML element is passed because of child groups.

#>
##########################################################################################################
    Param(
        #Parent WSUS Group
        [Parameter(Mandatory=$true,ParameterSetName="CreateGroupWithChild",Position=0)]
        [Parameter(Mandatory=$true,ParameterSetName="CreateGroupWithoutChild",Position=0)]
        [Microsoft.UpdateServices.Internal.BaseApi.ComputerTargetGroup]$ParentComputerGroup,

        #New Computer group that also has child groups
        [Parameter(Mandatory=$true,ParameterSetName="CreateGroupWithChild")]
        [System.Xml.XmlElement]$NewComputerGroupElement,

        #New computer group that does not have any child groups
        [Parameter(Mandatory=$true,ParameterSetName="CreateGroupWithoutChild")]
        [String]$NewComputerGroupName
    )
    $currentchildGroupNames = $parentComputerGroup.GetChildTargetGroups() | Select-Object -ExpandProperty Name
    $allGroups = $WSUSServer.GetComputerTargetGroups() | Select-Object -ExpandProperty Name
    if($NewComputerGroupElement){#Create group and then recurse to create child groups
        $groupName = $newComputerGroupElement.'#text'
        if($groupName -notin $allGroups){#Group does not exists on target WSUS at this time.
            if(!$currentchildGroupNames){#Parent Group has no child, create the group
                Add-TextToCMLog $LogFile  "Creating group named `"$($groupName)`" as a child group of `"$($ParentComputerGroup.Name)`"." $component 1
                $newGroup = $WSUSServer.CreateComputerTargetGroup($groupName, $ParentComputerGroup)
            }elseif($groupName -notin $currentchildGroupNames){
                Add-TextToCMLog $LogFile  "Creating group named `"$($groupName)`" as a child group of `"$($ParentComputerGroup.Name)`"." $component 1
                $newGroup = $WSUSServer.CreateComputerTargetGroup($groupName, $ParentComputerGroup)
            }else{
                Add-TextToCMLog $LogFile  "Group `"$($groupName)`" under parent group `"$($ParentComputerGroup.Name)`" already exists, skipping." $component 1
                $newGroup = $WSUSServer.GetComputerTargetGroups() | Where-Object {$_.Name -eq $groupName}
            }
        }else{#Group with same computer name already exists
            [bool]$NeedsToBeDeleted = $false
            if(!$currentchildGroupNames){#Parent Group has no child, delete the existing computer group with the same name
                $NeedsToBeDeleted = $true
            }elseif($groupName -notin $currentchildGroupNames){
                    $NeedsToBeDeleted = $true
                }
            }
            if($NeedsToBeDeleted){
                Add-TextToCMLog $LogFile  "Computer group named `"$($groupName)`" already exists, but not under group `"$($ParentComputerGroup.Name)`", deleting group." $component 1
                Try{
                    ($WSUSServer.GetComputerTargetGroups() | Where-Object {$_.Name -eq $groupName}).Delete()
                }Catch{
                    Add-TextToCMLog $LogFile  "Failed to delete computer target group." $component 3
                    Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
                    Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
                    Exit $($_.Exception.HResult)
                }
                Add-TextToCMLog $LogFile  "Creating group named `"$($groupName)`" as a child group of `"$($ParentComputerGroup.Name)`"." $component 1
                $newGroup = $WSUSServer.CreateComputerTargetGroup($groupName, $ParentComputerGroup)
            }else{
                Add-TextToCMLog $LogFile  "Group `"$($groupName)`" under parent group `"$($ParentComputerGroup.Name)`" already exists, skipping." $component 1
                $newGroup = $WSUSServer.GetComputerTargetGroups() | Where-Object {$_.Name -eq $groupName}
            }

        #Recurse for any child computer groups
        $NewComputerGroupElement.ComputerGroup | ForEach-Object{
            if($_ -is [String]){
                New-ComputerGroupFromXML -ParentComputerGroup $newGroup -NewComputerGroupName $_
            }elseif($_ -is [System.Xml.XmlElement]){
                New-ComputerGroupFromXML -ParentComputerGroup $newGroup -NewComputerGroupElement $_
            }
        }

    }elseif($NewComputerGroupName){#Create group only
        $groupName = $NewComputerGroupName
        if($groupName -notin $allGroups){#Group does not exists on target WSUS at this time, create the group
            Add-TextToCMLog $LogFile  "Creating group named `"$($groupName)`" as a child group of `"$($ParentComputerGroup.Name)`"." $component 1

            $newGroup = $WSUSServer.CreateComputerTargetGroup($groupName, $ParentComputerGroup)
        }else{#Group with same computer name already exists
            [bool]$NeedsToBeDeleted = $false
            if(!$currentchildGroupNames){#Parent Group has no child, delete the existing computer group with the same name
                $NeedsToBeDeleted = $true
            }elseif($groupName -notin $currentchildGroupNames){
                    $NeedsToBeDeleted = $true
            }
            if($NeedsToBeDeleted){
                Add-TextToCMLog $LogFile  "Computer group named `"$($groupName)`" already exists, but not under group `"$($ParentComputerGroup.Name)`", deleting group." $component 1
                Try{
                    ($WSUSServer.GetComputerTargetGroups() | Where-Object {$_.Name -eq $groupName}).Delete()
                }Catch{
                    Add-TextToCMLog $LogFile  "Failed to delete computer target group." $component 3
                    Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
                    Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
                    Exit $($_.Exception.HResult)
                }
                Add-TextToCMLog $LogFile  "Creating group named `"$($groupName)`" as a child group of `"$($ParentComputerGroup.Name)`"." $component 1
                $newGroup = $WSUSServer.CreateComputerTargetGroup($groupName, $ParentComputerGroup)
            }else{
                Add-TextToCMLog $LogFile  "Group `"$($groupName)`" under parent group `"$($ParentComputerGroup.Name)`" already exists, skipping." $component 1
                $newGroup = $WSUSServer.GetComputerTargetGroups() | Where-Object {$_.Name -eq $groupName}
            }
        }
    }
}
##########################################################################################################

Function Set-WSUSConfiguration{
##########################################################################################################
<#
.SYNOPSIS
   Applies the WSUS configuration provided to the WSUS Server.
   If the WSUS Server is busy, the function will wait retry to apply the configuration after a delay up to a certain time.

.DESCRIPTION
   Tries the Save() method of the WSUS Configuration item  and catches any error that may occur.
   If the exception is that the WSUS Server is busy processing a change, it will retry for a while.
   Parameters

#>
##########################################################################################################
    Param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullorEmpty()]
        [Microsoft.UpdateServices.Internal.BaseApi.UpdateServerConfiguration]$WSUSConfiguration,
        [int]$MinsRetryInterval = 5,
        [int]$MaxRetryCount = 144
    )

    $configUpdated = $false
    $i=1
    Add-TextToCMLog $LogFile "Attempting to save WSUS Configuration." $component 1
    while(!$configUpdated -and ($i -le $MaxRetryCount)){
        Try{
            $WSUSConfiguration.Save()
            Add-TextToCMLog $LogFile "Successfully updated WSUS Configuration." $component 1
            $configUpdated = $true
        } Catch{
            if($($_.Exception.Message) -like "*`"Cannot save configuration because the server is still processing a previous`r`nconfiguration change.`""){
                Add-TextToCMLog $LogFile "Could not configure WSUS Server, server is still processing a previous configuration change." $component 2
                Add-TextToCMLog $LogFile "Waiting for $MinsRetryInterval minutes before next attempt. Retry count: $($i) of $($MaxRetryCount)" $component 2
                Start-Sleep -Seconds ($MinsRetryInterval * 60)
                $i++
            }else{
                Add-TextToCMLog $LogFile  "Failed to update WSUS Configuration." $component 3
                Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
                Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
                Exit $($_.Exception.HResult)
            }
        }
    }
    if(!$configUpdated){
        Add-TextToCMLog $LogFile  "Failed to update WSUS Configuration." $component 3
        Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
        Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
        Exit $($_.Exception.HResult)
    }
}
##########################################################################################################

Function Remove-AutomaticApprovalRule{
##########################################################################################################
<#
.SYNOPSIS
   Wrapper to delete an automatic approval rule.
   If the WSUS Server is busy, the function will wait retry to apply the configuration after a delay up to a certain time.
#>
##########################################################################################################
    Param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullorEmpty()]
        [Microsoft.UpdateServices.Internal.BaseApi.AutomaticUpdateApprovalRule]$AutomaticApprovalRule,
        [int]$MinsRetryInterval = 5,
        [int]$MaxRetryCount = 144
    )

    $configUpdated = $false
    $i=1
    Add-TextToCMLog $LogFile "Attempting to delete automatic approval rule `"$($AutomaticApprovalRule.Name)`"." $component 1
    while(!$configUpdated -and ($i -le $MaxRetryCount)){
        Try{
            $WSUSServer.DeleteInstallApprovalRule($AutomaticApprovalRule.Id)
            Add-TextToCMLog $LogFile "Successfully deleted automatic approval rule." $component 1
            $configUpdated = $true
        } Catch{
            if($($_.Exception.Message) -like "*`"Cannot save configuration because the server is still processing a previous`r`nconfiguration change.`""){
                Add-TextToCMLog $LogFile "Could not configure WSUS Server, server is still processing a previous configuration change." $component 2
                Add-TextToCMLog $LogFile "Waiting for $MinsRetryInterval minutes before next attempt. Retry count: $($i) of $($MaxRetryCount)" $component 2
                Start-Sleep -Seconds ($MinsRetryInterval * 60)
                $i++
            }else{
                Add-TextToCMLog $LogFile  "Failed to delete automatic approval rule `"$($AutomaticApprovalRule.Name)`"." $component 3
                Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
                Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
                Exit $($_.Exception.HResult)
            }
        }
    }
    if(!$configUpdated){
        Add-TextToCMLog $LogFile  "Failed to delete automatic approval rule `"$($AutomaticApprovalRule.Name)`"." $component 3
        Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
        Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
        Exit $($_.Exception.HResult)
    }
}
##########################################################################################################

Function Invoke-EulaCheck {
##########################################################################################################
    <#
    .SYNOPSIS
        This function will periodically check the WSUS Database to see if all EULA files
        are downloaded/verified.

    .DESCRIPTION
        The script will run a query against the tbFile table and look for EULA files.
        In order to approve an update that has EULA(s), all EULA files must be in state=12
        If any of the EULA files are missing, WSUS will not let you approve this update.
    #>
##########################################################################################################
    Param(
        #How many checks are done before giving up
        [Parameter()]
        [int]$MaxIterations = 60,

        #How long is the pause between checks?
        [Parameter()]
        [int]$SecondsToWait = 1
    )

    #Reusing logic in Connect-WSUSDB function to identify the server instance.
    If ($WSUSServerDB.IsUsingWindowsInternalDatabase){
        #Using the Windows Internal Database.
        If($WSUSServerDB.ServerName -eq "MICROSOFT##WID"){
            $ServerInstance = "\\.\pipe\MICROSOFT##WID\tsql\query"
        }
        Else{
            $ServerInstance = "\\.\pipe\MSSQL`$MICROSOFT##SSEE\sql\query"
        }
    }
    Else{
        #SQL Server
        $ServerInstance = "$($WSUSServerDB.ServerName)"
    }


    #Define the query
    $tsql = "SELECT f.FileDigest,f.FileName,fos.ActualState FROM [SUSDB].[dbo].[tbFile] f INNER JOIN [SUSDB].[dbo].[tbFileOnServer] fos ON f.FileDigest = fos.FileDigest WHERE f.IsEula = 1"
    #If Database name is different from default of SUSDB (for some unknown/unsupported reason)
    if($($WSUSServerDB.DatabaseName) -ne "SUSDB"){
        $tsql = $tsql -replace "SUSDB","$($WSUSServerDB.DatabaseName)"
    }

    $EULAFilesVerified = $false
    $i = 0
    Do{
        Try{
            $eulaResults = Invoke-Sqlcmd2 -ServerInstance $ServerInstance -Query $tsql
            $verifiedEulas = $eulaResults | Where-Object {$_.ActualState -eq 12}
            Add-TextToCMLog $LogFile "$($verifiedEulas.count)`/$($eulaResults.count) EULA files ready." $component 1
        }Catch{
            Add-TextToCMLog $LogFile "Error while checking EULA files." $component 3
            Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
            Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
            Exit $($_.Exception.HResult)
        }
        if($verifiedEulas.count -eq $eulaResults.count){
            $EULAFilesVerified = $true
        }else{
            $i++
            Start-Sleep -Seconds $SecondsToWait
        }
    }Until($i -eq $MaxIterations -or $EULAFilesVerified)

    if($EULAFilesVerified){
        Add-TextToCMLog $LogFile "All EULA files are verified." $component 1
    }else{
        Add-TextToCMLog $LogFile "Max number of iterations reached and could not verify all EULA files." $component 3
        $failedEulas = $eulaResults | Where-Object {$_.ActualState -ne 12}
        Add-TextToCMLog $LogFile "There are $($failedEulas.Count) EULA files that failed verification." $component 3
        ForEach($eula in $failedEulas){
            $StringFileDigest = [System.BitConverter]::ToString($eula.FileDigest) -replace "-",""
            $FolderName = [System.BitConverter]::ToString(($eula.FileDigest)[($eula.FileDigest).Length-1])
            $Extension = ".txt"

            $PathOfEula = Join-Path (Join-Path $CurrentWSUSContentDir "WsusContent") (Join-Path $FolderName ($StringFileDigest + $Extension))
            Add-TextToCMLog $LogFile "EULA file at path `"$PathOfEula`" could not be verified." $component 3
        }
        Exit 1
    }
}
##########################################################################################################

Function Import-WSUSConfigurationFromXML{
##########################################################################################################
    <#
    .SYNOPSIS
       Import/Apply WSUS configuration from specified XML file.
       The XML file will also contains approvals for each update that will be imported on the target WSUS Server
       if approvals are included.


    .DESCRIPTION
       Imports general configuration such as:
        -Update files options (download only when approved, languages, etc.)
        -Computer Groups
        -Update approvals (if selected)
    #>
##########################################################################################################
        Param(
            [Parameter(Mandatory=$true)]
            [string] $fileName,

            #If $WSUSConfigOnly is true, function will not create computer groups or apply update approvals
            [switch] $WSUSConfigOnly = $false
        )

        #Verify file exists
        Try{
            [xml]$WSUSXMLConfig = New-Object System.Xml.XmlDocument
            $WSUSXMLConfig.Load($fileName)
        } Catch{
            Add-TextToCMLog $LogFile  "Failed to load XML file $($filename)" $component 3
            Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
            Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
            Exit $($_.Exception.HResult)
        }

        [bool]$configUpdateNeeded = $false
        #WSUS Configuration that we will change and then apply to the "importing" WSUS Server.
        $WSUSConfiguration = $WSUSServer.GetConfiguration()

        #region UpdateFiles configuration
        Add-TextToCMLog $LogFile  "Checking if update files configuration needs to be updated." $component 1
        Try{
            [bool]$downloadExpressPackages = [Boolean]::Parse($WSUSXMLConfig.WSUSConfiguration.GeneralConfig.UpdateFiles.DownloadExpressPackages)
            [bool]$downloadUpdateBinariesAsNeeded = [Boolean]::Parse($WSUSXMLConfig.WSUSConfiguration.GeneralConfig.UpdateFiles.DownloadUpdateBinariesAsNeeded)
        }Catch{
            Add-TextToCMLog $LogFile  "Could not parse some configuration elements from the XML file to boolean." $component 3
            Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
            Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
            Exit $($_.Exception.HResult)
        }

        $currentDownloadExpressPackages = $WSUSConfiguration.DownloadExpressPackages
        $currentDownloadUpdateBinariesAsNeeded = $WSUSConfiguration.DownloadUpdateBinariesAsNeeded
        $currentHostBinariesOnMicrosoftUpdate = $WSUSConfiguration.HostBinariesOnMicrosoftUpdate
        $currentGetContentFromMU = $WSUSConfiguration.GetContentFromMU

        if(($currentDownloadExpressPackages -ne $downloadExpressPackages) -OR ($currentDownloadUpdateBinariesAsNeeded -ne $downloadUpdateBinariesAsNeeded) -OR ($currentHostBinariesOnMicrosoftUpdate -ne $false) -OR ($currentGetContentFromMU -ne $false)){

            Add-TextToCMLog $LogFile "Update Files configuration is different from expected values." $component 1
            Add-TextToCMLog $LogFile "DownloadExpressPackages is `"$($currentDownloadExpressPackages)`". Value expected: `"$($downloadExpressPackages)`"" $component 1
            Add-TextToCMLog $LogFile "DownloadUpdateBinariesAsNeeded is `"$($currentDownloadUpdateBinariesAsNeeded)`". Value expected: `"$($downloadUpdateBinariesAsNeeded)`"" $component 1

            #For Disconnected WSUS
            Add-TextToCMLog $LogFile "HostBinariesOnMicrosoftUpdate is `"$($currentHostBinariesOnMicrosoftUpdate)`". Value expected: `"$($false)`"" $component 1
            Add-TextToCMLog $LogFile "GetContentFromMU is `"$($currentGetContentFromMU)`". Value expected: `"$($false)`"" $component 1


            $WSUSConfiguration.HostBinariesOnMicrosoftUpdate = $false
            $WSUSConfiguration.GetContentFromMU = $false
            $WSUSConfiguration.DownloadExpressPackages = $downloadExpressPackages
            $WSUSConfiguration.DownloadUpdateBinariesAsNeeded = $downloadUpdateBinariesAsNeeded

            $configUpdateNeeded = $true
        }else{
            Add-TextToCMLog $LogFile "WSUS Update Files configuration matches expected values." $component 1
        }
        #endregion UpdateFiles configuration


        #region EnabledUpdateLanguages
        $languages = Confirm-StringArray ($WSUSXMLConfig.WSUSConfiguration.GeneralConfig.UpdateFiles.EnabledUpdateLanguages.Language)
        if($languages){

            $currentLanguages = $WSUSConfiguration.GetEnabledUpdateLanguages()
            if($currentLanguages){
                $diffs = Compare-Object -ReferenceObject $languages -DifferenceObject $currentLanguages
            }

            if(!$currentLanguages -or $diffs){ #There are differences between languagues currently used on the WSUS Server and the XML configuration file
                Add-TextToCMLog $LogFile "Changing enabled languages to the following list: `"$($languages -join ",")`" on current WSUS Server because the current selection does not match the XML configuration file." $component 1

                $WSUSConfiguration.AllUpdateLanguagesEnabled = $false
                $WSUSConfiguration.SetEnabledUpdateLanguages($languages)
                $configUpdateNeeded = $true
            }
        }#endregion EnabledUpdateLanguages

        #region WSUSAutoApprovals
        if(($WSUSConfiguration.AutoApproveWsusInfrastructureUpdates -ne $false) -or ($WSUSConfiguration.AutoRefreshUpdateApprovals -ne $false)){
            Add-TextToCMLog $LogFile "WSUS Advanced Automatic approval rules are not disabled." $component 1
            $WSUSConfiguration.AutoApproveWsusInfrastructureUpdates = $false
            $WSUSConfiguration.AutoRefreshUpdateApprovals = $false
            $configUpdateNeeded = $true
        }else{
            Add-TextToCMLog $LogFile "WSUS Advanced Automatic approval rules are already disabled." $component 1
        }
        #endregion WSUSAutoApprovals

        #region TargetingMode
        Add-TextToCMLog $LogFile  "Checking if targeting mode needs to be updated." $component 1
        $targetingMode = Confirm-StringArray ($WSUSXMLConfig.WSUSConfiguration.GeneralConfig.TargetingMode)
        if(!$targetingMode){
            Add-TextToCMLog $LogFile  "No targeting mode in XML file, defaulting to `"Client`" (GPO/Registry controlled) targeting mode." $component 1
            $targetingMode = "Client"
        }
        if($WSUSConfiguration.TargetingMode -ne $targetingMode){
            Add-TextToCMLog $LogFile  "Current TargetingMode is `"$($WSUSConfiguration.TargetingMode)`", expected value is `"$targetingMode`"." $component 1
            $WSUSConfiguration.TargetingMode = $targetingMode
            $configUpdateNeeded = $true
        }else{
            Add-TextToCMLog $LogFile  "Current TargetingMode matches expected value." $component 1
        }
        #endregion TargetingMode

        #region oobe
        Add-TextToCMLog $LogFile  "Making sure Out-of-box experience (OOBE) is disabled." $component 1
        if(!($WSUSConfiguration.OobeInitialized)){
            $WSUSConfiguration.OobeInitialized = $true
            $configUpdateNeeded = $true
        }else{
            Add-TextToCMLog $LogFile  "Out-of-box experience (OOBE) is already disabled." $component 1
        }
        #endregion oobe

        if($configUpdateNeeded){
            Add-TextToCMLog $LogFile  "WSUS Configuration needs to be updated." $component 1
            Set-WSUSConfiguration -WSUSConfiguration $WSUSConfiguration
        }else{
            Add-TextToCMLog $LogFile  "WSUS Configuration matches expected settings, skipping WSUS configuration modification." $component 1
        }


        #region ApprovalRules

        $currentRules = $WSUSServer.GetInstallApprovalRules()
        if($currentRules){
            Add-TextToCMLog $LogFile "Automatic approval rules are configured, will attempt to remove the rules." $component 1
            foreach($rule in $currentRules){
                Remove-AutomaticApprovalRule -AutomaticApprovalRule $rule
                Start-Sleep -Seconds 5
            }
        }else{
            Add-TextToCMLog $LogFile "There are no automatic approvals rules, skipping removal." $component 1
        }
        #endregion ApprovalRules

        if(!$WSUSConfigOnly){#Do not continue if WSUSConfigOnly is true
            #region ComputerGroups
            Add-TextToCMLog $LogFile "Creating missing computer groups, if needed." $component 1
            [System.Xml.XmlElement]$computerGroups = $WSUSXMLConfig.WSUSConfiguration.ComputerGroups
            if($computerGroups){

                [System.Xml.XmlElement]$allComputersGroupElement = $computerGroups.ComputerGroup
                $allComputersGroupName = "All Computers"
                $unassignedComputersGroupName = "Unassigned Computers"

                #Verify that the first computer group is "All Computers"
                if($($allComputersGroupElement.'#text') -eq $allComputersGroupName){
                    $subGroups = $allComputersGroupElement.ComputerGroup

                    $allComputersGroup = $WSUSServer.GetComputerTargetGroups() | Where-Object{$_.Id -eq 'a0a08746-4dbe-4a37-9adf-9e7652c0b421'}

                    foreach($subGroup in $subGroups){
                        if($subGroup -is [System.Xml.XmlElement]){#Computer group has sub groups
                            New-ComputerGroupFromXML -ParentComputerGroup $allComputersGroup -NewComputerGroupElement $subGroup
                        }elseif($subGroup -is [String]){#Computer Group does not have any child groups
                            If($subGroup -ne $unassignedComputersGroupName){#Ignore 'Unassigned Computers' since it's built-in
                                New-ComputerGroupFromXML -ParentComputerGroup $allComputersGroup -NewComputerGroupName $subGroup
                            }
                        }
                        else{
                            Add-TextToCMLog $LogFile "Information on child group `"$($subGroup)`" under All Computers XML element is neither an XMLElement or a String, please verify XML file." $component 2
                        }
                    }
                }else{
                    Add-TextToCMLog $LogFile "First computer group in XML file is not `"All Computers`", make sure XML is properly formatted." $component 3
                    Exit 1
                }

            }else{
                Add-TextToCMLog $LogFile "Computer Groups information is missing from XML file." $component 2
            }
            #endregion ComputerGroups

            #region UpdateApprovals
            if($IncludeApprovals){
                Add-TextToCMLog $LogFile "Importing updates approvals." $component 1

                [System.Xml.XmlElement]$approvedUpdates = $WSUSXMLConfig.WSUSConfiguration.ApprovedUpdates
                if($approvedUpdates){

                    $approvedUpdatesID = ($approvedUpdates.ChildNodes).ID

                    if($approvedUpdatesID){
                        Add-TextToCMLog $LogFile "Getting all updates from WSUS Server $($WSUSFQDN)." $component 1

                        $AllUpdates = Get-WSUSUpdates -WSUSServer $WSUSServer

                        Add-TextToCMLog $LogFile "Declining all updates that are not in the approved updates list from the XML file." $component 1
                        Try{
                            $UpdatesToDecline = $AllUpdates | Where-Object {($_.IsDeclined -eq $false) -and ($_.id.UpdateID.Guid -notin $approvedUpdatesID)}
                            foreach($update in $UpdatesToDecline){
                                #Invoke-WSUSSyncCheck $WSUSServer
                                $update.Decline($true) | Out-Null
                                Add-TextToCMLog $LogFile "Declined update $($update.Title) (ID: $($update.Id.UpdateID.Guid))" $component 1
                            }
                        } Catch{
                            Add-TextToCMLog $LogFile  "Failed declining updates." $component 3
                            Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
                            Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
                            Exit $($_.Exception.HResult)
                        }#end decline updates
                        Add-TextToCMLog $LogFile "Done declining updates." $component 1

                        Add-TextToCMLog $LogFile "Resetting WSUS and verifying EULA files." $component 1

                        #Reset WSUS
                        Reset-WSUSServer -MaxIterations 60 -MinsToWait 1

                        #Check EULA files, 5 minutes should be more than enough to verify a couple of text files.
                        Invoke-EulaCheck -MaxIterations 60 -SecondsToWait 5


                        [int]$minsToWait = 2
                        Add-TextToCMLog $LogFile "Waiting $($minsToWait) minutes for WSUS Server to process the changes." $component 1
                        Start-Sleep -Seconds ($minsToWait*60)


                        Add-TextToCMLog $LogFile "Approving updates for each applicable computer group." $component 1
                        $WSUSComputerGroups = $WSUSServer.GetComputerTargetGroups()
                        Try{
                            foreach($update in ($approvedUpdates.ChildNodes)){
                                $wsusUpdate = $AllUpdates | Where-Object {$_.id.UpdateID.Guid -eq $update.ID}
                                $updateTitle = $wsusUpdate | Select-Object -ExpandProperty Title

                                $update.ComputerGroups.ComputerGroup | ForEach-Object{
                                    switch($($_.'#text')){
                                        "All Computers"{
                                            $groupName = $WSUSComputerGroups | Where-Object{$_.Id -eq 'a0a08746-4dbe-4a37-9adf-9e7652c0b421'} | Select-Object -ExpandProperty Name
                                        }
                                        "Unassigned Computers"{
                                            $groupName = $WSUSComputerGroups | Where-Object{$_.Id -eq 'b73ca6ed-5727-47f3-84de-015e03f6a88a'} | Select-Object -ExpandProperty Name
                                        }
                                        default{
                                            $groupName = $_
                                        }
                                    }

                                    $group = $WSUSComputerGroups | Where-Object {$_.Name -eq $groupName}

                                    if($wsusUpdate.RequiresLicenseAgreementAcceptance){
                                        $wsusUpdate.AcceptLicenseAgreement()
                                    }

                                    $Action = $_.Action
                                    [bool]$IsOptional = [System.Boolean]::Parse($_.IsOptional)

                                    If($_.Deadline){
                                        [datetime]$epoch = '1970-01-01 00:00:00'
                                        $Deadline = $epoch.AddSeconds($_.Deadline)
                                    }

                                    If(!$IsOptional){
                                        If(-not ($_.Deadline)){
                                            Add-TextToCMLog $LogFile "Approving update `"$($updateTitle)`" with action `"$Action`" for computer group `"$($group.Name)`"." $component 1
                                            [void]$wsusUpdate.Approve($Action, $group)
                                        }Else{
                                            Add-TextToCMLog $LogFile "Approving update `"$($updateTitle)`" with action `"$Action`" for computer group `"$($group.Name)`" with a deadline date of `"$($Deadline)`"." $component 1
                                            [void]$wsusUpdate.Approve($Action, $group, $Deadline)
                                        }
                                    }Else{
                                        Add-TextToCMLog $LogFile "Approving update `"$($updateTitle)`" for computer group `"$($group.Name)`" for optional install." $component 1
                                        [void]$wsusUpdate.ApproveForOptionalInstall($group)
                                    }
                                }
                            }
                        } Catch{
                            Add-TextToCMLog $LogFile  "Failed approving updates." $component 3
                            Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
                            Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
                            Exit $($_.Exception.HResult)
                        }#End approve updates
                        Add-TextToCMLog $LogFile "Done approving updates." $component 1
                        Add-TextToCMLog $LogFile "Waiting $($minsToWait) minutes for WSUS Server to process the changes." $component 1
                        Start-Sleep -Seconds ($minsToWait*60)
                    }else{
                        Add-TextToCMLog $LogFile "Updates approvals are empty." $component 2
                    }
                }else{
                    Add-TextToCMLog $LogFile "No updates approvals found in XML file, skipping approvals." $component 2
                }
            }
            #endregion UpdateApprovals
        }#End Computer groups and update approvals

}
##########################################################################################################

#Taken from https://github.com/RamblingCookieMonster/PSDeploy/tree/master/PSDeploy/Private

function Start-ConsoleProcess
{
<#
.Synopsis
    Launch console process, pipe strings to its StandardInput
    and get resulting StandardOutput/StandardError streams and exit code.

.Description
    This function will start console executable, pipe any user-specified strings to it
    and capture StandardOutput/StandardError streams and exit code.
    It returns object with following properties:

    StdOut - array of strings captured from StandardOutput
    StdErr - array of strings captured from StandardError
    ExitCode - exit code set by executable

.Parameter FilePath
    Path to the executable or its name.

.Parameter ArgumentList
    Array of arguments for the executable.
    Passing arguments as an array allows to run even such unfriendly applications as robocopy.

.Parameter InputObject
    Array of strings to be piped to the executable's StandardInput.
    This allows you to execute commands in interactive sessions of netsh and diskpart.

.Example
    Start-ConsoleProcess -FilePath find

    Start find.exe and capture its output.
    Because no arguments specified, find.exe prints error to StandardError stream,
    which is captured by the function:

    StdOut StdErr                               ExitCode
    ------ ------                               --------
    {}     {FIND: Parameter format not correct}        2

.Example
    'aaa', 'bbb', 'ccc' | Start-ConsoleProcess -FilePath find -ArgumentList '"aaa"'

    Start find.exe, pipe strings to its StandardInput and capture its output.
    Find.exe will attempt to find string "aaa" in StandardInput stream and
    print matches to StandardOutput stream, which is captured by the function:

    StdOut StdErr ExitCode
    ------ ------ --------
    {aaa}  {}            0

.Example
    'list disk', 'list volume' | Start-ConsoleProcess -FilePath diskpart

    Start diskpart.exe, pipe string to its StandardInput and capture its output.
    Diskpart.exe will accept piped strings as if they were typed in the interactive session
    and list all disks and volumes on the PC.

    Note that running diskpart requires already elevated PowerShell console.
    Otherwise, you will recieve elevation request and diskpart will run,
    however, no strings would be piped to it.

    Example:

    PS > $Result = 'list disk', 'list volume' | Start-ConsoleProcess -FilePath diskpart
    PS > $Result.StdOut

    Microsoft DiskPart version 6.3.9600

    Copyright (C) 1999-2013 Microsoft Corporation.
    On computer: HAL9000

    DISKPART>
      Disk ###  Status         Size     Free     Dyn  Gpt
      --------  -------------  -------  -------  ---  ---
      Disk 0    Online          298 GB      0 B

    DISKPART>
      Volume ###  Ltr  Label        Fs     Type        Size     Status     Info
      ----------  ---  -----------  -----  ----------  -------  ---------  --------
      Volume 0     E                       DVD-ROM         0 B  No Media
      Volume 1     C   System       NTFS   Partition    100 GB  Healthy    System
      Volume 2     D   Storage      NTFS   Partition    198 GB  Healthy

    DISKPART>

.Example
    Start-ConsoleProcess -FilePath robocopy -ArgumentList 'C:\Src', 'C:\Dst', '/mir'

    Start robocopy.exe with arguments and capture its output.
    Robocopy.exe will mirror contents of the 'C:\Src' folder to 'C:\Dst'
    and print log to StandardOutput stream, which is captured by the function.

    Example:

    PS > $Result = Start-ConsoleProcess -FilePath robocopy -ArgumentList 'C:\Src', 'C:\Dst', '/mir'
    PS > $Result.StdOut

    -------------------------------------------------------------------------------
       ROBOCOPY     ::     Robust File Copy for Windows
    -------------------------------------------------------------------------------

      Started : 01 January 2016 y. 00:00:01
       Source : C:\Src\
         Dest : C:\Dst\

        Files : *.*

      Options : *.* /S /E /DCOPY:DA /COPY:DAT /PURGE /MIR /R:1000000 /W:30

    ------------------------------------------------------------------------------

	                       1	C:\Src\
	        New File  		       6	Readme.txt
      0%
    100%

    ------------------------------------------------------------------------------

                   Total    Copied   Skipped  Mismatch    FAILED    Extras
        Dirs :         1         0         0         0         0         0
       Files :         1         1         0         0         0         0
       Bytes :         6         6         0         0         0         0
       Times :   0:00:00   0:00:00                       0:00:00   0:00:00


       Speed :                 103 Bytes/sec.
       Speed :               0.005 MegaBytes/min.
       Ended : 01 January 2016 y. 00:00:01
#>
    Param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath,

        [string[]]$ArgumentList,

        [Parameter(ValueFromPipeline = $true)]
        [string[]]$InputObject
    )

    End
    {
        if($Input)
        {
            # Collect all pipeline input
            # http://www.powertheshell.com/input_psv3/
            $StdIn = @($Input)
        }
        else
        {
            $StdIn = $InputObject
        }

        try
        {
            "Starting process: $FilePath", "Redirect StdIn: $([bool]$StdIn.Count)", "Arguments: $ArgumentList" | Write-Verbose

            if($StdIn.Count)
            {
                $Output = $StdIn | & $FilePath $ArgumentList 2>&1
            }
            else
            {
                $Output = & $FilePath $ArgumentList 2>&1
            }
        }
        catch
        {
            throw $_
        }

        Write-Verbose 'Finished, processing output'

        $StdOut = New-Object -TypeName System.Collections.Generic.List``1[String]
        $StdErr = New-Object -TypeName System.Collections.Generic.List``1[String]

        foreach($item in $Output)
        {
            # Data from StdOut will be strings, while StdErr produces
            # System.Management.Automation.ErrorRecord objects.
            # http://stackoverflow.com/a/33002914/4424236
            if($item.Exception.Message)
            {
                $StdErr.Add($item.Exception.Message)
            }
            else
            {
                $StdOut.Add($item)
            }
        }

        Write-Verbose 'Returning result'
        New-Object -TypeName PSCustomObject -Property @{
            ExitCode = $LASTEXITCODE
            StdOut = $StdOut.ToArray()
            StdErr = $StdErr.ToArray()
        } | Select-Object -Property StdOut, StdErr, ExitCode
    }
}
##########################################################################################################

#Taken from https://github.com/RamblingCookieMonster/PSDeploy/tree/master/PSDeploy/Private

function Invoke-Robocopy
{
<#
.Synopsis
    Wrapper function for robocopy.exe

.Parameter Path
    String. Source path. You can use relative path.

.Parameter Destination
    Array of destination paths. You can use relative paths.

.Parameter ArgumentList
    Array of additional arguments for robocopy.exe

.Parameter Retry
    Integer. Number of retires. Default is 2.

.Parameter EnableExit
    Switch. Exit function if Robocopy throws "terminating" error code.

.Parameter PassThru
    Switch. Returns an object with the following properties:

    StdOut - array of strings captured from StandardOutput
    StdErr - array of strings captured from StandardError
    ExitCode - Enum with Robocopy exit code in human-readable format

    By default, this function doesn't generate any output.

.Link
    https://technet.microsoft.com/en-us/library/cc733145.aspx

.Link
    http://ss64.com/nt/robocopy.html

.Link
    http://ss64.com/nt/robocopy-exit.html

.Example
    'c:\bravo', 'c:\charlie' | Invoke-Robocopy -Path 'c:\alpha' -ArgumentList @('/xo', '/e' )

    Copy 'c:\alpha' to 'c:\bravo' and 'c:\charlie'. Copy subdirectories, include empty directories, exclude older files.
#>
    [CmdletBinding()]
    Param
    (
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateScript({Test-Path -Path $_})]
        [string]$Path,

        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string[]]$Destination,

        [Parameter(ValueFromPipelineByPropertyName = $true)]
        [string[]]$ArgumentList,

        [Parameter(ValueFromPipelineByPropertyName = $true)]
        [int]$Retry = 2,

        [Parameter(ValueFromPipelineByPropertyName = $true)]
        [switch]$EnableExit,

        [Parameter(ValueFromPipelineByPropertyName = $true)]
        [switch]$PassThru
    )

    Begin
    {
        # https://learn-powershell.net/2016/03/07/building-a-enum-that-supports-bit-fields-in-powershell/
        function New-RobocopyHelper
        {
            $TypeName = 'Robocopy.ExitCode'

            # http://stackoverflow.com/questions/16552801/how-do-i-conditionally-add-a-class-with-add-type-typedefinition-if-it-isnt-add
            if (! ([System.Management.Automation.PSTypeName]$TypeName).Type) {
                try {
                    #region Module Builder
                    $Domain = [System.AppDomain]::CurrentDomain
                    $DynAssembly = New-Object -TypeName System.Reflection.AssemblyName($TypeName)
                    $AssemblyBuilder = $Domain.DefineDynamicAssembly($DynAssembly, [System.Reflection.Emit.AssemblyBuilderAccess]::Run) # Only run in memory
                    $ModuleBuilder = $AssemblyBuilder.DefineDynamicModule($TypeName, $false)
                    #endregion Module Builder

                    # https://pshirwin.wordpress.com/2016/03/18/robocopy-exitcodes-the-powershell-way/
                    #region Enum
                    $EnumBuilder = $ModuleBuilder.DefineEnum($TypeName, 'Public', [int32])
                    [void]$EnumBuilder.DefineLiteral('NoChange', [int32]0x00000000)
                    [void]$EnumBuilder.DefineLiteral('OKCopy', [int32]0x00000001)
                    [void]$EnumBuilder.DefineLiteral('ExtraFiles', [int32]0x00000002)
                    [void]$EnumBuilder.DefineLiteral('MismatchedFilesFolders', [int32]0x00000004)
                    [void]$EnumBuilder.DefineLiteral('FailedCopyAttempts', [int32]0x00000008)
                    [void]$EnumBuilder.DefineLiteral('FatalError', [int32]0x000000010)
                    $EnumBuilder.SetCustomAttribute(
                        [FlagsAttribute].GetConstructor([Type]::EmptyTypes),
                        @()
                    )
                    [void]$EnumBuilder.CreateType()
                    #endregion Enum
                } catch {
                    throw $_
                }
            }
        }

        New-RobocopyHelper
    }

    Process
    {
        foreach ($item in $Destination) {
            # Resolve destination paths, remove trailing backslash, add Retries and combine all arguments into one array
            $AllArguments = @(
                (Resolve-Path -Path $Path).ProviderPath -replace '\\+$'
            ) + (
                $item | ForEach-Object {
                    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($_) -replace '\\+$'
                }
            ) + $ArgumentList + "/R:$Retry"

            # Invoke Robocopy
            $Result = Start-ConsoleProcess -FilePath 'robocopy.exe' -ArgumentList $AllArguments
            $Result.ExitCode = [Robocopy.ExitCode]$Result.ExitCode

            # Dump Robocopy log to Verbose stream
            $Result.StdOut | Write-Verbose

            # Process Robocopy exit code
            # http://latkin.org/blog/2012/07/08/using-enums-in-powershell/
            if ($Result.ExitCode -band [Robocopy.ExitCode]'FailedCopyAttempts, FatalError') {
                if ($EnableExit) {
                    $host.SetShouldExit(1)
                } else {
                    $ErrorMessage =  @($Result.ExitCode) + (
                        # Try to provide additional info about error.
                        # WARNING: This WILL fail in localized Windows. E.g., "������" in Russian.
                        $Result.StdOut | Select-String -Pattern '\s*ERROR\s+:\s+(.+)' | ForEach-Object {
                            $_.Matches.Groups[1].Value
                        }
                    )

                    $ErrorMessage -join [System.Environment]::NewLine | Write-Error
                }
            } else {
                # Passthru Robocopy result
                if ($PassThru) {
                    $Result
                }
            }
        }
    }
}
##########################################################################################################
function Get-WSUSUtil{
    <#
    .SYNOPSIS
        Returns a FileInfo object for the WSUSUTIL.EXE program
    #>
    #Get WSUSUTIL.EXE path, we need to use it for our import process
    #Default WSUS install path
    Try{
        $Wsusutil = Get-Item (Join-Path $env:ProgramFiles "Update Services\Tools\WsusUtil.exe")
    }Catch{}
    if(!$Wsusutil){#WsusUtil not in the default path, let's try finding WsusUtil.exe from the log file path in WSUS Configuration
        Try{
            $logFilePath = $WSUSServer.GetConfiguration() | Select-Object -ExpandProperty LogFilePath
            $Wsusutil = Join-Path $(((Get-Item "$logFilePath").Parent).FullName) "Tools\WsusUtil.exe"
        }Catch{}
    }

    if(!(Test-Path $Wsusutil.FullName)){
        Add-TextToCMLog $LogFile "Could not find a valid path to WsusUtil.exe, cannot proceed with metadata import." $component 3
        Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
        Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
        Exit $($_.Exception.HResult)
    }
    Return $Wsusutil
}
##########################################################################################################

function Reset-WsusDatabase{
##########################################################################################################
    <#
    .SYNOPSIS
        This function DROPS (delete) the WSUS Database and recreates the database.
        This function is usually run before importing WSUS Metadata for a clean import.

    .DESCRIPTION
       After a couple of tests of various disconnected WSUS instances, the most reliable way to make sure
       that WSUS successfully reconciles approved updates with WSUS Content available seems to be to wipe
       SUSDB and recreate it.
    #>
##########################################################################################################
    Add-TextToCMLog $LogFile "Deleting and re-creating the WSUS Database." $component 1

    $WsusUtil = Get-WSUSUtil
    #Reusing logic in Connect-WSUSDB function to identify the server instance.
    If ($WSUSServerDB.IsUsingWindowsInternalDatabase){
        #Using the Windows Internal Database.
        If($WSUSServerDB.ServerName -eq "MICROSOFT##WID"){
            $ServerInstance = "\\.\pipe\MICROSOFT##WID\tsql\query"
        }
        Else{
            $ServerInstance = "\\.\pipe\MSSQL`$MICROSOFT##SSEE\sql\query"
        }
    }
    Else{
        #SQL Server
        $ServerInstance = "$($WSUSServerDB.ServerName)"
    }

    Try{
        Add-TextToCMLog $LogFile "Stopping WSUS Service." $component 1
        Stop-Service -Name "WsusService"
        Set-Service -Name "WsusService" -StartupType Manual #Prevent service from restarting automatically

        Add-TextToCMLog $LogFile "Stopping IIS Service." $component 1
        Stop-Service -Name "W3SVC"
        Set-Service -Name "W3SVC" -StartupType Manual #Prevent service from restarting automatically

    }Catch{
        Add-TextToCMLog $LogFile "Failed to stop WSUS Services." $component 3
        Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
        Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
        Exit $($_.Exception.HResult)
    }

    #Connect to the database server and drop SUSDB
    Try{
        Add-TextToCMLog $LogFile "Connecting to database server `"$($ServerInstance)`" and dropping database `"$($WSUSServerDB.DatabaseName)`"." $component 1
        $tsql =@"
USE [master]
GO
ALTER DATABASE [SUSDB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE
GO
DROP DATABASE [SUSDB]
GO
"@
        #If Database name is different from default of SUSDB (for some unknown/unsupported reason)
        if($($WSUSServerDB.DatabaseName) -ne "SUSDB"){
            $tsql = $tsql -replace "SUSDB","$($WSUSServerDB.DatabaseName)"
        }

        Invoke-Sqlcmd2 -ServerInstance $ServerInstance -Query $tsql -ParseGO

        Add-TextToCMLog $LogFile "Done dropping database `"$($WSUSServerDB.DatabaseName)`"." $component 1
    }
    Catch{
        Add-TextToCMLog $LogFile "Failed deleting `"$($WSUSServerDB.DatabaseName)`" for WSUS instance `"$($WSUSServer.name)`"." $component 3
        Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
        Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
        Exit $($_.Exception.HResult)
    }

    Try{
        Add-TextToCMLog $LogFile "Running wsusutil postinstall to re-create the WSUS database." $component 1

        if($WSUSServerDB.IsUsingWindowsInternalDatabase){#WID
            $result = Start-ConsoleProcess -FilePath $($Wsusutil.FullName) -ArgumentList "postinstall","CONTENT_DIR=`"$($CurrentWSUSContentDir)`""
        }else{#Actual SQL Server
            $result = Start-ConsoleProcess -FilePath $($Wsusutil.FullName) -ArgumentList "postinstall","SQL_INSTANCE_NAME=`"$($ServerInstance)`"","CONTENT_DIR=`"$($CurrentWSUSContentDir)`""
        }

        if($result.ExitCode -eq 0){
            Add-TextToCMLog $LogFile "WSUS Postinstall configuration was successful." $component 1
            if($result.StdOut){Add-TextToCMLog $LogFile "Output message: $($result.StdOut)" $component 1}
            if($result.StdErr){Add-TextToCMLog $LogFile "Output message: $($result.StdErr)" $component 2}
        }else{
            Add-TextToCMLog $LogFile "WSUS Postinstall configuration was not successful." $component 3
            Add-TextToCMLog $LogFile "Exit code: $($result.ExitCode)" $component 3
            if($result.StdOut){Add-TextToCMLog $LogFile "Output message: $($result.StdOut)" $component 3}
            if($result.StdErr){Add-TextToCMLog $LogFile "Output message: $($result.StdErr)" $component 3}
            Exit 1
        }
    }Catch{
        Add-TextToCMLog $LogFile "Failed to run the WSUS Postinstall to recreate the SUSDB." $component 3
        Add-TextToCMLog $LogFile "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
        Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
        Exit $($_.Exception.HResult)
    }

    #wsusutil postinstall should have started the IIS and WsusService services back on, let's check and set them back to automatic startup
    if((Get-Service -Name "W3SVC").Status -eq "Running"){
        Set-Service -Name "W3SVC" -StartupType Automatic
    }else{
        Add-TextToCMLog $LogFile "The IIS service `"W3SVC`" is not running, cannot continue with import." $component 3
        Exit 1
    }

    if((Get-Service -Name "WsusService").Status -eq "Running"){
        Set-Service -Name "WsusService" -StartupType Automatic
    }else{
        Add-TextToCMLog $LogFile "The WSUS service `"WsusService`" is not running, cannot continue with import." $component 3
        Exit 1
    }

    Add-TextToCMLog $LogFile "WSUS Database re-created and postinstall complete." $component 1
}
##########################################################################################################

Function Reset-WSUSServer{
##########################################################################################################
    <#
    .SYNOPSIS
        This function performs a "wsusutil reset" and waits until all approved updates are in a ready state.
    #>
##########################################################################################################
    Param
    (
        #Define how many iterations you wait before we stop checking if all approved updates are ready
        [Parameter(Mandatory = $false)]
        [int]$MaxIterations = 180,

        #Define how much time you wait between iterations to check how many updates are ready
        [Parameter(Mandatory = $false)]
        [int]$MinsToWait = 1
    )
    Try{
        $WSUSServer.ResetAndVerifyContentState()
        Add-TextToCMLog $LogFile "WSUS Reset started, this process will take a while to finish. WSUS will then start verifying that content is available for each update." $component 1
        Add-TextToCMLog $LogFile "This function will wait for a maximum of $($MinsToWait * $MaxIterations) minutes before aborting the script." $component 1
        Add-TextToCMLog $LogFile "Waiting a minute before checking updates readiness..." $component 1
        Start-Sleep -Seconds 60

        [int]$i = 1
        [bool]$ApprovedUpdatesReady = $false
        do{
            #$ApprovedUpdates = $WSUSServer.GetUpdates() | Where-Object {$_.IsApproved}
            $ApprovedUpdates = Get-WSUSUpdates -WSUSServer $WSUSServer | Where-Object {$_.IsApproved}

            $ready = $ApprovedUpdates | Where-Object {$_.State -eq "Ready"}

            if(($($ready.count) -eq $($ApprovedUpdates.count))){
                $ApprovedUpdatesReady = $true
            }else{
                Add-TextToCMLog $LogFile "$($ready.count)`/$($ApprovedUpdates.count) updates ready." $component 1
                $i++
                Start-Sleep -Seconds ($MinsToWait*60)
            }
        }while(!$ApprovedUpdatesReady -and ($i -lt $MaxIterations))

        if(!$ApprovedUpdatesReady -and ($i -ge $MaxIterations)){
            Add-TextToCMLog $LogFile "Reached maximum number of iterations and the content download is still not finished." $component 3
            Add-TextToCMLog $LogFile "WSUS Server might be able to provide patches to clients but 1 or more patches may be missing content. WSUS Server verification needed." $component 3
            Exit 1
        }else{
            Add-TextToCMLog $LogFile "WSUS Reset complete."  $component 1
        }
    }Catch{
        Add-TextToCMLog $LogFile "Failed to perform WSUS Reset and verify WSUS content." $component 3
        Add-TextToCMLog $LogFile "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
        Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
        Exit $($_.Exception.HResult)
    }
}
##########################################################################################################

Function Set-IISWsusPoolConfiguration{
##########################################################################################################
    <#
    .SYNOPSIS
        Modifies the IIS Pool for WSUS with the specified parameters.


    .DESCRIPTION
        Checks if the IIS application pool for WSUS is using default values and changes them according to
        specified values. If the IIS pool is not using default values, it will not change them unless
        the -Force switch is used.

        Recommended values by Microsoft: https://support.microsoft.com/en-ae/help/4490414/windows-server-update-services-best-practices
        Queue Length = 2000 (up from default of 1000)
        Idle Time-out (minutes) = 0 (down from the default of 20)
        Ping Enabled = False (from default of True)
        Private Memory Limit (KB) = 0 (unlimited, up from the default of 1843200 KB)
        Regular Time Interval (minutes) = 0 (to prevent a recycle, and modified from the default of 1740)

        These are the default values for the parameters used by the function.
    #>
##########################################################################################################
    Param
    (
        [Parameter(Mandatory = $false)]
        [string]$WSUSPoolName = "WsusPool",
        [Parameter(Mandatory = $false)]
        [int64]$QueueLength = 2000,
        [Parameter(Mandatory = $false)]
        [System.TimeSpan]$IdleTimeout = (New-TimeSpan -Minutes 0),
        [Parameter(Mandatory = $false)]
        [bool]$PingEnabled = $false,
        [Parameter(Mandatory = $false)]
        [int64]$PrivateMemoryLimit = 0,
        [Parameter(Mandatory = $false)]
        [System.TimeSpan]$RegularTimeInterval = (New-TimeSpan -Minutes 0)
    )
    Try{
        Add-TextToCMLog $LogFile "Checking IIS Application Pool `"$($WSUSPoolName)`"." $component 1

        <#
        #Default values of the IIS WSUS Pool
        [int64]$DefaultQueueLength = 1000
        [System.TimeSpan]$DefaultIdleTimeout = (New-TimeSpan -Minutes 20)
        [bool]$DefaultPingEnabled = $true
        [int64]$DefaultPrivateMemoryLimit = 1843200
        [System.TimeSpan]$DefaultRegularTimeInterval = (New-TimeSpan -Minutes 1740)
        #>

        Import-Module WebAdministration -Force #Make sure the IIS: drive is available.
        $configChanged = $false

        [int64]$currentQueueLength = Get-ItemProperty -Path "IIS:\AppPools\$($WSUSPoolName)" -Name "queueLength" | Select-Object -ExpandProperty Value
        [System.TimeSpan]$currentIdleTimeout = Get-ItemProperty -Path "IIS:\AppPools\$($WSUSPoolName)" -Name "processModel.idleTimeout" | Select-Object -ExpandProperty Value
        [bool]$currentPingEnabled = Get-ItemProperty -Path "IIS:\AppPools\$($WSUSPoolName)" -Name "processModel.pingingEnabled" | Select-Object -ExpandProperty Value
        [int64]$currentPrivateMemoryLimit = Get-ItemProperty -Path "IIS:\AppPools\$($WSUSPoolName)" -Name "recycling.periodicrestart.privateMemory" | Select-Object -ExpandProperty Value
        [System.TimeSpan]$currentRegularTimeInterval = Get-ItemProperty -Path "IIS:\AppPools\$($WSUSPoolName)" -Name "recycling.periodicrestart.time" | Select-Object -ExpandProperty Value


        if($currentQueueLength -ne $QueueLength){
            Add-TextToCMLog $LogFile "Changing queue length from `"$($currentQueueLength)`" to `"$($QueueLength)`"." $component 1
            Set-ItemProperty -Path "IIS:\AppPools\$($WSUSPoolName)" -Name queueLength -Value $QueueLength
            $configChanged = $true
        }

        if($currentIdleTimeout -ne $IdleTimeout){
            Add-TextToCMLog $LogFile "Changing Idle Time-out from `"$($currentIdleTimeout.TotalMinutes)`" minutes to `"$($IdleTimeout.TotalMinutes)`" minutes." $component 1
            Set-ItemProperty -Path "IIS:\AppPools\$($WSUSPoolName)" -Name "processModel.idleTimeout" -Value $IdleTimeout
            $configChanged = $true
        }

        if($currentPingEnabled -ne $PingEnabled){
            Add-TextToCMLog $LogFile "Changing Ping Enabled from `"$($currentPingEnabled)`" to `"$($PingEnabled)`"." $component 1
            Set-ItemProperty -Path "IIS:\AppPools\$($WSUSPoolName)" -Name "processModel.pingingEnabled" -Value $PingEnabled
            $configChanged = $true
        }

        if($currentPrivateMemoryLimit -ne $PrivateMemoryLimit){
            Add-TextToCMLog $LogFile "Changing Private Memory Limit from $($currentPrivateMemoryLimit) to $($PrivateMemoryLimit)." $component 1
            Set-ItemProperty -Path "IIS:\AppPools\$($WSUSPoolName)" -Name "recycling.periodicrestart.privateMemory" -Value $PrivateMemoryLimit
            $configChanged = $true
        }

        if($currentRegularTimeInterval -ne $RegularTimeInterval){
            Add-TextToCMLog $LogFile "Changing Regular Time Interval from `"$($currentRegularTimeInterval.TotalMinutes)`" minutes to `"$($RegularTimeInterval.TotalMinutes)`" minutes." $component 1
            Set-ItemProperty -Path "IIS:\AppPools\$($WSUSPoolName)" -Name "recycling.periodicrestart.time" -Value $RegularTimeInterval
            $configChanged = $true
        }

        if($configChanged){
            Add-TextToCMLog $LogFile "IIS Pool `"$($WSUSPoolName)`" configuration changed, recycling the WSUS Pool." $component 1
            (Get-Item IIS:\AppPools\$($WSUSPoolName)).Recycle()
        }else{
            Add-TextToCMLog $LogFile "Did not need to modify IIS Application Pool configuration `"$($WSUSPoolName)`"." $component 1
        }
        Add-TextToCMLog $LogFile "Done checking/updating the configuration of the IIS Application Pool `"$($WSUSPoolName)`"." $component 1
    } Catch{
        Add-TextToCMLog $LogFile "Failed to check or update IIS configuration for the WSUS Pool." $component 3
        Add-TextToCMLog $LogFile "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
        Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
        Exit $($_.Exception.HResult)
    }
}
##########################################################################################################

Function Add-WSUSDBCustomIndexes{
    <#
    .SYNOPSIS
    Taken from https://damgoodadmin.com/2017/11/05/fully-automate-software-update-maintenance-in-cm/
    Adds custom indexes to the WSUS Database.
    #>
	Add-TextToCMLog $LogFile "User selected AddIndex. Will try to verify indexes and create where necessary." $component 1

	$SqlConnection = Connect-WSUSDB $WSUSServerDB

    If(!$SqlConnection)
    {
		Add-TextToCMLog $LogFile "Failed to connect to the WSUS database '$($WSUSServerDB.ServerName)'." $component 3
    }
    Else{

		#Loop through the hashtable and create the indexes.
		$FailedIndex = $False
		ForEach ($TableName in $IndexArray.Keys){

			#Determine if the index exists and create it if not.
			$Index = Invoke-SQLCMD $SqlConnection "Use $($WSUSServerDB.DatabaseName);SELECT * FROM sys.indexes WHERE name='IX_DGA_$TableName' AND object_id = OBJECT_ID('$TableName')"

			#If the index doesn't exist then create it.
			If($Index.Rows.Count -eq 0 ){
				Add-TextToCMLog $LogFile "The index IX_DGA_$TableName does not exist and will be created." $component 1

				If (!$WhatIfPreference){

					#Add the index.
					$Index = Invoke-SQLCMD $SqlConnection "Use $($WSUSServerDB.DatabaseName);CREATE NONCLUSTERED INDEX IX_DGA_$TableName ON $TableName($($IndexArray[$TableName]))"

					#Verify that the index exists now.
					$Index = Invoke-SQLCMD $SqlConnection "Use $($WSUSServerDB.DatabaseName);SELECT * FROM sys.indexes WHERE name='IX_DGA_$TableName' AND object_id = OBJECT_ID('$TableName')"
					If($Index.Rows.Count -eq 0 ){
						Add-TextToCMLog $LogFile "Failed to create the index IX_DGA_$TableName." $component 2
						$FailedIndex = $True
                    }
                    Else{
						Add-TextToCMLog $LogFile "Successfully created the index IX_DGA_$TableName." $component 1
					}
				}
			}
		} #ForEach IndexArray

		If ($FailedIndex){
			Add-TextToCMLog $LogFile "Some indexes failed to create." $component 1
        }
        Else{
			Add-TextToCMLog $LogFile "All indexes have been added or verified." $component 1
		}

		#Disconnect from the database.
		$SqlConnection.Close()
	} #Connect-WSUSDB
}
##########################################################################################################

Function Remove-WSUSDBCustomIndexes{
    <#
    .SYNOPSIS
    Taken from https://damgoodadmin.com/2017/11/05/fully-automate-software-update-maintenance-in-cm/
    Removes custom indexes from the WSUS Database.
    #>

    Add-TextToCMLog $LogFile "User selected RemoveCustomIndexes. Will try to remove the custom indexes." $component 1

	$SqlConnection = Connect-WSUSDB $WSUSServerDB

    If(!$SqlConnection)
    {
		Add-TextToCMLog $LogFile "Failed to connect to the WSUS database '$($WSUSServerDB.ServerName)'." $component 3
    }
    Else{

		#Loop through the hashtable and remove the indexes.
		$FailedIndex = $False
		ForEach ($TableName in $IndexArray.Keys){

			#Determine if the index exists.
			$Index = Invoke-SQLCMD $SqlConnection "Use $($WSUSServerDB.DatabaseName);SELECT * FROM sys.indexes WHERE name='IX_DGA_$TableName' AND object_id = OBJECT_ID('$TableName')"

			#If the index exists then remove it.
			If($Index.Rows.Count -gt 0 ){
				Add-TextToCMLog $LogFile "The index IX_DGA_$TableName exists and will be removed." $component 1

				If (!$WhatIfPreference){

					#Remove the index.
					$Index = Invoke-SQLCMD $SqlConnection "Use $($WSUSServerDB.DatabaseName);DROP INDEX IX_DGA_$TableName ON $TableName"

					#Verify that the index no longer exists.
					$Index = Invoke-SQLCMD $SqlConnection "Use $($WSUSServerDB.DatabaseName);SELECT * FROM sys.indexes WHERE name='IX_DGA_$TableName' AND object_id = OBJECT_ID('$TableName')"
					If($Index.Rows.Count -gt 0 ){
						Add-TextToCMLog $LogFile "Failed to remove the index IX_DGA_$TableName." $component 2
						$FailedIndex = $True
                    }
                    Else{
						Add-TextToCMLog $LogFile "Successfully removed the index IX_DGA_$TableName." $component 1
					}
				}
			}
		} #ForEach IndexArray

		If ($FailedIndex){
			Add-TextToCMLog $LogFile "Some indexes failed to remove." $component 1
        }
        Else{
			Add-TextToCMLog $LogFile "All indexes have been removed." $component 1
		}

		#Disconnect from the database.
		$SqlConnection.Close()
	} #Connect-WSUSDB
}
##########################################################################################################

#Taken from ConfigMgr Client Health script, see https://www.andersrodland.com/configmgr-client-health/
Function Test-XML {
        <#
        .SYNOPSIS
        Test the validity of an XML file
        #>
        [CmdletBinding()]
        param ([parameter(mandatory=$true)][ValidateNotNullorEmpty()][string]$xmlFilePath)
        # Check the file exists
        if (!(Test-Path -Path $xmlFilePath)) { throw "$xmlFilePath is not valid. Please provide a valid path to the .xml config file" }
        # Check for Load or Parse errors when loading the XML file
        $xml = New-Object System.Xml.XmlDocument
        try {
            $xml.Load((Get-ChildItem -Path $xmlFilePath).FullName)
            return $true
        }
        catch [System.Xml.XmlException] {
            Write-Error "$xmlFilePath : $($_.toString())"
            Write-Error "Configuration file $Config is NOT valid XML. Script will not execute."
            return $false
        }
    }
##########################################################################################################

Function Show-LocallyPublishedUpdates {
        <#
        .SYNOPSIS
        This function will make sure any locally published updates in the WSUS Database are shown in the WSUS Console
        #>
        [CmdletBinding()]
        param()

        #Reusing logic in Connect-WSUSDB function to identify the server instance.
        If ($WSUSServerDB.IsUsingWindowsInternalDatabase){
            #Using the Windows Internal Database.
            If($WSUSServerDB.ServerName -eq "MICROSOFT##WID"){
                $ServerInstance = "\\.\pipe\MICROSOFT##WID\tsql\query"
            }
            Else{
                $ServerInstance = "\\.\pipe\MSSQL`$MICROSOFT##SSEE\sql\query"
            }
        }
        Else{
            #SQL Server
            $ServerInstance = "$($WSUSServerDB.ServerName)"
        }

        #Connect to the database server and drop SUSDB
        Try{
            Add-TextToCMLog $LogFile "Updating database to show locally published updates in WSUS." $component 1
            $tsql = "UPDATE [dbo].[tbUpdate] SET IsLocallyPublished = 0 WHERE IsLocallyPublished = 1"

            Invoke-Sqlcmd2 -ServerInstance $ServerInstance -Database $($WSUSServerDB.DatabaseName) -Query $tsql

            Add-TextToCMLog $LogFile "Done updating database." $component 1
        }
        Catch{
            Add-TextToCMLog $LogFile "Failed updating `"$($WSUSServerDB.DatabaseName)`" for WSUS instance `"$($WSUSServer.name)`"." $component 3
            Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
            Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
            Exit $($_.Exception.HResult)
        }
    }
##########################################################################################################
#endregion Functions

$scriptVersion = "0.9.3"
$mainComponent = "Invoke-WSUSImportExportManager"
$component = $mainComponent
$scriptPath = split-path -parent $MyInvocation.MyCommand.Definition
$IndexArray = @{
                'tbLocalizedProperty' = 'LocalizedPropertyID'
                'tbLocalizedPropertyForRevision'='LocalizedPropertyID'
                'tbRevision' = 'RowID, RevisionID'
                'tbRevisionSupersedesUpdate' = 'SupersededUpdateID'
                }

$IsXMLConfigSelected = $false
$IsMetadataSelected = $false
$IsImportingMetadataWithoutXMLFile = $false
$IsWSUSContentSelected = $false


#region Parameter validation

#Taken from ConfigMgr Client Health script, see https://www.andersrodland.com/configmgr-client-health/
# Read configuration from XML file
if (Test-Path $ConfigFile) {
    # Test if valid XML
    if ((Test-XML -xmlFilePath $ConfigFile) -ne $true ) { Exit 1 }

    # Load XML file into variable
    Try { $Xml = [xml](Get-Content -Path $ConfigFile) }
    Catch {
        $ErrorMessage = $_.Exception.Message
        $text = "Error, could not read $ConfigFile. Check file location and share/ntfs permissions. Is XML config file damaged?"
        $text += "`nError message: $ErrorMessage"
        Write-Error $text
        Exit 1
    }
}
else {
    $text = "Error, could not access $ConfigFile. Check file location and share/ntfs permissions. Did you misspell the name?"
    Write-Error $text
    Exit 1
}

#LogFile validation
$LogFile = $xml.Configuration.LogFile
if($LogFile -notlike "*.log"){
    Write-Error "LogFile does not end with .log, please provide a valid log file name"
    Exit 1
}
$ParentPath = Split-Path $LogFile
if($ParentPath -eq ""){#Filename only, using script location
    $LogFile = Join-Path $scriptPath $LogFile
}elseif(!(Test-Path $ParentPath)){
    Try{
        [void](New-Item -ItemType Directory -Path $ParentPath -ErrorAction Stop)
    }Catch{
        $text = "`nCould not create folder at `"$($ParentPath)`""
        $text += "`nError: $($_.Exception.HResult)): $($_.Exception.Message)"
        $text += "`n$($_.InvocationInfo.PositionMessage)"
        Write-Error $text
        Exit 1
    }
}

$LogFile = "filesystem::$($LogFile)"

Try{
    $MaxLogSize = [int]$Xml.Configuration.MaxLogSize
}Catch{}
If(($null -eq $MaxLogSize) -or ($MaxLogSize -eq 0)){
    #Use Default MaxLogSize
    $MaxLogSize = [int]2621440
}

#If the log file exists and is larger then the maximum then roll it over.
If (Test-path  $LogFile -PathType Leaf) {
    If ((Get-Item $LogFile).length -gt $MaxLogSize){
        Move-Item -Force $LogFile ($LogFile -replace ".$","_") -WhatIf:$False
    }
}

Add-TextToCMLog $LogFile "$component started (Version $($scriptVersion))." $component 1

#Validating other parameters
Try{
    #Server parameters
    [string]$StandAloneWSUS = $Xml.Configuration.Server.WSUSHostname
    [int]$StandAloneWSUSPort = $Xml.Configuration.Server.WSUSPortNumber
    [bool]$StandAloneWSUSSSL = (($Xml.Configuration.Server.WSUSSSLEnabled) -eq [bool]::TrueString)

    #Actions
    $Actions = $Xml.Configuration.Actions.Action
    [bool]$Import = (($Actions | Where-Object {$_.Name -eq "Import"} | Select-Object -ExpandProperty Enabled) -eq [bool]::TrueString)
    If($Import){
        $ImportOptions = ($Actions | Where-Object {$_.Name -eq "Import"}).Option
        [string]$SourceDir = $ImportOptions | Where-Object {$_.Name -eq "SourceDir"} | Select-Object -ExpandProperty Location
        [bool]$IsWSUSContentSelected = (($ImportOptions | Where-Object {$_.Name -eq "WSUSContent"} | Select-Object -ExpandProperty Enabled) -eq [bool]::TrueString)
        [bool]$IsMetadataSelected = (($ImportOptions | Where-Object {$_.Name -eq "Metadata"} | Select-Object -ExpandProperty Enabled) -eq [bool]::TrueString)
        if($IsMetadataSelected){
            [string]$MetadataFilename = $ImportOptions | Where-Object {$_.Name -eq "Metadata"} | Select-Object -ExpandProperty Filename
            [bool]$DropSUSDB = (($ImportOptions | Where-Object {$_.Name -eq "Metadata"} | Select-Object -ExpandProperty DropSUSDB) -eq [bool]::TrueString)
        }
        [bool]$IsXMLConfigSelected = (($ImportOptions | Where-Object {$_.Name -eq "XMLConfiguration"} | Select-Object -ExpandProperty Enabled) -eq [bool]::TrueString)
        if($IsXMLConfigSelected){
            [string]$XMLConfigFileName = $ImportOptions | Where-Object {$_.Name -eq "XMLConfiguration"} | Select-Object -ExpandProperty Filename
            [bool]$IncludeApprovals = (($ImportOptions | Where-Object {$_.Name -eq "XMLConfiguration"} | Select-Object -ExpandProperty IncludeApprovals) -eq [bool]::TrueString)
        }
    }
    [bool]$Export = (($Actions | Where-Object {$_.Name -eq "Export"} | Select-Object -ExpandProperty Enabled) -eq [bool]::TrueString)
    If($Export){
        $ExportOptions = ($Actions | Where-Object {$_.Name -eq "Export"}).Option
        [string]$DestinationDir = $ExportOptions | Where-Object {$_.Name -eq "DestinationDir"} | Select-Object -ExpandProperty Location
        [bool]$IsWSUSContentSelected = (($ExportOptions | Where-Object {$_.Name -eq "WSUSContent"} | Select-Object -ExpandProperty Enabled) -eq [bool]::TrueString)
        [bool]$IsMetadataSelected = (($ExportOptions | Where-Object {$_.Name -eq "Metadata"} | Select-Object -ExpandProperty Enabled) -eq [bool]::TrueString)
        if($IsMetadataSelected){
            [string]$MetadataFilename = $ExportOptions | Where-Object {$_.Name -eq "Metadata"} | Select-Object -ExpandProperty Filename
        }
        [bool]$IsXMLConfigSelected = (($ExportOptions | Where-Object {$_.Name -eq "XMLConfiguration"} | Select-Object -ExpandProperty Enabled) -eq [bool]::TrueString)
        if($IsXMLConfigSelected){
            [string]$XMLConfigFileName = $ExportOptions | Where-Object {$_.Name -eq "XMLConfiguration"} | Select-Object -ExpandProperty Filename
            [bool]$IncludeApprovals = (($ExportOptions | Where-Object {$_.Name -eq "XMLConfiguration"} | Select-Object -ExpandProperty IncludeApprovals) -eq [bool]::TrueString)
        }
    }
    [bool]$ReindexSUSDB = (($Actions | Where-Object {$_.Name -eq "ReindexSUSDB"} | Select-Object -ExpandProperty Enabled) -eq [bool]::TrueString)
    [bool]$UseCustomIndexes = (($Actions | Where-Object {$_.Name -eq "UseCustomIndexes"} | Select-Object -ExpandProperty Enabled) -eq [bool]::TrueString)
    [bool]$RemoveCustomIndexes = (($Actions | Where-Object {$_.Name -eq "RemoveCustomIndexes"} | Select-Object -ExpandProperty Enabled) -eq [bool]::TrueString)

    [bool]$SetIISWSUSPoolSettings = (($Actions | Where-Object {$_.Name -eq "SetIISWSUSPoolSettings"} | Select-Object -ExpandProperty Enabled) -eq [bool]::TrueString)
    If($SetIISWSUSPoolSettings){
        $PoolSettings = ($Actions | Where-Object {$_.Name -eq "SetIISWSUSPoolSettings"}).PoolSetting
        [string]$WSUSPoolName = ($PoolSettings | Where-Object {$_.Name -eq "WSUSPoolName"}).InnerText
        [int64]$QueueLength = ($PoolSettings | Where-Object {$_.Name -eq "QueueLength"}).InnerText
        [TimeSpan]$IdleTimeout = New-TimeSpan -Minutes  ([int](($PoolSettings | Where-Object {$_.Name -eq "IdleTimeout"}).InnerText))
        [bool]$PingEnabled = ((($PoolSettings | Where-Object {$_.Name -eq "PingEnabled"}).InnerText) -eq [bool]::TrueString)
        [int64]$PrivateMemoryLimit = ($PoolSettings | Where-Object {$_.Name -eq "PrivateMemoryLimit"}).InnerText
        [TimeSpan]$RegularTimeInterval = New-TimeSpan -Minutes  ([int](($PoolSettings | Where-Object {$_.Name -eq "RegularTimeInterval"}).InnerText))
    }

    [bool]$ShowLocallyPublishedUpdates = (($Actions | Where-Object {$_.Name -eq "ShowLocallyPublishedUpdates"} | Select-Object -ExpandProperty Enabled) -eq [bool]::TrueString)

}Catch{
    Add-TextToCMLog $LogFile  "Error validating configuration file settings." $component 3
    Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
    Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
    Exit $($_.Exception.HResult)
}



#Make sure at least one action parameter was given.
If (!$UseCustomIndexes -and !$RemoveCustomIndexes -and !$Export -and !$Import -and !$ReindexSUSDB -and !$SetIISWSUSPoolSettings -and !$ShowLocallyPublishedUpdates) {
    Add-TextToCMLog $LogFile "You must choose one of the action parameters: Import, Export, UseCustomIndexes, RemoveCustomIndexes, ReindexSUSDB, SetIISWSUSPoolSettings or ShowLocallyPublishedUpdates" $component 3
    Exit 1
}

#Make sure we are not adding and removing custom indexes in the same execution
If ($UseCustomIndexes -and $RemoveCustomIndexes) {
    Add-TextToCMLog $LogFile "You cannot add and remove custom indexes at the same time, choose one." $component 3
    Exit 1
}

#If importing or exporting, make sure only 1 parameter is selected
If ($Export -and $Import){
    Add-TextToCMLog $LogFile "You cannot import and export at the same time, choose one." $component 3
    Exit 1
}

#If importing or exporting, make sure the required arguments are also specified
If($Export -or $Import){
    #Validate Import/Export options
    if(!$IsXMLConfigSelected -and !$IsMetadataSelected -and !$IsWSUSContentSelected){
        Add-TextToCMLog $LogFile "If using Import or Export, you need to select at least one component to import or export, valid options are: XMLConfig, Metadata, WSUSContent" $component 3
        Exit 1
    }
    #Validate directory
    If($Import){
        If(!$SourceDir){
            Add-TextToCMLog $LogFile "You must specify a valid source directory which will be used for the import process." $component 3
            Exit 1
        }
        if($SourceDir.StartsWith(".")){
            Add-TextToCMLog $LogFile "Source directory starts with a `".`", assuming source directory is a subfolder of the script path." $component 1
            $SourceDir = Join-Path $scriptPath $SourceDir.Substring(1,$SourceDir.Length-1)
            Add-TextToCMLog $LogFile "Source Directory is now `"$($SourceDir)`"." $component 1
        }
        If(!(Test-Path $SourceDir -PathType Container)){
            Add-TextToCMLog $LogFile  "Folder `"$($SourceDir)`" could not be found or is not a folder." $component 3
            Exit 1
        }
    }elseif($Export){
        If(!$DestinationDir){
            Add-TextToCMLog $LogFile "You must specify a valid source directory which will be used for the export process." $component 3
            Exit 1
        }
        if($DestinationDir.StartsWith(".")){
            Add-TextToCMLog $LogFile "Destination directory starts with a `".`", assuming destination directory is a subfolder of the script path." $component 1
            $DestinationDir = Join-Path $scriptPath $DestinationDir.Substring(1,$DestinationDir.Length-1)
            Add-TextToCMLog $LogFile "Destination Directory is now `"$($DestinationDir)`"." $component 1
        }
        If(!(Test-Path $DestinationDir -PathType Container)){
            Try{
                Remove-Item -Path $DestinationDir -ErrorAction SilentlyContinue
                New-Item -ItemType Directory -Path $DestinationDir -ErrorAction Stop | Out-Null
            } Catch{
                Add-TextToCMLog $LogFile  "Could not create folder `"$($DestinationDir)`"" $component 3
                Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
                Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
                Exit $($_.Exception.HResult)
            }
        }
    }
    if($Import -and $IsMetadataSelected -and !$IsXMLConfigSelected){
            $IsImportingMetadataWithoutXMLFile = $true
    }
}


#Make sure WSUS Server is specified
If (!$StandAloneWSUS){
    Add-TextToCMLog $LogFile "You must specify the WSUS Server, variable `"StandAloneWSUS`" is null or empty." $component 3
    Exit 1
}

#endregion Parameter validation

#Try to load the UpdateServices module.
Try {
    [reflection.assembly]::LoadWithPartialName("Microsoft.UpdateServices.Administration") | out-null
} Catch {
    Add-TextToCMLog $LogFile "Failed to load the UpdateServices module." $component 3
    Add-TextToCMLog $LogFile "Please make sure that WSUS Admin Console is installed on this machine" $component 3
    Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
    Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
}

#Try and figure out WSUS connection details based on the parameters given.
If ($StandAloneWSUS){
    $WSUSFQDN = $StandAloneWSUS

    #If a port wasn't passed then set the default the port based on the SSL setting.
    If (!$StandAloneWSUSPort){
        If ($StandAloneWSUSSSL){
            $WSUSPort = 8531
        }
        Else{
            $WSUSPort = 8530
        }
    }
    Else{
        $WSUSPort = $StandAloneWSUSPort
    }
    $WSUSSSL = $StandAloneWSUSSSL
}

#Connect to the WSUS Server
Try{
    $WSUSServer = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer($WSUSFQDN, $WSUSSSL, $WSUSPort)
} Catch {
    Add-TextToCMLog $LogFile "Failed to connect to the WSUS server $WSUSFQDN on port $WSUSPort with$(If(!$WSUSSSL){"out"}) SSL." $component 3
    Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
    Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
    $WSUSServer = $null
    Exit $($_.Exception.HResult)
}

#If the WSUS object is not instantiated then exit.
If ($null -eq $WSUSServer) {
    if($WSUSSSL){
        Add-TextToCMLog $LogFile "Failed to connect to WSUS Server $($WSUSFQDN) on port ($WSUSPort) using SSL." $component 3
    }else{
        Add-TextToCMLog $LogFile "Failed to connect to WSUS Server $($WSUSFQDN) on port ($WSUSPort)" $component 3
    }
    Exit 1
}
Add-TextToCMLog $LogFile "Connected to WSUS server $WSUSFQDN." $component 1


$WSUSServerDB = Get-WSUSDB $WSUSServer
If(!$WSUSServerDB)
{
	Add-TextToCMLog $LogFile "Failed to get the WSUS database configuration." $component 3
    Exit 1
}

if($SetIISWSUSPoolSettings){
    Set-IISWsusPoolConfiguration -WSUSPoolName $WSUSPoolName -QueueLength $QueueLength -IdleTimeout $IdleTimeout -PingEnabled $PingEnabled -PrivateMemoryLimit $PrivateMemoryLimit -RegularTimeInterval $RegularTimeInterval
}

if($Import -or $Export){
    Try{
        #Content directory = Folder where "WSUSContent" and "UpdateServicesPackages" reside, also known as CONTENT_DIR when using wsusutil.exe postinstall command
        $CurrentWSUSContentDir = ((Get-Item ($WSUSServer.GetConfiguration() | Select-Object -ExpandProperty LocalContentCachePath)).Parent).FullName

        If(!$CurrentWSUSContentDir){
            Add-TextToCMLog $LogFile "Import/Export operation aborted, could not determine the WSUS Content directory. " $component 3
            Add-TextToCMLog $LogFile "Is your WSUS instance correctly configured? Did you run the post install configuration?" $component 3
            Exit 1
        }

        #[string[]]$FoldersToCopy = "WSUSContent","UpdateServicesPackages"
        [string[]]$FoldersToCopy = "WSUSContent"
        ##########################################################################################################

        If($Export){
            if($IsMetadataSelected){
                $MetadataFilename = Join-Path $DestinationDir $MetadataFilename
                $MetadataExportLogFile = Join-Path $scriptPath "WSUSMetadataExport.log"
            }
            if($IsXMLConfigSelected){
                $XMLConfigFileName = Join-Path $DestinationDir $XMLConfigFileName
            }
            Add-TextToCMLog $LogFile "Perfoming EXPORT of WSUS Server $($WSUSFQDN)." $component 1
            if($IsXMLConfigSelected){
                $component = "WSUS Export - Configuration"
                Try{
                    Add-TextToCMLog $LogFile "Exporting WSUS configuration to XML file `"$($XMLConfigFileName)`"" $component 1
                    Invoke-WSUSSyncCheck -WSUSServer $WSUSServer -SyncLeadTime 0
                    Export-WSUSConfigurationToXML -fileName $XMLConfigFileName
                    Add-TextToCMLog $LogFile "WSUS Configuration exported successfully." $component 1
                } Catch{
                    Add-TextToCMLog $LogFile "Failed to export WSUS XML configuration.." $component 3
                    Add-TextToCMLog $LogFile "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
                    Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
                    Exit $($_.Exception.HResult)
                }

            }
            if($IsMetadataSelected){
                $component = "WSUS Export - Metadata"
                Try{
                    Invoke-WSUSSyncCheck -WSUSServer $WSUSServer -SyncLeadTime 0
                    Add-TextToCMLog $LogFile "Exporting WSUS Metadata to `"$($MetadataFilename)`"" $component 1
                    Add-TextToCMLog $LogFile "WSUS Metadata export in progress. This will take a while." $component 1
                    #You can use a .CAB file format or .XML.GZ format for the filename. Make sure to use .XML.GZ or it will fail (file too big)
                    $WSUSServer.ExportUpdates($MetadataFilename, $MetadataExportLogFile)
                    Add-TextToCMLog $LogFile "WSUS Metadata exported successfully." $component 1
                } Catch{
                    Add-TextToCMLog $LogFile "Failed to export WSUS Metadata." $component 3
                    Add-TextToCMLog $LogFile "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
                    Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
                    Exit $($_.Exception.HResult)
                }
            }
            if($IsWSUSContentSelected){
                $component = "WSUS Export - Content"
                Try{
                    foreach($folder in $FoldersToCopy){
                        $source = Join-Path $CurrentWSUSContentDir $folder
                        $destination = Join-Path $DestinationDir $folder
                        $robocopyLog = Join-Path $scriptPath "RobocopyExportLog_$($folder).log"
                        Add-TextToCMLog $LogFile "Mirroring content from `"$($source)`" to `"$($destination)`"" $component 1
                        Add-TextToCMLog $LogFile "Using Robocopy to perform the operation, see export log at `"$($robocopyLog)`" for details" $component 1

                        #ROBOCOPY OPTIONS USED: /MIR=Mirror source and destination, /XA:SH=Ignore System and Hidden files, /W:10=Wait 10 seconds to retry, -Retry 3=Retry 3 times,/MT=multi thread
                        $robocopyResult = Invoke-Robocopy -Path $($source) -Destination $($destination) -ArgumentList "/MIR","/XA:SH","/W:10","/MT","/LOG:`"$($robocopyLog)`"" -Retry 3 -PassThru
                        Add-TextToCMLog $LogFile "Done mirroring folder `"$folder`", robocopy finished with exit code `"$($robocopyResult.ExitCode)`"." $component 1
                    }
                } Catch{
                    Add-TextToCMLog $LogFile "WSUS Content export failed." $component 3
                    Add-TextToCMLog $LogFile "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
                    Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
                    Exit $($_.Exception.HResult)
                }
            }
            $component = $mainComponent
            Add-TextToCMLog $LogFile "Done perfoming EXPORT of WSUS Server $($WSUSFQDN)." $component 1
        }


        #IMPORT FUNCTION
        If($Import){
            if($IsMetadataSelected){
                $MetadataFilename = Join-Path $SourceDir $MetadataFilename
                $MetadataImportLogFile = Join-Path $scriptPath "WSUSMetadataImport.log"
            }
            if($IsXMLConfigSelected){
                $XMLConfigFileName = Join-Path $SourceDir $XMLConfigFileName
            }
            Add-TextToCMLog $LogFile "Perfoming IMPORT of WSUS Server $($WSUSFQDN)." $component 1
            if($IsMetadataSelected){
                $component = "WSUS Import - Metadata"

                if($DropSUSDB){
                    Reset-WsusDatabase
                }

                #BEFORE Importing metadata, let's make sure the WSUS Configuration matches what is in the XML file.
                if(!$IsImportingMetadataWithoutXMLFile){
                    Try{
                        Add-TextToCMLog $LogFile "Updating WSUS configuration only before importing metadata." $component 1
                        Invoke-WSUSSyncCheck -WSUSServer $WSUSServer -SyncLeadTime 5
                        Import-WSUSConfigurationFromXML -fileName $XMLConfigFileName -WSUSConfigOnly
                        Add-TextToCMLog $LogFile "Done updating WSUS configuration." $component 1
                    } Catch{
                        Add-TextToCMLog $LogFile "Failed to update WSUS configuration." $component 3
                        Add-TextToCMLog $LogFile "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
                        Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
                        Exit $($_.Exception.HResult)
                    }
                }else{
                    Add-TextToCMLog $LogFile "Importing WSUS Metadata without updating WSUS configuration with XML file." $component 2
                    Add-TextToCMLog $LogFile "Make sure languages selected and update files options are matching the WSUS Server where the metadata were exported or you will be missing content." $component 2
                }

                Try{
                    Add-TextToCMLog $LogFile "Importing WSUS Metadata from file `"$($MetadataFilename)`"" $component 1
                    Add-TextToCMLog $LogFile "This could take a while to complete..." $component 1

                    $Wsusutil = Get-WSUSUtil
                    $result = Start-ConsoleProcess -FilePath $($Wsusutil.FullName) -ArgumentList "import","$($MetadataFilename)","$($MetadataImportLogFile)"
                    if($result.ExitCode -eq 0){
                        Add-TextToCMLog $LogFile "WSUS Metadata import was successful." $component 1
                        if($result.StdOut){Add-TextToCMLog $LogFile "Output message: $($result.StdOut)" $component 1}
                        if($result.StdErr){Add-TextToCMLog $LogFile "Output message: $($result.StdErr)" $component 2}

                        Invoke-WSUSSyncCheck -WSUSServer $WSUSServer -SyncLeadTime 5
                        if($UseCustomIndexes){
                            Add-WSUSDBCustomIndexes
                        }

                        Invoke-WSUSSyncCheck -WSUSServer $WSUSServer -SyncLeadTime 5
                        #Reindexing Database after metadata import to prevent timeout issues when importing a lot of updates.
                        Invoke-WSUSDBReindex

                    }else{
                        Add-TextToCMLog $LogFile "WSUS Metadata import was not successful." $component 3
                        Add-TextToCMLog $LogFile "Exit code: $($result.ExitCode)" $component 3
                        if($result.StdOut){Add-TextToCMLog $LogFile "Output message: $($result.StdOut)" $component 3}
                        if($result.StdErr){Add-TextToCMLog $LogFile "Output message: $($result.StdErr)" $component 3}
                        Exit $($result.ExitCode)
                    }
                } Catch{
                    Add-TextToCMLog $LogFile "Failed to import WSUS Metadata." $component 3
                    Add-TextToCMLog $LogFile "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
                    Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
                    Exit $($_.Exception.HResult)
                }

                #Making sure the IIS Application pool is up and running, sometimes the WSUSPool is not started.
                Try{
                    $WSUSPoolName = "WsusPool"
                    Import-Module WebAdministration
                    $wsusPool = (Get-Item IIS:\AppPools\$($WSUSPoolName))
                    if($wsusPool.State -ne "Started"){
                        Start-Sleep -Seconds 30
                    }
                    $wsusPool = (Get-Item IIS:\AppPools\$($WSUSPoolName))
                    if($wsusPool.State -ne "Started"){
                        Add-TextToCMLog $LogFile "Attempting to start the IIS Application pool for WSUS." $component 2
                        $wsusPool.Start()
                        Start-Sleep -Seconds 30
                        $wsusPool = (Get-Item IIS:\AppPools\$($WSUSPoolName))
                        if($wsusPool.State -ne "Started"){
                            Add-TextToCMLog $LogFile "Unable to start the IIS Application pool for WSUS." $component 3
                            Exit 1
                        }
                    }
                }Catch{
                    Add-TextToCMLog $LogFile "Failed to verify the state of the IIS Application pool for WSUS." $component 3
                    Add-TextToCMLog $LogFile "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
                    Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
                    Exit $($_.Exception.HResult)
                }
            }

            if($IsWSUSContentSelected){
                $component = "WSUS Import - Content"
                Try{
                    Add-TextToCMLog $LogFile "Stopping WSUS Service." $component 1
                    Stop-Service -Name WsusService -Force
                    Set-Service -Name WsusService -StartupType Manual
                    Add-TextToCMLog $LogFile "WSUS Service stopped." $component 1

                    Add-TextToCMLog $LogFile "Removing all current BITS transfer to avoid issues with the content copy." $component 1
                    Get-BitsTransfer -AllUsers | Remove-BitsTransfer
                    Add-TextToCMLog $LogFile "Removed BITS transfers." $component 1

                    foreach($folder in $FoldersToCopy){
                        $source = Join-Path $SourceDir $folder
                        if(Test-Path $source){
                            $destination = Join-Path $CurrentWSUSContentDir $folder
                            $robocopyLog = Join-Path $scriptPath "RobocopyImportLog_$($folder).log"
                            Add-TextToCMLog $LogFile "Mirroring content from `"$($source)`" to `"$($destination)`"" $component 1
                            Add-TextToCMLog $LogFile "Using Robocopy to perform the operation, see import log at `"$($robocopyLog)`" for details" $component 1

                            #ROBOCOPY OPTIONS USED: /MIR=Mirror source and destination, /XA:SH=Ignore System and Hidden files, /W:10=Wait 10 seconds to retry, -Retry 3=Retry 3 times,/MT=multi thread
                            $robocopyResult = Invoke-Robocopy -Path $($source) -Destination $($destination) -ArgumentList "/MIR","/XA:SH","/W:10","/MT","/LOG:`"$($robocopyLog)`"" -Retry 3 -PassThru
                            Add-TextToCMLog $LogFile "Done mirroring folder `"$folder`", robocopy finished with exit code `"$($robocopyResult.ExitCode)`"." $component 1
                        }else{
                            Add-TextToCMLog $LogFile "Folder `"$folder`" not found in `"$SourceDir`", skipping copy." $component 1
                        }
                    }

                    Add-TextToCMLog $LogFile "Starting the WSUS Service." $component 1
                    Start-Service -Name WsusService
                    Set-Service -Name WsusService -StartupType Automatic
                    Add-TextToCMLog $LogFile "WSUS Service started." $component 1
                } Catch{
                    Add-TextToCMLog $LogFile "WSUS Content copy failed." $component 3
                    Add-TextToCMLog $LogFile "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
                    Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
                    Exit $($_.Exception.HResult)
                }
            }

            if($IsXMLConfigSelected){
                $component = "WSUS Import - Configuration"
                Invoke-WSUSSyncCheck -WSUSServer $WSUSServer -SyncLeadTime 15
                Try{
                    Add-TextToCMLog $LogFile "Importing WSUS configuration from XML file `"$XMLConfigFileName`"." $component 1
                    Import-WSUSConfigurationFromXML -fileName $XMLConfigFileName
                    Add-TextToCMLog $LogFile "WSUS Configuration updated successfully." $component 1
                }Catch{
                    Add-TextToCMLog $LogFile "Failed to import configuration data from XML file." $component 3
                    Add-TextToCMLog $LogFile "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
                    Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
                    Exit $($_.Exception.HResult)
                }
            }
            $component = $mainComponent
            Add-TextToCMLog $LogFile "Done perfoming IMPORT of WSUS Server $($WSUSFQDN)." $component 1
        }
    }Catch{
        Add-TextToCMLog $LogFile "Import/Export operation failed." $component 3
        Add-TextToCMLog $LogFile "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $component 3
        Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $component 3
        Exit $($_.Exception.HResult)
    }
}



#If importing metadata and custom indexes are selected, we already do add indexes right after importing metadata
If ($UseCustomIndexes -and !($Import -and $IsMetadataSelected)){
    Add-WSUSDBCustomIndexes
}

If ($RemoveCustomIndexes){
    Remove-WSUSDBCustomIndexes
}

if($ReindexSUSDB){
    Invoke-WSUSDBReindex
}

if($Import -and ($IsMetadataSelected -or $IsXMLConfigSelected)){
    $component = "WSUS Import - Reset"
    Add-TextToCMLog $LogFile "Executing a WSUS Reset after importing metadata or WSUS XML Configuration." $component 1

    Reset-WSUSServer -MaxIterations 180 -MinsToWait 1

    $component = $mainComponent
}

if($ShowLocallyPublishedUpdates){
    Show-LocallyPublishedUpdates
}
Add-TextToCMLog $LogFile "$component finished." $component 1
Add-TextToCMLog $LogFile "#############################################################################################" $component 1