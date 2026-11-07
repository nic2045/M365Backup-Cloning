BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'M365Cloning.psd1') -Force
    $script:Base = "Prod=@{TenantId='tenant-prod-0001';ClientId='c';CertThumbprint='x'}; Dev=@{TenantId='tenant-dev-0001';ClientId='client-dev-0001';CertThumbprint='x';AllowReset=`$true}; BreakGlass=@('bg-user@dev.example'); ProtectedAccounts=@('dev.admin@dev.example'); ServiceAccounts=@('svc.sync@dev.example'); DevUsers=@(@{Type='TestUser';Id='test.internal@dev.example';Persona='Internals'})"

    function script:New-ConfigFile([string]$Text) {
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.psd1')
        Set-Content -LiteralPath $path -Value "@{ $Text }"
        $path
    }
    function script:New-Config([string]$Text = $script:Base) { Import-M365CloningConfig -Path (script:New-ConfigFile $Text) }
    function script:New-Inventory {
        @{
            ProdGlobalAdmins = @(
                @{ id = 'prod-admin-0001'; userPrincipalName = 'admin.one@prod.example'; mail = 'admin.one@prod.example' }
                @{ id = 'prod-admin-0002'; userPrincipalName = 'admin.two@prod.example'; mail = 'admin.two@prod.example' }
                @{ id = 'prod-bg-0001'; userPrincipalName = 'bg-user@dev.example'; mail = '' }
            )
            ProdReadError    = ''
            Dev              = @{
                Users                     = @(
                    @{ id = 'user-admin-0001'; userPrincipalName = 'dev.admin@dev.example'; mail = ''; userType = 'Member'; onPremisesSyncEnabled = $null }
                    @{ id = 'user-bg-0001'; userPrincipalName = 'bg-user@dev.example'; mail = ''; userType = 'Member' }
                    @{ id = 'user-svc-0001'; userPrincipalName = 'svc.sync@dev.example'; mail = ''; userType = 'Member' }
                    @{ id = 'user-test-0001'; userPrincipalName = 'test.internal@dev.example'; mail = ''; userType = 'Member' }
                    @{ id = 'user-other-0001'; userPrincipalName = 'someone@dev.example'; mail = ''; userType = 'Member' }
                    @{ id = 'user-synced-0001'; userPrincipalName = 'synced@dev.example'; mail = ''; userType = 'Member'; onPremisesSyncEnabled = $true }
                    @{ id = 'guest-admin-0001'; userPrincipalName = 'admin.one_prod.example#EXT#@dev.example'; mail = 'admin.one@prod.example'; userType = 'Guest' }
                    @{ id = 'guest-other-0001'; userPrincipalName = 'partner_x.example#EXT#@dev.example'; mail = 'partner@x.example'; userType = 'Guest' }
                )
                Groups                    = @(
                    @{ id = 'group-bg-0001'; displayName = 'CA-BreakglassAccounts'; groupTypes = @() }
                    @{ id = 'group-admins-0001'; displayName = 'CA-Persona-Admins'; groupTypes = @() }
                    @{ id = 'group-old-0001'; displayName = 'Old Test Group'; groupTypes = @() }
                    @{ id = 'group-prod-0001'; displayName = 'Pilot Ring'; groupTypes = @() }
                    @{ id = 'group-m365-0001'; displayName = 'Team Site'; groupTypes = @('Unified') }
                    @{ id = 'group-role-0001'; displayName = 'Role Group'; groupTypes = @(); isAssignableToRole = $true }
                    @{ id = 'group-sync-0001'; displayName = 'Synced Group'; groupTypes = @(); onPremisesSyncEnabled = $true }
                )
                ConditionalAccessPolicies = @(
                    @{ id = 'ca-0001'; displayName = 'CA001-Global-Base'; state = 'enabled' }
                    @{ id = 'ca-0002'; displayName = 'CA999-Dev-Only'; state = 'enabled' }
                )
                DeviceConfigurations      = @(@{ id = 'dc-0001'; displayName = 'Win - Base' }, @{ id = 'dc-0002'; displayName = 'Win - Dev Trial' })
                DeviceCompliancePolicies  = @(@{ id = 'cp-0001'; displayName = 'Win - Compliance' })
                ConfigurationPolicies     = @(@{ id = 'sc-0001'; name = 'SC - Defender' })
                Intents                   = @()
                AssignmentFilters         = @(@{ id = 'flt-0001'; displayName = 'Filter Dev Only' })
                ManagedDevices            = @(@{ id = 'dev-0001'; deviceName = 'VM-TEST-01'; operatingSystem = 'Windows' })
                CrossTenantPartners       = @(@{ tenantId = 'tenant-prod-0001' })
                ToolkitServicePrincipals  = @(@{ id = 'sp-0001'; appId = 'client-dev-0001'; displayName = 'Toolkit Dev' })
            }
        }
    }
    # Prod (Source) and Dev (Target) differ: these names exist only in Dev.
    function script:New-Comparison {
        [pscustomobject]@{
            Types = @(
                [pscustomobject]@{ ResourceType = 'microsoft.entra.conditionalaccesspolicy'; Added = @(); Removed = @('CA999-Dev-Only'); Changed = @(); Unchanged = 1 }
                [pscustomobject]@{ ResourceType = 'microsoft.intune.deviceconfigurationpolicywindows10'; Added = @(); Removed = @('Win - Dev Trial'); Changed = @(); Unchanged = 1 }
                [pscustomobject]@{ ResourceType = 'microsoft.intune.deviceandappmanagementassignmentfilter'; Added = @(); Removed = @('Filter Dev Only'); Changed = @(); Unchanged = 0 }
                [pscustomobject]@{ ResourceType = 'microsoft.entra.group'; Added = @(); Removed = @('Old Test Group', 'CA-BreakglassAccounts'); Changed = @(); Unchanged = 1 }
            )
        }
    }
    function script:Deletes($Plan) { @($Plan['Actions'] | Where-Object { $_['Operation'] -eq 'Delete' -and $_['Status'] -eq 'planned' } | ForEach-Object { "$($_['ResourceType'])|$($_['Name'])" }) }
    function script:Read-Audit([string]$Root) {
        $path = Join-Path $Root 'audit.jsonl'
        if (Test-Path $path) { @(Get-Content -LiteralPath $path | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
    }
    function script:New-Writer([string]$FailOn = '') {
        $writes = [System.Collections.Generic.List[object]]::new()
        $script:Writes = $writes
        $fail = $FailOn
        {
            param($Method, $Uri, $Body, $TenantId, $Config)
            $writes.Add(@{ Method = $Method; Uri = $Uri; TenantId = $TenantId })
            if ($fail -and $Uri -like "*$fail") { throw 'simulated failure' }
            $null
        }.GetNewClosure()
    }
}

Describe 'Reset config' {
    It 'loads AllowReset and ServiceAccounts' {
        $c = script:New-Config
        $c.Dev.AllowReset | Should -BeTrue
        $c.ServiceAccounts | Should -Contain 'svc.sync@dev.example'
    }
    It 'rejects AllowReset that is not a boolean' {
        { script:New-Config ($script:Base -replace 'AllowReset=\$true', "AllowReset='yes'") } | Should -Throw '*AllowReset*'
    }
}

Describe 'Reset protection list' {
    BeforeEach { $script:Config = script:New-Config }
    It 'lists every source with its origin' {
        $plan = New-DevResetPlan -Config $script:Config -Inventory (script:New-Inventory) -Mode Full
        $sources = @($plan['Protected'] | ForEach-Object { $_['Source'] } | Sort-Object -Unique)
        foreach ($s in 'config: ProtectedAccounts', 'config: BreakGlass', 'config: ServiceAccounts', 'Prod: Global Administrator',
            'Dev: B2B guest of a Prod Global Administrator', 'Dev: guest (guests are never deleted)', 'Dev: app registration of this toolkit',
            'Dev: cross-tenant access partner and cross-tenant sync (kept)') {
            $sources | Should -Contain $s
        }
        @($plan['Protected'] | Where-Object { $_['Kind'] -eq 'Group' -and $_['Name'] -eq 'CA-BreakglassAccounts' }).Count | Should -Be 1
    }
    It 'does not take the break-glass account of Prod into the Prod admin list' {
        $plan = New-DevResetPlan -Config $script:Config -Inventory (script:New-Inventory) -Mode Full
        @($plan['Protected'] | Where-Object { $_['Source'] -eq 'Prod: Global Administrator' -and $_['Name'] -eq 'bg-user@dev.example' }).Count | Should -Be 0
    }
    It 'lists a Prod admin without a guest in Dev as Invite (info), never as a write' {
        $plan = New-DevResetPlan -Config $script:Config -Inventory (script:New-Inventory) -Mode Full
        $inv = @($plan['Actions'] | Where-Object { $_['Operation'] -eq 'Invite' })
        $inv.Count | Should -Be 1
        $inv[0]['Name'] | Should -Be 'admin.two@prod.example'
        $inv[0]['Status'] | Should -Be 'info'
    }
    It 'refuses when Prod could not be read' {
        $inv = script:New-Inventory; $inv.ProdGlobalAdmins = $null; $inv.ProdReadError = '403 Forbidden'
        { New-DevResetPlan -Config $script:Config -Inventory $inv -Mode Full } | Should -Throw '*could not be read*403*'
    }
    It 'refuses when Prod returns no Global Administrator' {
        $inv = script:New-Inventory; $inv.ProdGlobalAdmins = @()
        { New-DevResetPlan -Config $script:Config -Inventory $inv -Mode Full } | Should -Throw '*no Global Administrator*'
    }
    It 'refuses when the config protects no account' {
        $c = script:New-Config ($script:Base -replace "BreakGlass=@\('bg-user@dev.example'\); ProtectedAccounts=@\('dev.admin@dev.example'\); ", '')
        { New-DevResetPlan -Config $c -Inventory (script:New-Inventory) -Mode Full } | Should -Throw '*protects no account*'
    }
    It 'refuses when no protected account exists in Dev (lockout)' {
        $inv = script:New-Inventory
        $inv.Dev.Users = @($inv.Dev.Users | Where-Object { $_.id -in 'user-other-0001', 'guest-other-0001' })
        { New-DevResetPlan -Config $script:Config -Inventory $inv -Mode Full } | Should -Throw '*none of the protected accounts*'
    }
    It 'refuses a plan for the Prod tenant' {
        $c = script:New-Config; $c.Dev.TenantId = 'tenant-prod-0001'
        { New-DevResetPlan -Config $c -Inventory (script:New-Inventory) -Mode Full } | Should -Throw '*Prod tenant ID*'
    }
}

Describe 'Reset plan, mode Full' {
    BeforeAll {
        $script:Config = script:New-Config
        $script:Plan = New-DevResetPlan -Config $script:Config -Inventory (script:New-Inventory) -Mode Full
        $script:Del = script:Deletes $script:Plan
    }
    It 'deletes the whole reset scope' {
        foreach ($d in 'ConditionalAccessPolicy|CA001-Global-Base', 'ConditionalAccessPolicy|CA999-Dev-Only', 'DeviceConfiguration|Win - Base',
            'DeviceConfiguration|Win - Dev Trial', 'DeviceCompliancePolicy|Win - Compliance', 'ConfigurationPolicy|SC - Defender',
            'AssignmentFilter|Filter Dev Only', 'Group|Old Test Group', 'Group|Pilot Ring', 'User|test.internal@dev.example') {
            $script:Del | Should -Contain $d
        }
    }
    It 'never plans a protected object' {
        foreach ($d in 'User|dev.admin@dev.example', 'User|bg-user@dev.example', 'User|svc.sync@dev.example', 'Group|CA-BreakglassAccounts', 'Group|CA-Persona-Admins') {
            $script:Del | Should -Not -Contain $d
        }
        @($script:Plan['Actions'] | Where-Object { $_['Name'] -like '*#EXT#*' }).Count | Should -Be 0
    }
    It 'never deletes devices, other members, synced objects, Microsoft 365 or role groups' {
        $script:Del | Should -Not -Contain 'ManagedDevice|VM-TEST-01'
        @($script:Plan['Actions'] | Where-Object { $_['ResourceType'] -eq 'ManagedDevice' -and $_['Operation'] -eq 'Keep' -and $_['Status'] -eq 'skipped' }).Count | Should -Be 1
        foreach ($d in 'User|someone@dev.example', 'User|synced@dev.example', 'Group|Team Site', 'Group|Role Group', 'Group|Synced Group') {
            $script:Del | Should -Not -Contain $d
        }
    }
    It 'orders CA, Intune policies, filters, groups, users' {
        $order = @($script:Plan['Actions'] | Where-Object { $_['Operation'] -eq 'Delete' } | ForEach-Object { $_['ResourceType'] })
        $first = @{}; for ($i = $order.Count - 1; $i -ge 0; $i--) { $first[$order[$i]] = $i }
        $last = @{}; for ($i = 0; $i -lt $order.Count; $i++) { $last[$order[$i]] = $i }
        $last['ConditionalAccessPolicy'] | Should -BeLessThan $first['DeviceConfiguration']
        $last['ConfigurationPolicy'] | Should -BeLessThan $first['AssignmentFilter']
        $last['AssignmentFilter'] | Should -BeLessThan $first['Group']
        $last['Group'] | Should -BeLessThan $first['User']
    }
    It 'has a stable hash' {
        Get-ApplyPlanHash -Plan $script:Plan | Should -Be (Get-ApplyPlanHash -Plan (New-DevResetPlan -Config $script:Config -Inventory (script:New-Inventory) -Mode Full))
    }
    It 'shows the protection list in the preview' {
        $md = ConvertTo-ApplyPlanMarkdown -Plan $script:Plan -PlanHash 'h'
        $md | Should -Match 'Protected \(never deleted or changed\)'
        $md | Should -Match 'Prod: Global Administrator'
    }
}

Describe 'Reset plan, mode Align' {
    BeforeAll {
        $script:Config = script:New-Config
        $script:Plan = New-DevResetPlan -Config $script:Config -Inventory (script:New-Inventory) -Mode Align -Comparison (script:New-Comparison)
        $script:Del = script:Deletes $script:Plan
    }
    It 'needs the drift report' {
        { New-DevResetPlan -Config $script:Config -Inventory (script:New-Inventory) -Mode Align } | Should -Throw '*drift report*'
    }
    It 'deletes only what exists in Dev and not in Prod' {
        @($script:Del | Sort-Object) | Should -Be @('AssignmentFilter|Filter Dev Only', 'ConditionalAccessPolicy|CA999-Dev-Only', 'DeviceConfiguration|Win - Dev Trial', 'Group|Old Test Group')
    }
    It 'never deletes the protection list, even when the report calls it Dev-only' {
        $script:Del | Should -Not -Contain 'Group|CA-BreakglassAccounts'
    }
    It 'keeps test users' {
        $script:Del | Should -Not -Contain 'User|test.internal@dev.example'
    }
}

Describe 'Invoke-DevResetPlan' {
    BeforeEach {
        $script:Config = script:New-Config
        $script:Plan = New-DevResetPlan -Config $script:Config -Inventory (script:New-Inventory) -Mode Full
        $script:Hash = Get-ApplyPlanHash -Plan $script:Plan
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }
    It 'refuses without AllowReset' {
        $script:Config['Dev']['AllowReset'] = $false
        $w = script:New-Writer
        { Invoke-DevResetPlan -Plan $script:Plan -Config $script:Config -ConfirmPlanHash $script:Hash -ConfirmTenant 'tenant-dev-0001' -GraphWriter $w -HistoryRoot $script:Root } | Should -Throw '*AllowReset*'
        $script:Writes.Count | Should -Be 0
    }
    It 'refuses a wrong plan hash' {
        $w = script:New-Writer
        { Invoke-DevResetPlan -Plan $script:Plan -Config $script:Config -ConfirmPlanHash ('0' * 64) -ConfirmTenant 'tenant-dev-0001' -GraphWriter $w -HistoryRoot $script:Root } | Should -Throw '*hash*'
        $script:Writes.Count | Should -Be 0
    }
    It 'refuses without the second confirmation' {
        $w = script:New-Writer
        { Invoke-DevResetPlan -Plan $script:Plan -Config $script:Config -ConfirmPlanHash $script:Hash -ConfirmTenant '' -GraphWriter $w -HistoryRoot $script:Root } | Should -Throw '*second confirmation*'
        { Invoke-DevResetPlan -Plan $script:Plan -Config $script:Config -ConfirmPlanHash $script:Hash -ConfirmTenant 'tenant-prod-0001' -GraphWriter $w -HistoryRoot $script:Root } | Should -Throw '*second confirmation*'
        $script:Writes.Count | Should -Be 0
        (script:Read-Audit $script:Root | Where-Object { $_.Mode -eq 'refused' }).Count | Should -Be 2
    }
    It 'refuses a plan whose delete hits the protection list' {
        $bad = New-DevResetPlan -Config $script:Config -Inventory (script:New-Inventory) -Mode Full
        $bad['Actions'] = [object[]]@($bad['Actions']) + @([ordered]@{ ResourceType = 'User'; Name = 'dev.admin@dev.example'; Operation = 'Delete'; Status = 'planned'; Reason = 'x'; DscResource = ''; Differences = @(); Properties = [ordered]@{ Id = 'user-admin-0001'; Kind = 'User' } })
        $w = script:New-Writer
        { Invoke-DevResetPlan -Plan $bad -Config $script:Config -ConfirmPlanHash (Get-ApplyPlanHash -Plan $bad) -ConfirmTenant 'tenant-dev-0001' -GraphWriter $w -HistoryRoot $script:Root } | Should -Throw '*protection list*'
        $script:Writes.Count | Should -Be 0
    }
    It 'switches CA off, then deletes, in the planned order, Dev only' {
        $w = script:New-Writer
        $r = Invoke-DevResetPlan -Plan $script:Plan -Config $script:Config -ConfirmPlanHash $script:Hash -ConfirmTenant 'TENANT-DEV-0001' -GraphWriter $w -HistoryRoot $script:Root
        $r.Failed | Should -Be 0
        $r.Deleted | Should -Be $script:Plan['Summary']['Planned']
        $script:Writes[0].Method | Should -Be 'PATCH'
        $script:Writes[0].Uri | Should -BeLike '*/v1.0/identity/conditionalAccess/policies/ca-0001'
        $script:Writes[1].Method | Should -Be 'DELETE'
        @($script:Writes | Where-Object { $_.TenantId -ne 'tenant-dev-0001' }).Count | Should -Be 0
        @($script:Writes | Where-Object { $_.Uri -like '*managedDevices*' -or $_.Uri -like '*deletedItems*' }).Count | Should -Be 0
        $lastGroup = [array]::FindLastIndex([object[]]$script:Writes.ToArray(), [Predicate[object]] { param($x) $x.Uri -like '*/groups/*' })
        $firstUser = [array]::FindIndex([object[]]$script:Writes.ToArray(), [Predicate[object]] { param($x) $x.Uri -like '*/users/*' })
        $lastGroup | Should -BeLessThan $firstUser
    }
    It 'stops the later steps after a failure' {
        $w = script:New-Writer -FailOn 'ca-0002'
        $r = Invoke-DevResetPlan -Plan $script:Plan -Config $script:Config -ConfirmPlanHash $script:Hash -ConfirmTenant 'tenant-dev-0001' -GraphWriter $w -HistoryRoot $script:Root
        $r.Failed | Should -Be 1
        $r.NotRun | Should -BeGreaterThan 0
        @($script:Writes | Where-Object { $_.Uri -like '*/groups/*' -or $_.Uri -like '*/users/*' }).Count | Should -Be 0
    }
    It 'writes one audit line per delete, without IDs or tokens' {
        $w = script:New-Writer
        $null = Invoke-DevResetPlan -Plan $script:Plan -Config $script:Config -ConfirmPlanHash $script:Hash -ConfirmTenant 'tenant-dev-0001' -GraphWriter $w -HistoryRoot $script:Root
        $lines = @(script:Read-Audit $script:Root | Where-Object { $_.Mode -eq 'reset' })
        $lines.Count | Should -Be ($script:Plan['Summary']['Planned'] + 1)
        $text = Get-Content -LiteralPath (Join-Path $script:Root 'audit.jsonl') -Raw
        $text | Should -Not -Match 'ca-0001|user-test-0001|client-dev-0001|Bearer'
    }
}

Describe 'Reset write allow list' {
    BeforeAll { $script:Config = script:New-Config }
    It 'allows DELETE of the reset kinds and the one PATCH, Dev only' {
        InModuleScope M365Cloning -Parameters @{ C = $script:Config } {
            param($C)
            { Assert-DevResetWriteAllowed -Method DELETE -Uri 'https://graph.microsoft.com/v1.0/groups/g-1' -TenantId 'tenant-dev-0001' -Config $C } | Should -Not -Throw
            { Assert-DevResetWriteAllowed -Method DELETE -Uri 'https://graph.microsoft.com/beta/deviceManagement/assignmentFilters/f-1' -TenantId 'tenant-dev-0001' -Config $C } | Should -Not -Throw
            { Assert-DevResetWriteAllowed -Method PATCH -Uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/p-1' -Body @{ state = 'disabled' } -TenantId 'tenant-dev-0001' -Config $C } | Should -Not -Throw
        }
    }
    It 'blocks everything else' {
        InModuleScope M365Cloning -Parameters @{ C = $script:Config } {
            param($C)
            { Assert-DevResetWriteAllowed -Method DELETE -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/d-1' -TenantId 'tenant-dev-0001' -Config $C } | Should -Throw '*Blocked*'
            { Assert-DevResetWriteAllowed -Method DELETE -Uri 'https://graph.microsoft.com/v1.0/directory/deletedItems/x-1' -TenantId 'tenant-dev-0001' -Config $C } | Should -Throw '*Blocked*'
            { Assert-DevResetWriteAllowed -Method DELETE -Uri 'https://graph.microsoft.com/v1.0/applications/a-1' -TenantId 'tenant-dev-0001' -Config $C } | Should -Throw '*Blocked*'
            { Assert-DevResetWriteAllowed -Method DELETE -Uri 'https://graph.microsoft.com/v1.0/groups/g-1' -TenantId 'tenant-prod-0001' -Config $C } | Should -Throw '*Blocked*'
            { Assert-DevResetWriteAllowed -Method PATCH -Uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/p-1' -Body @{ state = 'enabled' } -TenantId 'tenant-dev-0001' -Config $C } | Should -Throw '*Blocked*'
            { Assert-DevResetWriteAllowed -Method POST -Uri 'https://graph.microsoft.com/v1.0/groups' -TenantId 'tenant-dev-0001' -Config $C } | Should -Throw '*Blocked*'
            { Assert-DevResetWriteAllowed -Method DELETE -Uri 'https://graph.microsoft.com/v1.0/groups/g-1?x=1' -TenantId 'tenant-dev-0001' -Config $C } | Should -Throw '*Blocked*'
        }
    }
}

Describe 'Invoke-DevRebuildChain' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Config = script:New-Config
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        $rootDir = $script:Root
        $calls = $script:Calls
        # Fake step scripts: plan mode writes a plan file with hash 'hash-<prefix>' and one planned entry.
        $script:Runner = {
            param($ScriptPath, [hashtable]$Arguments)
            $name = Split-Path $ScriptPath -Leaf
            $calls.Add("$name|$(if ($Arguments.ContainsKey('Apply')) { 'apply:' + $Arguments['ConfirmPlanHash'] } else { 'plan' })")
            $reports = Join-Path $rootDir 'reports'; $null = New-Item -ItemType Directory -Path $reports -Force
            $prefix = switch ($name) { 'Invoke-DevBaseline.ps1' { 'dev-baseline-plan' } 'Invoke-ApplyDev.ps1' { 'apply-plan' } 'Invoke-DevUsers.ps1' { 'dev-users-plan' } default { 'drift' } }
            if ($Arguments.ContainsKey('Apply')) { return }
            $doc = @{ PlanHash = "hash-$prefix"; Plan = @{ Summary = @{ Planned = 1 } } }
            $doc | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $reports "$prefix-$([guid]::NewGuid().ToString('N')).json")
        }.GetNewClosure()
    }
    It 'runs each step only after its own confirmation and ends with the drift report' {
        $prompt = { param($StepName, $PlanHash, $PlanPath) $PlanHash }
        $r = Invoke-DevRebuildChain -ScriptRoot '/scripts' -ConfigPath 'c.psd1' -Config $script:Config -HistoryRoot $script:Root -Runner $script:Runner -Prompt $prompt
        $r.Completed | Should -BeTrue
        @($script:Calls) | Should -Be @(
            'Invoke-DevBaseline.ps1|plan', 'Invoke-DevBaseline.ps1|apply:hash-dev-baseline-plan',
            'Invoke-ApplyDev.ps1|plan', 'Invoke-ApplyDev.ps1|apply:hash-apply-plan',
            'Invoke-DevUsers.ps1|plan', 'Invoke-DevUsers.ps1|apply:hash-dev-users-plan',
            'Get-DriftReport.ps1|plan')
    }
    It 'stops when a step is not confirmed' {
        $prompt = { param($StepName, $PlanHash, $PlanPath) if ($StepName -eq 'Base state') { $PlanHash } else { 'no' } }
        $r = Invoke-DevRebuildChain -ScriptRoot '/scripts' -ConfigPath 'c.psd1' -Config $script:Config -HistoryRoot $script:Root -Runner $script:Runner -Prompt $prompt
        $r.Completed | Should -BeFalse
        @($script:Calls | Where-Object { $_ -like '*apply:*' }).Count | Should -Be 1
        @($script:Calls) | Should -Not -Contain 'Get-DriftReport.ps1|plan'
    }
}
