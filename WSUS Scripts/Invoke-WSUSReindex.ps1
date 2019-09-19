<#
.SYNOPSIS
Powershell script that will reindex the WSUS Database.
.DESCRIPTION
No need to install extra SQL command line tools to be able to reindex the database with this script.
#>

Param(
    #Define a WSUS server.
    [Parameter(Mandatory=$true)]
    [string]$WSUSServerName,

    #Define the WSUS server port.
    [Parameter(Mandatory=$true)]
    [int]$WSUSPort,

    #Define the WSUS server's SSL setting.
    [bool]$WSUSSSL = $False

)

#region Functions
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
        Write-Error "Failed to get the WSUS database details."
        Write-Error "Error ($($_.Exception.HResult)): $($_.Exception.Message)"
        Write-Error "$($_.InvocationInfo.PositionMessage)"
        Exit 1
    }

    If (!($WSUSServerDB)){
        Write-Error "Failed to get the WSUS database details."
        Exit 1
    }

    #This is a just a test built into the API, it's not actually making the connection we'll use.
    Try{
        $WSUSServerDB.ConnectToDatabase()
    }
    Catch{
        Write-Error "Failed to connect to the ($($WSUSServerDB.DatabaseName)) database on $($WSUSServerDB.ServerName)."
        Write-Error "Error ($($_.Exception.HResult)): $($_.Exception.Message)"
        Write-Error "$($_.InvocationInfo.PositionMessage)"
        Exit 1
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
#>
##########################################################################################################

    Param(
        [Parameter(Mandatory=$true)]
        [Microsoft.UpdateServices.Administration.IDatabaseConfiguration] $WSUSServerDB
    )

    #Determine the connection string based on the type of DB being used.
    If ($WSUSServerDB.IsUsingWindowsInternalDatabase){
        #Using the Windows Internal Database.  Come one dawg ... just stop this insanity and migrate this to SQL.
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
    }
    Catch{
        Write-Error "Could not connect to WSUS DB."
        Write-Error "Error ($($_.Exception.HResult)): $($_.Exception.Message)"
        Write-Error "$($_.InvocationInfo.PositionMessage)"
        Exit 1
    }

    Return $SqlConnection
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
                    Invoke-SqlCmd2 -ServerInstance instance -Database msdb -Query ...
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
                ...
                msdb                          618112                Server1/Instance1
                tempdb                        563200                Server1/Instance1
                ...
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
                    $results = Invoke-Sqlcmd2 -ServerInstance ... -MessagesToOutput
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
            HelpMessage = 'SQL Server Instance required...')]
        [Parameter(ParameterSetName = 'Ins-Fil',
            Position = 0,
            Mandatory = $true,
            ValueFromPipeline = $true,
            ValueFromPipelineByPropertyName = $true,
            ValueFromRemainingArguments = $false,
            HelpMessage = 'SQL Server Instance required...')]
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
                    # While streaming ...
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

    Write-Output "WSUS Reindex: Starting reindex of WSUS DB"

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
        
        Invoke-Sqlcmd2 -SQLConnection $SqlConnection -Database $($WSUSServerdb.DatabaseName) -Query $($tSQL) -MessagesToOutput -ErrorAction Stop | ForEach-Object{
            Write-Output "$($_)"
        }
    }Catch{
        Write-Error "Failed to reindex WSUS DB."
        Write-Error "Error ($($_.Exception.HResult)): $($_.Exception.Message)"
        Write-Error "$($_.InvocationInfo.PositionMessage)"
        Exit 1
    }
    Write-Output "WSUS Reindex: Done."
}
##########################################################################################################
#endregion Functions

Try{
    [reflection.assembly]::LoadWithPartialName("Microsoft.UpdateServices.Administration") | out-null
    $WSUSServer = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer($WSUSServerName, $WSUSSSL, $WSUSPort)
}Catch{
    Write-Error "Could not connect to WSUS Server."
    Write-Error "Error ($($_.Exception.HResult)): $($_.Exception.Message)"
    Write-Error "$($_.InvocationInfo.PositionMessage)"
    Exit 1
}

Try{
    $WSUSServerDB = Get-WSUSDB -WSUSServer $WSUSServer
    Invoke-WSUSDBReindex
}Catch{
    Write-Error "Failed to reindex WSUS DB."
    Write-Error "Error ($($_.Exception.HResult)): $($_.Exception.Message)"
    Write-Error "$($_.InvocationInfo.PositionMessage)"
    Exit 1
}