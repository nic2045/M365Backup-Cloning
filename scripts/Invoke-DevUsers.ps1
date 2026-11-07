#requires -Version 7.0
<#
.SYNOPSIS
    Test users and invited admins in the Dev tenant from the positive list DevUsers (issue #22). Dev tenant only.
.DESCRIPTION
    Default (-Plan): reads the Dev state (GET only: the listed users, the persona groups and their members), builds
    the plan, writes History\reports\dev-users-plan-*.json/.md and prints the plan hash. Nothing is changed.
    -Apply -ConfirmPlanHash <hash>: reads the Dev state again, builds the plan again and applies it only if its hash
    equals the one you looked at; needs Dev.ApplyAllowed = $true. Creates test users, invites admins as B2B
    guests (no invitation mail) and adds them to the empty Dev group of their persona. Never removes anything.
    -ShowInitialPasswords prints the random initial passwords of new test users once to the console; they are never
    stored. Without it an admin resets the password before the first sign-in.
    Offline plan: -DirectoryPath <json> with the Dev state ({ Users, Groups, Members }), for a preview only.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config.psd1'),
    [securestring]$DevToken,
    [string]$DirectoryPath,
    [string]$HistoryRoot = (Join-Path $PSScriptRoot '..\History'),
    [switch]$Plan,
    [switch]$Apply,
    [string]$ConfirmPlanHash,
    [switch]$ShowInitialPasswords
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\M365Cloning\M365Cloning.psd1') -Force

if ($Plan -and $Apply) { throw 'Use either -Plan (default) or -Apply, not both.' }
if ($Apply -and [string]::IsNullOrWhiteSpace($ConfirmPlanHash)) {
    throw 'Run without -Apply first, read the plan in History\reports, then pass its hash with -ConfirmPlanHash.'
}
if ($Apply -and $DirectoryPath) { throw '-Apply reads the Dev state online (-DevToken); -DirectoryPath is for a preview only.' }

$config = Import-M365CloningConfig -Path $ConfigPath
$entries = if ($config.ContainsKey('DevUsers') -and $config.DevUsers) { @($config.DevUsers) } else { @() }
if ($entries.Count -eq 0) { throw 'DevUsers is empty in the config: nothing to plan.' }

if ($DirectoryPath) {
    $directory = Get-Content -LiteralPath $DirectoryPath -Raw | ConvertFrom-Json -AsHashtable
}
else {
    if (-not $DevToken) { throw 'Pass -DevToken (Dev app registration) or -DirectoryPath for an offline preview.' }
    $directory = Get-DevDirectory -Token $DevToken -Config $config
}

$userPlan = New-DevUserPlan -Config $config -Directory $directory
$hash = Get-ApplyPlanHash -Plan $userPlan

if (-not $Apply) {
    $files = Export-ApplyPlan -Plan $userPlan -HistoryRoot $HistoryRoot -FilePrefix 'dev-users-plan'
    Write-ApplyAudit -HistoryRoot $HistoryRoot -Mode plan -PlanHash $hash -TargetTenantId $config.Dev.TenantId -Counts $userPlan.Summary -Reason 'dev users'
    $userPlan.Summary | Format-Table | Out-String | Write-Host
    Write-Host "Plan:      $($files.Markdown)"
    Write-Host "Plan hash: $hash"
    Write-Host 'Nothing was changed. To apply exactly this plan: scripts/Invoke-DevUsers.ps1 -Apply -ConfirmPlanHash <hash>'
    return
}

$result = Invoke-DevUserPlan -Plan $userPlan -Config $config -ConfirmPlanHash $ConfirmPlanHash -Token $DevToken -HistoryRoot $HistoryRoot -ShowInitialPasswords:$ShowInitialPasswords
Write-Host "Applied: $($result.Applied)  Failed: $($result.Failed)"
if ($result.Failed -gt 0) { $result.Results | Where-Object { $_.Status -eq 'failed' } | ForEach-Object { [pscustomobject]$_ } | Format-Table Name, Operation, Message | Out-String | Write-Host; exit 1 }
