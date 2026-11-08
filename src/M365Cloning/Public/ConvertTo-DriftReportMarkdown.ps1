function ConvertTo-DriftReportMarkdown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Report,
        [string]$GeneratedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC'
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Drift report')
    $lines.Add('')
    # Source (issue #27 part 3, ADR 0020): desired/ of the configuration repository instead of Prod.
    $src = if ($Report -is [System.Collections.IDictionary]) { $Report['Source'] } elseif ($Report.PSObject.Properties.Name -contains 'Source') { $Report.Source } else { $null }
    $fromRepo = $src -is [System.Collections.IDictionary] -and [string]$src['Kind'] -eq 'Repository'
    $desired = if ($fromRepo) { 'Desired' } else { 'Prod' }
    $lines.Add("Direction: $($Report.Direction). Generated: $GeneratedAt. Read only: nothing was changed.")
    if ($fromRepo) { $lines.Add(''); $lines.Add("Desired state: configuration repository, commit $([string]$src['Commit']). Prod was not read.") }
    $lines.Add('')
    if ($Report.IsIdentical) {
        $lines.Add("**No differences.** Dev matches $(if ($fromRepo) { 'the desired state' } else { 'Prod' }) for the compared resources.")
        return ($lines -join "`n") + "`n"
    }
    $lines.Add('| Added (missing in Dev) | Removed (extra in Dev) | Changed | Unchanged |')
    $lines.Add('|---|---|---|---|')
    $lines.Add("| $($Report.Summary.Added) | $($Report.Summary.Removed) | $($Report.Summary.Changed) | $($Report.Summary.Unchanged) |")
    foreach ($type in $Report.Types) {
        if ($type.Added.Count + $type.Removed.Count + $type.Changed.Count -eq 0) { continue }
        $lines.Add('')
        $lines.Add("## $($type.ResourceType)")
        foreach ($n in $type.Added) { $lines.Add("- Added: $n") }
        foreach ($n in $type.Removed) { $lines.Add("- Removed: $n") }
        foreach ($c in $type.Changed) {
            $lines.Add('')
            $lines.Add("### Changed: $($c.Name)")
            $lines.Add("| Property | $desired | Dev |")
            $lines.Add('|---|---|---|')
            foreach ($d in $c.Differences) {
                $esc = { param($s) ([string]$s) -replace '\|', '\|' -replace "`r?`n", ' ' }
                $lines.Add("| $(& $esc $d.Property) | $(& $esc $d.Source) | $(& $esc $d.Target) |")
            }
        }
    }
    ($lines -join "`n") + "`n"
}
