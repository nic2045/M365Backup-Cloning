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
    # Header of the file (issue #51), then the report as Compare-TenantSnapshot returns it.
    $doc = [ordered]@{
        SchemaVersion = $script:M365CloningSchemaVersion
        Kind          = 'drift'
        CreatedUtc    = (Get-Date).ToUniversalTime().ToString('o')
    }
    $fields = if ($Report -is [System.Collections.IDictionary]) { @($Report.Keys) } else { @($Report.PSObject.Properties.Name) }
    foreach ($k in $fields) { if (-not $doc.Contains([string]$k)) { $doc[[string]$k] = if ($Report -is [System.Collections.IDictionary]) { $Report[$k] } else { $Report.$k } } }
    $doc | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $jsonPath -Encoding utf8
    ConvertTo-DriftReportMarkdown -Report $Report | Set-Content -LiteralPath $mdPath -Encoding utf8 -NoNewline
    [pscustomobject]@{ Json = $jsonPath; Markdown = $mdPath }
}
