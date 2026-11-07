#requires -Version 7.0
<#
.SYNOPSIS
    Suitability check (issue #39): is the Dev tenant enough to mirror Prod, or is an equivalent tenant needed?
    Read only: changes nothing in any tenant.
.DESCRIPTION
    Reads the licences of Prod and Dev (GET /subscribedSkus) and the usage of Prod from a Prod snapshot, compares them
    with the rules in src\M365Cloning\Data\TenantFitRules.psd1 and writes tenantfit-*.json / .md to History\reports\
    plus one audit line (History\audit.jsonl, mode 'fitcheck').
    Licences: -ProdLicencePath / -DevLicencePath (saved answer of GET /subscribedSkus) or online with -ProdToken /
    -DevToken (app-only Graph tokens, permission LicenseAssignment.Read.All). Without either, that list counts as
    not readable and the result is grey ('not verified').
    Prod usage: -ProdSnapshotPath, else the newest History\Tenants\Prod\*\snapshot.json, else with -TakeProdSnapshot
    a new UTCM snapshot of Prod (only a read job; it counts against the UTCM snapshot quota). Without a snapshot every
    feature Prod is licensed for counts as used.
    Exit code: 0 green (Dev is enough), 1 yellow (enough with gaps), 2 red (equivalent tenant needed),
    3 grey (not verified: a licence list could not be read).
    Meant to run on a schedule (docs/automation.md); ADR 0004 allows a schedule because it only reports.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config.psd1'),
    [securestring]$ProdToken,
    [securestring]$DevToken,
    [string]$ProdLicencePath,
    [string]$DevLicencePath,
    [string]$ProdSnapshotPath,
    [switch]$TakeProdSnapshot,
    [string]$HistoryRoot = (Join-Path $PSScriptRoot '..\History')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\M365Cloning\M365Cloning.psd1') -Force

$config = Import-M365CloningConfig -Path $ConfigPath

$readLicences = {
    param([string]$Path, [securestring]$Token, [string]$Side)
    if ($Path) { return (Get-TenantLicences -Path $Path) }
    if ($Token) { return (Get-TenantLicences -Token $Token) }
    [ordered]@{ Readable = $false; Error = "no -${Side}LicencePath and no -${Side}Token"; Available = [string[]]@(); Skus = [object[]]@() }
}
$prodLic = & $readLicences $ProdLicencePath $ProdToken 'Prod'
$devLic = & $readLicences $DevLicencePath $DevToken 'Dev'

$snapshotFile = $ProdSnapshotPath
if (-not $snapshotFile) {
    $prodDir = Join-Path $HistoryRoot (Join-Path 'Tenants' 'Prod')
    if (Test-Path -LiteralPath $prodDir) {
        $latest = Get-ChildItem -LiteralPath $prodDir -Directory | Sort-Object Name -Descending |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'snapshot.json') } | Select-Object -First 1
        if ($latest) { $snapshotFile = Join-Path $latest.FullName 'snapshot.json' }
    }
}
if (-not $snapshotFile -and $TakeProdSnapshot) {
    if (-not $ProdToken) { throw '-TakeProdSnapshot needs -ProdToken.' }
    $resources = if ($config.ContainsKey('Resources') -and $config.Resources) { $config.Resources } else { Get-M365CloningDefaultResources -Config $config }
    $snapshotFile = Get-UtcmTenantSnapshot -Token $ProdToken -Side Prod -TenantId $config.Prod.TenantId -Resources $resources -HistoryRoot $HistoryRoot
}
$snapshot = if ($snapshotFile) { Read-UtcmSnapshotFile -Path $snapshotFile } else { $null }

$assessment = Get-TenantFitAssessment -ProdLicences $prodLic -DevLicences $devLic -ProdSnapshot $snapshot -Config $config
$files = Export-TenantFitReport -Assessment $assessment -HistoryRoot $HistoryRoot
Write-ApplyAudit -HistoryRoot $HistoryRoot -Mode fitcheck -TargetTenantId ([string]$config.Dev.TenantId) -Reason "$($assessment.Status): $($assessment.Verdict)" -Counts ([ordered]@{
        Red = [int]$assessment.Summary.Red; Yellow = [int]$assessment.Summary.Yellow; Info = [int]$assessment.Summary.Info
    })

Write-Host "Result: $($assessment.Status) - $($assessment.Verdict)"
Write-Host "Report: $($files.Markdown)"
exit @{ green = 0; yellow = 1; red = 2; grey = 3 }[$assessment.Status]
