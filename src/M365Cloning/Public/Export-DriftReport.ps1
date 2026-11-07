function Export-DriftReport {
    <#
    .SYNOPSIS
        Writes the report as JSON and Markdown to History\reports\ (git-ignored).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Report,
        [string]$HistoryRoot = (Join-Path (Get-Location) 'History')
    )
    $dir = Join-Path $HistoryRoot 'reports'
    $null = New-Item -ItemType Directory -Path $dir -Force
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $jsonPath = Join-Path $dir "drift-$stamp.json"
    $mdPath = Join-Path $dir "drift-$stamp.md"
    $Report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $jsonPath -Encoding utf8
    ConvertTo-DriftReportMarkdown -Report $Report | Set-Content -LiteralPath $mdPath -Encoding utf8 -NoNewline
    [pscustomobject]@{ Json = $jsonPath; Markdown = $mdPath }
}
