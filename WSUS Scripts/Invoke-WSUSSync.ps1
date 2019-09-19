<#
.SYNOPSIS
Simple script to synchronize updates on the WSUS Server
.DESCRIPTION
Instead of using the built-in WSUS Synchronization schedule, schedule this script as a scheduled task to synchronize with Microsoft.
By using the task scheduler, we can easily trigger other tasks after a successful synchronization.
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
    $Subscription = $WSUSServer.GetSubscription()
    $SyncStatus = $Subscription.GetSynchronizationStatus()

    if($SyncStatus -eq "NotProcessing"){
        $Subscription.StartSynchronization()
        Write-Output "WSUS Synchronization started."

        while($Subscription.GetSynchronizationStatus() -ne "NotProcessing"){
            <#
            Write-output "SyncStatus: $($Subscription.GetSynchronizationStatus())"
            Write-Output "SyncProgress: $($Subscription.GetSynchronizationProgress().Phase)"
            Write-Output "SyncProgress: $($Subscription.GetSynchronizationProgress().ProcessedItems) processed items of $($Subscription.GetSynchronizationProgress().TotalItems)"
            #>
            Start-Sleep -Seconds 1
        }
        Write-Output "WSUS Synchronization finished."
        $syncResult = $Subscription.GetEventHistory() | Select-Object -First 1
        if($syncResult.IsError){
            Write-Output "Synchronization unsuccessful."
            Write-Output "Error text: $($syncResult.ErrorText)"
            Write-Output "Exiting script with error code: $($syncResult.ErrorCode)"
            exit $($syncResult.ErrorCode)
        }
    }else{
        Write-Output "WSUS is already synchronizing, exiting..."
    }
}Catch{
    Write-Error "Failed to reindex WSUS DB."
    Write-Error "Error ($($_.Exception.HResult)): $($_.Exception.Message)"
    Write-Error "$($_.InvocationInfo.PositionMessage)"
    Exit 1
}