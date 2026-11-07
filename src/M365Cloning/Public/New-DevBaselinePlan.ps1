function New-DevBaselinePlan {
    <#
    .SYNOPSIS
        Pure function: plan that brings the Dev tenant to its documented base state (issue #8). Writes nothing.
    .DESCRIPTION
        Compares Get-DevBaselineDefinition with a Dev snapshot (UTCM, Get-M365CloningBaselineResources):
          missing group                   -> Create a static, EMPTY security group (New-EmptyGroupProperties)
          group with other flags          -> Update SecurityEnabled / MailEnabled only (the described properties)
          dynamic group (rule or type)    -> blocked: the base state wants a static group; changing a dynamic group
                                             would remove members, so it is left to a person
          exclusion group without persona -> blocked (ADR 0003: no recognisable persona)
          missing partner (Prod tenant)   -> Create: B2B collaboration inbound allowed for all users and applications
                                             of the Prod tenant, inbound invitations redeemed automatically
          partner, auto-redeem off        -> Update AutomaticUserConsentSettings only
          partner with own B2B inbound    -> blocked when it differs: the baseline never widens or narrows an access
                                             rule that someone set; only an unset rule (inherits the default) is set
          everything as described         -> 'exists' (in the base state)
        Never deletes: objects in Dev that the base state does not name are not in the plan.
        The plan has the shape of New-ApplyPlan (DscResource, Properties) and is applied by Invoke-ApplyPlan (same
        gate: plan hash, Dev.ApplyAllowed, Dev tenant only, audit). Nested settings of the partner carry the CIM
        class in '__CimClass' for the DSC runner. Summary.InBaseline is $true when nothing is planned or blocked:
        that is the empty difference report of the acceptance of #8.
        DSC resources: AADGroup (map, ADR 0001); AADCrossTenantAccessPolicyConfigurationPartner follows the rule
        'AAD' + UTCM resource name like the others (Get-DscResourceMap) and is checked with Get-DscResource by the
        runner. It is deliberately not in Get-DscResourceMap, so that a Prod -> Dev apply never copies the partner
        list of Prod.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Target
    )

    foreach ($side in 'Prod', 'Dev') {
        if (-not $Config.Contains($side) -or $Config[$side] -isnot [System.Collections.IDictionary] -or
            [string]::IsNullOrWhiteSpace([string]$Config[$side]['TenantId'])) { throw "Config has no $side tenant ID." }
    }
    $prodId = [string]$Config['Prod']['TenantId']
    if ([string]$Config['Dev']['TenantId'] -eq $prodId) {
        throw 'The target tenant ID equals the Prod tenant ID. Refused: the baseline is written to the Dev tenant only.'
    }

    $definition = Get-DevBaselineDefinition -Config $Config
    $groupDsc = [string](Get-DscResourceMap)['microsoft.entra.group'].Dsc
    $partnerType = 'microsoft.entra.crosstenantaccesspolicyconfigurationpartner'
    $partnerDsc = 'AADCrossTenantAccessPolicyConfigurationPartner'

    # Case-insensitive property read (UTCM properties are PascalCase, Graph camelCase).
    $get = {
        param($o, [string]$k)
        if ($null -eq $o) { return $null }
        if ($o -is [System.Collections.IDictionary]) {
            foreach ($key in $o.Keys) { if ([string]$key -ieq $k) { return $o[$key] } }
            return $null
        }
        $p = $o.PSObject.Properties | Where-Object { $_.Name -ieq $k } | Select-Object -First 1
        if ($p) { $p.Value } else { $null }
    }

    $groupsByName = @{}
    $partners = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($Target['resources'])) {
        $type = ([string]$r['resourceType']).ToLowerInvariant()
        $props = if ($r['properties'] -is [System.Collections.IDictionary]) { $r['properties'] } else { @{} }
        if ($type -eq 'microsoft.entra.group') {
            $name = [string](& $get $props 'DisplayName')
            if (-not $name) { $name = [string]$r['displayName'] }
            if ($name) {
                $k = $name.ToLowerInvariant()
                if (-not $groupsByName.ContainsKey($k)) { $groupsByName[$k] = [System.Collections.Generic.List[object]]::new() }
                $groupsByName[$k].Add($props)
            }
        }
        elseif ($type -eq $partnerType) { $partners.Add($props) }
    }

    $actions = [System.Collections.Generic.List[object]]::new()
    $new = {
        param($Type, $Name, $Operation, $Status, $Reason, $Dsc, $Props, $Diffs)
        [ordered]@{
            ResourceType = $Type; Name = $Name; Operation = $Operation; Status = $Status; Reason = $Reason
            DscResource = $Dsc; AssignmentClass = ''; Differences = [object[]]@($Diffs); Properties = $Props
        }
    }

    foreach ($g in $definition.Groups) {
        $name = [string]$g.Name
        $label = if ($g.Kind -eq 'break-glass') { 'break-glass group' } elseif ($g.Kind -eq 'exclusion') { "exclusion group (persona $($g.Persona))" } else { "persona group ($($g.Persona))" }
        if ([string]::IsNullOrWhiteSpace([string]$g.Persona)) {
            $actions.Add((& $new 'microsoft.entra.group' $name 'Create' 'blocked' 'the group has no recognisable persona (naming scheme or PersonaMap, ADR 0003); fix Baseline.ExclusionGroups' $groupDsc $null @()))
            continue
        }
        $found = @(if ($groupsByName.ContainsKey($name.ToLowerInvariant())) { $groupsByName[$name.ToLowerInvariant()] })
        if ($found.Count -gt 1) {
            $actions.Add((& $new 'microsoft.entra.group' $name 'Update' 'blocked' 'the name occurs more than once in Dev; clean it up by hand' $groupDsc $null @()))
            continue
        }
        if ($found.Count -eq 0) {
            $actions.Add((& $new 'microsoft.entra.group' $name 'Create' 'planned' "$label of the base state: static, empty" $groupDsc (New-EmptyGroupProperties -Name $name -Description "Dev base state: $label; no members.") @()))
            continue
        }
        $current = $found[0]
        $rule = [string](& $get $current 'MembershipRule')
        $types = @(& $get $current 'GroupTypes') | ForEach-Object { [string]$_ }
        if (-not [string]::IsNullOrWhiteSpace($rule) -or ($types -contains 'DynamicMembership')) {
            $actions.Add((& $new 'microsoft.entra.group' $name 'Update' 'blocked' 'dynamic group: the base state wants a static, empty group; a change would remove members, change it by hand' $groupDsc $null @()))
            continue
        }
        $diffs = [System.Collections.Generic.List[object]]::new()
        foreach ($pair in @(@('SecurityEnabled', $true), @('MailEnabled', $false))) {
            $is = & $get $current $pair[0]
            if ($null -eq $is -or [bool]$is -ne $pair[1]) { $diffs.Add([ordered]@{ Property = $pair[0]; Source = [string]$pair[1]; Target = [string]$is }) }
        }
        if ($diffs.Count -eq 0) {
            $actions.Add((& $new 'microsoft.entra.group' $name 'None' 'exists' "$label is in the base state" '' $null @()))
            continue
        }
        $nick = [string](& $get $current 'MailNickname')
        if ([string]::IsNullOrWhiteSpace($nick)) { $nick = [string](New-EmptyGroupProperties -Name $name)['MailNickname'] }
        $props = [ordered]@{ DisplayName = $name; MailNickname = $nick; SecurityEnabled = $true; MailEnabled = $false; Ensure = 'Present' }
        $actions.Add((& $new 'microsoft.entra.group' $name 'Update' 'planned' "${label}: security group, not mail-enabled; members unchanged" $groupDsc $props @($diffs)))
    }

    if ($definition.Partner) {
        $partnerName = "Prod tenant as partner ($prodId)"
        $consent = [ordered]@{ __CimClass = 'MSFT_AADCrossTenantAccessPolicyAutomaticUserConsentSettings'; InboundAllowed = $true }
        $targetConfig = {
            param($Value, $TargetType)
            [ordered]@{
                __CimClass = 'MSFT_AADCrossTenantAccessPolicyTargetConfiguration'
                AccessType = 'allowed'
                Targets    = [object[]]@([ordered]@{ __CimClass = 'MSFT_AADCrossTenantAccessPolicyTarget'; Target = $Value; TargetType = $TargetType })
            }
        }
        $b2b = [ordered]@{
            __CimClass     = 'MSFT_AADCrossTenantAccessPolicyB2BSetting'
            UsersAndGroups = (& $targetConfig 'AllUsers' 'user')
            Applications   = (& $targetConfig 'AllApplications' 'application')
        }
        $current = @($partners | Where-Object { [string](& $get $_ 'PartnerTenantId') -ieq $prodId }) | Select-Object -First 1
        if (-not $current) {
            $props = [ordered]@{ PartnerTenantId = $prodId; B2BCollaborationInbound = $b2b; AutomaticUserConsentSettings = $consent; Ensure = 'Present' }
            $actions.Add((& $new $partnerType $partnerName 'Create' 'planned' 'cross-tenant access: B2B collaboration inbound allowed for the Prod tenant, inbound invitations redeemed automatically (no cross-tenant sync)' $partnerDsc $props @()))
        }
        else {
            $props = [ordered]@{ PartnerTenantId = $prodId }
            $diffs = [System.Collections.Generic.List[object]]::new()
            $blockers = [System.Collections.Generic.List[string]]::new()
            $inbound = & $get (& $get $current 'AutomaticUserConsentSettings') 'InboundAllowed'
            if ($inbound -ne $true) {
                $diffs.Add([ordered]@{ Property = 'AutomaticUserConsentSettings.InboundAllowed'; Source = 'True'; Target = [string]$inbound })
                $props['AutomaticUserConsentSettings'] = $consent
            }
            $b2bNow = & $get $current 'B2BCollaborationInbound'
            $isSet = { param($cfg) $null -ne $cfg -and -not [string]::IsNullOrWhiteSpace([string](& $get $cfg 'AccessType')) }
            $ug = & $get $b2bNow 'UsersAndGroups'; $apps = & $get $b2bNow 'Applications'
            if (-not (& $isSet $ug) -and -not (& $isSet $apps)) {
                $diffs.Add([ordered]@{ Property = 'B2BCollaborationInbound'; Source = 'allowed (AllUsers, AllApplications)'; Target = '(not set, inherits the default)' })
                $props['B2BCollaborationInbound'] = $b2b
            }
            else {
                $isAllowedForAll = {
                    param($cfg, $value)
                    ([string](& $get $cfg 'AccessType') -ieq 'allowed') -and (@(& $get $cfg 'Targets' | ForEach-Object { [string](& $get $_ 'Target') }) -contains $value)
                }
                if (-not (& $isAllowedForAll $ug 'AllUsers') -or -not (& $isAllowedForAll $apps 'AllApplications')) {
                    $blockers.Add('B2B collaboration inbound for the Prod tenant is set to something else than "allowed for all users and applications"; the baseline does not widen or narrow it, check it by hand')
                }
            }
            if ($blockers.Count -gt 0) {
                $actions.Add((& $new $partnerType $partnerName 'Update' 'blocked' ($blockers -join '; ') $partnerDsc $null @($diffs)))
            }
            elseif ($diffs.Count -eq 0) {
                $actions.Add((& $new $partnerType $partnerName 'None' 'exists' 'cross-tenant access for the Prod tenant is in the base state' '' $null @()))
            }
            else {
                $props['Ensure'] = 'Present'
                $actions.Add((& $new $partnerType $partnerName 'Update' 'planned' 'cross-tenant access for the Prod tenant: only the described settings are set' $partnerDsc $props @($diffs)))
            }
        }
    }

    # Groups first (order 1), then the partner; within that by name (ordinal, the same on every machine).
    $keyed = [System.Collections.Generic.List[object]]::new()
    foreach ($a in $actions) {
        $rank = if ($a['ResourceType'] -eq 'microsoft.entra.group') { '1' } else { '2' }
        $keyed.Add([pscustomobject]@{ Key = "$rank|$($a['Name'])"; Action = $a })
    }
    $keyed.Sort([System.Comparison[object]] { param($x, $y) [string]::CompareOrdinal($x.Key, $y.Key) })
    $sorted = [object[]]@($keyed | ForEach-Object { $_.Action })
    $count = { param($status) @($sorted | Where-Object { $_['Status'] -eq $status }).Count }
    $planned = [int](& $count 'planned'); $blocked = [int](& $count 'blocked')
    Complete-PlanShape -Kind 'baseline' -Plan ([ordered]@{
        Direction      = 'Dev base state'
        Title          = 'Dev baseline plan: difference to the base state (preview, nothing was changed)'
        ApplyHint      = 'scripts/Invoke-DevBaseline.ps1 -Apply -ConfirmPlanHash <hash above>'
        TargetTenantId = [string]$Config['Dev']['TenantId']
        Actions        = $sorted
        Notes          = [string[]]@($definition.Notes)
        Summary        = [ordered]@{
            Planned    = $planned
            Blocked    = $blocked
            Skipped    = [int](& $count 'skipped')
            Exists     = [int](& $count 'exists')
            InBaseline = ($planned -eq 0 -and $blocked -eq 0)
        }
    })
}
