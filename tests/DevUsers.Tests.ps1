BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'M365Cloning.psd1') -Force
    $script:Base = "Prod=@{TenantId='tenant-prod-0001';ClientId='c';CertThumbprint='x'}; Dev=@{TenantId='tenant-dev-0001';ClientId='c';CertThumbprint='x';ApplyAllowed=`$true}; BreakGlass=@('bg-user@dev.example')"
    $script:Users = "DevUsers=@(@{Type='TestUser';Id='test.internal@dev.example';Persona='Internals';DisplayName='Test Internals 01'}; @{Type='AdminGuest';Id='admin.one@prod.example';Persona='Admins'})"

    function script:New-ConfigFile([string]$Text) {
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.psd1')
        Set-Content -LiteralPath $path -Value "@{ $Text }"
        $path
    }
    function script:New-Config([string]$Extra = $script:Users) { Import-M365CloningConfig -Path (script:New-ConfigFile "$script:Base; $Extra") }
    function script:New-Directory {
        @{
            Users   = @(@{ id = 'user-exist-0001'; userPrincipalName = 'old.test@dev.example'; mail = ''; userType = 'Member' })
            Groups  = @(@{ id = 'group-admins-0001'; displayName = 'CA-Persona-Admins' }, @{ id = 'group-internals-0001'; displayName = 'CA-Persona-Internals' })
            Members = @{ 'CA-Persona-Admins' = @(); 'CA-Persona-Internals' = @() }
        }
    }
    function script:Get-Action($Plan, $Op, $Name) { @($Plan['Actions'] | Where-Object { $_['Operation'] -eq $Op -and $_['Name'] -eq $Name })[0] }
    function script:Read-Audit([string]$Root) {
        $path = Join-Path $Root 'audit.jsonl'
        if (Test-Path $path) { @(Get-Content -LiteralPath $path | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
    }
    # Records every write; returns ids like Graph does.
    function script:New-Writer {
        $script:Writes = [System.Collections.Generic.List[object]]::new()
        {
            param($Method, $Uri, $Body, $TenantId, $Config)
            $script:Writes.Add(@{ Method = $Method; Uri = $Uri; Body = ($Body | ConvertTo-Json -Depth 5 -Compress); TenantId = $TenantId })
            if ($Uri -like '*/users') { return [pscustomobject]@{ id = 'user-new-0001' } }
            if ($Uri -like '*/invitations') { return [pscustomobject]@{ invitedUser = [pscustomobject]@{ id = 'guest-new-0001' } } }
            $null
        }
    }
}

Describe 'DevUsers config check' {
    It 'accepts the example file with placeholders (structure only)' {
        $c = Import-M365CloningConfig -Path (Join-Path $PSScriptRoot '..' 'config.example.psd1') -AllowPlaceholders
        @($c.DevUsers).Count | Should -Be 2
    }
    It 'refuses an unknown persona' {
        { script:New-Config "DevUsers=@(@{Type='TestUser';Id='a@dev.example';Persona='Nobody'})" } | Should -Throw '*unknown*'
    }
    It 'refuses more than one persona for one account' {
        { script:New-Config "DevUsers=@(@{Type='TestUser';Id='a@dev.example';Persona=@('Admins','Internals')})" } | Should -Throw '*exactly one Persona*'
    }
    It 'refuses a break-glass account in the list' {
        { script:New-Config "DevUsers=@(@{Type='TestUser';Id='bg-user@dev.example';Persona='Admins'})" } | Should -Throw '*break-glass*'
    }
    It 'refuses the persona BreakGlass' {
        { script:New-Config "DevUsers=@(@{Type='TestUser';Id='a@dev.example';Persona='BreakGlass'})" } | Should -Throw '*BreakGlass*'
    }
    It 'refuses a wrong type and a duplicate' {
        { script:New-Config "DevUsers=@(@{Type='Owner';Id='a@dev.example';Persona='Admins'})" } | Should -Throw '*Type*'
        { script:New-Config "DevUsers=@(@{Type='TestUser';Id='a@dev.example';Persona='Admins'}; @{Type='AdminGuest';Id='A@dev.example';Persona='Admins'})" } | Should -Throw '*more than once*'
    }
    It 'accepts a persona that is only in PersonaMap' {
        $c = script:New-Config "PersonaMap=@{Developers=@('CA_Personas_Developers')}; DevUsers=@(@{Type='TestUser';Id='d@dev.example';Persona='Developers'})"
        @($c.DevUsers).Count | Should -Be 1
    }
}

Describe 'New-DevUserPlan' {
    It 'plans CreateUser, InviteGuest and AddMember, accounts first' {
        $plan = New-DevUserPlan -Config (script:New-Config) -Directory (script:New-Directory)
        $plan['Summary']['Planned'] | Should -Be 4
        (script:Get-Action $plan 'CreateUser' 'test.internal@dev.example')['Properties']['userPrincipalName'] | Should -Be 'test.internal@dev.example'
        $inv = script:Get-Action $plan 'InviteGuest' 'admin.one@prod.example'
        $inv['Properties']['sendInvitationMessage'] | Should -BeFalse
        $inv['Properties']['invitedUserEmailAddress'] | Should -Be 'admin.one@prod.example'
        (script:Get-Action $plan 'AddMember' 'admin.one@prod.example -> CA-Persona-Admins')['Properties']['GroupId'] | Should -Be 'group-admins-0001'
        @($plan['Actions'])[0]['Operation'] | Should -Not -Be 'AddMember'
        @($plan['Actions'])[-1]['Operation'] | Should -Be 'AddMember'
    }
    It 'contains no password' {
        $json = New-DevUserPlan -Config (script:New-Config) -Directory (script:New-Directory) | ConvertTo-Json -Depth 20
        $json | Should -Not -Match '(?i)password"\s*:'
        $json | Should -Not -Match 'passwordProfile'
    }
    It 'marks an existing account as exists and only adds the membership' {
        $config = script:New-Config "DevUsers=@(@{Type='TestUser';Id='old.test@dev.example';Persona='Internals'})"
        $plan = New-DevUserPlan -Config $config -Directory (script:New-Directory)
        (script:Get-Action $plan 'CreateUser' 'old.test@dev.example')['Status'] | Should -Be 'exists'
        $m = script:Get-Action $plan 'AddMember' 'old.test@dev.example -> CA-Persona-Internals'
        $m['Status'] | Should -Be 'planned'
        $m['Properties']['MemberId'] | Should -Be 'user-exist-0001'
    }
    It 'marks an existing membership as exists' {
        $config = script:New-Config "DevUsers=@(@{Type='TestUser';Id='old.test@dev.example';Persona='Internals'})"
        $dir = script:New-Directory
        $dir.Members['CA-Persona-Internals'] = @('user-exist-0001')
        $plan = New-DevUserPlan -Config $config -Directory $dir
        $plan['Summary']['Planned'] | Should -Be 0
        $plan['Summary']['Exists'] | Should -Be 2
    }
    It 'blocks an entry whose persona group does not exist in Dev (needs-group)' {
        $dir = script:New-Directory
        $dir.Groups = @($dir.Groups | Where-Object { $_.displayName -ne 'CA-Persona-Admins' })
        $plan = New-DevUserPlan -Config (script:New-Config) -Directory $dir
        $a = script:Get-Action $plan 'InviteGuest' 'admin.one@prod.example'
        $a['Status'] | Should -Be 'blocked'
        $a['Reason'] | Should -Match 'needs-group'
        @($plan['Actions'] | Where-Object { $_['Name'] -like 'admin.one*' }).Count | Should -Be 1
    }
    It 'uses the group name from PersonaMap' {
        $config = script:New-Config "PersonaMap=@{Admins=@('CA_Personas_Admins')}; DevUsers=@(@{Type='AdminGuest';Id='admin.one@prod.example';Persona='Admins'})"
        $dir = script:New-Directory
        $dir.Groups = @(@{ id = 'group-map-0001'; displayName = 'CA_Personas_Admins' })
        $plan = New-DevUserPlan -Config $config -Directory $dir
        (script:Get-Action $plan 'AddMember' 'admin.one@prod.example -> CA_Personas_Admins')['Properties']['GroupId'] | Should -Be 'group-map-0001'
    }
    It 'contains only accounts of the positive list' {
        $plan = New-DevUserPlan -Config (script:New-Config) -Directory (script:New-Directory)
        @($plan['Actions'] | Where-Object { $_['Name'] -like 'old.test*' }).Count | Should -Be 0
    }
    It 'refuses a config whose Dev tenant equals Prod' {
        $config = script:New-Config
        $config['Dev']['TenantId'] = $config['Prod']['TenantId']
        { New-DevUserPlan -Config $config -Directory (script:New-Directory) } | Should -Throw '*Prod*'
    }
    It 'gives the same hash for the same input' {
        $a = Get-ApplyPlanHash -Plan (New-DevUserPlan -Config (script:New-Config) -Directory (script:New-Directory))
        $b = Get-ApplyPlanHash -Plan (New-DevUserPlan -Config (script:New-Config) -Directory (script:New-Directory))
        $a | Should -Be $b
    }
}

Describe 'Invoke-DevUserPlan: refusals (nothing is written)' {
    BeforeEach {
        $script:Writer = script:New-Writer
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Config = script:New-Config
        $script:Plan = New-DevUserPlan -Config $script:Config -Directory (script:New-Directory)
        $script:Hash = Get-ApplyPlanHash -Plan $script:Plan
    }
    It 'refuses when Dev.ApplyAllowed is not $true' {
        $script:Config['Dev']['ApplyAllowed'] = $false
        { Invoke-DevUserPlan -Plan $script:Plan -Config $script:Config -ConfirmPlanHash $script:Hash -GraphWriter $script:Writer -HistoryRoot $script:Root -RetryDelaySeconds 0 } | Should -Throw '*ApplyAllowed*'
        $script:Writes.Count | Should -Be 0
    }
    It 'refuses a wrong or empty plan hash' {
        { Invoke-DevUserPlan -Plan $script:Plan -Config $script:Config -ConfirmPlanHash ('0' * 64) -GraphWriter $script:Writer -HistoryRoot $script:Root -RetryDelaySeconds 0 } | Should -Throw '*hash*'
        { Invoke-DevUserPlan -Plan $script:Plan -Config $script:Config -ConfirmPlanHash '' -GraphWriter $script:Writer -HistoryRoot $script:Root -RetryDelaySeconds 0 } | Should -Throw '*hash*'
        $script:Writes.Count | Should -Be 0
    }
    It 'refuses the Prod tenant' {
        $script:Config['Dev']['TenantId'] = $script:Config['Prod']['TenantId']
        $script:Plan['TargetTenantId'] = $script:Config['Prod']['TenantId']
        { Invoke-DevUserPlan -Plan $script:Plan -Config $script:Config -ConfirmPlanHash (Get-ApplyPlanHash -Plan $script:Plan) -GraphWriter $script:Writer -HistoryRoot $script:Root -RetryDelaySeconds 0 } | Should -Throw '*Prod*'
        $script:Writes.Count | Should -Be 0
    }
    It 'writes the refusal to the audit log' {
        $script:Config['Dev']['ApplyAllowed'] = $false
        { Invoke-DevUserPlan -Plan $script:Plan -Config $script:Config -ConfirmPlanHash $script:Hash -GraphWriter $script:Writer -HistoryRoot $script:Root -RetryDelaySeconds 0 } | Should -Throw
        @(script:Read-Audit $script:Root)[0].Mode | Should -Be 'refused'
    }
}

Describe 'Invoke-DevUserPlan: confirmed apply' {
    BeforeEach {
        $script:Writer = script:New-Writer
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Config = script:New-Config
        $script:Plan = New-DevUserPlan -Config $script:Config -Directory (script:New-Directory)
        $script:Hash = Get-ApplyPlanHash -Plan $script:Plan
    }
    It 'creates the test user, invites the admin and adds both to their persona groups (Dev tenant only)' {
        $r = Invoke-DevUserPlan -Plan $script:Plan -Config $script:Config -ConfirmPlanHash $script:Hash -GraphWriter $script:Writer -HistoryRoot $script:Root -RetryDelaySeconds 0
        $r.Applied | Should -Be 4
        $r.Failed | Should -Be 0
        $script:Writes.Count | Should -Be 4
        @($script:Writes | ForEach-Object { $_.TenantId } | Select-Object -Unique) | Should -Be @('tenant-dev-0001')
        @($script:Writes | Where-Object { $_.Uri -eq 'https://graph.microsoft.com/v1.0/users' }).Count | Should -Be 1
        @($script:Writes | Where-Object { $_.Uri -eq 'https://graph.microsoft.com/v1.0/invitations' }).Count | Should -Be 1
        $members = @($script:Writes | Where-Object { $_.Uri -like '*/members/$ref' })
        $members.Count | Should -Be 2
        ($members | Where-Object { $_.Uri -like '*group-admins-0001*' }).Body | Should -Match 'guest-new-0001'
        ($members | Where-Object { $_.Uri -like '*group-internals-0001*' }).Body | Should -Match 'user-new-0001'
    }
    It 'sends a random password that must be changed at first sign-in, and never sends the invitation mail' {
        $null = Invoke-DevUserPlan -Plan $script:Plan -Config $script:Config -ConfirmPlanHash $script:Hash -GraphWriter $script:Writer -HistoryRoot $script:Root -RetryDelaySeconds 0
        $body = ($script:Writes | Where-Object { $_.Uri -like '*/users' }).Body | ConvertFrom-Json
        $body.passwordProfile.forceChangePasswordNextSignIn | Should -BeTrue
        $body.passwordProfile.password.Length | Should -Be 24
        (($script:Writes | Where-Object { $_.Uri -like '*/invitations' }).Body | ConvertFrom-Json).sendInvitationMessage | Should -BeFalse
    }
    It 'never writes the password to the result file or the audit log' {
        $null = Invoke-DevUserPlan -Plan $script:Plan -Config $script:Config -ConfirmPlanHash $script:Hash -GraphWriter $script:Writer -HistoryRoot $script:Root -RetryDelaySeconds 0
        $pw = (($script:Writes | Where-Object { $_.Uri -like '*/users' }).Body | ConvertFrom-Json).passwordProfile.password
        foreach ($f in (Get-ChildItem -LiteralPath $script:Root -Recurse -File)) {
            (Get-Content -LiteralPath $f.FullName -Raw) | Should -Not -Match ([regex]::Escape($pw))
        }
    }
    It 'gives every new test user its own password' {
        $a = & (Get-Module M365Cloning) { New-InitialPassword }
        $b = & (Get-Module M365Cloning) { New-InitialPassword }
        $a | Should -Not -Be $b
        $a | Should -Match '[A-Z]'
        $a | Should -Match '[a-z]'
        $a | Should -Match '[0-9]'
    }
    It 'records a failed write and goes on; the membership of a failed account is failed, not written' {
        $failing = {
            param($Method, $Uri, $Body, $TenantId, $Config)
            if ($Uri -like '*/users') { throw 'Request_BadRequest: domain not verified' }
            & $script:Writer -Method $Method -Uri $Uri -Body $Body -TenantId $TenantId -Config $Config
        }
        $r = Invoke-DevUserPlan -Plan $script:Plan -Config $script:Config -ConfirmPlanHash $script:Hash -GraphWriter $failing -HistoryRoot $script:Root -RetryDelaySeconds 0
        $r.Failed | Should -Be 2
        @($script:Writes | Where-Object { $_.Uri -like '*group-internals-0001*' }).Count | Should -Be 0
    }
}

Describe 'Write allow list for Dev users' {
    BeforeAll { $script:AllowConfig = script:New-Config }
    It 'allows exactly users, invitations and group members on Graph v1.0 in Dev' {
        $m = Get-Module M365Cloning
        foreach ($uri in 'https://graph.microsoft.com/v1.0/users', 'https://graph.microsoft.com/v1.0/invitations', 'https://graph.microsoft.com/v1.0/groups/group-1/members/$ref') {
            { & $m { param($u, $c) Assert-DevDirectoryWriteAllowed -Uri $u -TenantId 'tenant-dev-0001' -Config $c } $uri $script:AllowConfig } | Should -Not -Throw
        }
    }
    It 'blocks every other path, another host and a query string' {
        $m = Get-Module M365Cloning
        foreach ($uri in 'https://graph.microsoft.com/v1.0/users/u-1', 'https://graph.microsoft.com/v1.0/groups', 'https://graph.microsoft.com/v1.0/directoryRoles/r/members/$ref',
            'https://graph.microsoft.com/beta/users', 'https://example.org/v1.0/users', 'https://graph.microsoft.com/v1.0/users?x=1', 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies') {
            { & $m { param($u, $c) Assert-DevDirectoryWriteAllowed -Uri $u -TenantId 'tenant-dev-0001' -Config $c } $uri $script:AllowConfig } | Should -Throw '*Blocked*'
        }
    }
    It 'blocks the Prod tenant and any tenant other than Dev' {
        $m = Get-Module M365Cloning
        foreach ($t in 'tenant-prod-0001', 'tenant-other-0001') {
            { & $m { param($t, $c) Assert-DevDirectoryWriteAllowed -Uri 'https://graph.microsoft.com/v1.0/users' -TenantId $t -Config $c } $t $script:AllowConfig } | Should -Throw '*Blocked*'
        }
    }
    It 'stops a writer from reaching a path outside the allow list through a manipulated plan' {
        $config = script:New-Config
        $plan = New-DevUserPlan -Config $config -Directory (script:New-Directory)
        foreach ($a in @($plan['Actions'] | Where-Object { $_['Operation'] -eq 'AddMember' })) { $a['Properties']['GroupId'] = 'g/../../directoryRoles/x' }
        $writer = script:New-Writer
        $r = Invoke-DevUserPlan -Plan $plan -Config $config -ConfirmPlanHash (Get-ApplyPlanHash -Plan $plan) -GraphWriter $writer -HistoryRoot (Join-Path $TestDrive 'manip') -RetryDelaySeconds 0
        @($script:Writes | Where-Object { $_.Uri -like '*members*' }).Count | Should -Be 0
        @($r.Results | Where-Object { $_['Operation'] -eq 'AddMember' -and $_['Status'] -eq 'failed' }).Count | Should -Be 2
    }
}
