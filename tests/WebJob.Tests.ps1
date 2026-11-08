# Jobs of the web interface (issue #14, ADR 0012), the area of a plan (issue #66), the Actor of the audit line and the
# app-only sign-in. Offline only: the scripts run against the fixtures, tokens are fakes, nothing calls a tenant.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'M365Cloning.psd1') -Force
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures'
    $script:Scripts = Join-Path $PSScriptRoot '..' 'scripts'
    $script:Valid = Join-Path $script:Fixtures 'config.valid.psd1'
    $script:Prod = Join-Path $script:Fixtures 'prod.snapshot.json'
    $script:Dev = Join-Path $script:Fixtures 'dev.snapshot.json'
    $script:Lic = Join-Path $script:Fixtures 'dev.subscribedskus.json'
    $script:Inv = Join-Path $script:Fixtures 'dev.reset-inventory.json'

    function script:New-JobFile {
        param([string]$Root, [string]$Action, [hashtable]$Options = @{}, [hashtable]$Confirm = @{}, [string]$Id = 'job-20261107-120000-abc123')
        $dir = Join-Path $Root 'jobs'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $path = Join-Path $dir "$Id.json"
        $file = [ordered]@{
            SchemaVersion = '2'; Kind = 'job'
            Job = [ordered]@{
                id = $Id; action = $Action; status = 'queued'; role = 'Applier'; actor = 'Test Person'
                createdUtc = '2026-11-07T12:00:00Z'; updatedUtc = '2026-11-07T12:00:00Z'; startedUtc = $null; finishedUtc = $null
                options = $Options; steps = @(); message = ''; result = @{}
            }
            Confirm = $Confirm
        }
        $file | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
        $path
    }
    function script:Read-Job([string]$Path) { (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable)['Job'] }

    # Offline stand-in for the script call: the same script, with the fixture files instead of the tokens.
    $script:Offline = {
        param([string]$Path, [System.Collections.IDictionary]$Parameters, [string]$Log)
        $script:Calls.Add([pscustomobject]@{ Script = (Split-Path -Leaf $Path); Parameters = $Parameters })
        $p = @{} + $Parameters
        foreach ($k in @($p.Keys)) { if ($k -like '*Token') { $p.Remove($k) } }
        switch (Split-Path -Leaf $Path) {
            'Get-DriftReport.ps1' { $p['SourceSnapshotPath'] = $script:Prod; $p['TargetSnapshotPath'] = $script:Dev }
            'Export-DesiredState.ps1' { $p['SnapshotPath'] = $script:Prod }
            'Invoke-ApplyDev.ps1' { $p['SourceSnapshotPath'] = $script:Prod; $p['TargetSnapshotPath'] = $script:Dev; $p['LicencePath'] = $script:Lic }
            'Invoke-DevReset.ps1' { $p['InventoryPath'] = $script:Inv; if ($p['Mode'] -eq 'Align') { $p['SourceSnapshotPath'] = $script:Prod; $p['TargetSnapshotPath'] = $script:Dev } }
        }
        $global:LASTEXITCODE = 0
        & $Path @p *>&1 | ForEach-Object { Add-Content -LiteralPath $Log -Value ([string]$_) -Encoding utf8 }
        $global:LASTEXITCODE
    }
    $script:FakeToken = { param($Config, [string]$Side) $script:Signed.Add($Side); ConvertTo-SecureString -String "fake-$Side" -AsPlainText -Force }
}

Describe 'Plan area (issue #66)' {
    It 'an Intune plan keeps the Intune entries and skips the rest with an area reason' {
        $cfg = Import-M365CloningConfig -Path $script:Valid
        $src = Read-UtcmSnapshotFile -Path $script:Prod
        $tgt = Read-UtcmSnapshotFile -Path $script:Dev
        $all = New-ApplyPlan -Source $src -Target $tgt -Config $cfg
        $intune = New-ApplyPlan -Source $src -Target $tgt -Config $cfg -Area Intune
        $intune['Area'] | Should -Be 'Intune'
        $all.Contains('Area') | Should -BeFalse
        foreach ($a in @($intune['Actions'] | Where-Object { $_['Status'] -in 'planned', 'blocked' })) {
            ($a['ResourceType'].StartsWith('microsoft.intune.') -or $a['Reason'].StartsWith('empty static copy: Intune policy')) | Should -BeTrue -Because $a['Name']
        }
        $outside = @($all['Actions'] | Where-Object { $_['Status'] -in 'planned', 'blocked' -and -not $_['ResourceType'].StartsWith('microsoft.intune.') -and -not $_['Reason'].StartsWith('empty static copy: Intune policy') })
        $outside.Count | Should -BeGreaterThan 0 -Because 'the fixture has entries outside Intune'
        foreach ($o in $outside) {
            $same = @($intune['Actions'] | Where-Object { $_['ResourceType'] -eq $o['ResourceType'] -and $_['Name'] -eq $o['Name'] })[0]
            $same['Status'] | Should -Be 'skipped'
            $same['Reason'] | Should -BeLike 'area: outside Intune*'
        }
        (Get-ApplyPlanHash -Plan $intune) | Should -Not -Be (Get-ApplyPlanHash -Plan $all)
    }
    It 'a plan of all areas has the same hash as before (no Area field)' {
        $cfg = Import-M365CloningConfig -Path $script:Valid
        $src = Read-UtcmSnapshotFile -Path $script:Prod
        $tgt = Read-UtcmSnapshotFile -Path $script:Dev
        (Get-ApplyPlanHash -Plan (New-ApplyPlan -Source $src -Target $tgt -Config $cfg)) |
            Should -Be (Get-ApplyPlanHash -Plan (New-ApplyPlan -Source $src -Target $tgt -Config $cfg -Area All))
    }
}

Describe 'Actor in the audit line (issue #14)' {
    AfterEach { Remove-Item Env:M365CLONING_ACTOR -ErrorAction SilentlyContinue }
    It 'writes Actor from M365CLONING_ACTOR, without control characters and at most 256 characters' {
        $root = Join-Path $TestDrive 'actor'
        $env:M365CLONING_ACTOR = "Test`nPerson" + ('x' * 300)
        Write-ApplyAudit -HistoryRoot $root -Mode plan -TargetTenantId 'tenant-dev-0001'
        $line = Get-Content -LiteralPath (Join-Path $root 'audit.jsonl') | ConvertFrom-Json
        $line.Actor | Should -BeLike 'TestPerson*'
        $line.Actor.Length | Should -Be 256
    }
    It 'writes no Actor when the script runs by hand' {
        $root = Join-Path $TestDrive 'noactor'
        Write-ApplyAudit -HistoryRoot $root -Mode plan -TargetTenantId 'tenant-dev-0001'
        (Get-Content -LiteralPath (Join-Path $root 'audit.jsonl') | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'Actor'
    }
}

Describe 'Invoke-WebJob: preview jobs change nothing' {
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $script:Signed = [System.Collections.Generic.List[string]]::new()
    }
    It 'runs the drift report, keeps the steps and links the report' {
        $root = Join-Path $TestDrive 'drift'
        $path = script:New-JobFile -Root $root -Action drift
        Invoke-WebJob -JobPath $path -HistoryRoot $root -ConfigPath $script:Valid -ScriptRoot $script:Scripts -TokenProvider $script:FakeToken -ScriptRunner $script:Offline
        $job = script:Read-Job $path
        $job['status'] | Should -Be 'succeeded'
        @($job['steps'].key) | Should -Be @('check', 'signin', 'run', 'result')
        @($job['steps'].status | Select-Object -Unique) | Should -Be @('done')
        $job['result']['reportId'] | Should -BeLike 'drift-*'
        $job['startedUtc'] | Should -Not -BeNullOrEmpty
        $job['finishedUtc'] | Should -Not -BeNullOrEmpty
        @($script:Signed) | Should -Be @('Prod', 'Dev')
        $audit = Get-Content -LiteralPath (Join-Path $root 'audit.jsonl') | ConvertFrom-Json
        $audit.Actor | Should -Be 'Test Person'
        $env:M365CLONING_ACTOR | Should -BeNullOrEmpty
    }
    It 'builds an Intune plan with -Plan and -Area and records plan id and hash' {
        $root = Join-Path $TestDrive 'plan'
        $path = script:New-JobFile -Root $root -Action 'plan-apply' -Options @{ area = 'Intune' }
        Invoke-WebJob -JobPath $path -HistoryRoot $root -ConfigPath $script:Valid -ScriptRoot $script:Scripts -TokenProvider $script:FakeToken -ScriptRunner $script:Offline
        $job = script:Read-Job $path
        $job['status'] | Should -Be 'succeeded'
        $script:Calls[0].Parameters['Plan'] | Should -BeTrue
        $script:Calls[0].Parameters.Contains('Apply') | Should -BeFalse
        $script:Calls[0].Parameters['Area'] | Should -Be 'Intune'
        $job['result']['planId'] | Should -BeLike 'apply-plan-*'
        $file = Get-Content -LiteralPath (Join-Path $root 'reports' "$($job['result']['planId']).json") -Raw | ConvertFrom-Json -AsHashtable
        $job['result']['planHash'] | Should -Be $file['PlanHash']
        $file['Plan']['Area'] | Should -Be 'Intune'
    }
    It 'builds a reset preview with mode and device action' {
        $root = Join-Path $TestDrive 'resetplan'
        $path = script:New-JobFile -Root $root -Action 'plan-reset' -Options @{ mode = 'Full'; deviceAction = 'Retire' }
        Invoke-WebJob -JobPath $path -HistoryRoot $root -ConfigPath $script:Valid -ScriptRoot $script:Scripts -TokenProvider $script:FakeToken -ScriptRunner $script:Offline
        $job = script:Read-Job $path
        $job['status'] | Should -Be 'succeeded'
        $script:Calls[0].Parameters['Mode'] | Should -Be 'Full'
        $script:Calls[0].Parameters['DeviceAction'] | Should -Be 'Retire'
        $job['result']['planId'] | Should -BeLike 'dev-reset-plan-full-*'
    }
    It 'refuses Wipe for devices in a reset preview' {
        $root = Join-Path $TestDrive 'wipe'
        $path = script:New-JobFile -Root $root -Action 'plan-reset' -Options @{ deviceAction = 'Wipe' }
        Invoke-WebJob -JobPath $path -HistoryRoot $root -ConfigPath $script:Valid -ScriptRoot $script:Scripts -TokenProvider $script:FakeToken -ScriptRunner $script:Offline
        (script:Read-Job $path)['status'] | Should -Be 'failed'
        $script:Calls.Count | Should -Be 0
    }
    It 'stops at the next step when the job was cancelled' {
        $root = Join-Path $TestDrive 'cancel'
        $path = script:New-JobFile -Root $root -Action drift
        $null = New-Item -ItemType File -Path (Join-Path $root 'jobs' 'job-20261107-120000-abc123.cancel')
        Invoke-WebJob -JobPath $path -HistoryRoot $root -ConfigPath $script:Valid -ScriptRoot $script:Scripts -TokenProvider $script:FakeToken -ScriptRunner $script:Offline
        $job = script:Read-Job $path
        $job['status'] | Should -Be 'cancelled'
        @($job['steps'].status | Select-Object -Unique) | Should -Be @('skipped')
        $script:Calls.Count | Should -Be 0
        $script:Signed.Count | Should -Be 0
    }
    It 'runs the setup check with its scope and signs in nowhere itself (issue #18)' {
        $root = Join-Path $TestDrive 'setup'
        $path = script:New-JobFile -Root $root -Action 'setup-check' -Options @{ scope = 'Config' }
        Invoke-WebJob -JobPath $path -HistoryRoot $root -ConfigPath $script:Valid -ScriptRoot $script:Scripts -TokenProvider $script:FakeToken -ScriptRunner $script:Offline
        $job = script:Read-Job $path
        $job['status'] | Should -Be 'succeeded' -Because $job['message']
        $job['result']['reportId'] | Should -BeLike 'setup-check-*'
        $job['result']['exitCode'] | Should -BeIn 0, 1, 2, 3
        $script:Calls[0].Script | Should -Be 'Invoke-SetupCheck.ps1'
        $script:Calls[0].Parameters['Scope'] | Should -Be 'Config'
        $script:Signed.Count | Should -Be 0
    }
    It 'exports the desired state signed in to Prod only (issue #27)' {
        $root = Join-Path $TestDrive 'export'
        $repo = Join-Path $TestDrive 'export-repo'
        $null = New-Item -ItemType Directory -Path $repo -Force
        & git -C $repo init --quiet 2>&1 | Out-Null
        & git -C $repo -c user.name=t -c user.email=t@localhost commit --quiet --allow-empty -m init 2>&1 | Out-Null
        $cfgPath = Join-Path $TestDrive 'export-config.psd1'
        (Get-Content $script:Valid -Raw) -replace '\}\s*$', "    ConfigRepository = '$($repo -replace "'", "''")'`n}" | Set-Content $cfgPath
        $path = script:New-JobFile -Root $root -Action 'export-desired'
        Invoke-WebJob -JobPath $path -HistoryRoot $root -ConfigPath $cfgPath -ScriptRoot $script:Scripts -TokenProvider $script:FakeToken -ScriptRunner $script:Offline
        $job = script:Read-Job $path
        $job['status'] | Should -Be 'succeeded' -Because $job['message']
        $job['result']['reportId'] | Should -BeLike 'desired-export-*'
        @($script:Signed) | Should -Be @('Prod')
        $script:Calls[0].Script | Should -Be 'Export-DesiredState.ps1'
        Test-Path (Join-Path $repo 'desired') | Should -BeTrue
    }
    It 'reports an unreadable config through the setup check instead of failing the job' {
        $root = Join-Path $TestDrive 'setup-noconfig'
        $path = script:New-JobFile -Root $root -Action 'setup-check' -Options @{ scope = 'Config' }
        Invoke-WebJob -JobPath $path -HistoryRoot $root -ConfigPath (Join-Path $TestDrive 'nope.psd1') -ScriptRoot $script:Scripts -ScriptRunner $script:Offline
        $job = script:Read-Job $path
        $job['status'] | Should -Be 'succeeded' -Because $job['message']
        $job['result']['exitCode'] | Should -Be 2
        $check = Get-Content (Join-Path $root 'reports' "$($job['result']['reportId']).json") -Raw | ConvertFrom-Json
        ($check.Checks | Where-Object Id -eq 'config-readable').Status | Should -Be 'red'
    }
    It 'reports a failed sign-in without running the script' {
        $root = Join-Path $TestDrive 'signin'
        $path = script:New-JobFile -Root $root -Action drift
        Invoke-WebJob -JobPath $path -HistoryRoot $root -ConfigPath $script:Valid -ScriptRoot $script:Scripts -TokenProvider { throw 'AADSTS700027: certificate not registered' } -ScriptRunner $script:Offline
        $job = script:Read-Job $path
        $job['status'] | Should -Be 'failed'
        $job['message'] | Should -BeLike 'Sign-in failed: AADSTS700027*'
        ($job['steps'] | Where-Object key -eq 'signin').status | Should -Be 'failed'
        ($job['steps'] | Where-Object key -eq 'run').status | Should -Be 'skipped'
        $script:Calls.Count | Should -Be 0
    }
    It 'runs only a queued job' {
        $root = Join-Path $TestDrive 'twice'
        $path = script:New-JobFile -Root $root -Action drift
        Invoke-WebJob -JobPath $path -HistoryRoot $root -ConfigPath $script:Valid -ScriptRoot $script:Scripts -TokenProvider $script:FakeToken -ScriptRunner $script:Offline
        { Invoke-WebJob -JobPath $path -HistoryRoot $root -ConfigPath $script:Valid -ScriptRoot $script:Scripts -TokenProvider $script:FakeToken -ScriptRunner $script:Offline } | Should -Throw '*not queued*'
    }
}

Describe 'Invoke-WebJob: apply needs the confirmation' {
    BeforeAll {
        # A plan file as the preview writes it.
        $script:PlanRoot = Join-Path $TestDrive 'applyplans'
        $null = & (Join-Path $script:Scripts 'Invoke-ApplyDev.ps1') -ConfigPath $script:Valid -SourceSnapshotPath $script:Prod -TargetSnapshotPath $script:Dev -LicencePath $script:Lic -HistoryRoot $script:PlanRoot -Area Intune 6>$null
        $null = & (Join-Path $script:Scripts 'Invoke-DevReset.ps1') -ConfigPath $script:Valid -Mode Full -InventoryPath $script:Inv -HistoryRoot $script:PlanRoot -DeviceAction Retire 6>$null
        $script:ApplyFile = Get-ChildItem (Join-Path $script:PlanRoot 'reports') -Filter 'apply-plan-*.json' | Select-Object -First 1
        $script:ResetFile = Get-ChildItem (Join-Path $script:PlanRoot 'reports') -Filter 'dev-reset-plan-full-*.json' | Select-Object -First 1
        $script:ApplyHash = (Get-Content $script:ApplyFile.FullName -Raw | ConvertFrom-Json).PlanHash
        $script:ResetHash = (Get-Content $script:ResetFile.FullName -Raw | ConvertFrom-Json).PlanHash
    }
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $script:Signed = [System.Collections.Generic.List[string]]::new()
        $script:Record = { param([string]$Path, [System.Collections.IDictionary]$Parameters, [string]$Log) $script:Calls.Add([pscustomobject]@{ Script = (Split-Path -Leaf $Path); Parameters = $Parameters }); 0 }
    }
    It 'applies with the confirmed hash and the area of the plan' {
        $path = script:New-JobFile -Root $script:PlanRoot -Id 'job-20261107-120001-aaaaaa' -Action apply -Options @{ planId = $script:ApplyFile.BaseName; planKind = 'apply' } -Confirm @{ PlanHash = $script:ApplyHash }
        Invoke-WebJob -JobPath $path -HistoryRoot $script:PlanRoot -ConfigPath $script:Valid -ScriptRoot $script:Scripts -TokenProvider $script:FakeToken -ScriptRunner $script:Record
        (script:Read-Job $path)['status'] | Should -Be 'succeeded'
        $c = $script:Calls[0]
        $c.Script | Should -Be 'Invoke-ApplyDev.ps1'
        $c.Parameters['Apply'] | Should -BeTrue
        $c.Parameters['ConfirmPlanHash'] | Should -Be $script:ApplyHash
        $c.Parameters['Area'] | Should -Be 'Intune'
        $c.Parameters['ProdToken'] | Should -BeOfType [securestring]
    }
    It 'refuses another hash and writes a refused audit line with the Actor' {
        $path = script:New-JobFile -Root $script:PlanRoot -Id 'job-20261107-120002-bbbbbb' -Action apply -Options @{ planId = $script:ApplyFile.BaseName; planKind = 'apply' } -Confirm @{ PlanHash = ('0' * 64) }
        Invoke-WebJob -JobPath $path -HistoryRoot $script:PlanRoot -ConfigPath $script:Valid -ScriptRoot $script:Scripts -TokenProvider $script:FakeToken -ScriptRunner $script:Record
        $job = script:Read-Job $path
        $job['status'] | Should -Be 'failed'
        $job['message'] | Should -BeLike 'Refused:*hash*'
        $script:Calls.Count | Should -Be 0
        $script:Signed.Count | Should -Be 0
        $last = Get-Content (Join-Path $script:PlanRoot 'audit.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
        $last.Mode | Should -Be 'refused'
        $last.Actor | Should -Be 'Test Person'
    }
    It 'refuses a plan id of another kind' {
        $path = script:New-JobFile -Root $script:PlanRoot -Id 'job-20261107-120003-cccccc' -Action apply -Options @{ planId = $script:ResetFile.BaseName; planKind = 'apply' } -Confirm @{ PlanHash = $script:ResetHash }
        Invoke-WebJob -JobPath $path -HistoryRoot $script:PlanRoot -ConfigPath $script:Valid -ScriptRoot $script:Scripts -TokenProvider $script:FakeToken -ScriptRunner $script:Record
        (script:Read-Job $path)['status'] | Should -Be 'failed'
        $script:Calls.Count | Should -Be 0
    }
    It 'resets only with the hash of the typed Dev tenant ID, and passes mode, device action and the config tenant' {
        $path = script:New-JobFile -Root $script:PlanRoot -Id 'job-20261107-120004-dddddd' -Action apply -Options @{ planId = $script:ResetFile.BaseName; planKind = 'reset' } -Confirm @{ PlanHash = $script:ResetHash; TenantHash = (Get-TenantIdHash -TenantId 'TENANT-DEV-0001 ') }
        Invoke-WebJob -JobPath $path -HistoryRoot $script:PlanRoot -ConfigPath $script:Valid -ScriptRoot $script:Scripts -TokenProvider $script:FakeToken -ScriptRunner $script:Record
        (script:Read-Job $path)['status'] | Should -Be 'succeeded'
        $c = $script:Calls[0]
        $c.Script | Should -Be 'Invoke-DevReset.ps1'
        $c.Parameters['Mode'] | Should -Be 'Full'
        $c.Parameters['DeviceAction'] | Should -Be 'Retire'
        $c.Parameters['ConfirmTenant'] | Should -Be 'tenant-dev-0001'
    }
    It 'refuses a reset when the typed tenant is not the Dev tenant' {
        $path = script:New-JobFile -Root $script:PlanRoot -Id 'job-20261107-120005-eeeeee' -Action apply -Options @{ planId = $script:ResetFile.BaseName; planKind = 'reset' } -Confirm @{ PlanHash = $script:ResetHash; TenantHash = (Get-TenantIdHash -TenantId 'tenant-prod-0001') }
        Invoke-WebJob -JobPath $path -HistoryRoot $script:PlanRoot -ConfigPath $script:Valid -ScriptRoot $script:Scripts -TokenProvider $script:FakeToken -ScriptRunner $script:Record
        $job = script:Read-Job $path
        $job['status'] | Should -Be 'failed'
        $job['message'] | Should -BeLike '*typed tenant*'
        $script:Calls.Count | Should -Be 0
    }
    It 'refuses a reset without the second confirmation' {
        $path = script:New-JobFile -Root $script:PlanRoot -Id 'job-20261107-120006-ffffff' -Action apply -Options @{ planId = $script:ResetFile.BaseName; planKind = 'reset' } -Confirm @{ PlanHash = $script:ResetHash }
        Invoke-WebJob -JobPath $path -HistoryRoot $script:PlanRoot -ConfigPath $script:Valid -ScriptRoot $script:Scripts -TokenProvider $script:FakeToken -ScriptRunner $script:Record
        (script:Read-Job $path)['status'] | Should -Be 'failed'
        $script:Calls.Count | Should -Be 0
    }
    It 'marks the job failed when the script ends with an error code' {
        $path = script:New-JobFile -Root $script:PlanRoot -Id 'job-20261107-120007-gggggg' -Action apply -Options @{ planId = $script:ApplyFile.BaseName; planKind = 'apply' } -Confirm @{ PlanHash = $script:ApplyHash }
        Invoke-WebJob -JobPath $path -HistoryRoot $script:PlanRoot -ConfigPath $script:Valid -ScriptRoot $script:Scripts -TokenProvider $script:FakeToken -ScriptRunner { 1 }
        $job = script:Read-Job $path
        $job['status'] | Should -Be 'failed'
        $job['result']['exitCode'] | Should -Be 1
        ($job['steps'] | Where-Object key -eq 'run').status | Should -Be 'failed'
    }
    It 'every job file it writes follows the schema' {
        . (Join-Path $PSScriptRoot 'contract' 'ContractHelpers.ps1')
        $work = Join-Path $TestDrive 'schema'; $null = New-Item -ItemType Directory -Path $work -Force
        foreach ($f in Get-ChildItem (Join-Path $script:PlanRoot 'jobs') -Filter '*.json') {
            Test-ContractJson -Json (Get-Content $f.FullName -Raw) -Definition 'JobFile' -Folder $work | Should -BeNullOrEmpty -Because $f.Name
        }
    }
}

Describe 'Get-WebJobGraphToken (Az.Accounts, ADR 0013)' {
    BeforeAll {
        # Stand-ins so the Az cmdlets can be mocked where Az.Accounts is not installed (CI, Linux). Nothing signs in.
        $stubs = @{
            'Connect-AzAccount'    = { param([switch]$ServicePrincipal, $Tenant, $ApplicationId, $CertificateThumbprint, $Scope, [switch]$SkipContextPopulation) }
            'Get-AzAccessToken'    = { param($ResourceUrl, $TenantId) }
            'Disconnect-AzAccount' = { param($Scope) }
        }
        foreach ($name in $stubs.Keys) {
            if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { New-Item -Path "Function:\global:$name" -Value $stubs[$name] -Force | Out-Null }
        }
    }
    BeforeEach {
        Mock -ModuleName M365Cloning Connect-AzAccount { }
        Mock -ModuleName M365Cloning Disconnect-AzAccount { }
    }
    It 'signs in with the certificate (process scope), asks for a Graph token and signs out' {
        Mock -ModuleName M365Cloning Get-AzAccessToken { [pscustomobject]@{ Token = (ConvertTo-SecureString 'fake-token' -AsPlainText -Force) } }
        $token = InModuleScope M365Cloning { Get-WebJobGraphToken -TenantId 'tenant-dev-0001' -ClientId 'client-dev-0001' -CertThumbprint 'thumb-dev-0001' }
        $token | Should -BeOfType [securestring]
        [System.Net.NetworkCredential]::new('', $token).Password | Should -Be 'fake-token'
        Should -Invoke -ModuleName M365Cloning Connect-AzAccount -Times 1 -Exactly -ParameterFilter {
            $ServicePrincipal -and $Tenant -eq 'tenant-dev-0001' -and $ApplicationId -eq 'client-dev-0001' -and $CertificateThumbprint -eq 'thumb-dev-0001' -and $Scope -eq 'Process'
        }
        Should -Invoke -ModuleName M365Cloning Get-AzAccessToken -Times 1 -Exactly -ParameterFilter { $ResourceUrl -eq 'https://graph.microsoft.com' }
        Should -Invoke -ModuleName M365Cloning Disconnect-AzAccount -Times 1 -Exactly
    }
    It 'accepts the plain string token of older Az.Accounts versions' {
        Mock -ModuleName M365Cloning Get-AzAccessToken { [pscustomobject]@{ Token = 'plain-token' } }
        $token = InModuleScope M365Cloning { Get-WebJobGraphToken -TenantId 't' -ClientId 'c' -CertThumbprint 'x' }
        [System.Net.NetworkCredential]::new('', $token).Password | Should -Be 'plain-token'
    }
    It 'names the cause of a refused sign-in and still signs out' {
        Mock -ModuleName M365Cloning Connect-AzAccount { throw 'AADSTS700027: Client assertion contains an invalid signature.' }
        { InModuleScope M365Cloning { Get-WebJobGraphToken -TenantId 't' -ClientId 'c' -CertThumbprint 'x' } } | Should -Throw 'Sign-in of the app registration failed: AADSTS700027*'
        Should -Invoke -ModuleName M365Cloning Disconnect-AzAccount -Times 1 -Exactly
    }
    It 'refuses placeholders of the example config without signing in' {
        { InModuleScope M365Cloning { Get-WebJobGraphToken -TenantId '<dev-tenant-guid>' -ClientId 'c' -CertThumbprint 'x' } } | Should -Throw '*no TenantId*'
        { InModuleScope M365Cloning { Get-WebJobGraphToken -TenantId 't' -ClientId 'c' -CertThumbprint '<certificate-thumbprint>' } } | Should -Throw '*no CertThumbprint*'
        Should -Invoke -ModuleName M365Cloning Connect-AzAccount -Times 0 -Exactly
    }
    It 'fails when the answer has no token' {
        Mock -ModuleName M365Cloning Get-AzAccessToken { [pscustomobject]@{ Token = '' } }
        { InModuleScope M365Cloning { Get-WebJobGraphToken -TenantId 't' -ClientId 'c' -CertThumbprint 'x' } } | Should -Throw '*no access token*'
    }
    It 'is what the job runner uses without a TokenProvider, once per tenant the action reads' {
        Mock -ModuleName M365Cloning Get-WebJobGraphToken { ConvertTo-SecureString "fake-$TenantId" -AsPlainText -Force }
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $root = Join-Path $TestDrive 'azsignin'
        $path = script:New-JobFile -Root $root -Action 'plan-users'
        Invoke-WebJob -JobPath $path -HistoryRoot $root -ConfigPath $script:Valid -ScriptRoot $script:Scripts -ScriptRunner { param($Path, $Parameters, $Log) $script:Calls.Add($Parameters); 0 }
        Should -Invoke -ModuleName M365Cloning Get-WebJobGraphToken -Times 1 -Exactly -ParameterFilter { $TenantId -eq 'tenant-dev-0001' -and $ClientId -eq 'client-dev-0001' -and $CertThumbprint -eq 'thumb-dev-0001' }
        [System.Net.NetworkCredential]::new('', $script:Calls[0]['DevToken']).Password | Should -Be 'fake-tenant-dev-0001'
        $script:Calls[0].Contains('ProdToken') | Should -BeFalse
    }
    It 'no own token code is left in the module (issue #70)' {
        $src = Join-Path $PSScriptRoot '..' 'src'
        Get-ChildItem $src -Recurse -Filter '*.ps1' | Select-String -Pattern 'client_assertion|oauth2/v2.0/token|SignData' | Should -BeNullOrEmpty
    }
}
