function Read-UtcmSnapshotFile {
    <#
    .SYNOPSIS
        Reads a saved snapshot.json (a configurationBaseline: resources[] with displayName, resourceType, properties).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Snapshot file not found: $Path" }
    $snapshot = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 50
    if (-not $snapshot.ContainsKey('resources')) { throw "Not a snapshot (no 'resources'): $Path" }
    $snapshot
}
