function ConvertTo-ApplyProperties {
    <#
    .SYNOPSIS
        Turns the Prod properties of one resource into the properties to apply in Dev, or says why not.
    .DESCRIPTION
        Rules (ADR 0001, fail-closed: when in doubt the resource is blocked, never widened):
        - Ids are dropped, Ensure is always 'Present' (an automatic run never deletes).
        - Assignments and CA group lists refer to groups by NAME. A group must exist in Dev or be created
          earlier in the same plan. A group target without a name and a ConfigMgr collection block the resource.
        - Assignment filters are referenced by ID: the Prod ID is turned into the filter name (Prod snapshot) and
          then into the ID of the Dev filter with that name. A filter that Dev lacks, or that this plan creates first,
          blocks the resource ('needs-filter'); the filter's Dev ID exists only after the apply.
        - Conditional Access: State is always 'enabledForReportingButNotEnforced' (Report-only); the break-glass
          users and groups from the config are always in ExcludeUsers / ExcludeGroups; without them the policy is
          blocked. Specific users in IncludeUsers / ExcludeUsers (other than All, None, GuestsOrExternalUsers and
          the configured break-glass accounts) block the policy because users are not mirrored.
        - Role resources: assignments to users block the resource, roles go to groups only.
        - Groups are copied as static, empty security groups (ADR 0003): no members, owners, group members, role or
          licence assignments, and a dynamic membership rule is not carried over.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)]$Resource,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$KnownGroups,
        [string[]]$BreakGlassUsers = @(),
        [string[]]$BreakGlassGroups = @(),
        # @{ ProdIdToName = <id -> name>; DevNameToId = <name -> id>; Planned = HashSet of filter names created by the plan }
        $FilterMap
    )

    $reasons = [System.Collections.Generic.List[string]]::new()
    $source = if ($Resource['properties'] -is [System.Collections.IDictionary]) { $Resource['properties'] } else { @{} }
    $props = ConvertTo-CanonicalObject -Value $source

    foreach ($key in @($props.Keys)) { if ($key -match '^(id|identity)$') { $props.Remove($key) } }
    $props['Ensure'] = 'Present'

    $findKey = { param($dict, $name) @($dict.Keys | Where-Object { $_ -ieq $name }) | Select-Object -First 1 }

    # Assignments (Intune policies)
    $assignmentsKey = & $findKey $props 'Assignments'
    if ($assignmentsKey) {
        $kept = [System.Collections.Generic.List[object]]::new()
        foreach ($assignment in @($props[$assignmentsKey])) {
            if ($assignment -isnot [System.Collections.IDictionary]) { $reasons.Add('an assignment cannot be read'); continue }
            $dataType = [string]$assignment['dataType']
            $groupName = [string]$assignment['groupDisplayName']
            if ($dataType -match 'groupassignmenttarget$') {
                if ([string]::IsNullOrWhiteSpace($groupName)) { $reasons.Add('a group assignment has no group name (groups are matched by name)') }
                elseif (-not $KnownGroups.Contains($groupName)) { $reasons.Add("assignment group '$groupName' does not exist in Dev and is not part of this plan") }
            }
            elseif ($dataType -match 'configurationmanagercollection') { $reasons.Add('a ConfigMgr collection assignment cannot be mapped') }
            $filterId = [string]$assignment['deviceAndAppManagementAssignmentFilterId']
            $filterType = [string]$assignment['deviceAndAppManagementAssignmentFilterType']
            $devFilterId = ''
            if (-not [string]::IsNullOrWhiteSpace($filterId) -and $filterType -ne 'none') {
                # Assignments name a filter by ID only (schema: deviceAndAppManagementAssignmentFilterId). The ID is
                # matched to the filter's name through the Prod snapshot and to the Dev filter with that name.
                $filterName = if ($FilterMap -and $FilterMap.ProdIdToName.ContainsKey($filterId)) { [string]$FilterMap.ProdIdToName[$filterId] } else { '' }
                if ([string]::IsNullOrWhiteSpace($filterName)) {
                    $reasons.Add('an assignment filter is not in the Prod snapshot (add microsoft.intune.deviceandappmanagementassignmentfilter to the resources)')
                }
                elseif ($FilterMap.DevNameToId.ContainsKey($filterName)) { $devFilterId = [string]$FilterMap.DevNameToId[$filterName] }
                elseif ($FilterMap.Planned.Contains($filterName)) {
                    $reasons.Add("needs-filter: assignment filter '$filterName' is created by this plan; its Dev ID is known only afterwards, run the plan again after apply")
                }
                else { $reasons.Add("needs-filter: assignment filter '$filterName' does not exist in Dev and is not part of this plan") }
            }
            $copy = [ordered]@{}
            foreach ($key in $assignment.Keys) {
                if ($key -match '^(groupId|deviceAndAppManagementAssignmentFilterId|collectionId)$') { continue }
                $copy[$key] = $assignment[$key]
            }
            if ($devFilterId) { $copy['deviceAndAppManagementAssignmentFilterId'] = $devFilterId }
            $kept.Add($copy)
        }
        $props[$assignmentsKey] = [object[]]@($kept.ToArray())
    }

    # Groups: static and empty (ADR 0003). No users, no group-in-group, no role or licence assignment, no dynamic rule.
    if ($Type -eq 'microsoft.entra.group') {
        foreach ($name in 'Members', 'Owners', 'GroupAsMembers', 'MemberOf', 'AssignedLicenses', 'AssignedToRole', 'MembershipRule', 'MembershipRuleProcessingState') {
            $k = & $findKey $props $name
            if ($k) { $props.Remove($k) }
        }
        $gtKey = & $findKey $props 'GroupTypes'
        if ($gtKey) {
            $types = @($props[$gtKey] | Where-Object { [string]$_ -ine 'DynamicMembership' })
            if ($types.Count -gt 0) { $props[$gtKey] = [object[]]$types } else { $props.Remove($gtKey) }
        }
        $nickKey = & $findKey $props 'MailNickname'
        $dnKey = & $findKey $props 'DisplayName'
        if (-not $nickKey -and $dnKey) {
            $nick = ([string]$props[$dnKey] -replace '[^A-Za-z0-9_-]', '')
            if ($nick) { $props['MailNickname'] = $nick }
        }
    }

    # Roles: groups only
    if ($Type -match 'role') {
        foreach ($key in @($props.Keys)) {
            if ($key -match '^(users?|members?|principals?)(ids?)?$' -and @($props[$key]).Count -gt 0 -and -not [string]::IsNullOrWhiteSpace((@($props[$key]) -join ''))) {
                $reasons.Add("'$key' assigns users; roles are assigned through groups only")
            }
        }
    }

    # Conditional Access
    if ($Type -eq 'microsoft.entra.conditionalaccesspolicy') {
        $keywords = @('all', 'none', 'guestsorexternalusers')
        $breakUsers = @($BreakGlassUsers | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $breakGroups = @($BreakGlassGroups | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($breakUsers.Count -eq 0 -and $breakGroups.Count -eq 0) {
            $reasons.Add('no break-glass exclusion configured (BreakGlass / BreakGlassGroups); a Conditional Access policy is not applied without it')
        }

        foreach ($listName in 'IncludeGroups', 'ExcludeGroups') {
            $k = & $findKey $props $listName
            if ($k) {
                foreach ($g in @($props[$k])) {
                    if ([string]::IsNullOrWhiteSpace([string]$g)) { continue }
                    if (-not $KnownGroups.Contains([string]$g)) { $reasons.Add("needs-group: $listName '$g' does not exist in Dev, is not part of this plan and has no recognisable persona (add it to PersonaMap or create it in Dev)") }
                }
            }
        }
        foreach ($listName in 'IncludeUsers', 'ExcludeUsers') {
            $k = & $findKey $props $listName
            if ($k) {
                foreach ($u in @($props[$k])) {
                    $text = [string]$u
                    if ([string]::IsNullOrWhiteSpace($text)) { continue }
                    if ($keywords -contains $text.ToLowerInvariant()) { continue }
                    if ($breakUsers -contains $text) { continue }
                    $reasons.Add("$listName names a specific user; users are not mirrored")
                    break
                }
            }
        }

        $props['State'] = 'enabledForReportingButNotEnforced'
        $euKey = & $findKey $props 'ExcludeUsers'; if (-not $euKey) { $euKey = 'ExcludeUsers' }
        $egKey = & $findKey $props 'ExcludeGroups'; if (-not $egKey) { $egKey = 'ExcludeGroups' }
        $props[$euKey] = [object[]]@((@(if ($props.Contains($euKey)) { $props[$euKey] }) + $breakUsers) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
        $props[$egKey] = [object[]]@((@(if ($props.Contains($egKey)) { $props[$egKey] }) + $breakGroups) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    }

    [pscustomobject]@{ Properties = $props; Reasons = @($reasons | Select-Object -Unique) }
}
