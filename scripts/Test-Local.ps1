#requires -Version 7.0
<#
.SYNOPSIS
    All checks of this repository on your own machine (no GitHub Actions budget, ADR 0022): Pester, the Python suites and the secret scan.
.DESCRIPTION
    pwsh scripts/Test-Local.ps1                 everything (before a pull request)
    pwsh scripts/Test-Local.ps1 -SkipPester     without Pester
    pwsh scripts/Test-Local.ps1 -SkipPython     without the Python suites (web/api, web/ui, tools/intunecd)
    pwsh scripts/Test-Local.ps1 -SkipSecretScan without gitleaks
    Pester 5 (tests/), pytest of web/api, web/ui and tools/intunecd (the requirements of each folder: pip install --require-hashes -r <folder>/requirements-dev.txt), and gitleaks
    (https://github.com/gitleaks/gitleaks, the same scan as the workflow ci). A step whose tool is not installed is skipped and said so; it does not fail the run.
    Nothing here talks to a tenant. Exit code 0 = everything that ran is fine, 1 = something failed.
#>
[CmdletBinding()]
param (
    [switch]$SkipPester,
    [switch]$SkipPython,
    [switch]$SkipSecretScan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Path $PSScriptRoot -Parent
$results = [System.Collections.Generic.List[object]]::new()
$add = { param($step, $state, $text) $results.Add([pscustomobject]@{ Step = $step; State = $state; Text = $text }) }

if (-not $SkipPester) {
    Write-Host '== Pester (tests/)' -ForegroundColor Cyan
    $pester = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [version]'5.5.0' } | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $pester) { & $add 'Pester' 'skipped' 'Pester 5.5 or newer is not installed (Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser)' }
    else {
        Import-Module $pester -Force
        $run = Invoke-Pester -Path (Join-Path $root 'tests') -CI -PassThru -Output Minimal
        if ($run.FailedCount -gt 0 -or $run.FailedBlocksCount -gt 0 -or $run.FailedContainersCount -gt 0) { & $add 'Pester' 'failed' "$($run.FailedCount) test(s), $($run.FailedBlocksCount) block(s), $($run.FailedContainersCount) container(s) failed" }
        else { & $add 'Pester' 'ok' "$($run.PassedCount) passed, $($run.SkippedCount) skipped" }
    }
}

if (-not $SkipPython) {
    $python = @('python3', 'python') | Where-Object { Get-Command -Name $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
    foreach ($suite in @(@('web/api', 'web/api'), @('web/ui', 'web/ui'), @('tools/intunecd', 'tools/intunecd'))) {
        Write-Host "== pytest ($($suite[0]))" -ForegroundColor Cyan
        $folder = Join-Path $root $suite[1]
        if (-not $python) { & $add "pytest $($suite[0])" 'skipped' 'Python is not installed'; continue }
        & $python -c 'import pytest' 2>$null
        if ($LASTEXITCODE -ne 0) { & $add "pytest $($suite[0])" 'skipped' "pytest is not installed (pip install --require-hashes -r $($suite[1])/requirements-dev.txt)"; continue }
        Push-Location $folder
        try { & $python -m pytest -q; $exit = $LASTEXITCODE } finally { Pop-Location }
        if ($exit -eq 0) { & $add "pytest $($suite[0])" 'ok' '' } else { & $add "pytest $($suite[0])" 'failed' "exit code $exit" }
    }
}

if (-not $SkipSecretScan) {
    Write-Host '== gitleaks' -ForegroundColor Cyan
    if (-not (Get-Command -Name gitleaks -ErrorAction SilentlyContinue)) { & $add 'gitleaks' 'skipped' 'gitleaks is not installed (https://github.com/gitleaks/gitleaks)' }
    else {
        Push-Location $root
        try { & gitleaks detect --no-banner --redact --source . ; $exit = $LASTEXITCODE } finally { Pop-Location }
        if ($exit -eq 0) { & $add 'gitleaks' 'ok' 'no secret found' } else { & $add 'gitleaks' 'failed' "exit code $exit (a finding or an error, see above)" }
    }
}

Write-Host ''
foreach ($r in $results) {
    $color = switch ($r.State) { 'ok' { 'Green' } 'failed' { 'Red' } default { 'Yellow' } }
    Write-Host ('{0,-8} {1}{2}' -f $r.State, $r.Step, $(if ($r.Text) { ' - ' + $r.Text } else { '' })) -ForegroundColor $color
}
if (@($results | Where-Object State -EQ 'failed').Count -gt 0) { exit 1 }
exit 0
