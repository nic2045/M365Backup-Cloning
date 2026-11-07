function ConvertTo-ApplyPlanMarkdown {
    <#
    .SYNOPSIS
        Plan as Markdown for the preview (the properties themselves stay in the JSON file).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan,
        [Parameter(Mandatory)][string]$PlanHash
    )
    $sb = [System.Text.StringBuilder]::new()
    $title = if ($Plan.Contains('Title') -and $Plan['Title']) { [string]$Plan['Title'] } else { 'Apply plan Prod -> Dev (preview, nothing was changed)' }
    $null = $sb.AppendLine("# $title")
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("Plan hash: ``$PlanHash``")
    $null = $sb.AppendLine()
    $s = $Plan['Summary']
    $line = "Planned: $($s['Planned']) | Blocked: $($s['Blocked']) | Skipped: $($s['Skipped'])"
    if ($s.Contains('Exists')) { $line += " | Exists: $($s['Exists'])" }
    if ($s.Contains('Protected')) { $line += " | Protected: $($s['Protected']) | Invite (info): $($s['Invite'])" }
    $null = $sb.AppendLine($line)
    if ($s.Contains('InBaseline')) {
        $null = $sb.AppendLine()
        $null = $sb.AppendLine($(if ($s['InBaseline']) { 'Base state reached: no difference.' } else { 'Difference to the base state: see the planned and blocked entries.' }))
    }
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('| Status | Operation | Resource type | Name | Reason |')
    $null = $sb.AppendLine('|---|---|---|---|---|')
    foreach ($a in $Plan['Actions']) {
        $reason = ([string]$a['Reason']).Replace('|', '\|')
        $name = ([string]$a['Name']).Replace('|', '\|')
        $null = $sb.AppendLine("| $($a['Status']) | $($a['Operation']) | $($a['ResourceType']) | $name | $reason |")
    }
    if ($Plan.Contains('Protected') -and @($Plan['Protected']).Count -gt 0) {
        $null = $sb.AppendLine()
        $null = $sb.AppendLine('Protected (never deleted or changed):')
        $null = $sb.AppendLine()
        $null = $sb.AppendLine('| Kind | Name | Source |')
        $null = $sb.AppendLine('|---|---|---|')
        foreach ($p in $Plan['Protected']) { $null = $sb.AppendLine("| $($p['Kind']) | $(([string]$p['Name']).Replace('|', '\|')) | $($p['Source']) |") }
    }
    if ($Plan.Contains('Licences') -and $Plan['Licences']) {
        $lic = $Plan['Licences']
        $null = $sb.AppendLine()
        $null = $sb.AppendLine('## Licences')
        $null = $sb.AppendLine()
        if (-not $lic['Readable']) { $null = $sb.AppendLine("The licence list of Dev could not be read ($($lic['Error'])). Entries that need a licence are blocked.") }
        elseif (@($lic['Missing']).Count -eq 0) { $null = $sb.AppendLine('All licences that the planned entries need are present in Dev.') }
        if (@($lic['Missing']).Count -gt 0) {
            $null = $sb.AppendLine()
            $null = $sb.AppendLine('| Missing | Service plans (any of) | Blocked entries |')
            $null = $sb.AppendLine('|---|---|---|')
            foreach ($m in $lic['Missing']) { $null = $sb.AppendLine("| $($m['Feature']) | $(@($m['ServicePlans']) -join ', ') | $((@($m['Entries']) -join '<br>').Replace('|', '\|')) |") }
        }
        foreach ($w in @($lic['Warnings'])) { $null = $sb.AppendLine("- Warning: $w") }
    }
    if ($Plan.Contains('Notes') -and @($Plan['Notes']).Count -gt 0) {
        $null = $sb.AppendLine()
        $null = $sb.AppendLine('Notes:')
        foreach ($note in $Plan['Notes']) { $null = $sb.AppendLine("- $note") }
    }
    $null = $sb.AppendLine()
    $hint = if ($Plan.Contains('ApplyHint') -and $Plan['ApplyHint']) { [string]$Plan['ApplyHint'] } else { 'scripts/Invoke-ApplyDev.ps1 -Apply -ConfirmPlanHash <hash above>' }
    $null = $sb.AppendLine("Apply only this plan: ``$hint``. Blocked, skipped and existing entries are never applied.")
    $sb.ToString()
}
