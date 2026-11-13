#requires -Version 7.0
<#
.SYNOPSIS
    Read-only drift report Prod -> Dev (ADR 0001). Changes nothing in any tenant.
.DESCRIPTION
    Online: takes a UTCM snapshot of the Prod and the Dev tenant (the only POST is createSnapshot, which
    only reads), keeps both under History\Tenants\<Prod|Dev>\<timestamp>\, compares them and
    writes drift-*.json / drift-*.md to History\reports\ plus one audit line (History\audit.jsonl, mode 'report',
    issue #13): counts of added, removed and changed resources only, no names or properties.
    Offline: -SourceSnapshotPath / -TargetSnapshotPath compare two saved snapshot.json files, no network.
    -DryRun prints what would be called and does nothing else.
    Tokens: app-only Graph tokens (scope https://graph.microsoft.com/.default) from the app registration of
    each tenant (certificate). Get them with your own means and pass them as SecureString.
    -Source Repository (issue #27 part 3, ADR 0020): the sync report. The desired side is desired/ of the configuration
    repository (ConfigRepository, Read-DesiredStateSnapshot) instead of Prod; Prod is not read and -ProdToken is not
    needed. desired/ must have no uncommitted change. Dev is read live (-DevToken) or offline (-TargetSnapshotPath). The
    report names the source and the commit. Default: Live (ADR 0019).
    -ReportExitCode (for a schedule, docs/automation.md): exit code 0 no differences, 1 differences, 3 not verified
    (a tenant, the repository or the config could not be read). Without it the script ends with 0 or stops with an error.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config.psd1'),
    [securestring]$ProdToken,
    [securestring]$DevToken,
    [string]$SourceSnapshotPath,
    [string]$TargetSnapshotPath,
    [string]$HistoryRoot = (Join-Path $PSScriptRoot '..\History'),
    [ValidateSet('Live', 'Repository')][string]$Source = 'Live',
    [switch]$ReportExitCode,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\M365Cloning\M365Cloning.psd1') -Force

try {
if ($Source -eq 'Repository' -and $SourceSnapshotPath) {
    throw '-Source Repository reads the desired state from the configuration repository; -SourceSnapshotPath is for -Source Live.'
}
$offline = $TargetSnapshotPath -and ($Source -eq 'Repository' -or $SourceSnapshotPath)
if ($Source -eq 'Live' -and ($SourceSnapshotPath -or $TargetSnapshotPath) -and -not ($SourceSnapshotPath -and $TargetSnapshotPath)) {
    throw 'Offline: pass both -SourceSnapshotPath and -TargetSnapshotPath.'
}

$config = Import-M365CloningConfig -Path $ConfigPath
$entry = $config
$resources = if ($entry.ContainsKey('Resources') -and $entry.Resources) { $entry.Resources } else { Get-M365CloningDefaultResources -Config $entry }

if ($DryRun) {
    Write-Host 'Dry run: no request is sent.'
    if ($Source -eq 'Repository') {
        Write-Host "Desired state: desired/ of the configuration repository (must be committed). Prod is not read. Dev tenant: $($entry.Dev.TenantId)"
        Write-Host 'Dev: POST .../admin/configurationManagement/configurationSnapshots/createSnapshot (read only job), then GET job and snapshot.'
    }
    else {
        Write-Host "Prod tenant: $($entry.Prod.TenantId)  Dev tenant: $($entry.Dev.TenantId)"
        Write-Host 'Per tenant: POST .../admin/configurationManagement/configurationSnapshots/createSnapshot (read only job), then GET job and snapshot.'
    }
    Write-Host ('Resources: ' + ($resources -join ', '))
    if ($ReportExitCode) { exit 0 }
    return
}

if ($Source -eq 'Repository') {
    # Sync report (ADR 0020): desired/ against Dev. Same reading and the same Dev copy as the apply from the repository
    # (ADR 0019), so the report shows exactly what a plan from the repository would act on.
    $desired = Read-DesiredStateSnapshot -Config $entry
    Write-Host "Desired state: configuration repository, commit $($desired.Commit.Substring(0, 12)) ($($desired.Files) files). Prod is not read."
    if ($offline) { $devFile = $TargetSnapshotPath }
    else {
        $DevToken = Resolve-M365CloningToken -Config $config -Side Dev -Token $DevToken
        $devFile = Get-UtcmTenantSnapshot -Token $DevToken -Side Dev -TenantId $entry.Dev.TenantId -Resources $resources -HistoryRoot $HistoryRoot
    }
    $target = ConvertTo-DesiredComparableSnapshot -Snapshot (Read-UtcmSnapshotFile -Path $devFile)
    $report = Compare-TenantSnapshot -Source $desired.Snapshot -Target $target -SourceInfo @{ Kind = 'Repository'; Commit = $desired.Commit }
    $label = "drift desired/ $($desired.Commit.Substring(0, 12)) -> Dev"
}
else {
    if ($offline) {
        $prodFile = $SourceSnapshotPath; $devFile = $TargetSnapshotPath
    }
    else {
        $ProdToken = Resolve-M365CloningToken -Config $config -Side Prod -Token $ProdToken
        $DevToken = Resolve-M365CloningToken -Config $config -Side Dev -Token $DevToken
        $prodFile = Get-UtcmTenantSnapshot -Token $ProdToken -Side Prod -TenantId $entry.Prod.TenantId -Resources $resources -HistoryRoot $HistoryRoot
        $devFile = Get-UtcmTenantSnapshot -Token $DevToken -Side Dev -TenantId $entry.Dev.TenantId -Resources $resources -HistoryRoot $HistoryRoot
    }
    $report = Compare-TenantSnapshot -Source (Read-UtcmSnapshotFile -Path $prodFile) -Target (Read-UtcmSnapshotFile -Path $devFile)
    $label = 'drift Prod -> Dev'
}

$files = Export-DriftReport -Report $report -HistoryRoot $HistoryRoot
$sum = $report.Summary
Write-ApplyAudit -HistoryRoot $HistoryRoot -Mode report -TargetTenantId ([string]$entry.Dev.TenantId) -Reason ("{0} ({1}): {2} added, {3} removed, {4} changed" -f $label, $(if ($offline) { 'offline' } else { 'online' }), $sum.Added, $sum.Removed, $sum.Changed)
$report.Summary | Format-Table | Out-String | Write-Host
Write-Host "Report: $($files.Markdown)"
if ($report.IsIdentical) { Write-Host 'No differences.' }
}
catch {
    if (-not $ReportExitCode) { throw }
    # Not verified: say why without stopping the schedule with an unhandled error (exit 3, like the suitability check).
    Write-Host "Not verified: $(($_.Exception.Message -split "`r?`n")[0])"
    exit 3
}
if ($ReportExitCode) { exit $(if ($report.IsIdentical) { 0 } else { 1 }) }
