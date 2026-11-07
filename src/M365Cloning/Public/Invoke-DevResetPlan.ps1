function Invoke-DevResetPlan {
    <#
    .SYNOPSIS
        Runs a confirmed factory reset plan (New-DevResetPlan) in the Dev tenant (issue #7, ADR 0005).
    .DESCRIPTION
        Gate (Assert-DevApplyGate -Purpose Reset): the plan hash (first confirmation), -ConfirmTenant equal to the Dev
        tenant ID (second confirmation), Dev.AllowReset = $true, Dev tenant only, Prod refused; every refusal goes to
        the audit log. Before the first write the plan is checked again: it must carry a protection list, and no
        planned delete may hit a protected account or group.
        Order: Conditional Access (PATCH state = 'disabled', then DELETE), Intune policies, assignment filters,
        groups, users. A failure stops the later steps (status 'not-run'), so that nothing a failed object still
        uses is removed after it. Every write goes through Invoke-DevResetWrite (allow list: DELETE of the reset
        kinds and the one PATCH; Dev only); the permanent delete of the deleted items is never called.
        Graph is used, not Microsoft365DSC: a DSC delete is Ensure = 'Absent', which ADR 0001 keeps out of every
        automatic run; the reset is the one documented exception (ADR 0005) and stays a single, visible write path.
        Audit: one line per delete (kind and name, no IDs, tokens or properties) and one summary line.
        -GraphWriter replaces the real write (tests); it gets -Method, -Uri, -Body, -TenantId, -Config.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ConfirmPlanHash,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ConfirmTenant,
        [securestring]$Token,
        [scriptblock]$GraphWriter,
        [string]$HistoryRoot = (Join-Path (Get-Location) 'History'),
        [string]$GraphHost = 'https://graph.microsoft.com'
    )

    $hash = Assert-DevApplyGate -Plan $Plan -Config $Config -ConfirmPlanHash $ConfirmPlanHash -HistoryRoot $HistoryRoot -Purpose Reset -ConfirmTenant $ConfirmTenant
    $target = [string]$Plan['TargetTenantId']
    $devId = [string]$Config['Dev']['TenantId']

    $protected = @($Plan['Protected'])
    $refuse = { param($why) Write-ApplyAudit -HistoryRoot $HistoryRoot -Mode refused -PlanHash $hash -TargetTenantId $target -Reason $why; throw "Reset refused: $why" }
    if ($protected.Count -eq 0) { & $refuse 'the plan has no protection list' }
    $planned = @($Plan['Actions'] | Where-Object { $_['Status'] -eq 'planned' -and $_['Operation'] -eq 'Delete' })
    foreach ($a in $planned) {
        $hit = @($protected | Where-Object { [string]$_['Name'] -and [string]$_['Name'] -ieq [string]$a['Name'] -and
                ( ($_['Kind'] -eq 'Account' -and $a['ResourceType'] -eq 'User') -or ($_['Kind'] -eq 'Group' -and $a['ResourceType'] -eq 'Group') ) })
        if ($hit) { & $refuse "a planned delete hits the protection list ($($a['ResourceType']) '$($a['Name'])')" }
        if ($a['ResourceType'] -in 'ManagedDevice', 'Invite') { & $refuse 'devices and invitations are never written by the reset' }
    }

    if (-not $GraphWriter -and -not $Token) { throw 'Pass -Token (Dev app registration, app-only).' }
    $writer = if ($GraphWriter) { $GraphWriter } else {
        { param($Method, $Uri, $Body, $TenantId, $Config) Invoke-DevResetWrite -Method $Method -Uri $Uri -Body $Body -TenantId $TenantId -Config $Config -Token $Token }
    }
    $write = {
        param([string]$Method, [string]$Uri, [System.Collections.IDictionary]$Body)
        # The allow list is checked here as well, so a test writer cannot be reached with another path either.
        Assert-DevResetWriteAllowed -Method $Method -Uri $Uri -Body $Body -TenantId $devId -Config $Config
        & $writer -Method $Method -Uri $Uri -Body $Body -TenantId $devId -Config $Config
    }

    $steps = @(
        @{ Name = 'Conditional Access'; Kinds = @('ConditionalAccessPolicy') }
        @{ Name = 'Intune policies'; Kinds = @('DeviceConfiguration', 'DeviceCompliancePolicy', 'ConfigurationPolicy', 'Intent') }
        @{ Name = 'Assignment filters'; Kinds = @('AssignmentFilter') }
        @{ Name = 'Groups'; Kinds = @('Group') }
        @{ Name = 'Users'; Kinds = @('User') }
    )
    $results = [System.Collections.Generic.List[object]]::new()
    $stopped = $false
    foreach ($step in $steps) {
        $items = @($planned | Where-Object { $_['ResourceType'] -in $step.Kinds })
        $stepFailed = $false
        foreach ($a in $items) {
            $kind = [string]$a['ResourceType']; $name = [string]$a['Name']
            if ($stopped) { $results.Add([ordered]@{ Step = $step.Name; ResourceType = $kind; Name = $name; Status = 'not-run'; Message = 'an earlier step failed' }); continue }
            $uri = "$GraphHost/$(Get-DevResetEndpoint -Kind $kind)/$([string]$a['Properties']['Id'])"
            try {
                if ($kind -eq 'ConditionalAccessPolicy') { $null = & $write 'PATCH' $uri ([ordered]@{ state = 'disabled' }) }
                $null = & $write 'DELETE' $uri $null
                $results.Add([ordered]@{ Step = $step.Name; ResourceType = $kind; Name = $name; Status = 'deleted'; Message = '' })
                Write-ApplyAudit -HistoryRoot $HistoryRoot -Mode reset -PlanHash $hash -TargetTenantId $target -Reason "deleted $($kind): $name"
            }
            catch {
                $msg = ([string]$_.Exception.Message -split "`n")[0]
                if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) }
                $results.Add([ordered]@{ Step = $step.Name; ResourceType = $kind; Name = $name; Status = 'failed'; Message = $msg })
                Write-ApplyAudit -HistoryRoot $HistoryRoot -Mode reset -PlanHash $hash -TargetTenantId $target -Reason "failed to delete $($kind): $name"
                $stepFailed = $true
            }
        }
        if ($stepFailed) { $stopped = $true }
    }

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $dir = Join-Path (Join-Path $HistoryRoot 'apply') "dev-reset-$stamp"
    $null = New-Item -ItemType Directory -Path $dir -Force
    ConvertTo-Json -InputObject ([object[]]@($results)) -Depth 5 | Set-Content -LiteralPath (Join-Path $dir 'result.json') -Encoding utf8

    $deleted = @($results | Where-Object { $_['Status'] -eq 'deleted' }).Count
    $failed = @($results | Where-Object { $_['Status'] -eq 'failed' }).Count
    $notRun = @($results | Where-Object { $_['Status'] -eq 'not-run' }).Count
    $counts = @{ Planned = $planned.Count; Deleted = $deleted; Failed = $failed; NotRun = $notRun }
    Write-ApplyAudit -HistoryRoot $HistoryRoot -Mode reset -PlanHash $hash -TargetTenantId $target -Counts $counts -Reason $(if ($failed -gt 0) { "dev reset ($($Plan['Mode'])): stopped after a failure" } else { "dev reset ($($Plan['Mode'])): finished" })
    [pscustomobject]@{ PlanHash = $hash; Deleted = $deleted; Failed = $failed; NotRun = $notRun; Results = [object[]]@($results) }
}
