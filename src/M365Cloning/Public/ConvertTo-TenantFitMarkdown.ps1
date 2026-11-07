function ConvertTo-TenantFitMarkdown {
    <#
    .SYNOPSIS
        Pure: Markdown view of a suitability check (Get-TenantFitAssessment, issue #39).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Assessment)
    $a = $Assessment
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine('# Tenant suitability check')
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("Result: **$($a.Status)** - $($a.Verdict)")
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("Verified: $($a.Verified). Usage of Prod from: $($a.ProdUsageSource). Created (UTC): $($a.CreatedUtc)")
    $null = $sb.AppendLine()
    $s = $a.Summary
    $null = $sb.AppendLine('| Red | Yellow | Info | Features used in Prod | Missing in Dev |')
    $null = $sb.AppendLine('|---|---|---|---|---|')
    $null = $sb.AppendLine("| $($s.Red) | $($s.Yellow) | $($s.Info) | $($s.FeaturesUsedInProd) | $($s.FeaturesMissingInDev) |")
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('## Findings')
    $null = $sb.AppendLine()
    if (@($a.Findings).Count -eq 0) { $null = $sb.AppendLine('None.') }
    else {
        $null = $sb.AppendLine('| Severity | Category | Message | Affected types | Count |')
        $null = $sb.AppendLine('|---|---|---|---|---|')
        foreach ($f in @($a.Findings)) {
            $msg = ([string]$f.Message).Replace('|', '\|')
            $null = $sb.AppendLine("| $($f.Severity) | $($f.Category) | $msg | $((@($f.AffectedTypes)) -join ', ') | $($f.AffectedCount) |")
        }
    }
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('## Licences')
    $null = $sb.AppendLine()
    foreach ($side in 'Prod', 'Dev') {
        $l = $a.Licences[$side]
        $null = $sb.AppendLine("**$side**: readable $($l.Readable)$(if ($l.Error) { " ($($l.Error))" })")
        $null = $sb.AppendLine()
        if (@($l.Skus).Count -gt 0) {
            $null = $sb.AppendLine('| SKU | Status | Enabled | Warning | Consumed |')
            $null = $sb.AppendLine('|---|---|---|---|---|')
            foreach ($k in @($l.Skus)) { $null = $sb.AppendLine("| $($k['SkuPartNumber']) | $($k['CapabilityStatus']) | $($k['PrepaidEnabled']) | $($k['PrepaidWarning']) | $($k['ConsumedUnits']) |") }
            $null = $sb.AppendLine()
        }
    }
    $sb.ToString()
}
