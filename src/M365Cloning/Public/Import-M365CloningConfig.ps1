function Import-M365CloningConfig {
    <#
    .SYNOPSIS
        Loads and validates config.psd1 (see config.example.psd1): exactly one Prod/Dev pair.
    .DESCRIPTION
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
    $config
}
