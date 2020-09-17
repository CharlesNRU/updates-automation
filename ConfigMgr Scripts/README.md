# ConfigMgr Scripts
These are used for ConfigMgr sites syncing to an upstream WSUS and not directly to Microsoft.

## Invoke-AfterPatchTuesdayCheck
When ran, it will check if the current date is within 7 days after patch tuesday.
If the current date is within 7 days after patch tuesday, the script exits with exit code 0, else it exits with exit code 1.

## Invoke-OfflineSUPSync
The script needs to run from the site server.
It retrieves information related to the upstream WSUS server being used to synchronize updates.
Then, it performs 2 checks:
- Sheduled Task check: The script will check if a specific scheduled task on the upstream WSUS Server has completed successfully or not. If it's successful it will verify the date the script ran and make sure it's newer than the last time.
If it's newer than the last time the script ran, the "ScheduledTask" check has passed.
- ArrivalDate check: The script will retrieve the updates on the upstream WSUS Server and check the latest "ArrivalDate" attribute.
If it's newer than the last time the script ran, the "ArrivalDate" check has passed.

Note: You may use the -SkipScheduledTask parameter to skip the scheduled task check or use the -Force switch to skip both checks.

After the 2 checks are successful, the script will initiate a software update synchronization and check if it's successful or not and exit accordingly.

Important: The **needs** Bryan Dam's script "Invoke-DGASoftwareUpdatePointSync.ps1" to initiate the synchronization. It should be placed in the same folder as this script.

## Invoke-RunADRs
The script will run a set of ADRs with a pattern given.
It will also retry if an ADR fails to run for some reason. Deadlocks are not uncommon when running multiple ADRs in quick succession.

Example:
```powershell
Invoke-RunADRs.ps1 -Mode RunAllPatterns -ADRPatterns @("*Windows 10*","*Windows 7*")
```
The line above will run all ADRs with "Windows 10" or "Windows 7" in their name.

You can also alternate different patterns every execution, you can also use a config.ini file to specify the parameters.

Example config.ini file:
```ini
Mode=IteratePatternsBetweenExecutions
ADRPatterns=@('* - Deployment A','* - Deployment B')
DeleteSUGBeforeRunningADR
```

```powershell
Invoke-RunADRs.ps1 -configfile config.ini
```
The first time the script runs, it will run all ADRs with names with "- Deployment A".
If you rerun the script a second time, it will now run all ADRs with "- Deployment B".
It will alternate which ADRs are run every time you run the script.

Note: The "DeleteSUGBeforeRunningADR" switch assumes that you are reusing SUGS and not creating a new one SUG every run.

# My setup
I setup the scripts to run from the site server from the task scheduler (poor man's automation...)
## ConfigMgr site syncing to a WSUS connected to internet
When the upstream WSUS instance is connected to internet, you do not have to rely on a separate process to get updates imported to WSUS. You *know* that the WSUS instance should have new updates after patch tuesday.
1) Invoke-AfterPatchTuesdayCheck: Is it within 1 week of patch tuesday?
2) If within 1 week of patch tuesday, run Invoke-OfflineSUPSync to sync the SUP (skip the scheduled task check)
3) Run cleanup script that declines any updates on the SUP that is not approved on the upstream WSUS server.
I use Bryan Dam's script with the Decline-NotApprovedUpdatesOnUpstreamWSUS.ps1 plugin **only**, no other criteria is used to decline updates. This ensures that the same updates on the WSUS instances are available to the ConfigMgr site.
Direct link to the plugin for more information: https://github.com/bryandam/SoftwareUpdateScripts/blob/master/Invoke-DGASoftwareUpdateMaintenance/Plugins/Disabled/Decline-NotApprovedUpdatesOnUpstreamWSUS.ps1
4) Invoke-RunADRs
## ConfigMgr site syncing to a WSUS disconnected from internet
When the upstream WSUS is disconnected, we do not know when new updates will be available on the upstream WSUS. In this case, I have created a separate script that handles the import and export of WSUS for disconnected environments. I set up a scheduled task on the WSUS server called "WSUS Import" that is run when importing new updates to the WSUS instance. Invoke-OfflineSUPsync will check if the task was successful before checking the arrivaldate on the WSUS Server.
1) Invoke-OfflineSUPSync
2) Run cleanup script, see section above for declining updates not approved on the upstream WSUS server.
3) Invoke-RunADRs
