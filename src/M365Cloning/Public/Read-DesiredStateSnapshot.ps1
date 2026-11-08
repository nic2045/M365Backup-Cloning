function ConvertFrom-DesiredStateResource {
    <#
    .SYNOPSIS
        Pure function: turns the content of one desired-state file back into a resource of a UTCM snapshot (issue #27
        part 2, ADR 0019), so New-ApplyPlan works on it unchanged.
    .DESCRIPTION
        - An assignment filter gets a synthetic Id equal to its display name (the export removed its Prod ID). The apply
          drops Id before it writes, so the synthetic value never reaches Dev.
        - An assignment that names its filter (deviceAndAppManagementAssignmentFilterDisplayName, written by the
          export) gets that name as deviceAndAppManagementAssignmentFilterId and loses the name field. New-ApplyPlan then
          maps "ID" -> name through the same snapshot and name -> Dev ID through the Dev snapshot, as for a Prod snapshot.
        Everything else stays as it is in the file.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Content)

    $type = ([string]$Content['resourceType']).ToLowerInvariant()
    $name = [string]$Content['displayName']
    $props = [ordered]@{}
    foreach ($k in $Content['properties'].Keys) { $props[$k] = $Content['properties'][$k] }

    if ($type -eq 'microsoft.intune.deviceandappmanagementassignmentfilter') {
        $hasId = @($props.Keys | Where-Object { $_ -match '^(?i)(id|identity)$' -and -not [string]::IsNullOrWhiteSpace([string]$props[$_]) }).Count -gt 0
        if (-not $hasId) { $props['Id'] = $name }
    }
    $assignmentsKey = @($props.Keys | Where-Object { $_ -ieq 'Assignments' }) | Select-Object -First 1
    if ($assignmentsKey) {
        $props[$assignmentsKey] = [object[]]@(foreach ($a in @($props[$assignmentsKey])) {
                if ($a -isnot [System.Collections.IDictionary] -or -not $a.Contains('deviceAndAppManagementAssignmentFilterDisplayName')) { $a; continue }
                $copy = [ordered]@{}
                foreach ($ak in $a.Keys) { if ($ak -ne 'deviceAndAppManagementAssignmentFilterDisplayName') { $copy[$ak] = $a[$ak] } }
                $copy['deviceAndAppManagementAssignmentFilterId'] = [string]$a['deviceAndAppManagementAssignmentFilterDisplayName']
                $copy
            })
    }
    [ordered]@{ resourceType = $type; displayName = $name; properties = $props }
}

function ConvertTo-DesiredComparableSnapshot {
    <#
    .SYNOPSIS
        Pure function: a copy of a Dev snapshot without what the export never writes (ADR 0018 point 4), so a plan from
        the repository does not see a difference where the desired state only left a property out on purpose.
    .DESCRIPTION
        Removes the connection properties (Get-DesiredStateConnectionProperty) of every resource and collectionId in
        its assignments. Id, Identity and groupId stay: the comparison ignores them already, and the Dev IDs are needed
        to map filters and groups. The snapshot passed in is not changed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot)

    $connection = Get-DesiredStateConnectionProperty
    $copy = [ordered]@{}
    foreach ($k in $Snapshot.Keys) { if ($k -ne 'resources') { $copy[$k] = $Snapshot[$k] } }
    $copy['resources'] = [object[]]@(foreach ($r in @($Snapshot['resources'])) {
            if ($r -isnot [System.Collections.IDictionary] -or $r['properties'] -isnot [System.Collections.IDictionary]) { $r; continue }
            $props = [ordered]@{}
            foreach ($k in $r['properties'].Keys) {
                if ($connection | Where-Object { $_ -ieq $k }) { continue }
                $v = $r['properties'][$k]
                if ($k -ieq 'Assignments') {
                    $v = [object[]]@(foreach ($a in @($v)) {
                            if ($a -isnot [System.Collections.IDictionary]) { $a; continue }
                            $ac = [ordered]@{}
                            foreach ($ak in $a.Keys) { if ($ak -ne 'collectionId') { $ac[$ak] = $a[$ak] } }
                            $ac
                        })
                }
                $props[$k] = $v
            }
            $res = [ordered]@{}
            foreach ($k in $r.Keys) { $res[$k] = $r[$k] }
            $res['properties'] = $props
            $res
        })
    $copy
}

function Read-DesiredStateSnapshot {
    <#
    .SYNOPSIS
        Reads the desired state of the configuration repository (desired/, written by Export-DesiredState) into a
        snapshot that New-ApplyPlan takes as its source instead of Prod (issue #27 part 2, ADR 0019). Read only: it
        changes nothing in the repository and reads no tenant.
    .DESCRIPTION
        - The repository must be a Git work tree and not this toolkit (same rule as the export, ADR 0018 point 5).
        - desired/ must have no change that is not committed (also no new file): the plan names the commit it was built
          from, and that commit must hold exactly what the plan read. Otherwise the run stops and says which files.
        - Every desired/<type>/<name>.json is read; a file that is not a desired-state file, or whose resourceType does
          not match its folder, stops the run with its path (a hand-edited file must not be skipped silently).
        Returns @{ Snapshot = @{ resources = [...] }; Commit = '<full commit id>'; Files = <count> }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    $repoSetting = if ($Config.Contains('ConfigRepository')) { [string]$Config['ConfigRepository'] } else { '' }
    if ([string]::IsNullOrWhiteSpace($repoSetting) -or $repoSetting -match '^\s*<.*>\s*$') {
        throw 'ConfigRepository is not set in config.psd1: the plan from the repository needs the path of your private configuration repository (ADR 0004).'
    }
    $repo = Assert-IntuneBackupRepository -Path $repoSetting
    $desired = Join-Path $repo 'desired'
    if (-not (Test-Path -LiteralPath $desired -PathType Container)) {
        throw "The configuration repository has no desired state (folder 'desired' is missing). Run the export first (scripts/Export-DesiredState.ps1 or the job 'export-desired')."
    }
    $dirty = @(Invoke-IntuneBackupGit -Repository $repo -Arguments @('-c', 'core.quotepath=off', 'status', '--porcelain', '--untracked-files=all', '--', 'desired') | Where-Object { $_ })
    if ($dirty.Count -gt 0) {
        $first = (($dirty | Select-Object -First 3) | ForEach-Object { ([string]$_).Substring([Math]::Min(3, ([string]$_).Length)) }) -join ', '
        throw "The desired state has $($dirty.Count) change(s) that are not committed ($first). Commit or discard them in the configuration repository first: a plan names the commit it was built from."
    }
    $commit = [string](Invoke-IntuneBackupGit -Repository $repo -Arguments @('rev-parse', 'HEAD') | Select-Object -First 1)
    if ($commit -notmatch '^[0-9a-f]{40}([0-9a-f]{24})?$') { throw 'The configuration repository has no commit yet. Run the export first.' }

    $files = @(Get-ChildItem -LiteralPath $desired -Filter '*.json' -File -Recurse | Sort-Object { $_.FullName } -Culture ([cultureinfo]::InvariantCulture))
    if ($files.Count -eq 0) { throw "The desired state in the configuration repository is empty. Run the export first." }
    $resources = foreach ($f in $files) {
        $rel = [IO.Path]::GetRelativePath($repo, $f.FullName).Replace('\', '/')
        try { $content = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json -AsHashtable -Depth 50 }
        catch { throw "Not a desired-state file (no valid JSON): $rel" }
        if ($content -isnot [System.Collections.IDictionary] -or [string]::IsNullOrWhiteSpace([string]$content['resourceType']) -or
            [string]::IsNullOrWhiteSpace([string]$content['displayName']) -or $content['properties'] -isnot [System.Collections.IDictionary]) {
            throw "Not a desired-state file (resourceType, displayName and properties are needed): $rel"
        }
        $folder = Split-Path -Leaf (Split-Path -Parent $f.FullName)
        if (-not [string]::Equals($folder, [string]$content['resourceType'], [StringComparison]::OrdinalIgnoreCase)) {
            throw "The resourceType of $rel does not match its folder '$folder'."
        }
        ConvertFrom-DesiredStateResource -Content $content
    }
    @{ Snapshot = @{ resources = [object[]]@($resources) }; Commit = $commit; Files = $files.Count }
}
