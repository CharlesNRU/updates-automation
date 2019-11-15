# SCCM Scripts
These are used for SCCM servers syncing to an upstream WSUS and not directly to Microsoft.

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