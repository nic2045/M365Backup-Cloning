function Write-ApplyAudit {
    <#
    .SYNOPSIS
        Appends one line to History\audit.jsonl (append only). Only fixed fields are written, never properties,
        tokens, client IDs or certificate data; the tenant is shortened to its first 8 characters.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HistoryRoot,
        [Parameter(Mandatory)][ValidateSet('plan', 'apply', 'refused', 'reset', 'fitcheck')][string]$Mode,
        [string]$PlanHash = '',
        [string]$TargetTenantId = '',
        [System.Collections.IDictionary]$Counts = @{},
        [string]$Reason = ''
    )
    $null = New-Item -ItemType Directory -Path $HistoryRoot -Force
    $short = if ($TargetTenantId.Length -gt 8) { $TargetTenantId.Substring(0, 8) + '...' } else { $TargetTenantId }
    $safeCounts = [ordered]@{}
    foreach ($key in ($Counts.Keys | Sort-Object)) { if ($Counts[$key] -is [int] -or $Counts[$key] -is [long]) { $safeCounts[[string]$key] = $Counts[$key] } }
    $entry = [ordered]@{
        Timestamp    = (Get-Date).ToUniversalTime().ToString('o')
        User         = "$([Environment]::UserDomainName)\$([Environment]::UserName)"
        Mode         = $Mode
        PlanHash     = $PlanHash
        TargetTenant = $short
        Counts       = $safeCounts
        Reason       = if ($Reason.Length -gt 200) { $Reason.Substring(0, 200) } else { $Reason }
    }
    Add-Content -LiteralPath (Join-Path $HistoryRoot 'audit.jsonl') -Value (ConvertTo-Json -InputObject $entry -Compress -Depth 5) -Encoding utf8
}
