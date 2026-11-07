#requires -Version 7.0
<#
.SYNOPSIS
    Factory reset of the Dev tenant (issue #7, ADR 0005). Dev tenant only, two confirmations.
.DESCRIPTION
    Two modes, same protection rules and confirmations:
      -Mode Align (default, careful): deletes only objects of the reset scope that exist in Dev but not in Prod (drift
                  report Prod -> Dev); the apply then aligns what differs.
      -Mode Full: deletes everything in the reset scope except the protection list and the base state, to rebuild Dev
                  in a controlled way. Use it on purpose only.
    Default (-Plan): reads Dev and the Global Administrators of Prod (GET only; Align also makes the UTCM snapshots of
    both), builds the plan with the protection list, writes History\reports\dev-reset-plan-*.json/.md and prints the
    plan hash. Nothing is changed.
    -Apply -ConfirmPlanHash <hash> -ConfirmTenant <Dev tenant ID>: reads again, builds the plan again and deletes only
    if its hash equals the one you looked at (first confirmation) and the tenant ID you typed is the Dev tenant of the
    config (second confirmation); needs Dev.AllowReset = $true. Devices, guests, licences, domains, app registrations
    and the cross-tenant settings are never deleted. Users, groups and Conditional Access policies stay in the deleted
    items for 30 days.
    Devices (issue #46): kept by default. -DeviceAction Keep|Remove|Retire|Wipe sets the action for all devices;
    -DeviceActionFile <.psd1 or .json> maps devices (Intune device ID, serial number or name) to an action and wins for
    those devices; a name shared by several devices blocks Remove, Retire and Wipe (issue #49), use the serial number. Wipe needs
    Dev.AllowDeviceWipe = $true. Devices with a name from Dev.ProtectedDevicePrefixes and devices of protected users
    are never touched. Pass the same device options with -Apply as with the preview, or the plan hash differs.
    -RebuildAfter: after a reset without failures, runs base state -> apply -> Dev users, each with its own plan and
    its own confirmation (type the plan hash), and ends with the drift report.
    Offline preview: -InventoryPath <json> (Get-DevResetInventory saved as JSON); Align also needs
    -SourceSnapshotPath (Prod) and -TargetSnapshotPath (Dev).
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config.psd1'),
    [ValidateSet('Align', 'Full')][string]$Mode = 'Align',
    [securestring]$ProdToken,
    [securestring]$DevToken,
    [string]$InventoryPath,
    [string]$SourceSnapshotPath,
    [string]$TargetSnapshotPath,
    [string]$HistoryRoot = (Join-Path $PSScriptRoot '..\History'),
    [switch]$Plan,
    [switch]$Apply,
    [string]$ConfirmPlanHash,
    [string]$ConfirmTenant,
    [switch]$RebuildAfter,
    [ValidateSet('Keep', 'Remove', 'Retire', 'Wipe')][string]$DeviceAction = 'Keep',
    [string]$DeviceActionFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\M365Cloning\M365Cloning.psd1') -Force

if ($Plan -and $Apply) { throw 'Use either -Plan (default) or -Apply, not both.' }
if ($Apply -and ([string]::IsNullOrWhiteSpace($ConfirmPlanHash) -or [string]::IsNullOrWhiteSpace($ConfirmTenant))) {
    throw 'Run without -Apply first, read the plan in History\reports, then pass its hash with -ConfirmPlanHash and the Dev tenant ID with -ConfirmTenant.'
}
if ($Apply -and ($InventoryPath -or $SourceSnapshotPath -or $TargetSnapshotPath)) { throw '-Apply reads online (-ProdToken, -DevToken); the offline files are for a preview only.' }
if ($RebuildAfter -and -not $Apply) { throw '-RebuildAfter runs after a confirmed reset (-Apply) only.' }

$config = Import-M365CloningConfig -Path $ConfigPath

if ($InventoryPath) {
    $inventory = Get-Content -LiteralPath $InventoryPath -Raw | ConvertFrom-Json -AsHashtable
}
else {
    if (-not $ProdToken -or -not $DevToken) { throw 'Pass -ProdToken and -DevToken, or -InventoryPath for an offline preview.' }
    $inventory = Get-DevResetInventory -DevToken $DevToken -ProdToken $ProdToken -Config $config
}

$comparison = $null
if ($Mode -eq 'Align') {
    if ($SourceSnapshotPath -or $TargetSnapshotPath) {
        if (-not ($SourceSnapshotPath -and $TargetSnapshotPath)) { throw 'Offline Align: pass both -SourceSnapshotPath and -TargetSnapshotPath.' }
        $prodFile = $SourceSnapshotPath; $devFile = $TargetSnapshotPath
    }
    else {
        if (-not $ProdToken -or -not $DevToken) { throw 'Mode Align needs the drift report: pass -ProdToken and -DevToken, or the two snapshot files.' }
        $resources = if ($config.ContainsKey('Resources') -and $config.Resources) { $config.Resources } else { Get-M365CloningDefaultResources -Config $config }
        $prodFile = Get-UtcmTenantSnapshot -Token $ProdToken -Side Prod -TenantId $config.Prod.TenantId -Resources $resources -HistoryRoot $HistoryRoot
        $devFile = Get-UtcmTenantSnapshot -Token $DevToken -Side Dev -TenantId $config.Dev.TenantId -Resources $resources -HistoryRoot $HistoryRoot
    }
    $comparison = Compare-TenantSnapshot -Source (Read-UtcmSnapshotFile -Path $prodFile) -Target (Read-UtcmSnapshotFile -Path $devFile)
}

$deviceActions = $null
if ($DeviceActionFile) {
    $deviceActions = if ($DeviceActionFile -match '\.json$') { Get-Content -LiteralPath $DeviceActionFile -Raw | ConvertFrom-Json -AsHashtable }
    else { Import-PowerShellDataFile -LiteralPath $DeviceActionFile }
    if ($deviceActions -isnot [System.Collections.IDictionary]) { throw '-DeviceActionFile must hold a map of device name to action (Keep, Remove, Retire, Wipe).' }
}
$resetPlan = New-DevResetPlan -Config $config -Inventory $inventory -Mode $Mode -Comparison $comparison -DeviceAction $DeviceAction -DeviceActions $deviceActions
$hash = Get-ApplyPlanHash -Plan $resetPlan

if (-not $Apply) {
    $files = Export-ApplyPlan -Plan $resetPlan -HistoryRoot $HistoryRoot -FilePrefix "dev-reset-plan-$($Mode.ToLowerInvariant())"
    $counts = @{ Planned = $resetPlan.Summary.Planned; Skipped = $resetPlan.Summary.Skipped; Protected = $resetPlan.Summary.Protected }
    Write-ApplyAudit -HistoryRoot $HistoryRoot -Mode plan -PlanHash $hash -TargetTenantId $config.Dev.TenantId -Counts $counts -Reason "dev reset ($Mode)"
    $resetPlan.Summary | Format-Table | Out-String | Write-Host
    Write-Host "Plan:      $($files.Markdown)"
    Write-Host "Plan hash: $hash"
    Write-Host "Nothing was changed. To run exactly this plan: scripts/Invoke-DevReset.ps1 -Mode $Mode -Apply -ConfirmPlanHash <hash> -ConfirmTenant <Dev tenant ID> (same device options)"
    return
}

$result = Invoke-DevResetPlan -Plan $resetPlan -Config $config -ConfirmPlanHash $ConfirmPlanHash -ConfirmTenant $ConfirmTenant -Token $DevToken -HistoryRoot $HistoryRoot
Write-Host "Deleted: $($result.Deleted)  Retired: $($result.Retired)  Wiped: $($result.Wiped)  Failed: $($result.Failed)  Not run: $($result.NotRun)"
if ($result.Failed -gt 0) {
    $result.Results | Where-Object { $_.Status -eq 'failed' } | ForEach-Object { [pscustomobject]$_ } | Format-Table Step, ResourceType, Name, Message | Out-String | Write-Host
    Write-Host 'The later steps were not run. Fix the cause and make a new plan.'
    exit 1
}
if ($RebuildAfter) {
    $chain = Invoke-DevRebuildChain -ScriptRoot $PSScriptRoot -ConfigPath $ConfigPath -Config $config -HistoryRoot $HistoryRoot -ProdToken $ProdToken -DevToken $DevToken
    $chain.Steps | ForEach-Object { [pscustomobject]$_ } | Format-Table Step, Status, Message | Out-String | Write-Host
    if ($chain.Report) { Write-Host "Drift report: $([System.IO.Path]::ChangeExtension($chain.Report, '.md'))" }
    if (-not $chain.Completed) { exit 1 }
}
else {
    Write-Host 'Rebuild next: scripts/Invoke-DevBaseline.ps1, then scripts/Invoke-ApplyDev.ps1, then scripts/Invoke-DevUsers.ps1 (or -RebuildAfter).'
}
