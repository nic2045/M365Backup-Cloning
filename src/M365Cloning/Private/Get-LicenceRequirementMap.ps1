function Get-LicenceRequirementMap {
    <#
    .SYNOPSIS
        Reads the licence rules (Data\LicenceRequirements.psd1): resource type -> service plans a Dev write needs.
    #>
    [CmdletBinding()]
    param()
    $path = Join-Path $script:ModuleRoot 'Data' 'LicenceRequirements.psd1'
    $data = Import-PowerShellDataFile -LiteralPath $path
    foreach ($r in @($data.Rules)) {
        [pscustomobject]@{
            Feature         = [string]$r.Feature
            Match           = [string]$r.Match
            WhenAnyProperty = [string[]]@($r['WhenAnyProperty'] | Where-Object { $_ })
            ServicePlans    = [string[]]@($r.ServicePlans | Where-Object { $_ })
            Known           = (@($r.ServicePlans | Where-Object { $_ }).Count -gt 0)
            Source          = [string]$r.Source
        }
    }
}
