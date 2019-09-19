﻿<#
.SYNOPSIS
Decline any update that is not approved on the upstream WSUS server.
.DESCRIPTION
If the current SUP uses an upstream WSUS server, decline any update that is not approved on the SUP.
.NOTES
The account (most likely the site server computer account) used to run the maintenance script will need at a minimum the "WSUS Reporters" permissions to connect and retrieve the list of updates on the upstream WSUS Server.

Written By: Charles Tousignant
Version 1.1: 2019-04-04
#>

Function Invoke-SelectUpdatesPlugin{
    $pluginComponent = "Decline-NotApprovedUpdatesOnUpstreamWSUS"

    $DeclinedUpdates = @{}
    
    Add-TextToCMLog $LogFile "Checking if WSUS server $WSUSFQDN is using an upstream WSUS." $pluginComponent 1
    $WSUSConfig = $WSUSServer.GetConfiguration()

    if($WSUSConfig.SyncFromMicrosoftUpdate -eq $false){
        Try{
            $UpstreamWSUSServer = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer($WSUSConfig.UpstreamWsusServerName, $WSUSConfig.UpstreamWsusServerUseSsl, $WSUSConfig.UpstreamWsusServerPortNumber)
        } Catch{
            Add-TextToCMLog $LogFile "Failed to connect to the upstream WSUS server $($WSUSConfig.UpstreamWsusServerName) on port $($WSUSConfig.UpstreamWsusServerPortNumber) with$(If(!$($WSUSConfig.UpstreamWsusServerUseSsl)){"out"}) SSL." $pluginComponent 3
            Add-TextToCMLog $LogFile  "Error: $($_.Exception.HResult)): $($_.Exception.Message)" $pluginComponent 3
            Add-TextToCMLog $LogFile "$($_.InvocationInfo.PositionMessage)" $pluginComponent 3
            $UpstreamWSUSServer = $null
            Set-Location $OriginalLocation
            Return
        }
        
        Add-TextToCMLog $LogFile "Retrieving all approved updates on Upstream WSUS Server `"$($WSUSConfig.UpstreamWsusServerName)`"." $pluginComponent 1
        $UpstreamApproved = $UpstreamWSUSServer.GetUpdates() | Where {$_.IsApproved}
        Add-TextToCMLog $LogFile "Retrieved list of updates on Upstream WSUS Server." $pluginComponent 1
        $UpstreamApprovedIDs = $UpstreamApproved.Id.UpdateId.Guid

        foreach($update in $ActiveUpdates){
            if($update.Id.UpdateId.Guid -notin $UpstreamApprovedIDs){
                $DeclinedUpdates.Set_Item($update.Id.UpdateId,"Update is not approved on upstream WSUS Server.")
            }
        }
    }else{
        Add-TextToCMLog $LogFile "WSUS server $WSUSFQDN is configured to sync with Microsoft, plugin is not applicable. Skipping plugin..." $pluginComponent 2
    }
    Return $DeclinedUpdates
}