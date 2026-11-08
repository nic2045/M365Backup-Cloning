function Compare-TenantSnapshot {
    <#
    .SYNOPSIS
        Compares the Prod snapshot (desired) with the Dev snapshot (actual). Pure function, no I/O.
    .DESCRIPTION
        Resources are matched by resourceType + name, groups and assignments by group name, not by ID.
        Added   = in Prod, missing in Dev (an apply would create it).
        Removed = in Dev, missing in Prod (extra in Dev; an automatic run never deletes it, ADR 0001).
        Changed = in both, properties differ.
        IsIdentical is true when there is no difference at all (empty report).
        Source (issue #27 part 3, ADR 0020): -SourceInfo @{ Kind = 'Repository'; Commit = '<commit>' } when the desired
        side is desired/ of the configuration repository (Read-DesiredStateSnapshot). The report then carries it as
        Source and its Direction names the repository. Without -SourceInfo the report keeps its shape (Prod -> Dev).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Source,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Target,
        [System.Collections.IDictionary]$SourceInfo
    )
    if ($SourceInfo -and ([string]$SourceInfo['Kind'] -ne 'Repository' -or [string]$SourceInfo['Commit'] -notmatch '^[0-9a-f]{40}([0-9a-f]{24})?$')) {
        throw 'SourceInfo needs Kind = Repository and the full commit ID of the configuration repository.'
    }

    $index = {
        param($Snapshot)
        $map = @{}
        foreach ($resource in @($Snapshot['resources'])) {
            $props = if ($resource['properties'] -is [System.Collections.IDictionary]) { $resource['properties'] } else { @{} }
            $name = $resource['displayName']
            foreach ($candidate in 'DisplayName', 'displayName', 'Name', 'Identity') {
                if (-not $name -and $props.Contains($candidate)) { $name = [string]$props[$candidate] }
            }
            if (-not $name) { $name = '(unnamed)' }
            $type = ([string]$resource['resourceType']).ToLowerInvariant()
            $key = "$type|$name"
            $n = 1
            while ($map.ContainsKey($key)) { $n++; $key = "$type|$name (duplicate $n)" }
            $map[$key] = [pscustomobject]@{
                Type = $type
                Name = if ($n -gt 1) { "$name (duplicate $n)" } else { $name }
                Flat = ConvertTo-FlatProperty -Value $props
            }
        }
        $map
    }

    $src = & $index $Source
    $tgt = & $index $Target
    $types = @($src.Values + $tgt.Values | ForEach-Object { $_.Type } | Sort-Object -Unique)

    $typeResults = foreach ($type in $types) {
        $added = [System.Collections.Generic.List[string]]::new()
        $removed = [System.Collections.Generic.List[string]]::new()
        $changed = [System.Collections.Generic.List[object]]::new()
        $unchanged = 0

        $keys = @($src.Keys + $tgt.Keys | Where-Object { $_ -like "$type|*" } | Sort-Object -Unique)
        foreach ($key in $keys) {
            $inSrc = $src.ContainsKey($key); $inTgt = $tgt.ContainsKey($key)
            if ($inSrc -and -not $inTgt) { $added.Add($src[$key].Name); continue }
            if ($inTgt -and -not $inSrc) { $removed.Add($tgt[$key].Name); continue }

            $diffs = [System.Collections.Generic.List[object]]::new()
            $paths = @($src[$key].Flat.Keys + $tgt[$key].Flat.Keys | Sort-Object -Unique)
            foreach ($path in $paths) {
                $a = if ($src[$key].Flat.Contains($path)) { @($src[$key].Flat[$path]) -join ' | ' } else { '<absent>' }
                $b = if ($tgt[$key].Flat.Contains($path)) { @($tgt[$key].Flat[$path]) -join ' | ' } else { '<absent>' }
                if ($a -cne $b) { $diffs.Add([pscustomobject]@{ Property = $path; Source = $a; Target = $b }) }
            }
            if ($diffs.Count -gt 0) { $changed.Add([pscustomobject]@{ Name = $src[$key].Name; Differences = $diffs.ToArray() }) }
            else { $unchanged++ }
        }
        [pscustomobject]@{
            ResourceType = $type
            Added        = $added.ToArray()
            Removed      = $removed.ToArray()
            Changed      = $changed.ToArray()
            Unchanged    = $unchanged
        }
    }
    $typeResults = @($typeResults)

    $summary = [pscustomobject]@{
        Added     = [int](($typeResults | ForEach-Object { $_.Added.Count } | Measure-Object -Sum).Sum)
        Removed   = [int](($typeResults | ForEach-Object { $_.Removed.Count } | Measure-Object -Sum).Sum)
        Changed   = [int](($typeResults | ForEach-Object { $_.Changed.Count } | Measure-Object -Sum).Sum)
        Unchanged = [int](($typeResults | ForEach-Object { $_.Unchanged } | Measure-Object -Sum).Sum)
    }
    $result = [pscustomobject]@{
        Direction   = 'Prod -> Dev (Source = Prod, Target = Dev)'
        Types       = $typeResults
        Summary     = $summary
        IsIdentical = ($summary.Added + $summary.Removed + $summary.Changed) -eq 0
    }
    if ($SourceInfo) {
        $commit = [string]$SourceInfo['Commit']
        $result.Direction = "Configuration repository -> Dev (Source = desired/ at commit $($commit.Substring(0, 12)), Target = Dev)"
        $result | Add-Member -NotePropertyName Source -NotePropertyValue ([ordered]@{ Kind = 'Repository'; Commit = $commit })
    }
    $result
}
