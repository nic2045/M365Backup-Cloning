function Wait-UtcmSnapshot {
    <#
    .SYNOPSIS
        Polls a snapshot job until it ends.
    .NOTES
        API (Microsoft Learn, 'Get configurationSnapshotJob'):
        GET /admin/configurationManagement/configurationSnapshotJobs/{id}
        status: notStarted | running | succeeded | failed | partiallySuccessful (evolvable enum, needs
        the Prefer header, set in Invoke-UtcmGraphRequest). resourceLocation and errorDetails need $select.
        partiallySuccessful is returned as a result with a warning; failed throws with errorDetails.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][securestring]$Token,
        [Parameter(Mandatory)][string]$JobId,
        [int]$TimeoutSeconds = 900,
        [int]$PollSeconds = 10,
        [string]$GraphBase = 'https://graph.microsoft.com/v1.0'
    )
    $uri = "$GraphBase/admin/configurationManagement/configurationSnapshotJobs/$JobId" +
        '?$select=id,status,resourceLocation,errorDetails,resources,completedDateTime,tenantId'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $job = Invoke-UtcmGraphRequest -Method GET -Uri $uri -Token $Token
        switch ($job.status) {
            'succeeded' { return $job }
            'partiallySuccessful' {
                Write-Warning "Snapshot $JobId finished partiallySuccessful: $($job.errorDetails -join '; ')"
                return $job
            }
            'failed' { throw "Snapshot $JobId failed: $($job.errorDetails -join '; ')" }
        }
        if ((Get-Date) -ge $deadline) { throw "Snapshot $JobId did not finish within $TimeoutSeconds s (status: $($job.status))." }
        if ($PollSeconds -gt 0) { Start-Sleep -Seconds $PollSeconds }
    }
}
