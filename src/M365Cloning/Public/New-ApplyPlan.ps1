function New-ApplyPlan {
    <#
    .SYNOPSIS
        Pure function: builds the plan to bring Dev to the state of Prod. Writes nothing, calls nothing.
    .DESCRIPTION
        Uses Compare-TenantSnapshot (Prod = Source, Dev = Target):
        Added   -> Create in Dev; Changed -> Update in Dev;
        Removed -> never deleted (ADR 0001), shown as 'skipped'.
        Each action has Status 'planned', 'blocked' (with Reason) or 'skipped'. Rules for blocking and for
        Conditional Access: see ConvertTo-ApplyProperties. The plan refuses a Dev tenant ID that equals the Prod
        tenant ID: apply writes to the Dev tenant only.
        Conditional Access groups (ADR 0003): a group that a Conditional Access policy refers to and that Dev lacks is
        planned as a static, EMPTY copy with the same name when it has a recognisable persona (naming scheme or
        PersonaMap, see Get-PersonaSettings); the configured break-glass groups are planned the same way. Without a
        recognisable persona the policy is blocked ('needs-group'). Plan.Notes lists referenced groups without a
        recognisable persona that are copied anyway.
        Intune (issue #2): an inclusion group of an Intune assignment that Dev lacks is planned as an empty static copy
        (assigned to nobody, never wider than Prod); a missing exclusion group blocks the policy. Assignment filters are
        matched by name through both snapshots; a filter that Dev lacks is created first and the policy is blocked
        until the next run ('needs-filter'). Secret-bearing types (Get-DscResourceMap, Secret) and profiles with an
        encrypted OMA-URI value (Test-ResourceHasSecret) are 'skipped' with a reason starting with 'secret:'.
        Conditional Access dependencies (issue #33): named locations and authentication strengths are applied before the
        policies (apply order 2); a policy that names one that Dev lacks and the plan does not create is blocked
        ('needs-location' / 'needs-auth-strength'). The built-in authentication strengths exist in every tenant and are
        never changed ('skipped: built-in'). The authentication method policies are 'skipped: report-only' (lockout risk).
        Copy all (ADR 0006, issue #40): every type of the catalog (Get-ResourceTypeCatalog) is planned through the
        same generic path. A type on the exclusion list (Data/ExcludedResourceTypes.psd1, ExcludeResourceTypes in the
        configuration, or a workload that is off) is 'skipped' with a reason starting with 'excluded:'. A type whose
        object every tenant has and that cannot be created (Data/ResourceRules.psd1, TenantDefaults) is
        'skipped: tenant default'. A property listed as secret (SecretProperties) skips the resource ('secret:').
        Generic reference fields (References, Handler 'generic', for example AuthenticationContexts) are resolved by
        their key against Dev and the creates of this plan. Only a type that the catalog does not know at all is
        blocked ('no Microsoft365DSC resource is mapped').
        Plan.TypeSummary counts per resource type: planned, blocked, skipped and excluded; Plan.ExcludedTypes lists
        the excluded types of the workloads that are on (they are not in the snapshot by default).
        The plan holds the properties to apply (from Prod, ids removed). The plan file is local and git-ignored.
        Area (issue #66): -Area Intune keeps only the Intune entries (resource type microsoft.intune.*) and the empty
        group copies an Intune assignment needs; every other planned or blocked entry becomes 'skipped' with a reason
        starting with 'area:'. The plan carries Area = 'Intune', so its hash differs from the plan of all areas.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Source,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Target,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [ValidateSet('All', 'Intune')][string]$Area = 'All'
    )

    foreach ($side in 'Prod', 'Dev') {
        if (-not $Config.Contains($side) -or $Config[$side] -isnot [System.Collections.IDictionary] -or
            [string]::IsNullOrWhiteSpace([string]$Config[$side]['TenantId'])) {
            throw "Config has no $side tenant ID."
        }
    }
    if ([string]$Config['Dev']['TenantId'] -eq [string]$Config['Prod']['TenantId']) {
        throw 'The target tenant ID equals the Prod tenant ID. Refused: apply writes to the Dev tenant only.'
    }

    $list = { param($name) if ($Config.Contains($name) -and $null -ne $Config[$name]) { @($Config[$name]) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } } }
    $breakUsers = [string[]]@(& $list 'BreakGlass')
    $breakGroups = [string[]]@(& $list 'BreakGlassGroups')

    $map = Get-ResourceTypeCatalog -Config $Config
    $rules = Import-PowerShellDataFile -Path (Join-Path $script:ModuleRoot 'Data' 'ResourceRules.psd1')
    $comparison = Compare-TenantSnapshot -Source $Source -Target $Target
    $srcIndex = Get-SnapshotResourceIndex -Snapshot $Source
    $tgtIndex = Get-SnapshotResourceIndex -Snapshot $Target

    # Group names that exist in Dev, or that this plan creates first.
    $known = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $tgtIndex.Values) { if ($entry.Type -eq 'microsoft.entra.group') { $null = $known.Add($entry.Name) } }
    foreach ($t in $comparison.Types) {
        if ($t.ResourceType -eq 'microsoft.entra.group') { foreach ($n in $t.Added) { $null = $known.Add($n) } }
    }

    # Conditional Access dependencies (issue #33): names that exist in Dev or that this plan creates first (order 2).
    # The three built-in authentication strengths exist in every tenant (Learn: 'Conditional Access authentication
    # strengths'; display names as listed by Graph, with and without the word 'strength' as the portal shows them).
    $locationType = 'microsoft.entra.namedlocationpolicy'
    $strengthType = 'microsoft.entra.authenticationstrengthpolicy'
    $builtInStrengths = @('Multifactor authentication', 'Passwordless MFA', 'Phishing-resistant MFA',
        'Multifactor authentication strength', 'Passwordless MFA strength', 'Phishing-resistant MFA strength')
    $knownLocations = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $knownStrengths = [System.Collections.Generic.HashSet[string]]::new([string[]]$builtInStrengths, [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $tgtIndex.Values) {
        if ($entry.Type -eq $locationType) { $null = $knownLocations.Add($entry.Name) }
        elseif ($entry.Type -eq $strengthType) { $null = $knownStrengths.Add($entry.Name) }
    }
    foreach ($t in $comparison.Types) {
        if ($t.ResourceType -eq $locationType) { foreach ($n in $t.Added) { $null = $knownLocations.Add($n) } }
        elseif ($t.ResourceType -eq $strengthType) { foreach ($n in $t.Added) { if ($n -notin $builtInStrengths) { $null = $knownStrengths.Add($n) } } }
    }

    # Conditional Access groups (ADR 0003): empty static copies for persona groups that Dev lacks.
    $personaSettings = Get-PersonaSettings -Config $Config
    $caType = 'microsoft.entra.conditionalaccesspolicy'
    $emptyGroups = [ordered]@{}
    $notes = [System.Collections.Generic.List[string]]::new()
    $caCount = 0
    foreach ($t in $comparison.Types) {
        if ($t.ResourceType -ne $caType) { continue }
        foreach ($caName in (@($t.Added) + @($t.Changed | ForEach-Object { $_.Name }))) {
            $entry = $srcIndex["$caType|$caName"]
            if (-not $entry) { continue }
            $caCount++
            $caProps = ConvertTo-CanonicalObject -Value $(if ($entry.Resource['properties'] -is [System.Collections.IDictionary]) { $entry.Resource['properties'] } else { @{} })
            foreach ($listKey in @($caProps.Keys | Where-Object { $_ -match '^(include|exclude)groups$' })) {
                foreach ($g in @($caProps[$listKey])) {
                    $gName = [string]$g
                    if ([string]::IsNullOrWhiteSpace($gName)) { continue }
                    $personaOfGroup = Resolve-PersonaOfGroup -GroupName $gName -Settings $personaSettings
                    if ($known.Contains($gName)) {
                        if (-not $personaOfGroup) { $notes.Add("Group '$gName' (policy '$caName') has no recognisable persona (naming scheme or PersonaMap); it is copied as it is.") }
                    }
                    elseif ($personaOfGroup) {
                        $emptyGroups[$gName] = $personaOfGroup
                        $null = $known.Add($gName)
                    }
                }
            }
        }
    }
    if ($caCount -gt 0) {
        foreach ($bg in $breakGroups) {
            if (-not $known.Contains($bg)) { $emptyGroups[$bg] = 'BreakGlass'; $null = $known.Add($bg) }
        }
    }

    # Intune assignment groups: an INCLUSION group that Dev lacks becomes an empty static copy (assigned to nobody,
    # so never wider than Prod). An exclusion group that Dev lacks stays blocked: an empty exclusion would widen.
    $intuneGroups = [ordered]@{}
    foreach ($t in $comparison.Types) {
        if ($t.ResourceType -notlike 'microsoft.intune.*') { continue }
        $entryMap = $map[$t.ResourceType]
        if (-not $entryMap -or $entryMap.Secret -or $entryMap.Excluded -or $entryMap.ReportOnly) { continue }
        foreach ($polName in (@($t.Added) + @($t.Changed | ForEach-Object { $_.Name }))) {
            $entry = $srcIndex["$($t.ResourceType)|$polName"]
            if (-not $entry -or $entry.Resource['properties'] -isnot [System.Collections.IDictionary]) { continue }
            $p = $entry.Resource['properties']
            $aKey = @($p.Keys | Where-Object { $_ -ieq 'Assignments' }) | Select-Object -First 1
            if (-not $aKey) { continue }
            foreach ($asg in @($p[$aKey])) {
                if ($asg -isnot [System.Collections.IDictionary]) { continue }
                $dt = [string]$asg['dataType']; $gName = [string]$asg['groupDisplayName']
                if ($dt -notmatch 'groupassignmenttarget$' -or $dt -match 'exclusion' -or [string]::IsNullOrWhiteSpace($gName)) { continue }
                if (-not $known.Contains($gName)) { $intuneGroups[$gName] = $polName; $null = $known.Add($gName) }
            }
        }
    }

    # Assignment filters are referenced by ID: Prod ID -> name (Prod snapshot) -> Dev ID (Dev snapshot).
    $filterType = 'microsoft.intune.deviceandappmanagementassignmentfilter'
    $idOf = { param($res) $pp = $res['properties']; if ($pp -is [System.Collections.IDictionary]) { foreach ($k in 'Identity', 'Id') { $hit = @($pp.Keys | Where-Object { $_ -ieq $k }) | Select-Object -First 1; if ($hit -and -not [string]::IsNullOrWhiteSpace([string]$pp[$hit])) { return [string]$pp[$hit] } } }; '' }
    $filterMap = @{
        ProdIdToName = @{}
        DevNameToId  = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        Planned      = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }
    foreach ($entry in $srcIndex.Values) { if ($entry.Type -eq $filterType) { $fid = & $idOf $entry.Resource; if ($fid) { $filterMap.ProdIdToName[$fid] = $entry.Name } } }
    foreach ($entry in $tgtIndex.Values) { if ($entry.Type -eq $filterType) { $fid = & $idOf $entry.Resource; if ($fid) { $filterMap.DevNameToId[$entry.Name] = $fid } } }
    foreach ($t in $comparison.Types) { if ($t.ResourceType -eq $filterType) { foreach ($n in $t.Added) { $null = $filterMap.Planned.Add($n) } } }

    # Generic reference fields (ADR 0006): field -> values that exist in Dev or that this plan creates first.
    $references = @{}
    $valueOf = { param($res, $key) $pp = $res['properties']; if ($pp -is [System.Collections.IDictionary]) { $hit = @($pp.Keys | Where-Object { $_ -ieq $key }) | Select-Object -First 1; if ($hit) { return [string]$pp[$hit] } }; '' }
    foreach ($r in @($rules.References | Where-Object { $_.Handler -eq 'generic' })) {
        $knownValues = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $tgtIndex.Values) { if ($entry.Type -eq $r.TargetType) { $v = & $valueOf $entry.Resource $r.MatchBy; if ($v) { $null = $knownValues.Add($v) } } }
        $targetEntry = $map[$r.TargetType]
        $targetCopied = $targetEntry -and -not $targetEntry.Excluded -and -not $targetEntry.Secret -and -not $targetEntry.ReportOnly
        foreach ($t in $comparison.Types) {
            if ($t.ResourceType -ne $r.TargetType -or -not $targetCopied) { continue }
            foreach ($n in $t.Added) { $src = $srcIndex["$($t.ResourceType)|$n"]; if ($src) { $v = & $valueOf $src.Resource $r.MatchBy; if ($v) { $null = $knownValues.Add($v) } } }
        }
        $references[[string]$r.Field] = @{ Known = $knownValues; Reason = [string]$r.Reason; TargetType = [string]$r.TargetType }
    }
    $isTenantDefault = {
        param($Entry, $Resource)
        $rule = $Entry.TenantDefault
        if (-not $rule -or -not $Resource -or $Resource['properties'] -isnot [System.Collections.IDictionary]) { return $false }
        $pp = $Resource['properties']
        $hit = @($pp.Keys | Where-Object { $_ -ieq [string]$rule.Property }) | Select-Object -First 1
        $hit -and "$($pp[$hit])" -eq "$($rule.Value)"
    }

    $built = [System.Collections.Generic.List[object]]::new()
    $add = {
        param($Type, $Name, $Operation, $Differences)

        $entry = $map[$Type]
        $order = if ($entry) { [int]$entry.Order } else { 9 }
        $action = [ordered]@{
            ResourceType = $Type
            Name         = $Name
            Operation    = $Operation
            Status       = 'planned'
            Reason       = ''
            DscResource  = if ($entry) { [string]$entry.Dsc } else { '' }
            AssignmentClass = if ($entry) { [string]$entry.AssignmentClass } else { '' }
            Differences  = [object[]]@($Differences)
            Properties   = $null
        }
        $srcResource = if ($srcIndex.ContainsKey("$Type|$Name")) { $srcIndex["$Type|$Name"].Resource } else { $null }
        if ($Operation -eq 'SkipDelete') {
            $action.Status = 'skipped'
            $action.Reason = 'exists only in Dev; an apply never deletes'
        }
        elseif ($entry -and $entry.Excluded) {
            $action.Status = 'skipped'
            $action.Reason = "excluded: $($entry.ExcludeReason)"
        }
        elseif ($entry -and $entry.ReportOnly) {
            $action.Status = 'skipped'
            $action.Reason = "report-only: $($entry.ReportReason); never applied automatically (it decides who can sign in), review and change it in Dev by hand"
        }
        elseif ($Type -eq $strengthType -and $builtInStrengths -contains $Name) {
            $action.Status = 'skipped'
            $action.Reason = 'built-in authentication strength: exists in every tenant and cannot be changed'
        }
        elseif ($entry -and $entry.Secret) {
            $action.Status = 'skipped'
            $action.Reason = "secret: $($entry.SecretReason) is never copied; create it in Dev by hand"
        }
        elseif ($srcResource -and (Test-ResourceHasSecret -Resource $srcResource)) {
            $action.Status = 'skipped'
            $action.Reason = 'secret: the profile holds an encrypted value (OMA-URI); it is never copied, create it in Dev by hand'
        }
        elseif ($srcResource -and ($secretProp = Get-ResourceSecretProperty -Resource $srcResource)) {
            $action.Status = 'skipped'
            $action.Reason = "secret: the property '$secretProp' holds a secret; the resource is never copied, create it in Dev by hand"
        }
        elseif ($entry -and (& $isTenantDefault $entry $srcResource)) {
            $action.Status = 'skipped'
            $action.Reason = "tenant default: every tenant has this object ($($entry.TenantDefault.Property) = $($entry.TenantDefault.Value)); it cannot be created, change it in Dev by hand if needed"
        }
        elseif (-not $entry) {
            $action.Status = 'blocked'
            $action.Reason = "no Microsoft365DSC resource is mapped for '$Type'"
        }
        elseif ($Name -match ' \(duplicate \d+\)$') {
            $action.Status = 'blocked'
            $action.Reason = 'the name occurs more than once in the snapshot'
        }
        else {
            $resource = $srcIndex["$Type|$Name"].Resource
            $converted = ConvertTo-ApplyProperties -Type $Type -Resource $resource -KnownGroups $known -BreakGlassUsers $breakUsers -BreakGlassGroups $breakGroups -FilterMap $filterMap -KnownLocations $knownLocations -KnownAuthStrengths $knownStrengths -Entry $entry -References $references
            if ($converted.Reasons.Count -gt 0) {
                $action.Status = 'blocked'
                $action.Reason = ($converted.Reasons -join '; ')
            }
            else { $action.Properties = $converted.Properties }
        }
        $built.Add([pscustomobject]@{ Key = ('{0}|{1}|{2}' -f $order, $Type, $Name); Action = $action })
    }

    foreach ($t in $comparison.Types) {
        foreach ($name in $t.Added) { & $add $t.ResourceType $name 'Create' @() }
        foreach ($changed in $t.Changed) {
            $diffs = foreach ($d in $changed.Differences) { [ordered]@{ Property = [string]$d.Property; Source = [string]$d.Source; Target = [string]$d.Target } }
            & $add $t.ResourceType $changed.Name 'Update' @($diffs)
        }
        foreach ($name in $t.Removed) { & $add $t.ResourceType $name 'SkipDelete' @() }
    }

    foreach ($gName in $emptyGroups.Keys) {
        $groupEntry = $map['microsoft.entra.group']
        $built.Add([pscustomobject]@{
                Key    = ('{0}|{1}|{2}' -f [int]$groupEntry.Order, 'microsoft.entra.group', $gName)
                Action = [ordered]@{
                    ResourceType = 'microsoft.entra.group'
                    Name         = $gName
                    Operation    = 'Create'
                    Status       = 'planned'
                    Reason       = "empty static copy (persona $($emptyGroups[$gName])): a Conditional Access policy refers to it; no members"
                    DscResource  = [string]$groupEntry.Dsc
                    AssignmentClass = ''
                    Differences  = [object[]]@()
                    Properties   = (New-EmptyGroupProperties -Name $gName -Description "Empty copy for Conditional Access (persona $($emptyGroups[$gName])); no members.")
                }
            })
    }
    foreach ($gName in $intuneGroups.Keys) {
        $groupEntry = $map['microsoft.entra.group']
        $built.Add([pscustomobject]@{
                Key    = ('{0}|{1}|{2}' -f [int]$groupEntry.Order, 'microsoft.entra.group', $gName)
                Action = [ordered]@{
                    ResourceType = 'microsoft.entra.group'
                    Name         = $gName
                    Operation    = 'Create'
                    Status       = 'planned'
                    Reason       = "empty static copy: Intune policy '$($intuneGroups[$gName])' assigns to it; no members"
                    DscResource  = [string]$groupEntry.Dsc
                    AssignmentClass = ''
                    Differences  = [object[]]@()
                    Properties   = (New-EmptyGroupProperties -Name $gName -Description 'Empty copy for an Intune assignment; no members.')
                }
            })
    }

    # Ordinal order (same on every machine): apply order, then type, then name. Keys are unique.
    $built.Sort([System.Comparison[object]] { param($a, $b) [string]::CompareOrdinal($a.Key, $b.Key) })
    $actions = [object[]]@($built | ForEach-Object { $_.Action })
    if ($Area -eq 'Intune') {
        foreach ($a in $actions) {
            if ($a.Status -notin 'planned', 'blocked') { continue }
            $inArea = ([string]$a.ResourceType).StartsWith('microsoft.intune.') -or ([string]$a.Reason).StartsWith('empty static copy: Intune policy')
            if (-not $inArea) {
                $a.Status = 'skipped'
                $a.Reason = 'area: outside Intune; make a plan of all areas to apply it'
            }
        }
        $notes.Add('Area Intune: only Intune entries and the empty group copies their assignments need; the rest is skipped.')
    }

    $isExcluded = { param($a) $a.Status -eq 'skipped' -and ([string]$a.Reason).StartsWith('excluded:') }
    $count = { param($status) @($actions | Where-Object { $_.Status -eq $status -and -not (& $isExcluded $_) }).Count }

    # Per type: planned / blocked / skipped / excluded (ADR 0006: the report shows what makes no sense to copy).
    $typeSummary = foreach ($g in @($actions | Group-Object { $_.ResourceType } | Sort-Object Name)) {
        $items = @($g.Group)
        [ordered]@{
            ResourceType = [string]$g.Name
            Planned      = @($items | Where-Object { $_.Status -eq 'planned' }).Count
            Blocked      = @($items | Where-Object { $_.Status -eq 'blocked' }).Count
            Skipped      = @($items | Where-Object { $_.Status -eq 'skipped' -and -not (& $isExcluded $_) }).Count
            Excluded     = @($items | Where-Object { & $isExcluded $_ }).Count
        }
    }
    $excludedTypes = foreach ($e in @($map.Values | Where-Object { $_.Excluded -and $_.ExcludeReason -notlike 'workload * is off*' } | Sort-Object { $_.Type })) {
        [ordered]@{ ResourceType = [string]$e.Type; Reason = [string]$e.ExcludeReason }
    }

    $shape = [ordered]@{
        Direction      = 'Prod -> Dev'
        TargetTenantId = [string]$Config['Dev']['TenantId']
        Actions        = $actions
        Notes          = [string[]]@($notes | Select-Object -Unique)
        TypeSummary    = [object[]]@($typeSummary)
        ExcludedTypes  = [object[]]@($excludedTypes)
        Summary        = [ordered]@{
            Planned  = [int](& $count 'planned')
            Blocked  = [int](& $count 'blocked')
            Skipped  = [int](& $count 'skipped')
            Excluded = [int]@($actions | Where-Object { & $isExcluded $_ }).Count
        }
    }
    if ($Area -ne 'All') { $shape['Area'] = $Area }
    Complete-PlanShape -Kind 'apply' -Plan $shape
}
