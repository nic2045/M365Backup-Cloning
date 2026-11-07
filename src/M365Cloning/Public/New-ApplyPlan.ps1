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
        The plan holds the properties to apply (from Prod, ids removed). The plan file is local and git-ignored.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Source,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Target,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
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

    $map = Get-DscResourceMap
    $comparison = Compare-TenantSnapshot -Source $Source -Target $Target
    $srcIndex = Get-SnapshotResourceIndex -Snapshot $Source
    $tgtIndex = Get-SnapshotResourceIndex -Snapshot $Target

    # Group names that exist in Dev, or that this plan creates first.
    $known = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $tgtIndex.Values) { if ($entry.Type -eq 'microsoft.entra.group') { $null = $known.Add($entry.Name) } }
    foreach ($t in $comparison.Types) {
        if ($t.ResourceType -eq 'microsoft.entra.group') { foreach ($n in $t.Added) { $null = $known.Add($n) } }
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
            Differences  = [object[]]@($Differences)
            Properties   = $null
        }
        if ($Operation -eq 'SkipDelete') {
            $action.Status = 'skipped'
            $action.Reason = 'exists only in Dev; an apply never deletes'
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
            $converted = ConvertTo-ApplyProperties -Type $Type -Resource $resource -KnownGroups $known -BreakGlassUsers $breakUsers -BreakGlassGroups $breakGroups
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
                    Differences  = [object[]]@()
                    Properties   = (New-EmptyGroupProperties -Name $gName -Description "Empty copy for Conditional Access (persona $($emptyGroups[$gName])); no members.")
                }
            })
    }

    # Ordinal order (same on every machine): apply order, then type, then name. Keys are unique.
    $built.Sort([System.Comparison[object]] { param($a, $b) [string]::CompareOrdinal($a.Key, $b.Key) })
    $actions = [object[]]@($built | ForEach-Object { $_.Action })

    $count = { param($status) @($actions | Where-Object { $_.Status -eq $status }).Count }
    [ordered]@{
        Direction      = 'Prod -> Dev'
        TargetTenantId = [string]$Config['Dev']['TenantId']
        Actions        = $actions
        Notes          = [string[]]@($notes | Select-Object -Unique)
        Summary        = [ordered]@{
            Planned = [int](& $count 'planned')
            Blocked = [int](& $count 'blocked')
            Skipped = [int](& $count 'skipped')
        }
    }
}
