function Export-TenantFitReport {
    <#
    .SYNOPSIS
        Writes a suitability check (issue #39) as JSON and Markdown to History\reports\ (git-ignored):
        tenantfit-<UTC timestamp>.json / .md. Returns both paths.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Assessment,
        [string]$HistoryRoot = (Join-Path (Get-Location) 'History')
    )
    $dir = Join-Path $HistoryRoot 'reports'
    $null = New-Item -ItemType Directory -Path $dir -Force
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $jsonPath = Join-Path $dir "tenantfit-$stamp.json"
    $mdPath = Join-Path $dir "tenantfit-$stamp.md"
    $Assessment | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $jsonPath -Encoding utf8
    ConvertTo-TenantFitMarkdown -Assessment $Assessment | Set-Content -LiteralPath $mdPath -Encoding utf8 -NoNewline
    [pscustomobject]@{ Json = $jsonPath; Markdown = $mdPath }
}
