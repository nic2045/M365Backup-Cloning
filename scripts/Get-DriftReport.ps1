#requires -Version 7.0
<#
.SYNOPSIS
    Read-only drift report Prod -> Dev (ADR 0001). Changes nothing in any tenant.
.DESCRIPTION
    Online: takes a UTCM snapshot of the Prod and the Dev tenant (the only POST is createSnapshot, which
    only reads), keeps both under History\Tenants\<Prod|Dev>\<timestamp>\, compares them and
    writes drift-*.json / drift-*.md to History\reports\.
    Offline: -SourceSnapshotPath / -TargetSnapshotPath compare two saved snapshot.json files, no network.
    -DryRun prints what would be called and does nothing else.
    Tokens: app-only Graph tokens (scope https://graph.microsoft.com/.default) from the app registration of
    each tenant (certificate). Get them with your own means and pass them as SecureString.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config.psd1'),
    [securestring]$ProdToken,
    [securestring]$DevToken,
    [string]$SourceSnapshotPath,
    [string]$TargetSnapshotPath,
    [string]$HistoryRoot = (Join-Path $PSScriptRoot '..\History'),
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\M365Cloning\M365Cloning.psd1') -Force

$offline = $SourceSnapshotPath -or $TargetSnapshotPath
if ($offline -and -not ($SourceSnapshotPath -and $TargetSnapshotPath)) {
    throw 'Offline: pass both -SourceSnapshotPath and -TargetSnapshotPath.'
}

$config = Import-M365CloningConfig -Path $ConfigPath
$entry = $config
$resources = if ($entry.ContainsKey('Resources') -and $entry.Resources) { $entry.Resources } else { Get-M365CloningDefaultResources -Config $entry }

if ($DryRun) {
    Write-Host 'Dry run: no request is sent.'
    Write-Host "Prod tenant: $($entry.Prod.TenantId)  Dev tenant: $($entry.Dev.TenantId)"
    Write-Host 'Per tenant: POST .../admin/configurationManagement/configurationSnapshots/createSnapshot (read only job), then GET job and snapshot.'
    Write-Host ('Resources: ' + ($resources -join ', '))
    return
}

if ($offline) {
    $prodFile = $SourceSnapshotPath; $devFile = $TargetSnapshotPath
}
else {
    if (-not $ProdToken -or -not $DevToken) { throw 'Pass -ProdToken and -DevToken (or use the offline parameters).' }
    $prodFile = Get-UtcmTenantSnapshot -Token $ProdToken -Side Prod -TenantId $entry.Prod.TenantId -Resources $resources -HistoryRoot $HistoryRoot
    $devFile = Get-UtcmTenantSnapshot -Token $DevToken -Side Dev -TenantId $entry.Dev.TenantId -Resources $resources -HistoryRoot $HistoryRoot
}

$report = Compare-TenantSnapshot -Source (Read-UtcmSnapshotFile -Path $prodFile) -Target (Read-UtcmSnapshotFile -Path $devFile)
$files = Export-DriftReport -Report $report -HistoryRoot $HistoryRoot
$report.Summary | Format-Table | Out-String | Write-Host
Write-Host "Report: $($files.Markdown)"
if ($report.IsIdentical) { Write-Host 'No differences.' }
