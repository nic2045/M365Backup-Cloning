function Get-DevPlanLicences {
    <#
    .SYNOPSIS
        Licences of the Dev tenant for the plan check of a script: offline from -LicencePath (saved answer of
        GET /subscribedSkus), else online with -DevToken (read only), else 'not readable' (offline preview without a
        licence file; Add-PlanLicenceCheck then blocks entries that need a licence).
    #>
    [CmdletBinding()]
    param(
        [securestring]$DevToken,
        [string]$LicencePath
    )
    if ($LicencePath) { return (Get-TenantLicences -Path $LicencePath) }
    if ($DevToken) { return (Get-TenantLicences -Token $DevToken) }
    [ordered]@{ Readable = $false; Error = 'offline preview without -LicencePath'; Available = [string[]]@(); Skus = [object[]]@() }
}
