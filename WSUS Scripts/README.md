# WSUS Scripts
These scripts are used for standalone WSUS instances.



## Invoke-WSUSSync
Will perform a WSUS sync. After the sync is finished, it will check if it was successful or not and exit accordingly.
Exitcode 0 = WSUS sync successful

## Invoke-EulaAccepter
Will check if any unapproved updates requires a license agreement before it can be approved. If yes, it will automatically accept license agreements and then, if automatic approval rules are configured/enabled, it will run the automatic approval rules.

## Invoke-WSUSReindex
This script will reindex your WSUS database without the need of installing extra SQL-related tools to access the database.
This is based on the script from https://gallery.technet.microsoft.com/scriptcenter/Invoke-WSUSDBMaintenance-af2a3a79
