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
    -Area Intune (issue #66): the plan covers only the Intune entries and the empty group copies their assignments need;
    the rest is skipped. Pass the same -Area with -Apply as with the preview, or the plan hash differs.
    -Source Repository (issue #27 part 2, ADR 0019): the desired state is read from desired/ in the configuration
    repository (ConfigRepository) instead of Prod; Prod is not read and -ProdToken is not needed. desired/ must have no
    uncommitted change. The plan names the commit it was built from and the commit is part of the plan hash, so -Apply
    refuses when the desired state changed since the preview. Pass the same -Source with -Apply as with the preview.
    Default: Live (a Prod snapshot, as before).
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
    [string]$ConfirmPlanHash,
    [ValidateSet('All', 'Intune')][string]$Area = 'All',
    [ValidateSet('Live', 'Repository')][string]$Source = 'Live'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\M365Cloning\M365Cloning.psd1') -Force

if ($Plan -and $Apply) { throw 'Use either -Plan (default) or -Apply, not both.' }
if ($Apply -and [string]::IsNullOrWhiteSpace($ConfirmPlanHash)) {
    throw 'Run without -Apply first, read the plan in History\reports, then pass its hash with -ConfirmPlanHash.'
}

$config = Import-M365CloningConfig -Path $ConfigPath
$resources = if ($config.ContainsKey('Resources') -and $config.Resources) { $config.Resources } else { Get-M365CloningDefaultResources -Config $config }

if ($Source -eq 'Repository') {
    # Desired state from the configuration repository (ADR 0019); Prod is not read. Dev is read live (or offline).
    if ($SourceSnapshotPath) { throw '-Source Repository reads the desired state from the configuration repository; -SourceSnapshotPath is for -Source Live.' }
    $desired = Read-DesiredStateSnapshot -Config $config
    Write-Host "Desired state: configuration repository, commit $($desired.Commit.Substring(0, 12)) ($($desired.Files) files). Prod is not read."
    if ($TargetSnapshotPath) { $devFile = $TargetSnapshotPath }
    else {
        if (-not $DevToken) { throw 'Pass -DevToken (or -TargetSnapshotPath for a saved Dev snapshot).' }
        $devFile = Get-UtcmTenantSnapshot -Token $DevToken -Side Dev -TenantId $config.Dev.TenantId -Resources $resources -HistoryRoot $HistoryRoot
    }
    $target = ConvertTo-DesiredComparableSnapshot -Snapshot (Read-UtcmSnapshotFile -Path $devFile)
    $applyPlan = New-ApplyPlan -Source $desired.Snapshot -Target $target -Config $config -Area $Area -SourceInfo @{ Kind = 'Repository'; Commit = $desired.Commit }
}
else {
    $offline = $SourceSnapshotPath -or $TargetSnapshotPath
    if ($offline -and -not ($SourceSnapshotPath -and $TargetSnapshotPath)) {
        throw 'Offline: pass both -SourceSnapshotPath and -TargetSnapshotPath.'
    }
    if ($offline) {
        $prodFile = $SourceSnapshotPath; $devFile = $TargetSnapshotPath
    }
    else {
        if (-not $ProdToken -or -not $DevToken) { throw 'Pass -ProdToken and -DevToken (or use the offline parameters).' }
        $prodFile = Get-UtcmTenantSnapshot -Token $ProdToken -Side Prod -TenantId $config.Prod.TenantId -Resources $resources -HistoryRoot $HistoryRoot
        $devFile = Get-UtcmTenantSnapshot -Token $DevToken -Side Dev -TenantId $config.Dev.TenantId -Resources $resources -HistoryRoot $HistoryRoot
    }
    $applyPlan = New-ApplyPlan -Source (Read-UtcmSnapshotFile -Path $prodFile) -Target (Read-UtcmSnapshotFile -Path $devFile) -Config $config -Area $Area
}
# Licence check (issue #32): entries whose licence Dev lacks are blocked before anything is applied.
$applyPlan = Add-PlanLicenceCheck -Plan $applyPlan -Licences (Get-DevPlanLicences -DevToken $DevToken -LicencePath $LicencePath)
$hash = Get-ApplyPlanHash -Plan $applyPlan

if (-not $Apply) {
    $files = Export-ApplyPlan -Plan $applyPlan -HistoryRoot $HistoryRoot
    Write-ApplyAudit -HistoryRoot $HistoryRoot -Mode plan -PlanHash $hash -TargetTenantId $config.Dev.TenantId -Counts $applyPlan.Summary
    $applyPlan.Summary | Format-Table | Out-String | Write-Host
    Write-Host "Plan:      $($files.Markdown)"
    Write-Host "Plan hash: $hash"
    Write-Host "Nothing was changed. To apply exactly this plan: scripts/Invoke-ApplyDev.ps1 -Apply -ConfirmPlanHash <hash>$(if ($Area -ne 'All') { " -Area $Area" })$(if ($Source -ne 'Live') { " -Source $Source" })"
    return
}

$result = Invoke-ApplyPlan -Plan $applyPlan -Config $config -ConfirmPlanHash $ConfirmPlanHash -HistoryRoot $HistoryRoot
Write-Host "Applied or unchanged: $($result.Applied)  Failed: $($result.Failed)"
if ($result.Failed -gt 0) { $result.Results | Where-Object { $_.Status -eq 'failed' } | Format-Table Name, ResourceType, Message | Out-String | Write-Host; exit 1 }
