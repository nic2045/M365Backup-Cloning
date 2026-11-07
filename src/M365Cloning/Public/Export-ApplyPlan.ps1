function Export-ApplyPlan {
    <#
    .SYNOPSIS
        Writes the plan as JSON and Markdown to History\reports\ (git-ignored) and returns the plan hash.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan,
        [string]$HistoryRoot = (Join-Path (Get-Location) 'History')
    )
    $hash = Get-ApplyPlanHash -Plan $Plan
    $dir = Join-Path $HistoryRoot 'reports'
    $null = New-Item -ItemType Directory -Path $dir -Force
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $jsonPath = Join-Path $dir "apply-plan-$stamp.json"
    $mdPath = Join-Path $dir "apply-plan-$stamp.md"
    [ordered]@{ PlanHash = $hash; Plan = $Plan } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $jsonPath -Encoding utf8
    ConvertTo-ApplyPlanMarkdown -Plan $Plan -PlanHash $hash | Set-Content -LiteralPath $mdPath -Encoding utf8 -NoNewline
    [pscustomobject]@{ Json = $jsonPath; Markdown = $mdPath; PlanHash = $hash }
}
