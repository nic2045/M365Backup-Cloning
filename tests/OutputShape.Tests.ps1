# One shape for the core's output files (issue #51, schema version 2). Offline, fixtures and mocks only.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'M365Cloning.psd1') -Force
    . (Join-Path $PSScriptRoot 'contract' 'ContractHelpers.ps1')
    . (Join-Path $PSScriptRoot 'contract' 'Get-ActionDigest.ps1')
    $script:History = Invoke-ContractSampleRun -HistoryRoot (Join-Path $TestDrive 'History')
    $script:Reports = Join-Path $script:History 'reports'
    $script:DevId = 'tenant-dev-0001'
    $script:ProdId = 'tenant-prod-0001'
    $script:PlanPrefixes = [ordered]@{
        'apply-plan-' = 'apply'; 'dev-baseline-plan-' = 'baseline'; 'dev-reset-plan-align-' = 'reset'; 'dev-reset-plan-full-' = 'reset'; 'dev-users-plan-' = 'users'
    }
    function script:Read-Report([string]$Prefix) {
        $f = @(Get-ChildItem -LiteralPath $script:Reports -Filter "$Prefix*.json" | Sort-Object Name)[0]
        Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json -AsHashtable
    }
    function script:New-Config([bool]$ApplyAllowed = $true) {
        $c = Import-M365CloningConfig -Path (Join-Path $PSScriptRoot 'fixtures' 'config.valid.psd1')
        $c['Dev']['ApplyAllowed'] = $ApplyAllowed
        $c
    }
    function script:New-Plan {
        $src = @{ resources = @(@{ displayName = 'P1'; resourceType = 'microsoft.intune.deviceconfigurationpolicywindows10'; properties = @{ DisplayName = 'P1'; Len = 8 } }) }
        $tgt = @{ resources = @() }
        New-ApplyPlan -Source $src -Target $tgt -Config (script:New-Config)
    }
}

Describe 'Plan files: header and tenant (points 1 and 5)' {
    It 'every plan file has SchemaVersion 2, its kind and a creation time, inside the file and inside the plan' {
        foreach ($prefix in $script:PlanPrefixes.Keys) {
            $doc = script:Read-Report $prefix
            $doc['SchemaVersion'] | Should -Be '2' -Because $prefix
            $doc['Kind'] | Should -Be $script:PlanPrefixes[$prefix] -Because $prefix
            { [datetime]::Parse($doc['CreatedUtc']) } | Should -Not -Throw
            $doc['Plan']['SchemaVersion'] | Should -Be '2'
            $doc['Plan']['Kind'] | Should -Be $script:PlanPrefixes[$prefix]
        }
    }
    It 'a plan carries the Dev tenant only shortened and as a hash, never the full ID' {
        foreach ($prefix in $script:PlanPrefixes.Keys) {
            $doc = script:Read-Report $prefix
            $doc['Plan'].Contains('TargetTenantId') | Should -BeFalse
            $doc['Plan']['TargetTenant'] | Should -Be 'tenant-d...'
            $doc['Plan']['TargetTenantHash'] | Should -Be (Get-TenantIdHash -TenantId $script:DevId)
            (Get-Content -LiteralPath (@(Get-ChildItem -LiteralPath $script:Reports -Filter "$prefix*.json")[0].FullName) -Raw) | Should -Not -Match ([regex]::Escape($script:DevId)) -Because $prefix
        }
    }
    It 'the tenant hash ignores case and spaces' {
        Get-TenantIdHash -TenantId ' TENANT-dev-0001 ' | Should -Be (Get-TenantIdHash -TenantId $script:DevId)
    }
    It 'the drift report and the suitability check have the same header' {
        $drift = script:Read-Report 'drift-'
        $drift['SchemaVersion'] | Should -Be '2'
        $drift['Kind'] | Should -Be 'drift'
        { [datetime]::Parse($drift['CreatedUtc']) } | Should -Not -Throw
        $fit = script:Read-Report 'tenantfit-'
        $fit['SchemaVersion'] | Should -Be '2'
        $fit['Kind'] | Should -Be 'tenantfit'
        $fit.Contains('Schema') | Should -BeFalse
    }
}

Describe 'Plans: one shape for every kind (points 2 and 3)' {
    It 'every plan has the same fields and the same summary counters' {
        $fields = $null; $counters = $null
        foreach ($prefix in $script:PlanPrefixes.Keys) {
            $plan = (script:Read-Report $prefix)['Plan']
            $f = @($plan.Keys | Sort-Object) -join ','
            $c = @($plan['Summary'].Keys | Sort-Object) -join ','
            if ($null -eq $fields) { $fields = $f; $counters = $c }
            $f | Should -Be $fields -Because $prefix
            $c | Should -Be $counters -Because $prefix
            @($plan['Summary']['Devices'].Keys | Sort-Object) -join ',' | Should -Be 'Keep,Protected,Remove,Retire,Wipe'
        }
        $counters | Should -Be 'Blocked,Devices,Excluded,Exists,InBaseline,Invite,Planned,Protected,Skipped'
    }
    It 'every plan has a licence section; the reset says it was not checked' {
        foreach ($prefix in $script:PlanPrefixes.Keys) {
            $lic = (script:Read-Report $prefix)['Plan']['Licences']
            $lic | Should -Not -BeNullOrEmpty -Because $prefix
            foreach ($k in 'Checked', 'Readable', 'Error', 'Available', 'Missing', 'Warnings') { $lic.Contains($k) | Should -BeTrue -Because "$prefix $k" }
            if ($prefix -like 'dev-reset-*') { $lic['Checked'] | Should -BeFalse } else { $lic['Checked'] | Should -BeTrue }
        }
    }
    It 'Properties is always an object and Differences always a list' {
        foreach ($prefix in $script:PlanPrefixes.Keys) {
            foreach ($a in (script:Read-Report $prefix)['Plan']['Actions']) {
                $a['Properties'] -is [System.Collections.IDictionary] | Should -BeTrue -Because "$prefix $($a['Name'])"
                $a.Contains('Differences') | Should -BeTrue
                $a.Contains('AssignmentClass') | Should -BeTrue
            }
        }
    }
    It 'TypeSummary and ExcludedTypes are present (empty lists for kinds that have none)' {
        foreach ($prefix in $script:PlanPrefixes.Keys) {
            $plan = (script:Read-Report $prefix)['Plan']
            $plan.Contains('TypeSummary') | Should -BeTrue
            $plan.Contains('ExcludedTypes') | Should -BeTrue
        }
        @((script:Read-Report 'apply-plan-')['Plan']['TypeSummary']).Count | Should -BeGreaterThan 0
    }
}

Describe 'Licences: one core in plan and suitability check (point 4)' {
    It 'both views start with Checked, Readable, Error and Available' {
        $plan = (script:Read-Report 'apply-plan-')['Plan']['Licences']
        $fit = (script:Read-Report 'tenantfit-')['Licences']
        foreach ($view in @($plan, $fit['Prod'], $fit['Dev'])) {
            foreach ($k in 'Checked', 'Readable', 'Error', 'Available') { $view.Contains($k) | Should -BeTrue }
        }
        $fit['Dev'].Contains('Skus') | Should -BeTrue
        $plan.Contains('Skus') | Should -BeFalse
    }
}

Describe 'Gate: the plan carries no full ID, the gate still checks the tenant and the Prod lock (point 5)' {
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $script:Starter = { param($PlanPath, $ResultPath, $TenantId, $ClientId, $CertThumbprint) $script:Calls.Add($TenantId); 0 }
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }
    It 'runs a current plan and takes the full Dev tenant ID from the config' {
        $plan = script:New-Plan
        $null = Invoke-ApplyPlan -Plan $plan -Config (script:New-Config) -ConfirmPlanHash (Get-ApplyPlanHash -Plan $plan) -ProcessStarter $script:Starter -HistoryRoot $script:Root
        $script:Calls.Count | Should -Be 1
        $script:Calls[0] | Should -Be $script:DevId
    }
    It 'refuses a plan whose tenant hash is the Prod tenant' {
        $plan = script:New-Plan
        $plan['TargetTenantHash'] = Get-TenantIdHash -TenantId $script:ProdId
        { Invoke-ApplyPlan -Plan $plan -Config (script:New-Config) -ConfirmPlanHash (Get-ApplyPlanHash -Plan $plan) -ProcessStarter $script:Starter -HistoryRoot $script:Root } | Should -Throw '*different tenant*'
        $script:Calls.Count | Should -Be 0
    }
    It 'refuses a plan without a tenant hash (fail-closed)' {
        $plan = script:New-Plan
        $plan.Remove('TargetTenantHash')
        { Invoke-ApplyPlan -Plan $plan -Config (script:New-Config) -ConfirmPlanHash (Get-ApplyPlanHash -Plan $plan) -ProcessStarter $script:Starter -HistoryRoot $script:Root } | Should -Throw '*different tenant*'
        $script:Calls.Count | Should -Be 0
    }
    It 'keeps the Prod lock: Dev equal to Prod in the config is refused' {
        $config = script:New-Config
        $config['Dev']['TenantId'] = $config['Prod']['TenantId']
        $plan = script:New-Plan
        $plan['TargetTenantHash'] = Get-TenantIdHash -TenantId $config['Prod']['TenantId']
        { Invoke-ApplyPlan -Plan $plan -Config $config -ConfirmPlanHash (Get-ApplyPlanHash -Plan $plan) -ProcessStarter $script:Starter -HistoryRoot $script:Root } | Should -Throw '*Prod*'
        $script:Calls.Count | Should -Be 0
    }
    It 'refuses a plan of an older format (no Kind, or schema version 1): make a new plan' {
        $old = script:New-Plan
        $old.Remove('Kind')
        { Invoke-ApplyPlan -Plan $old -Config (script:New-Config) -ConfirmPlanHash (Get-ApplyPlanHash -Plan $old) -ProcessStarter $script:Starter -HistoryRoot $script:Root } | Should -Throw '*make a new plan*'
        $v1 = script:New-Plan
        $v1['SchemaVersion'] = '1'
        { Invoke-ApplyPlan -Plan $v1 -Config (script:New-Config) -ConfirmPlanHash (Get-ApplyPlanHash -Plan $v1) -ProcessStarter $script:Starter -HistoryRoot $script:Root } | Should -Throw '*make a new plan*'
        $script:Calls.Count | Should -Be 0
    }
    It 'the plan hash has no time in it: the same input gives the same hash' {
        Get-ApplyPlanHash -Plan (script:New-Plan) | Should -Be (Get-ApplyPlanHash -Plan (script:New-Plan))
    }
}

Describe 'Plan files of an older format (point 8)' {
    It 'reads a current plan file' {
        $file = @(Get-ChildItem -LiteralPath $script:Reports -Filter 'apply-plan-*.json')[0]
        $doc = Read-ApplyPlanFile -Path $file.FullName
        $doc['Kind'] | Should -Be 'apply'
        $doc['PlanHash'] | Should -Match '^[0-9a-f]{64}$'
    }
    It 'refuses a file without SchemaVersion and Kind with "make a new plan"' {
        $path = Join-Path $TestDrive 'apply-plan-old.json'
        '{"PlanHash":"' + ('0' * 64) + '","Plan":{"Direction":"Prod -> Dev","TargetTenantId":"tenant-dev-0001","Actions":[],"Notes":[],"Summary":{"Planned":0,"Blocked":0,"Skipped":0}}}' | Set-Content -LiteralPath $path
        { Read-ApplyPlanFile -Path $path } | Should -Throw '*make a new plan*'
    }
}

Describe 'Audit: the same counters in every line (point 6)' {
    It 'every line of the sample run has the fixed counter set' {
        $expected = 'Applied,Blocked,Deleted,Excluded,Exists,Failed,Info,Invite,NotRun,Planned,Protected,Red,Retired,Skipped,Wiped,Yellow'
        foreach ($l in Get-Content -LiteralPath (Join-Path $script:History 'audit.jsonl')) {
            @(($l | ConvertFrom-Json -AsHashtable)['Counts'].Keys | Sort-Object) -join ',' | Should -Be $expected
        }
    }
    It 'drops unknown keys and non-numbers, fills missing counters with 0' {
        $root = Join-Path $TestDrive 'audit-shape'
        Write-ApplyAudit -HistoryRoot $root -Mode plan -TargetTenantId $script:DevId -Counts @{ Planned = 3; Token = 'x'; InBaseline = $true }
        $c = (Get-Content -LiteralPath (Join-Path $root 'audit.jsonl') | ConvertFrom-Json -AsHashtable)['Counts']
        $c['Planned'] | Should -Be 3
        $c['Failed'] | Should -Be 0
        $c.Contains('Token') | Should -BeFalse
        $c.Contains('InBaseline') | Should -BeFalse
    }
    It 'Operation and Status of every action are in the closed lists of the schema' {
        $schema = Get-Content -LiteralPath $script:SchemaPath -Raw | ConvertFrom-Json -AsHashtable
        $ops = @($schema['$defs']['PlanOperation']['enum']); $sts = @($schema['$defs']['PlanStatus']['enum'])
        foreach ($prefix in $script:PlanPrefixes.Keys) {
            foreach ($a in (script:Read-Report $prefix)['Plan']['Actions']) {
                $ops | Should -Contain $a['Operation']
                $sts | Should -Contain $a['Status']
            }
        }
    }
}

Describe 'Only the shape changed, not what the plans do (point 9)' {
    It 'actions, operations, statuses, reasons, protection lists and counts equal the digest made before #51' {
        $now = Get-ContractActionDigest -HistoryRoot $script:History | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
        $before = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures' 'contract' 'actions.golden.json') -Raw | ConvertFrom-Json -AsHashtable
        foreach ($k in $before.Keys) {
            @($now[$k]['Actions']) -join "`n" | Should -Be (@($before[$k]['Actions']) -join "`n") -Because "$k actions"
            @($now[$k]['Protected']) -join "`n" | Should -Be (@($before[$k]['Protected']) -join "`n") -Because "$k protected"
            $now[$k]['Counts'] | Should -Be $before[$k]['Counts'] -Because "$k counts"
        }
    }
}
