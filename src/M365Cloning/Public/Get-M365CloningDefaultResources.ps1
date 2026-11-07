function Get-M365CloningDefaultResources {
    <#
    .SYNOPSIS
        Resource type names for the snapshot request: every TCM type of the workloads that are on (ADR 0006).
    .DESCRIPTION
        Source: Data/ResourceTypes.psd1, the full type list of the TCM schema that Microsoft Learn links from
        'Supported Microsoft Intune / Entra resources for Tenant Configuration Management'
        (https://learn.microsoft.com/graph/utcm-intune-resources -> https://www.schemastore.org/utcm-monitor.json).
        Default workloads are Entra and Intune (Data/ResourceRules.psd1); Workloads in config.psd1 changes them.
        Excluded types (Data/ExcludedResourceTypes.psd1 and ExcludeResourceTypes in config.psd1) are not requested.
        Secret-bearing types and the authentication method policies are requested, so that the drift report shows
        them and the plan marks them 'skipped: secret' / 'skipped: report-only'.
        Resources in config.psd1 still overrides the whole list.
        Not covered: role scope tags (no TCM resource), apps (uploaded by SW-Depoyment), SharePoint (no TCM type).
    #>
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Config)

    $catalog = Get-ResourceTypeCatalog -Config $Config
    [string[]]@($catalog.Values | Where-Object { -not $_.Excluded } | ForEach-Object { $_.Type } | Sort-Object)
}
