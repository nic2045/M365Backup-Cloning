function Get-ResourceTypeCatalog {
    <#
    .SYNOPSIS
        Every TCM resource type with how the toolkit handles it (ADR 0006: copy all unless excluded).
    .DESCRIPTION
        Merges, per resource type:
        - Data/ResourceTypes.psd1: all types of the TCM schema (workload, key property, assignment CIM class).
        - Get-DscResourceMap: the types that were mapped one by one before ADR 0006. They keep their DSC name, order,
          secret and report-only marks unchanged (Handling 'mapped', or 'special' for groups, roles and Conditional
          Access, whose rules live in ConvertTo-ApplyProperties).
        - Data/ResourceRules.psd1: workloads and their DSC prefix, default order, secret types, tenant defaults.
        - Data/ExcludedResourceTypes.psd1 and the configuration (ExcludeResourceTypes): types that are never copied.
        Every other type gets Handling 'generic': DSC name '<prefix><resource name>' by the rule of Get-DscResourceMap.
        The name is lower case here; PowerShell matches DSC resource names without regard to case and the DSC runner
        takes the exact name from Get-DscResource before it applies anything.
        A type of a workload that is off (Workloads in the configuration; default Entra and Intune) is excluded with
        the reason 'workload <name> is off'.
        Returns a hashtable: type -> entry with Dsc, Order, AssignmentClass, Source, Secret, SecretReason, ReportOnly,
        ReportReason, Excluded, ExcludeReason, Handling, Workload, Key, TenantDefault.
    #>
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Config)

    $dataRoot = Join-Path $script:ModuleRoot 'Data'
    $types = (Import-PowerShellDataFile -Path (Join-Path $dataRoot 'ResourceTypes.psd1'))
    $rules = Import-PowerShellDataFile -Path (Join-Path $dataRoot 'ResourceRules.psd1')
    $excluded = (Import-PowerShellDataFile -Path (Join-Path $dataRoot 'ExcludedResourceTypes.psd1')).Types
    $map = Get-DscResourceMap

    # Workloads that are on: the configuration wins, otherwise the defaults of ResourceRules.psd1.
    $enabled = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($Config -and $Config.Contains('Workloads') -and $null -ne $Config['Workloads']) {
        foreach ($w in @($Config['Workloads'])) { $null = $enabled.Add([string]$w) }
    }
    else {
        foreach ($w in $rules.Workloads.Keys) { if ($rules.Workloads[$w].Default) { $null = $enabled.Add([string]$w) } }
    }

    # Exclusions added by the operator: a list of type names or a table type = reason.
    $configExcluded = @{}
    if ($Config -and $Config.Contains('ExcludeResourceTypes') -and $null -ne $Config['ExcludeResourceTypes']) {
        $ex = $Config['ExcludeResourceTypes']
        if ($ex -is [System.Collections.IDictionary]) { foreach ($k in $ex.Keys) { $configExcluded[([string]$k).ToLowerInvariant()] = [string]$ex[$k] } }
        else { foreach ($k in @($ex)) { $configExcluded[([string]$k).ToLowerInvariant()] = 'excluded in config.psd1 (ExcludeResourceTypes)' } }
    }

    $special = @('microsoft.entra.group', 'microsoft.entra.conditionalaccesspolicy', 'microsoft.entra.roledefinition', 'microsoft.intune.roledefinition')
    $catalog = @{}
    foreach ($type in $types.Types.Keys) {
        $data = $types.Types[$type]
        $workload = [string]$data.Workload
        $mapped = $map[$type]
        $entry = [ordered]@{
            Type            = $type
            Workload        = $workload
            Key             = [string]$data.Key
            AssignmentClass = [string]$data.AssignmentClass
            Source          = [string]$types.Source
            Dsc             = ''
            Order           = 4
            Secret          = $false
            SecretReason    = ''
            ReportOnly      = $false
            ReportReason    = ''
            Excluded        = $false
            ExcludeReason   = ''
            Handling        = 'generic'
            TenantDefault   = $rules.TenantDefaults[$type]
        }
        if ($mapped) {
            foreach ($k in 'Dsc', 'Order', 'AssignmentClass', 'Source', 'Secret', 'ReportOnly') { $entry[$k] = $mapped[$k] }
            if ($mapped.Contains('SecretReason')) { $entry.SecretReason = [string]$mapped.SecretReason }
            if ($mapped.Contains('ReportReason')) { $entry.ReportReason = [string]$mapped.ReportReason }
            $entry.Handling = if ($special -contains $type) { 'special' } else { 'mapped' }
        }
        else {
            $prefix = if ($rules.Workloads.Contains($workload)) { [string]$rules.Workloads[$workload].DscPrefix } else { '' }
            $entry.Dsc = $prefix + ($type -replace '^microsoft\.[a-z0-9]+\.', '')
            $entry.Order = if ($rules.OrderOverrides.Contains($type)) { [int]$rules.OrderOverrides[$type] } elseif ($rules.DefaultOrder.Contains($workload)) { [int]$rules.DefaultOrder[$workload] } else { 4 }
            if ($rules.SecretTypes.Contains($type)) { $entry.Secret = $true; $entry.SecretReason = [string]$rules.SecretTypes[$type] }
        }
        if ($excluded.Contains($type)) { $entry.Excluded = $true; $entry.ExcludeReason = [string]$excluded[$type] }
        elseif ($configExcluded.ContainsKey($type)) { $entry.Excluded = $true; $entry.ExcludeReason = $configExcluded[$type] }
        elseif (-not $enabled.Contains($workload)) { $entry.Excluded = $true; $entry.ExcludeReason = "workload $workload is off (Workloads in config.psd1)" }
        $catalog[$type] = $entry
    }
    # A mapped type that the schema file does not list (should not happen) keeps its mapping.
    foreach ($type in $map.Keys) {
        if ($catalog.ContainsKey($type)) { continue }
        $m = $map[$type]
        $catalog[$type] = [ordered]@{
            Type = $type; Workload = ''; Key = ''; AssignmentClass = [string]$m.AssignmentClass; Source = [string]$m.Source
            Dsc = [string]$m.Dsc; Order = [int]$m.Order; Secret = [bool]$m.Secret; SecretReason = [string]$m['SecretReason']
            ReportOnly = [bool]$m.ReportOnly; ReportReason = [string]$m['ReportReason']; Excluded = $false; ExcludeReason = ''
            Handling = 'mapped'; TenantDefault = $null
        }
    }
    $catalog
}
