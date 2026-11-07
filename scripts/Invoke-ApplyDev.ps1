#requires -Version 7.0
<#
.SYNOPSIS
    Apply Prod -> Dev with a preview and a confirmation (ADR 0001). Writes to the Dev tenant only.
.DESCRIPTION
    Default (-Plan): reads the Prod and Dev snapshots, builds the plan, writes History\reports\apply-plan-*.json/.md
    and prints the plan hash. Nothing is changed in any tenant.
    -Apply -ConfirmPlanHash <hash>: builds the plan again from the snapshots and applies it with Microsoft365DSC
    (own Windows PowerShell 5.1 process) only if its hash equals the one you looked at. It also needs
    Dev.ApplyAllowed = $true in the config. A changed tenant since the preview gives another hash and is refused.
    Snapshots: offline with -SourceSnapshotPath (Prod) and -TargetSnapshotPath (Dev), or online with -ProdToken
    and -DevToken (UTCM snapshot, read only, as in Get-DriftReport.ps1).
    Never run by an automatic job: the hash must come from a person who looked at the plan.
    Licences (issue #32): the plan reads the Dev licences (GET /subscribedSkus, read only; online with -DevToken,
    offline from -LicencePath) and blocks entries whose licence is missing. An offline preview without -LicencePath
    blocks every entry that needs a licence ('license: not verified').
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config.psd1'),
    [securestring]$ProdToken,
    [securestring]$DevToken,
    [string]$SourceSnapshotPath,
    [string]$TargetSnapshotPath,
    [string]$LicencePath,
    [string]$HistoryRoot = (Join-Path $PSScriptRoot '..\History'),
    [switch]$Plan,
    [switch]$Apply,
    [string]$ConfirmPlanHash
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\M365Cloning\M365Cloning.psd1') -Force

if ($Plan -and $Apply) { throw 'Use either -Plan (default) or -Apply, not both.' }
if ($Apply -and [string]::IsNullOrWhiteSpace($ConfirmPlanHash)) {
    throw 'Run without -Apply first, read the plan in History\reports, then pass its hash with -ConfirmPlanHash.'
}

$offline = $SourceSnapshotPath -or $TargetSnapshotPath
if ($offline -and -not ($SourceSnapshotPath -and $TargetSnapshotPath)) {
    throw 'Offline: pass both -SourceSnapshotPath and -TargetSnapshotPath.'
}

$config = Import-M365CloningConfig -Path $ConfigPath
$resources = if ($config.ContainsKey('Resources') -and $config.Resources) { $config.Resources } else { Get-M365CloningDefaultResources }

if ($offline) {
    $prodFile = $SourceSnapshotPath; $devFile = $TargetSnapshotPath
}
else {
    if (-not $ProdToken -or -not $DevToken) { throw 'Pass -ProdToken and -DevToken (or use the offline parameters).' }
    $prodFile = Get-UtcmTenantSnapshot -Token $ProdToken -Side Prod -TenantId $config.Prod.TenantId -Resources $resources -HistoryRoot $HistoryRoot
    $devFile = Get-UtcmTenantSnapshot -Token $DevToken -Side Dev -TenantId $config.Dev.TenantId -Resources $resources -HistoryRoot $HistoryRoot
}

$applyPlan = New-ApplyPlan -Source (Read-UtcmSnapshotFile -Path $prodFile) -Target (Read-UtcmSnapshotFile -Path $devFile) -Config $config
# Licence check (issue #32): entries whose licence Dev lacks are blocked before anything is applied.
$applyPlan = Add-PlanLicenceCheck -Plan $applyPlan -Licences (Get-DevPlanLicences -DevToken $DevToken -LicencePath $LicencePath)
$hash = Get-ApplyPlanHash -Plan $applyPlan

if (-not $Apply) {
    $files = Export-ApplyPlan -Plan $applyPlan -HistoryRoot $HistoryRoot
    Write-ApplyAudit -HistoryRoot $HistoryRoot -Mode plan -PlanHash $hash -TargetTenantId $config.Dev.TenantId -Counts $applyPlan.Summary
    $applyPlan.Summary | Format-Table | Out-String | Write-Host
    Write-Host "Plan:      $($files.Markdown)"
    Write-Host "Plan hash: $hash"
    Write-Host 'Nothing was changed. To apply exactly this plan: scripts/Invoke-ApplyDev.ps1 -Apply -ConfirmPlanHash <hash>'
    return
}

$result = Invoke-ApplyPlan -Plan $applyPlan -Config $config -ConfirmPlanHash $ConfirmPlanHash -HistoryRoot $HistoryRoot
Write-Host "Applied or unchanged: $($result.Applied)  Failed: $($result.Failed)"
if ($result.Failed -gt 0) { $result.Results | Where-Object { $_.Status -eq 'failed' } | Format-Table Name, ResourceType, Message | Out-String | Write-Host; exit 1 }
