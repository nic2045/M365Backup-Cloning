function Get-UtcmTenantSnapshot {
    <#
    .SYNOPSIS
        Snapshot of one tenant: start, wait, download, keep. Returns the path of snapshot.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][securestring]$Token,
        [Parameter(Mandatory)][ValidateSet('Prod', 'Dev')][string]$Side,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string[]]$Resources,
        [string]$HistoryRoot = (Join-Path (Get-Location) 'History'),
        [int]$TimeoutSeconds = 900,
        [int]$PollSeconds = 10
    )
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $outDir = Join-Path $HistoryRoot (Join-Path 'Tenants' (Join-Path $Side $stamp))
    $job = New-UtcmSnapshot -Token $Token -DisplayName "drift-report-$Side-$stamp" -Resources $Resources
    $done = Wait-UtcmSnapshot -Token $Token -JobId $job.id -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds
    Save-UtcmSnapshot -Token $Token -Job $done -OutDir $outDir
}
