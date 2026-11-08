#requires -Version 7.0
<#
.SYNOPSIS
    Read-only export of the Prod desired state into your private configuration repository, one Git commit per run
    (issue #27 part 1, ADR 0018). Changes nothing in any tenant; Dev is not read.
.DESCRIPTION
    Needs in config.psd1: ConfigRepository (path of your private configuration repository, a Git work tree; ADR 0004).
    Needs Git. Reads a UTCM snapshot of Prod (the same resource types as the apply) and writes one file per resource to
    <ConfigRepository>\desired\<type>\<name>.json: no IDs, no secrets, no tenant ID, groups and filters by name.
    Commits the folder (nothing is pushed), writes History\reports\desired-export-*.json (which files changed, which
    resources were skipped and why) and one audit line (mode 'export').
    Token: app-only Graph token of Prod (read permissions, see validation/README.md), as SecureString. The web interface
    gets it with the certificate (ADR 0013).
    -SnapshotPath uses a saved Prod snapshot.json instead (offline). -DryRun prints what would be done.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config.psd1'),
    [securestring]$ProdToken,
    [string]$SnapshotPath,
    [string]$HistoryRoot = (Join-Path $PSScriptRoot '..\History'),
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\M365Cloning\M365Cloning.psd1') -Force

$config = Import-M365CloningConfig -Path $ConfigPath
if ($DryRun) {
    $resources = if ($config.ContainsKey('Resources') -and $config.Resources) { @($config.Resources) } else { @(Get-M365CloningDefaultResources -Config $config) }
    Write-Host 'Dry run: nothing is read or written.'
    Write-Host "Configuration repository: $($config.ConfigRepository) (folder desired, one commit, no push)"
    Write-Host "Prod: one UTCM snapshot (read only) of $($resources.Count) resource types; Dev is not read."
    return
}
if (-not $ProdToken -and -not $SnapshotPath) { throw 'Pass -ProdToken (or -SnapshotPath for a saved Prod snapshot).' }
$result = Invoke-DesiredStateExport -Config $config -HistoryRoot $HistoryRoot -ProdToken $ProdToken -SnapshotPath $SnapshotPath
$r = $result.Report
Write-Host ("Files: {0}  added {1}, changed {2}, removed {3}, skipped {4}" -f $r.Files, $r.Added, $r.Changed, $r.Removed, @($r.Skipped).Count)
Write-Host "Report: $($result.Path)"
