#Requires -Version 7.2
<#
.SYNOPSIS
Starts the web app (API and interface) on this machine with one command (issue #79).

.DESCRIPTION
First start: checks Python 3.12, creates the Python environments under web.local\ and installs the locked packages,
makes the shared token secret (web.local\token.secret, only your account may read it). Every start: reads
web.settings.psd1, gives the settings only to the two apps, starts both on 127.0.0.1 and opens the browser.
Ctrl+C stops both. Nothing is written into a tenant. See docs/getting-started.md.

.PARAMETER Check
Only check Python, the settings and the ports; start nothing, create nothing.

.PARAMETER NoBrowser
Do not open the browser.

.PARAMETER SetLocalPassword
Ask for the password of the break-glass account and store only its hash in web.settings.psd1.

.PARAMETER SettingsPath
Another settings file (default: web.settings.psd1 next to the toolkit).

.EXAMPLE
pwsh scripts/Start-M365CloningWeb.ps1 -Check
#>
[CmdletBinding()]
param (
    [switch]$Check,
    [switch]$NoBrowser,
    [switch]$SetLocalPassword,
    [string]$SettingsPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'M365CloningWeb.psm1') -Force
$code = Invoke-M365CloningWeb -Check:$Check -NoBrowser:$NoBrowser -SetLocalPassword:$SetLocalPassword -SettingsPath $SettingsPath
exit $code
