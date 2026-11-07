#requires -Version 7.0
<#
.SYNOPSIS
    Runs one job of the web interface (issue #14, ADR 0012). Started by the web API in its own process; not meant to
    be started by hand.
.DESCRIPTION
    Reads History\jobs\<id>.json (written by the API with status 'queued'), runs the matching script of this folder
    and keeps state, steps and result in the same file; the output of the script goes to History\jobs\<id>.log.
    Writing jobs (apply) run only with the confirmation the person gave in the browser; the script checks the plan
    hash again, exactly as on the console. See Invoke-WebJob in the module.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$JobPath,
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config.psd1'),
    [string]$HistoryRoot = (Join-Path $PSScriptRoot '..\History')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\M365Cloning\M365Cloning.psd1') -Force

Invoke-WebJob -JobPath $JobPath -HistoryRoot $HistoryRoot -ConfigPath $ConfigPath -ScriptRoot $PSScriptRoot
