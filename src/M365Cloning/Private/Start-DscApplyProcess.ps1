function Start-DscApplyProcess {
    <#
    .SYNOPSIS
        Runs src/M365Cloning/Dsc/Apply-DscPlan.ps1 in its own Windows PowerShell 5.1 process (ADR 0001:
        Microsoft365DSC runs only there). Returns the exit code. Replaced by a mock in the tests.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$ResultPath,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$CertThumbprint
    )
    if (-not $IsWindows) { throw 'Microsoft365DSC needs Windows PowerShell 5.1 (powershell.exe); this host is not Windows.' }
    $exe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "Windows PowerShell 5.1 not found: $exe" }
    $runner = Join-Path $script:ModuleRoot 'Dsc\Apply-DscPlan.ps1'
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$runner`"",
        '-PlanPath', "`"$PlanPath`"", '-ResultPath', "`"$ResultPath`"",
        '-TenantId', "`"$TenantId`"", '-ClientId', "`"$ClientId`"", '-CertThumbprint', "`"$CertThumbprint`""
    )
    $process = Start-Process -FilePath $exe -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    $process.ExitCode
}
