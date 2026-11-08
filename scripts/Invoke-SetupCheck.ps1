#requires -Version 7.0
<#
.SYNOPSIS
    Setup check of this instance (issue #18): config, certificates, sign-in and permissions of both app registrations,
    the UTCM service principal, the break-glass accounts and the licences. Read only: creates, grants and changes
    nothing in any tenant.
.DESCRIPTION
    Writes History\reports\setup-check-<yyyyMMdd-HHmmss>.json (each check green, yellow, red or grey with what to do).
    -Scope Config: no sign-in (config, certificates, break-glass list, licences from the last suitability check).
    -Scope All (default): also signs in to Prod and Dev with the certificate of each app registration (Az.Accounts,
    ADR 0013) and reads with GET only. A failing sign-in is a red check, not an error of the script.
    Exit code: 0 green, 1 yellow, 2 red, 3 grey (something could not be checked).
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config.psd1'),
    [string]$HistoryRoot = (Join-Path $PSScriptRoot '..\History'),
    [ValidateSet('All', 'Config')][string]$Scope = 'All'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\M365Cloning\M365Cloning.psd1') -Force

$result = Invoke-SetupCheck -ConfigPath $ConfigPath -HistoryRoot $HistoryRoot -Scope $Scope
foreach ($c in $result.Checks) {
    $who = if ($c.Tenant) { " [$($c.Tenant)]" } else { '' }
    Write-Host ("{0,-6} {1}{2}: {3}" -f $c.Status, $c.Title, $who, $c.Detail)
    if ($c.Hint -and $c.Status -ne 'green') { Write-Host "       What to do: $($c.Hint)" }
}
Write-Host "Result: $($result.Status) (green $($result.Summary.Green), yellow $($result.Summary.Yellow), red $($result.Summary.Red), grey $($result.Summary.Grey))"
Write-Host "Report: $($result.Path)"
exit @{ green = 0; yellow = 1; red = 2; grey = 3 }[$result.Status]
