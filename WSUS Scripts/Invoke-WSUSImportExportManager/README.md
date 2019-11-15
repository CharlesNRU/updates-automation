# Invoke-WSUSImportExportManager
The purpose of this script is to handle the export/import process for WSUS without internet connectivity.

* WSUS with Internet connectivity will use this script to perform an EXPORT to get: WSUS Content, WSUS Metadata, WSUS Configuration XML file

* WSUS without internet connectivity will use this script to perform an IMPORT and get same Content, WSUS Metadata and WSUS Configuration (including update approvals) as the internet connected WSUS

## Actions
In order to tell the script what to do, there is an associated configuration XML file.
You can find examples of configuration files in this repo named config_import.xml and config_export.xml
In this configuration file, you can specify various actions that you want the script to perform.

### Action - Export
```xml
<Action Name='Export' Enabled='False'>
	<Option Name='DestinationDir' Location='D:\WSUS_IEM' />
	<Option Name='WSUSContent' Enabled='True' />
	<Option Name='Metadata' Enabled='True' Filename='WSUSMetadata.xml.gz'/>
	<Option Name='XMLConfiguration' Enabled='True' Filename='WSUSConfig.xml' IncludeApprovals='True' />
</Action>
```
If you enable this action, the script will perform an export. You must specify the following options:
* DestinationDir: In what directory should the files exported be copied to?
* WSUSContent: Should we export the 'WSUSContent' folder?
* Metadata: Should we export the WSUS updates metadata?
    * Filename: The filename that will be used to export metadata to $DestinationDir
    Note: The filename should end with the .xml.gz extension
* XMLConfiguration: Should we export the current WSUS Configuration?
    * IncludeApprovals: Should we include updates approvals with this export operation?

After the export operation is complete, grab a copy of $DestinationDir & this script and perfom an import operation on your disconnected WSUS server.

### Action - Import
```xml
<Action Name='Import' Enabled='True'>
	<Option Name='SourceDir' Location='D:\WSUS_IEM' />
	<Option Name='WSUSContent' Enabled='True' />
	<Option Name='Metadata' Enabled='True' Filename='WSUSMetadata.xml.gz' DropSUSDB='True' />
	<Option Name='XMLConfiguration' Enabled='True' Filename='WSUSConfig.xml' IncludeApprovals='True' />
</Action>
```

If you enable this action, the script will perform an import. You must specify the following options:
* SourceDir: What is the location of your source files to perfom this import operation? Normally this is the destination directory of an import performed by this script.
* WSUSContent: Import (mirror) the 'WSUSContent' folder?
* Metadata: Import the WSUS updates metadata?
    * Filename: The filename containing the wsus metadata located in $SourceDir
    * DropSUSDB: The script will drop (delete) the WSUS Database and re-create a clean database by re-running "wsusutil postinstall" before importing metadata.
* XMLConfiguration: Make sure the WSUS configuration matches the WSUS server we are importing updates from.
    *  Filename: The filename containing the wsus configuration located in $SourceDir
    * IncludeApprovals: Should the script use the update approvals information to approve the same updates on this WSUS instance?

### Action - ReindexSUSDB
```xml
<Action Name='ReindexSUSDB' Enabled='True' />
```
As its title says, this action will reindex SUSDB. This action is performed at the end of the script after all other actions were performed. The reindex operation is done entirely via PowerShell and does not require any sql tools being installed on the system the script is running.
Note: If updates metadata are imported, a reindex will also occur right after the wsus metadata import.
### Action - UseCustomIndexes
```xml
<Action Name='UseCustomIndexes' Enabled='True' />
````
This action creates custom indexes to the WSUS database that increases performance.
The code for this was taken directly from Bryan Dam's software update maintenance script.
### Action - RemoveCustomIndexes
```xml
<Action Name='RemoveCustomIndexes' Enabled='True' />
````
This action removes custom indexes to the WSUS database.
The code for this was taken directly from Bryan Dam's software update maintenance script.
### Action - SetIISWSUSPoolSettings
```xml
<Action Name='SetIISWSUSPoolSettings' Enabled='True'>
	<PoolSetting Name='WSUSPoolName'>WsusPool</PoolSetting>
	<PoolSetting Name='QueueLength'>2000</PoolSetting>
	<PoolSetting Name='IdleTimeout'>0</PoolSetting>
	<PoolSetting Name='PingEnabled'>False</PoolSetting>
	<PoolSetting Name='PrivateMemoryLimit'>0</PoolSetting>
	<PoolSetting Name='RegularTimeInterval'>0</PoolSetting>
</Action>
```
This action allows you to configure settings for the IIS application pool for WSUS. The default parameters are not very good.
See https://support.microsoft.com/en-ae/help/4490414/windows-server-update-services-best-practices for best practices according to Microsoft. You can adjust the settings in this action for your environment.

### Action - ShowLocallyPublishedUpdates
```xml
<Action Name='ShowLocallyPublishedUpdates' Enabled='True' />
```
This action will run an update statement on the WSUS DB to make locally published updates, like third-party products updates, show up in the WSUS Console.

# Thanks to:
Bryan Dam for his software update maintenance script: https://damgoodadmin.com/2018/10/17/latest-software-maintenance-script-making-wsus-suck-slightly-less/
Warren Frame for Start-ConsoleProcess and Invoke-Robocopy functions: https://github.com/RamblingCookieMonster
