function Import-M365CloningConfig {
    <#
    .SYNOPSIS
        Loads and validates config.psd1 (see config.example.psd1).
    .DESCRIPTION
        Rejects a config without a customer, without a Prod/Dev pair, with placeholders such as
        '<prod-tenant-guid>' still in it, or with identical Prod and Dev tenant IDs.
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

    if (-not $config.ContainsKey('Customers') -or @($config.Customers).Count -eq 0) {
        throw 'Config has no customer (Customers is empty).'
    }

    $isPlaceholder = { param($v) [string]$v -match '^\s*<.*>\s*$' -or [string]::IsNullOrWhiteSpace([string]$v) }

    foreach ($customer in $config.Customers) {
        $name = $customer['Name']
        if (-not $AllowPlaceholders -and (& $isPlaceholder $name)) { throw 'A customer Name is empty or still a placeholder.' }
        foreach ($side in 'Prod', 'Dev') {
            if (-not $customer.ContainsKey($side) -or $customer[$side] -isnot [hashtable]) {
                throw "Customer '$name': the $side tenant is missing (a Dev/Prod pair is required)."
            }
            foreach ($key in 'TenantId', 'ClientId', 'CertThumbprint') {
                $value = $customer[$side][$key]
                if (& $isPlaceholder $value) {
                    if (-not $AllowPlaceholders) {
                        throw "Customer '$name': $side.$key is empty or still a placeholder."
                    }
                }
            }
        }
        if (-not $AllowPlaceholders -and $customer.Prod.TenantId -eq $customer.Dev.TenantId) {
            throw "Customer '$name': Prod and Dev have the same TenantId."
        }
    }
    $config
}
