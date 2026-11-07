function Invoke-ApplyPlan {
    <#
    .SYNOPSIS
        Applies a confirmed plan to the Dev tenant with Microsoft365DSC (own Windows PowerShell 5.1 process).
    .DESCRIPTION
        Nothing starts unless ALL of this holds (each refusal is written to the audit log):
        - Dev.ApplyAllowed is $true in the local config;
        - Dev.TenantId is set, differs from Prod.TenantId and matches the plan's TargetTenantHash;
        - -ConfirmPlanHash equals the SHA-256 of the plan that is passed in (-Confirm:$false is not enough).
        Only actions with Status 'planned' are written to the plan file the child process reads. The child gets
        the Dev app registration (client ID, certificate thumbprint) from the config; no secret is passed.
        -ProcessStarter replaces the real process start (tests). It is called with the parameters of
        Start-DscApplyProcess and returns the exit code; the child writes its results to -ResultPath.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ConfirmPlanHash,
        [scriptblock]$ProcessStarter,
        [string]$HistoryRoot = (Join-Path (Get-Location) 'History')
    )

    $hash = Assert-DevApplyGate -Plan $Plan -Config $Config -ConfirmPlanHash $ConfirmPlanHash -HistoryRoot $HistoryRoot
    $target = [string]$Plan['TargetTenant']
    $dev = $Config['Dev']

    $planned = @($Plan['Actions'] | Where-Object { $_['Status'] -eq 'planned' })
    $counts = @{ Planned = $planned.Count; Blocked = [int]$Plan['Summary']['Blocked']; Skipped = [int]$Plan['Summary']['Skipped'] }
    if ($planned.Count -eq 0) {
        Write-ApplyAudit -HistoryRoot $HistoryRoot -Mode apply -PlanHash $hash -TargetTenantId $target -Counts ($counts + @{ Applied = 0; Failed = 0 }) -Reason 'nothing planned'
        return [pscustomobject]@{ PlanHash = $hash; Applied = 0; Failed = 0; Results = @(); ExitCode = 0 }
    }

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $dir = Join-Path (Join-Path $HistoryRoot 'apply') $stamp
    $null = New-Item -ItemType Directory -Path $dir -Force
    $planPath = Join-Path $dir 'plan.json'
    $resultPath = Join-Path $dir 'result.json'
    ConvertTo-Json -InputObject ([object[]]@($planned)) -Depth 30 | Set-Content -LiteralPath $planPath -Encoding utf8

    $starter = if ($ProcessStarter) { $ProcessStarter } else { { param($PlanPath, $ResultPath, $TenantId, $ClientId, $CertThumbprint) Start-DscApplyProcess @PSBoundParameters } }
    $exitCode = & $starter -PlanPath $planPath -ResultPath $resultPath -TenantId ([string]$dev['TenantId']) -ClientId ([string]$dev['ClientId']) -CertThumbprint ([string]$dev['CertThumbprint'])

    $results = @()
    if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
        $results = @(Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
    }
    $failed = @($results | Where-Object { $_.Status -eq 'failed' }).Count
    if ($results.Count -eq 0) { $failed = $planned.Count }
    $applied = @($results | Where-Object { $_.Status -in 'applied', 'unchanged' }).Count
    Write-ApplyAudit -HistoryRoot $HistoryRoot -Mode apply -PlanHash $hash -TargetTenantId $target -Counts ($counts + @{ Applied = $applied; Failed = $failed }) -Reason $(if ($failed -gt 0) { 'finished with failures' } else { 'finished' })
    [pscustomobject]@{ PlanHash = $hash; Applied = $applied; Failed = $failed; Results = $results; ExitCode = [int]$exitCode }
}
