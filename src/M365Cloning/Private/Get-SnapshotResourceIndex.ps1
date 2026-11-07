function Get-SnapshotResourceIndex {
    <#
    .SYNOPSIS
        Index of a snapshot: "type|name" -> @{ Type; Name; Resource }. Same naming rule as Compare-TenantSnapshot
        (so names in a drift report can be looked up here).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot)

    $map = @{}
    foreach ($resource in @($Snapshot['resources'])) {
        $props = if ($resource['properties'] -is [System.Collections.IDictionary]) { $resource['properties'] } else { @{} }
        $name = $resource['displayName']
        foreach ($candidate in 'DisplayName', 'displayName', 'Name', 'Identity') {
            if (-not $name -and $props.Contains($candidate)) { $name = [string]$props[$candidate] }
        }
        if (-not $name) { $name = '(unnamed)' }
        $type = ([string]$resource['resourceType']).ToLowerInvariant()
        $key = "$type|$name"
        $n = 1
        while ($map.ContainsKey($key)) { $n++; $key = "$type|$name (duplicate $n)" }
        $map[$key] = [pscustomobject]@{
            Type     = $type
            Name     = if ($n -gt 1) { "$name (duplicate $n)" } else { $name }
            Resource = $resource
        }
    }
    $map
}
