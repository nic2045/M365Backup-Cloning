#requires -Version 7.0
<#
.SYNOPSIS
    Read-only backup of the Intune configuration of Prod and Dev with IntuneCD into your private configuration
    repository, one Git commit per run (issue #68, ADR 0014). Changes nothing in any tenant.
.DESCRIPTION
    Needs in config.psd1: ConfigRepository (path of your private configuration repository, a Git work tree; ADR 0004)
    and optionally IntuneBackup (Python command, extra IntuneCD types to leave out). Needs Python 3.12 with
    tools/intunecd/requirements.txt installed and Git.
    Writes <ConfigRepository>\intune\prod and \dev, commits them (nothing is pushed), writes
    History\reports\intune-backup-*.json (which files changed) and one audit line (mode 'backup').
    Tokens: app-only Graph tokens of each tenant (read permissions for Intune, see validation/README.md); pass them
    as SecureString. The web interface gets them with the certificate (ADR 0013).
    -DryRun prints what would be done and does nothing else.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config.psd1'),
    [securestring]$ProdToken,
    [securestring]$DevToken,
    [string]$HistoryRoot = (Join-Path $PSScriptRoot '..\History'),
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\M365Cloning\M365Cloning.psd1') -Force

$config = Import-M365CloningConfig -Path $ConfigPath
if ($DryRun) {
    $settings = Get-IntuneBackupSettings -Config $config
    Write-Host 'Dry run: nothing is read or written.'
    Write-Host "Configuration repository: $($settings.Repository) (folders intune/prod and intune/dev, one commit, no push)"
    Write-Host "Python: $($settings.Python); IntuneCD backup only (read only), extra types left out: $(@($settings.Exclude) -join ', '); script types: $(if ($settings.IncludeScripts) { 'backed up (IncludeScripts)' } else { 'left out' })"
    return
}
if (-not $ProdToken -or -not $DevToken) { throw 'Pass -ProdToken and -DevToken.' }
$result = Invoke-IntuneBackup -Config $config -HistoryRoot $HistoryRoot -ProdToken $ProdToken -DevToken $DevToken
Write-Host "Report: $($result.Path)"
