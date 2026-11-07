# Counters of an audit line (issue #51): one fixed set for every mode.
$script:AuditCounterNames = @('Planned', 'Blocked', 'Skipped', 'Excluded', 'Exists', 'Invite', 'Protected', 'Applied', 'Failed', 'Deleted', 'Retired', 'Wiped', 'NotRun', 'Red', 'Yellow', 'Info')

function Write-ApplyAudit {
    <#
    .SYNOPSIS
        Appends one line to History\audit.jsonl (append only). Only fixed fields are written, never properties,
        tokens, client IDs or certificate data; the tenant is shortened to its first 8 characters.
        Started from the web interface, the line also carries Actor (environment variable M365CLONING_ACTOR).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HistoryRoot,
        [Parameter(Mandatory)][ValidateSet('report', 'plan', 'apply', 'refused', 'reset', 'fitcheck')][string]$Mode,
        [string]$PlanHash = '',
        [string]$TargetTenantId = '',
        [System.Collections.IDictionary]$Counts = @{},
        [string]$Reason = ''
    )
    $null = New-Item -ItemType Directory -Path $HistoryRoot -Force
    $short = Get-TenantIdShort -TenantId $TargetTenantId
    # The same counters in every line, whatever the mode (issue #51): unknown keys and non-numbers are dropped,
    # missing counters are 0.
    $safeCounts = [ordered]@{}
    foreach ($key in $script:AuditCounterNames) {
        $v = if ($Counts.Contains($key)) { $Counts[$key] } else { 0 }
        $safeCounts[$key] = if ($v -is [int] -or $v -is [long]) { [int]$v } else { 0 }
    }
    $entry = [ordered]@{
        Timestamp    = (Get-Date).ToUniversalTime().ToString('o')
        User         = "$([Environment]::UserDomainName)\$([Environment]::UserName)"
        Mode         = $Mode
        PlanHash     = $PlanHash
        TargetTenant = $short
        Counts       = $safeCounts
        Reason       = if ($Reason.Length -gt 200) { $Reason.Substring(0, 200) } else { $Reason }
    }
    # Actor (issue #14, ADR 0010): the person signed in to the web interface who started the job. The job runner
    # (Invoke-WebJob) sets M365CLONING_ACTOR for the run; a script started by hand has none. Control characters are
    # removed and the name is cut to 256 characters, as the schema allows.
    $actor = ([string]$env:M365CLONING_ACTOR) -replace '[\p{C}]', ''
    $actor = $actor.Trim()
    if ($actor) { $entry['Actor'] = if ($actor.Length -gt 256) { $actor.Substring(0, 256) } else { $actor } }
    Add-Content -LiteralPath (Join-Path $HistoryRoot 'audit.jsonl') -Value (ConvertTo-Json -InputObject $entry -Compress -Depth 5) -Encoding utf8
}
