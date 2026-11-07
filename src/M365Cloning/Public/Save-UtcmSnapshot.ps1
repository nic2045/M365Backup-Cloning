function Save-UtcmSnapshot {
    <#
    .SYNOPSIS
        Downloads the finished snapshot and keeps it locally.
    .DESCRIPTION
        Graph deletes snapshots after 7 days (Learn: 'Configuration management'), so the file is copied to
        History\Tenants\<Customer>\<Tenant>\<timestamp>\snapshot.json (git-ignored). The snapshot
        schema matches configurationBaseline: resources[] with displayName, resourceType, properties.
        meta.json holds the job id, status and resource list, no token.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][securestring]$Token,
        [Parameter(Mandatory)]$Job,
        [Parameter(Mandatory)][string]$OutDir
    )
    if (-not $Job.resourceLocation) { throw "Snapshot $($Job.id) has no resourceLocation." }
    $snapshot = Invoke-UtcmGraphRequest -Method GET -Uri $Job.resourceLocation -Token $Token
    $null = New-Item -ItemType Directory -Path $OutDir -Force
    $snapshotPath = Join-Path $OutDir 'snapshot.json'
    $snapshot | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $snapshotPath -Encoding utf8
    [ordered]@{
        jobId     = $Job.id
        status    = $Job.status
        resources = $Job.resources
        savedAt   = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutDir 'meta.json') -Encoding utf8
    $snapshotPath
}
