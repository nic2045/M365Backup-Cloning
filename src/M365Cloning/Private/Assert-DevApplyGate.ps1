function Assert-DevApplyGate {
    <#
    .SYNOPSIS
        Shared gate of every write to the Dev tenant (DSC apply and Dev users). Throws and writes the refusal to the
        audit log unless ALL of this holds:
        - a plan hash is given and equals the SHA-256 of the plan (-Confirm:$false is not enough);
        - Dev.TenantId is set, differs from Prod.TenantId and equals the plan's TargetTenantId;
        - Dev.ApplyAllowed is $true in the local config.
        With -Purpose Reset (the factory reset, ADR 0005) the switch is Dev.AllowReset instead of Dev.ApplyAllowed,
        and a second confirmation is needed: -ConfirmTenant must equal the Dev tenant ID of the config.
        Returns the plan hash.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [AllowEmptyString()][string]$ConfirmPlanHash,
        [Parameter(Mandatory)][string]$HistoryRoot,
        [ValidateSet('Apply', 'Reset')][string]$Purpose = 'Apply',
        [AllowEmptyString()][string]$ConfirmTenant = ''
    )

    $hash = Get-ApplyPlanHash -Plan $Plan
    $target = [string]$Plan['TargetTenantId']
    $refuse = {
        param($why)
        Write-ApplyAudit -HistoryRoot $HistoryRoot -Mode refused -PlanHash $hash -TargetTenantId $target -Reason $why
        throw "Apply refused: $why"
    }

    if ([string]::IsNullOrWhiteSpace($ConfirmPlanHash)) { & $refuse 'no plan hash given (-ConfirmPlanHash)' }
    $dev = if ($Config.Contains('Dev') -and $Config['Dev'] -is [System.Collections.IDictionary]) { $Config['Dev'] } else { @{} }
    $prod = if ($Config.Contains('Prod') -and $Config['Prod'] -is [System.Collections.IDictionary]) { $Config['Prod'] } else { @{} }
    if ([string]::IsNullOrWhiteSpace([string]$dev['TenantId'])) { & $refuse 'the config has no Dev tenant ID' }
    if ([string]$dev['TenantId'] -eq [string]$prod['TenantId']) { & $refuse 'the Dev tenant ID equals the Prod tenant ID' }
    if ($target -ne [string]$dev['TenantId']) { & $refuse 'the plan was made for a different tenant than Dev in the config' }
    if ($Purpose -eq 'Reset') {
        if ($dev['AllowReset'] -ne $true) { & $refuse 'Dev.AllowReset is not $true in the config' }
    }
    elseif ($dev['ApplyAllowed'] -ne $true) { & $refuse 'Dev.ApplyAllowed is not $true in the config' }
    if (-not [string]::Equals($ConfirmPlanHash.Trim(), $hash, [System.StringComparison]::OrdinalIgnoreCase)) {
        & $refuse 'the plan hash does not match this plan (look at the preview again and pass its hash)'
    }
    if ($Purpose -eq 'Reset' -and -not [string]::Equals($ConfirmTenant.Trim(), [string]$dev['TenantId'], [System.StringComparison]::OrdinalIgnoreCase)) {
        & $refuse 'second confirmation missing: pass the Dev tenant ID with -ConfirmTenant'
    }
    $hash
}
