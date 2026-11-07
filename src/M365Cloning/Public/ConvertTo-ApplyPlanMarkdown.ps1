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
    $null = $sb.AppendLine('# Apply plan Prod -> Dev (preview, nothing was changed)')
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("Plan hash: ``$PlanHash``")
    $null = $sb.AppendLine()
    $s = $Plan['Summary']
    $null = $sb.AppendLine("Planned: $($s['Planned']) | Blocked: $($s['Blocked']) | Skipped: $($s['Skipped'])")
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('| Status | Operation | Resource type | Name | Reason |')
    $null = $sb.AppendLine('|---|---|---|---|---|')
    foreach ($a in $Plan['Actions']) {
        $reason = ([string]$a['Reason']).Replace('|', '\|')
        $name = ([string]$a['Name']).Replace('|', '\|')
        $null = $sb.AppendLine("| $($a['Status']) | $($a['Operation']) | $($a['ResourceType']) | $name | $reason |")
    }
    if ($Plan.Contains('Notes') -and @($Plan['Notes']).Count -gt 0) {
        $null = $sb.AppendLine()
        $null = $sb.AppendLine('Notes:')
        foreach ($note in $Plan['Notes']) { $null = $sb.AppendLine("- $note") }
    }
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('Apply only this plan: `scripts/Invoke-ApplyDev.ps1 -Apply -ConfirmPlanHash <hash above>`. Blocked and skipped entries are never applied.')
    $sb.ToString()
}
