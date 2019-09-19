<#
.SYNOPSIS
This script will run and check if the current date is within 7 days of the last patch tuesday.

.DESCRIPTION
If the script is running within 7 days, the script exit with code 0 (successful)
Otherwise, it exits with 1 (fail)

The goal of this script is to use the task scheduler to run the script every week but we only want it to be successful once a month.
On a successful run of the scheduled task, we can trigger the SCCM SUP sync to the upstream WSUS, WSUS Cleanup and ADR runs.
This is similar to syncing within SCCM with patch tuesday + offset, except that chain mutliple tasks one after another on the site server with task scheduler.
#>

#Source: https://www.madwithpowershell.com/2014/10/calculating-patch-tuesday-with.html
#The 12th is the only day of the month that is always in the same calendar week as Patch Tuesday, so we can start there as a base.
$BaseDate = ( Get-Date -Day 12 ).Date
$PatchTuesday = $BaseDate.AddDays( 2 - [int]$BaseDate.DayOfWeek )

#Check if the script is running within a week of after patch tuesday
$CurrentDate = (Get-Date).Date
if($CurrentDate -gt $PatchTuesday -and $CurrentDate -le $PatchTuesday.AddDays(7)){
    Exit 0
}else{
    Exit 1
}