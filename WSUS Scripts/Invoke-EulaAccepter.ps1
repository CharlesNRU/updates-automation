<#
.SYNOPSIS
Simple script to automatically accept any license agreement of updates that are not declined and run automatic approval rules
.DESCRIPTION
WSUS Automatic approval rules will not approve updates that requires a license agreement acceptance by themselves.
This script will accept any license agreement of updates that are not declined and then will run the automatic approval rules to approve the updates.
#>

[reflection.assembly]::LoadWithPartialName("Microsoft.UpdateServices.Administration") | out-null
$WSUSFQDN = "localhost"
$WSUSSSL = 0
$WSUSPort = 8530
$WSUSServer = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer($WSUSFQDN, $WSUSSSL, $WSUSPort)

$RunRulesNeeded = $false
#Accept any license agreement of updates that were not automatically declined.
$WSUSServer.GetUpdates() | Where {!$_.IsDeclined -and $_.RequiresLicenseAgreementAcceptance} | ForEach-Object{
    Write-Output "Accepting License Agreement for update `"$($_.Title)`""
    [void]$_.AcceptLicenseAgreement()
    $RunRulesNeeded = $true
}

#Run the automatic approval rules to approve existing updates that would have been skipped because of license agreements.
if($RunRulesNeeded){
    $WSUSServer.GetInstallApprovalRules() | ForEach-Object{
        if($_.Enabled){
            Write-Output "Running automatic approval rule `"$($_.Name)`""
            [void]$_.ApplyRule()
        }else{
            Write-Output "Automatic approval rule `"$($_.Name)`" is disabled, skipping..."
        }
    }
}