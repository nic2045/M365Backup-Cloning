function Import-M365CloningConfig {
    <#
    .SYNOPSIS
        Loads and validates config.psd1 (see config.example.psd1): exactly one Prod/Dev pair.
    .DESCRIPTION
        Optional: Dev.ApplyAllowed (bool, default false), BreakGlass (users) and BreakGlassGroups (group names).
        Rejects a config without a Prod or Dev tenant, with placeholders such as '<prod-tenant-guid>'
        still in it, with identical Prod and Dev tenant IDs, or with the old 'Customers' list.
        -AllowPlaceholders is only for tests with the example file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowPlaceholders
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Config not found: $Path (copy config.example.psd1 to config.psd1)"
    }
    $config = Import-PowerShellDataFile -LiteralPath $Path

    if ($config.ContainsKey('Customers')) {
        throw "The 'Customers' list is not supported: one instance of this toolkit serves one Prod/Dev pair. Use Prod and Dev at the top level."
    }

    $isPlaceholder = { param($v) [string]::IsNullOrWhiteSpace([string]$v) -or [string]$v -match '^\s*<.*>\s*$' }

    foreach ($side in 'Prod', 'Dev') {
        if (-not $config.ContainsKey($side) -or $config[$side] -isnot [hashtable]) {
            throw "The $side tenant is missing (a Prod/Dev pair is required)."
        }
        foreach ($key in 'TenantId', 'ClientId', 'CertThumbprint') {
            if (-not $AllowPlaceholders -and (& $isPlaceholder $config[$side][$key])) {
                throw "$side.$key is empty or still a placeholder."
            }
        }
    }
    if (-not $AllowPlaceholders -and $config.Prod.TenantId -eq $config.Dev.TenantId) {
        throw 'Prod and Dev have the same TenantId.'
    }

    # Apply (ADR 0001): off unless Dev.ApplyAllowed is $true; the break-glass accounts are used for Conditional Access.
    if ($config.Dev.ContainsKey('ApplyAllowed') -and $config.Dev.ApplyAllowed -isnot [bool]) {
        throw 'Dev.ApplyAllowed must be $true or $false.'
    }
    foreach ($listName in 'BreakGlass', 'BreakGlassGroups') {
        if ($config.ContainsKey($listName) -and $null -ne $config[$listName]) {
            foreach ($entry in @($config[$listName])) {
                if ($entry -isnot [string]) { throw "$listName must be a list of strings." }
                if (-not $AllowPlaceholders -and $entry -match '^\s*<.*>\s*$') { throw "$listName still contains a placeholder." }
            }
        }
    }
    $config
}
