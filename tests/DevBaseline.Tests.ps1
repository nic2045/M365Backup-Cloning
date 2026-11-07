BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'M365Cloning.psd1') -Force
    $script:Base = "Prod=@{TenantId='tenant-prod-0001';ClientId='c';CertThumbprint='x'}; Dev=@{TenantId='tenant-dev-0001';ClientId='c';CertThumbprint='x';ApplyAllowed=`$true}; BreakGlass=@('bg-user@dev.example')"

    function script:New-ConfigFile([string]$Text) {
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.psd1')
        Set-Content -LiteralPath $path -Value "@{ $Text }"
        $path
    }
    function script:New-Config([string]$Extra = '') {
        $text = if ($Extra) { "$script:Base; $Extra" } else { $script:Base }
        Import-M365CloningConfig -Path (script:New-ConfigFile $text)
    }
    function script:New-Group([string]$Name, [hashtable]$Extra = @{}) {
        $p = @{ DisplayName = $Name; MailNickname = ($Name -replace '[^A-Za-z0-9_-]', ''); SecurityEnabled = $true; MailEnabled = $false; GroupTypes = @() }
        foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] }
        @{ displayName = $Name; resourceType = 'microsoft.entra.group'; properties = $p }
    }
    function script:New-Partner([hashtable]$Props) {
        @{ resourceType = 'microsoft.entra.crosstenantaccesspolicyconfigurationpartner'; properties = (@{ PartnerTenantId = 'tenant-prod-0001' } + $Props) }
    }
    function script:Allowed([string]$Value) { @{ AccessType = 'allowed'; Targets = @(@{ Target = $Value; TargetType = $(if ($Value -eq 'AllUsers') { 'user' } else { 'application' }) }) } }
    function script:New-Snap($Resources) { @{ resources = @($Resources) } }
    # Dev in the base state of the default config (five personas, break-glass group, partner set).
    function script:New-InBaselineSnap {
        $names = 'CA-BreakglassAccounts', 'CA-Persona-Admins', 'CA-Persona-Internals', 'CA-Persona-Externals', 'CA-Persona-Guests', 'CA-Persona-Microsoft365ServiceAccounts'
        $res = @($names | ForEach-Object { script:New-Group $_ })
        $res += script:New-Partner @{
            AutomaticUserConsentSettings = @{ InboundAllowed = $true; OutboundAllowed = $false }
            B2BCollaborationInbound      = @{ UsersAndGroups = (script:Allowed 'AllUsers'); Applications = (script:Allowed 'AllApplications') }
        }
        script:New-Snap $res
    }
    function script:Get-Action($Plan, [string]$Name) { @($Plan['Actions'] | Where-Object { $_['Name'] -eq $Name })[0] }
    function script:Get-PartnerAction($Plan) { @($Plan['Actions'] | Where-Object { $_['ResourceType'] -eq 'microsoft.entra.crosstenantaccesspolicyconfigurationpartner' })[0] }
}

Describe 'Baseline config check' {
    It 'accepts the example file with placeholders (structure only)' {
        $c = Import-M365CloningConfig -Path (Join-Path $PSScriptRoot '..' 'config.example.psd1') -AllowPlaceholders
        $c.Baseline.CrossTenantPartner | Should -BeTrue
    }
    It 'refuses an unknown key' {
        { script:New-Config "Baseline=@{Groups=@('x')}" } | Should -Throw '*unknown key*'
    }
    It 'refuses a flag that is not a bool' {
        { script:New-Config "Baseline=@{CrossTenantPartner='yes'}" } | Should -Throw '*CrossTenantPartner*'
    }
}

Describe 'New-DevBaselinePlan: empty Dev tenant' {
    BeforeAll {
        $script:Plan = New-DevBaselinePlan -Config (script:New-Config) -Target (script:New-Snap @())
    }
    It 'creates the break-glass group and one group per active persona, static and empty' {
        foreach ($name in 'CA-BreakglassAccounts', 'CA-Persona-Admins', 'CA-Persona-Internals', 'CA-Persona-Externals', 'CA-Persona-Guests', 'CA-Persona-Microsoft365ServiceAccounts') {
            $a = script:Get-Action $script:Plan $name
            $a['Operation'] | Should -Be 'Create'
            $a['Status'] | Should -Be 'planned'
            $a['DscResource'] | Should -Be 'AADGroup'
            $a['Properties']['SecurityEnabled'] | Should -BeTrue
            $a['Properties']['MailEnabled'] | Should -BeFalse
            $a['Properties'].Contains('Members') | Should -BeFalse
            $a['Properties'].Contains('MembershipRule') | Should -BeFalse
        }
    }
    It 'sets the Prod tenant as partner with B2B inbound allowed and automatic redemption' {
        $a = script:Get-PartnerAction $script:Plan
        $a['Operation'] | Should -Be 'Create'
        $a['DscResource'] | Should -Be 'AADCrossTenantAccessPolicyConfigurationPartner'
        $p = $a['Properties']
        $p['PartnerTenantId'] | Should -Be 'tenant-prod-0001'
        $p['Ensure'] | Should -Be 'Present'
        $p['AutomaticUserConsentSettings']['InboundAllowed'] | Should -BeTrue
        $p['AutomaticUserConsentSettings']['__CimClass'] | Should -Be 'MSFT_AADCrossTenantAccessPolicyAutomaticUserConsentSettings'
        $p['B2BCollaborationInbound']['UsersAndGroups']['AccessType'] | Should -Be 'allowed'
        $p['B2BCollaborationInbound']['UsersAndGroups']['Targets'][0]['Target'] | Should -Be 'AllUsers'
        $p['B2BCollaborationInbound']['Applications']['Targets'][0]['Target'] | Should -Be 'AllApplications'
        $p['B2BCollaborationInbound']['UsersAndGroups']['Targets'][0]['__CimClass'] | Should -Be 'MSFT_AADCrossTenantAccessPolicyTarget'
    }
    It 'does not configure cross-tenant synchronisation or other partner settings' {
        $p = (script:Get-PartnerAction $script:Plan)['Properties']
        $p.Contains('InboundTrust') | Should -BeFalse
        $p.Contains('B2BCollaborationOutbound') | Should -BeFalse
    }
    It 'targets the Dev tenant and is not in the base state yet' {
        $script:Plan['TargetTenantId'] | Should -Be 'tenant-dev-0001'
        $script:Plan['Summary']['InBaseline'] | Should -BeFalse
        $script:Plan['Summary']['Planned'] | Should -Be 7
    }
}

Describe 'New-DevBaselinePlan: differences' {
    It 'is empty when Dev is in the base state (acceptance of #8)' {
        $plan = New-DevBaselinePlan -Config (script:New-Config) -Target (script:New-InBaselineSnap)
        $plan['Summary']['InBaseline'] | Should -BeTrue
        $plan['Summary']['Planned'] | Should -Be 0
        $plan['Summary']['Blocked'] | Should -Be 0
        $plan['Summary']['Exists'] | Should -Be 7
    }
    It 'updates only the described properties of a group and keeps its mail nickname' {
        $snap = script:New-InBaselineSnap
        $snap.resources[1] = script:New-Group 'CA-Persona-Admins' @{ MailEnabled = $true; MailNickname = 'admins-old'; Description = 'kept' }
        $a = script:Get-Action (New-DevBaselinePlan -Config (script:New-Config) -Target $snap) 'CA-Persona-Admins'
        $a['Operation'] | Should -Be 'Update'
        $a['Status'] | Should -Be 'planned'
        @($a['Properties'].Keys | Sort-Object) -join ',' | Should -Be 'DisplayName,Ensure,MailEnabled,MailNickname,SecurityEnabled'
        $a['Properties']['MailNickname'] | Should -Be 'admins-old'
        @($a['Differences'] | ForEach-Object { $_['Property'] }) | Should -Contain 'MailEnabled'
    }
    It 'blocks a dynamic group instead of changing it' {
        $snap = script:New-InBaselineSnap
        $snap.resources[2] = script:New-Group 'CA-Persona-Internals' @{ GroupTypes = @('DynamicMembership'); MembershipRule = '(user.department -eq "IT")' }
        $a = script:Get-Action (New-DevBaselinePlan -Config (script:New-Config) -Target $snap) 'CA-Persona-Internals'
        $a['Status'] | Should -Be 'blocked'
        $a['Reason'] | Should -BeLike '*dynamic*'
    }
    It 'never plans anything for objects the base state does not name' {
        $snap = script:New-InBaselineSnap
        $snap.resources += script:New-Group 'Some other group'
        $plan = New-DevBaselinePlan -Config (script:New-Config) -Target $snap
        @($plan['Actions'] | Where-Object { $_['Name'] -eq 'Some other group' }).Count | Should -Be 0
        @($plan['Actions'] | Where-Object { $_['Operation'] -match 'Delete|Remove' }).Count | Should -Be 0
        $plan['Summary']['InBaseline'] | Should -BeTrue
    }
    It 'sets automatic redemption and an unset B2B inbound rule on an existing partner' {
        $snap = script:New-InBaselineSnap
        $snap.resources[6] = script:New-Partner @{ AutomaticUserConsentSettings = @{ InboundAllowed = $false } }
        $a = script:Get-PartnerAction (New-DevBaselinePlan -Config (script:New-Config) -Target $snap)
        $a['Operation'] | Should -Be 'Update'
        $a['Status'] | Should -Be 'planned'
        $a['Properties']['AutomaticUserConsentSettings']['InboundAllowed'] | Should -BeTrue
        $a['Properties'].Contains('B2BCollaborationInbound') | Should -BeTrue
        $a['Properties'].Contains('InboundTrust') | Should -BeFalse
    }
    It 'does not widen or narrow a B2B inbound rule that someone set' {
        $snap = script:New-InBaselineSnap
        $snap.resources[6] = script:New-Partner @{
            AutomaticUserConsentSettings = @{ InboundAllowed = $true }
            B2BCollaborationInbound      = @{ UsersAndGroups = @{ AccessType = 'allowed'; Targets = @(@{ Target = 'group-0001'; TargetType = 'group' }) }; Applications = (script:Allowed 'AllApplications') }
        }
        $a = script:Get-PartnerAction (New-DevBaselinePlan -Config (script:New-Config) -Target $snap)
        $a['Status'] | Should -Be 'blocked'
        $a['Properties'] | Should -BeNullOrEmpty
    }
    It 'creates an exclusion group with a persona and blocks one without' {
        $config = script:New-Config "Baseline=@{ExclusionGroups=@('CA-Persona-Admins-BaseProtection-Exclusions','Random exclusions')}"
        $plan = New-DevBaselinePlan -Config $config -Target (script:New-InBaselineSnap)
        (script:Get-Action $plan 'CA-Persona-Admins-BaseProtection-Exclusions')['Status'] | Should -Be 'planned'
        (script:Get-Action $plan 'Random exclusions')['Status'] | Should -Be 'blocked'
        $plan['Summary']['InBaseline'] | Should -BeFalse
    }
    It 'leaves out the persona groups and the partner when switched off' {
        $config = script:New-Config "Baseline=@{PersonaGroups=`$false;CrossTenantPartner=`$false}"
        $plan = New-DevBaselinePlan -Config $config -Target (script:New-Snap @())
        @($plan['Actions'] | ForEach-Object { $_['Name'] }) -join ',' | Should -Be 'CA-BreakglassAccounts'
    }
    It 'only refers to the Dev users and does not create them' {
        $config = script:New-Config "DevUsers=@(@{Type='TestUser';Id='t@dev.example';Persona='Internals'})"
        $plan = New-DevBaselinePlan -Config $config -Target (script:New-InBaselineSnap)
        @($plan['Actions'] | Where-Object { $_['ResourceType'] -like 'microsoft.graph.*' }).Count | Should -Be 0
        @($plan['Notes'] | Where-Object { $_ -like '*Invoke-DevUsers*' }).Count | Should -Be 1
    }
    It 'refuses a Dev tenant ID that equals the Prod tenant ID' {
        $config = script:New-Config
        $config['Dev']['TenantId'] = 'tenant-prod-0001'
        { New-DevBaselinePlan -Config $config -Target (script:New-Snap @()) } | Should -Throw '*Prod*'
    }
}

Describe 'Dev baseline: apply gate (Invoke-ApplyPlan)' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $script:Starter = {
            param($PlanPath, $ResultPath, $TenantId, $ClientId, $CertThumbprint)
            $script:Calls.Add(@{ Plan = (Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json); TenantId = $TenantId })
            '[]' | Set-Content -LiteralPath $ResultPath
            0
        }
        $script:Plan = New-DevBaselinePlan -Config (script:New-Config) -Target (script:New-Snap @())
        $script:Hash = Get-ApplyPlanHash -Plan $script:Plan
    }
    It 'refuses when Dev.ApplyAllowed is not $true' {
        $config = script:New-Config
        $config['Dev']['ApplyAllowed'] = $false
        { Invoke-ApplyPlan -Plan $script:Plan -Config $config -ConfirmPlanHash $script:Hash -ProcessStarter $script:Starter -HistoryRoot $script:Root } | Should -Throw '*ApplyAllowed*'
        $script:Calls.Count | Should -Be 0
    }
    It 'refuses a wrong plan hash' {
        { Invoke-ApplyPlan -Plan $script:Plan -Config (script:New-Config) -ConfirmPlanHash ('0' * 64) -ProcessStarter $script:Starter -HistoryRoot $script:Root } | Should -Throw '*hash*'
        $script:Calls.Count | Should -Be 0
    }
    It 'passes only the planned actions to the Dev tenant, all with Ensure Present' {
        $null = Invoke-ApplyPlan -Plan $script:Plan -Config (script:New-Config) -ConfirmPlanHash $script:Hash -ProcessStarter $script:Starter -HistoryRoot $script:Root
        $script:Calls.Count | Should -Be 1
        $script:Calls[0].TenantId | Should -Be 'tenant-dev-0001'
        @($script:Calls[0].Plan).Count | Should -Be 7
        @($script:Calls[0].Plan | Where-Object { $_.Properties.Ensure -ne 'Present' }).Count | Should -Be 0
    }
}
