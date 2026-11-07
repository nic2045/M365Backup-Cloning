function ConvertTo-TenantLicences {
    <#
    .SYNOPSIS
        Pure function: turns the Graph answer of GET /subscribedSkus into the licence view of one tenant.
    .DESCRIPTION
        Learn: subscribedSku (capabilityStatus Enabled, Warning, Suspended, Deleted, LockedOut) and servicePlanInfo
        (provisioningStatus Success, Disabled, Error, PendingInput, PendingActivation, PendingProvisioning).
        A service plan counts as available only with provisioningStatus 'Success' in a SKU with capabilityStatus
        'Enabled' or 'Warning' (Warning = grace period, still usable). PendingActivation is not counted: Learn says the
        service needs an explicit activation first.
        Usable for any tenant (Dev for the plan check, Prod and Dev for the suitability check, issue #39).
        Returns [ordered]@{ Readable; Error; Available = sorted service plan names; Skus = sorted list }. Each SKU has
        SkuPartNumber, CapabilityStatus, AppliesTo, ConsumedUnits, PrepaidEnabled/Warning/Suspended/LockedOut,
        ServicePlans (all) and ProvidedPlans (the ones counted as available). No IDs.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$SubscribedSkus)

    $get = {
        param($o, [string]$k)
        if ($null -eq $o) { return $null }
        if ($o -is [System.Collections.IDictionary]) { return $o[$k] }
        $p = $o.PSObject.Properties[$k]
        if ($p) { $p.Value } else { $null }
    }
    $list = & $get $SubscribedSkus 'value'
    if ($null -eq $list) { $list = $SubscribedSkus }
    $available = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $skus = [System.Collections.Generic.List[object]]::new()
    foreach ($sku in @($list | Where-Object { $null -ne $_ })) {
        $status = [string](& $get $sku 'capabilityStatus')
        $usable = $status -in @('Enabled', 'Warning')
        $plans = [System.Collections.Generic.List[string]]::new()
        $provided = [System.Collections.Generic.List[string]]::new()
        foreach ($sp in @(& $get $sku 'servicePlans' | Where-Object { $null -ne $_ })) {
            $name = [string](& $get $sp 'servicePlanName')
            if (-not $name) { continue }
            $plans.Add($name)
            if ($usable -and [string](& $get $sp 'provisioningStatus') -eq 'Success') { $null = $available.Add($name); $provided.Add($name) }
        }
        # Units (Learn: subscribedSku consumedUnits, prepaidUnits = licenseUnitsDetail enabled/warning/suspended/lockedOut).
        $units = & $get $sku 'prepaidUnits'
        $num = { param($o, [string]$k) $v = & $get $o $k; if ($null -eq $v) { 0 } else { [int]$v } }
        $skus.Add([ordered]@{
                SkuPartNumber    = [string](& $get $sku 'skuPartNumber')
                CapabilityStatus = $status
                AppliesTo        = [string](& $get $sku 'appliesTo')
                ConsumedUnits    = (& $num $sku 'consumedUnits')
                PrepaidEnabled   = (& $num $units 'enabled')
                PrepaidWarning   = (& $num $units 'warning')
                PrepaidSuspended = (& $num $units 'suspended')
                PrepaidLockedOut = (& $num $units 'lockedOut')
                ServicePlans     = [string[]]@($plans | Sort-Object)
                ProvidedPlans    = [string[]]@($provided | Sort-Object)
            })
    }
    [ordered]@{
        Readable  = $true
        Error     = ''
        Available = [string[]]@($available)
        Skus      = [object[]]@($skus | Sort-Object { $_.SkuPartNumber })
    }
}
