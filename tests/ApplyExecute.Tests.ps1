BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'M365Cloning.psd1') -Force
    $script:Valid = Join-Path $PSScriptRoot 'fixtures' 'config.valid.psd1'

    function script:New-Config([bool]$ApplyAllowed = $true) {
        $c = Import-M365CloningConfig -Path $script:Valid
        $c['Dev']['ApplyAllowed'] = $ApplyAllowed
        $c
    }
    function script:New-Res($Type, $Name, $Props) {
        @{ displayName = $Name; resourceType = $Type; properties = ($Props + @{ DisplayName = $Name }) }
    }
    function script:New-Snap($Resources) { @{ resources = @($Resources) } }
    # A plan with one planned action, one blocked action and one skipped action.
    function script:New-Plan {
        $src = script:New-Snap @(
            (script:New-Res 'microsoft.intune.deviceconfigurationpolicywindows10' 'Planned' @{ Len = 8 }),
            (script:New-Res 'microsoft.intune.deviceconfigurationpolicywindows10' 'Blocked' @{ Assignments = @(@{ dataType = '#microsoft.graph.exclusionGroupAssignmentTarget'; groupDisplayName = 'Missing' }) }))
        $tgt = script:New-Snap @(script:New-Res 'microsoft.intune.deviceconfigurationpolicywindows10' 'Dev only' @{ X = 1 })
        New-ApplyPlan -Source $src -Target $tgt -Config (script:New-Config)
    }
    function script:Read-Audit([string]$Root) {
        $path = Join-Path $Root 'audit.jsonl'
        if (Test-Path $path) { @(Get-Content -LiteralPath $path | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
    }
}

Describe 'Invoke-ApplyPlan: refusals (nothing is started)' {
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $script:Starter = { param($PlanPath, $ResultPath, $TenantId, $ClientId, $CertThumbprint) $script:Calls.Add($PlanPath); 0 }
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Plan = script:New-Plan
        $script:Hash = Get-ApplyPlanHash -Plan $script:Plan
    }
    It 'refuses when Dev.ApplyAllowed is not $true' {
        { Invoke-ApplyPlan -Plan $script:Plan -Config (script:New-Config $false) -ConfirmPlanHash $script:Hash -ProcessStarter $script:Starter -HistoryRoot $script:Root } | Should -Throw '*ApplyAllowed*'
        $script:Calls.Count | Should -Be 0
    }
    It 'refuses a wrong plan hash' {
        { Invoke-ApplyPlan -Plan $script:Plan -Config (script:New-Config) -ConfirmPlanHash ('0' * 64) -ProcessStarter $script:Starter -HistoryRoot $script:Root } | Should -Throw '*hash*'
        $script:Calls.Count | Should -Be 0
    }
    It 'refuses an empty plan hash' {
        { Invoke-ApplyPlan -Plan $script:Plan -Config (script:New-Config) -ConfirmPlanHash ' ' -ProcessStarter $script:Starter -HistoryRoot $script:Root } | Should -Throw '*hash*'
        $script:Calls.Count | Should -Be 0
    }
    It 'does not accept -Confirm:$false instead of the hash' {
        { Invoke-ApplyPlan -Plan $script:Plan -Config (script:New-Config) -Confirm:$false -ProcessStarter $script:Starter -HistoryRoot $script:Root } | Should -Throw
        $script:Calls.Count | Should -Be 0
    }
    It 'refuses a plan that was changed after the preview' {
        $changed = script:New-Plan
        @($changed['Actions'] | Where-Object { $_['Name'] -eq 'Planned' })[0]['Properties']['Len'] = 99
        { Invoke-ApplyPlan -Plan $changed -Config (script:New-Config) -ConfirmPlanHash $script:Hash -ProcessStarter $script:Starter -HistoryRoot $script:Root } | Should -Throw '*hash*'
        $script:Calls.Count | Should -Be 0
    }
    It 'refuses a plan for another tenant than Dev in the config' {
        $config = script:New-Config
        $config['Dev']['TenantId'] = 'tenant-other-0001'
        { Invoke-ApplyPlan -Plan $script:Plan -Config $config -ConfirmPlanHash $script:Hash -ProcessStarter $script:Starter -HistoryRoot $script:Root } | Should -Throw '*different tenant*'
        $script:Calls.Count | Should -Be 0
    }
    It 'refuses when the Dev tenant ID equals the Prod tenant ID' {
        $config = script:New-Config
        $config['Dev']['TenantId'] = $config['Prod']['TenantId']
        $plan = script:New-Plan
        $plan['TargetTenantHash'] = Get-TenantIdHash -TenantId $config['Prod']['TenantId']
        { Invoke-ApplyPlan -Plan $plan -Config $config -ConfirmPlanHash (Get-ApplyPlanHash -Plan $plan) -ProcessStarter $script:Starter -HistoryRoot $script:Root } | Should -Throw '*Prod*'
        $script:Calls.Count | Should -Be 0
    }
    It 'writes every refusal to the audit log' {
        { Invoke-ApplyPlan -Plan $script:Plan -Config (script:New-Config $false) -ConfirmPlanHash $script:Hash -ProcessStarter $script:Starter -HistoryRoot $script:Root } | Should -Throw
        $entries = script:Read-Audit $script:Root
        $entries.Count | Should -Be 1
        $entries[0].Mode | Should -Be 'refused'
        $entries[0].PlanHash | Should -Be $script:Hash
    }
}

Describe 'Invoke-ApplyPlan: confirmed apply' {
    BeforeEach {
        $script:Seen = [System.Collections.Generic.List[object]]::new()
        $script:Starter = {
            param($PlanPath, $ResultPath, $TenantId, $ClientId, $CertThumbprint)
            $script:Seen.Add(@{ Plan = (Get-Content -Raw $PlanPath | ConvertFrom-Json); Tenant = $TenantId; Client = $ClientId; Bound = @($PSBoundParameters.Keys) })
            ConvertTo-Json -InputObject @(@{ Name = 'Planned'; ResourceType = 'x'; Status = 'applied'; Message = '' }) | Set-Content -LiteralPath $ResultPath
            0
        }
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Plan = script:New-Plan
        $script:Hash = Get-ApplyPlanHash -Plan $script:Plan
    }
    It 'starts the process once with the Dev app registration and only the planned actions' {
        $r = Invoke-ApplyPlan -Plan $script:Plan -Config (script:New-Config) -ConfirmPlanHash $script:Hash.ToUpper() -ProcessStarter $script:Starter -HistoryRoot $script:Root
        $script:Seen.Count | Should -Be 1
        $script:Seen[0].Tenant | Should -Be 'tenant-dev-0001'
        $script:Seen[0].Client | Should -Be 'client-dev-0001'
        @($script:Seen[0].Plan).Count | Should -Be 1
        @($script:Seen[0].Plan)[0].Name | Should -Be 'Planned'
        $r.Applied | Should -Be 1
        $r.Failed | Should -Be 0
    }
    It 'passes no token or secret to the process' {
        $null = Invoke-ApplyPlan -Plan $script:Plan -Config (script:New-Config) -ConfirmPlanHash $script:Hash -ProcessStarter $script:Starter -HistoryRoot $script:Root
        ($script:Seen[0].Bound | Sort-Object) -join ',' | Should -Be 'CertThumbprint,ClientId,PlanPath,ResultPath,TenantId'
    }
    It 'counts a failed result' {
        $failing = { param($PlanPath, $ResultPath, $TenantId, $ClientId, $CertThumbprint) ConvertTo-Json -InputObject @(@{ Name = 'Planned'; ResourceType = 'x'; Status = 'failed'; Message = 'boom' }) | Set-Content -LiteralPath $ResultPath; 1 }
        $r = Invoke-ApplyPlan -Plan $script:Plan -Config (script:New-Config) -ConfirmPlanHash $script:Hash -ProcessStarter $failing -HistoryRoot $script:Root
        $r.Failed | Should -Be 1
        $r.ExitCode | Should -Be 1
    }
    It 'counts everything as failed when the process wrote no result' {
        $silent = { param($PlanPath, $ResultPath, $TenantId, $ClientId, $CertThumbprint) 1 }
        (Invoke-ApplyPlan -Plan $script:Plan -Config (script:New-Config) -ConfirmPlanHash $script:Hash -ProcessStarter $silent -HistoryRoot $script:Root).Failed | Should -Be 1
    }
    It 'does not start a process when nothing is planned' {
        $empty = New-ApplyPlan -Source (script:New-Snap @()) -Target (script:New-Snap @()) -Config (script:New-Config)
        $null = Invoke-ApplyPlan -Plan $empty -Config (script:New-Config) -ConfirmPlanHash (Get-ApplyPlanHash -Plan $empty) -ProcessStarter $script:Starter -HistoryRoot $script:Root
        $script:Seen.Count | Should -Be 0
    }
    It 'writes an audit line without secrets, with the shortened tenant' {
        $null = Invoke-ApplyPlan -Plan $script:Plan -Config (script:New-Config) -ConfirmPlanHash $script:Hash -ProcessStarter $script:Starter -HistoryRoot $script:Root
        $text = Get-Content -Raw (Join-Path $script:Root 'audit.jsonl')
        $text | Should -Not -Match 'thumb-dev-0001'
        $text | Should -Not -Match 'client-dev-0001'
        $text | Should -Not -Match 'tenant-dev-0001'
        $entry = (script:Read-Audit $script:Root)[-1]   # the summary line comes last
        $entry.Mode | Should -Be 'apply'
        $entry.PlanHash | Should -Be $script:Hash
        $entry.TargetTenant | Should -Be 'tenant-d...'
        $entry.Counts.Applied | Should -Be 1
        $entry.User | Should -Not -BeNullOrEmpty
    }
}

Describe 'Invoke-ApplyPlan: one audit line per result (issue #13)' {
    BeforeAll {
        $script:Root = Join-Path $TestDrive 'per-result'
        $script:Plan = script:New-Plan
        $script:Hash = Get-ApplyPlanHash -Plan $script:Plan
        $twoResults = { param($PlanPath, $ResultPath, $TenantId, $ClientId, $CertThumbprint)
            ConvertTo-Json -InputObject @(
                @{ Name = 'Planned'; ResourceType = 'IntuneDeviceConfigurationPolicyWindows10'; Status = 'applied'; Message = '' },
                @{ Name = 'Other'; ResourceType = 'IntuneDeviceConfigurationPolicyWindows10'; Status = 'failed'; Message = 'boom secret-detail' }) | Set-Content -LiteralPath $ResultPath; 1 }
        $null = Invoke-ApplyPlan -Plan $script:Plan -Config (script:New-Config) -ConfirmPlanHash $script:Hash -ProcessStarter $twoResults -HistoryRoot $script:Root
        $script:Lines = @(script:Read-Audit $script:Root)
    }
    It 'writes one line per result and the summary line last' {
        $script:Lines.Count | Should -Be 3
        $script:Lines[0].Reason | Should -Be 'applied IntuneDeviceConfigurationPolicyWindows10: Planned'
        $script:Lines[1].Reason | Should -Be 'failed to apply IntuneDeviceConfigurationPolicyWindows10: Other'
        $script:Lines[2].Reason | Should -Be 'finished with failures'
        foreach ($l in $script:Lines) { $l.Mode | Should -Be 'apply'; $l.PlanHash | Should -Be $script:Hash }
    }
    It 'never writes the error text of a result' {
        (Get-Content -Raw (Join-Path $script:Root 'audit.jsonl')) | Should -Not -Match 'secret-detail'
    }
}

Describe 'Write-ApplyAudit' {
    It 'appends lines and writes only the fixed fields' {
        $root = Join-Path $TestDrive 'audit'
        Write-ApplyAudit -HistoryRoot $root -Mode plan -PlanHash 'h1' -TargetTenantId 'tenant-dev-0001' -Counts @{ Planned = 2; Token = 'secret-value' }
        Write-ApplyAudit -HistoryRoot $root -Mode plan -PlanHash 'h2' -TargetTenantId 'tenant-dev-0001'
        @(Get-Content (Join-Path $root 'audit.jsonl')).Count | Should -Be 2
        (Get-Content -Raw (Join-Path $root 'audit.jsonl')) | Should -Not -Match 'secret-value'
        (script:Read-Audit $root)[0].Counts.Planned | Should -Be 2
    }
    It 'knows the mode report (drift report, issue #13)' {
        $root = Join-Path $TestDrive 'audit-report'
        Write-ApplyAudit -HistoryRoot $root -Mode report -TargetTenantId 'tenant-dev-0001' -Reason 'drift Prod -> Dev (offline): 1 added, 0 removed, 2 changed'
        (script:Read-Audit $root)[0].Mode | Should -Be 'report'
        { Write-ApplyAudit -HistoryRoot $root -Mode deleteall } | Should -Throw
    }
}
