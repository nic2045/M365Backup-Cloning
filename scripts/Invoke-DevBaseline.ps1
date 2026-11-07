#requires -Version 7.0
<#
.SYNOPSIS
    Brings the Dev tenant to its documented base state (issue #8, section 'Baseline' of the config). Dev only.
.DESCRIPTION
    Default (-Plan): reads the Dev state (UTCM snapshot, read only: groups and the cross-tenant access partners),
    builds the difference to the base state, writes History\reports\dev-baseline-plan-*.json/.md and prints the plan
    hash. Nothing is changed. "Base state reached" means: nothing planned, nothing blocked.
    -Apply -ConfirmPlanHash <hash>: reads the Dev state again, builds the plan again and applies it with
    Microsoft365DSC (own Windows PowerShell 5.1 process, same gate as scripts/Invoke-ApplyDev.ps1) only if its hash
    equals the one you looked at; needs Dev.ApplyAllowed = $true. Creates the missing static, empty groups and sets
    the cross-tenant access for the Prod tenant. Never deletes; never adds or removes members.
    Offline plan: -TargetSnapshotPath <snapshot.json> of Dev, for a preview only.
    Order with the other scripts: this one first, then scripts/Invoke-DevUsers.ps1 (it needs the persona groups),
    then scripts/Invoke-ApplyDev.ps1.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config.psd1'),
    [securestring]$DevToken,
    [string]$TargetSnapshotPath,
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
if ($Apply -and $TargetSnapshotPath) { throw '-Apply reads the Dev state online (-DevToken); -TargetSnapshotPath is for a preview only.' }

$config = Import-M365CloningConfig -Path $ConfigPath

if ($TargetSnapshotPath) {
    $devFile = $TargetSnapshotPath
}
else {
    if (-not $DevToken) { throw 'Pass -DevToken (Dev app registration) or -TargetSnapshotPath for an offline preview.' }
    $devFile = Get-UtcmTenantSnapshot -Token $DevToken -Side Dev -TenantId $config.Dev.TenantId -Resources (Get-M365CloningBaselineResources) -HistoryRoot $HistoryRoot
}

$basePlan = New-DevBaselinePlan -Config $config -Target (Read-UtcmSnapshotFile -Path $devFile)
$hash = Get-ApplyPlanHash -Plan $basePlan

if (-not $Apply) {
    $files = Export-ApplyPlan -Plan $basePlan -HistoryRoot $HistoryRoot -FilePrefix 'dev-baseline-plan'
    $counts = @{ Planned = $basePlan.Summary.Planned; Blocked = $basePlan.Summary.Blocked; Skipped = $basePlan.Summary.Skipped }
    Write-ApplyAudit -HistoryRoot $HistoryRoot -Mode plan -PlanHash $hash -TargetTenantId $config.Dev.TenantId -Counts $counts -Reason 'dev baseline'
    $basePlan.Summary | Format-Table | Out-String | Write-Host
    Write-Host "Plan:      $($files.Markdown)"
    Write-Host "Plan hash: $hash"
    if ($basePlan.Summary.InBaseline) {
        Write-Host 'Base state reached: no difference.'
        return
    }
    Write-Host 'Nothing was changed. To apply exactly this plan: scripts/Invoke-DevBaseline.ps1 -Apply -ConfirmPlanHash <hash>'
    return
}

$result = Invoke-ApplyPlan -Plan $basePlan -Config $config -ConfirmPlanHash $ConfirmPlanHash -HistoryRoot $HistoryRoot
Write-Host "Applied: $($result.Applied)  Failed: $($result.Failed)"
if ($basePlan.Summary.Blocked -gt 0) { Write-Host "Blocked (not changed, see the plan): $($basePlan.Summary.Blocked)" }
if ($result.Failed -gt 0) { $result.Results | Where-Object { $_.Status -eq 'failed' } | Format-Table Name, ResourceType, Message | Out-String | Write-Host; exit 1 }
Write-Host 'Run the plan again (without -Apply) to check that the base state is reached.'
