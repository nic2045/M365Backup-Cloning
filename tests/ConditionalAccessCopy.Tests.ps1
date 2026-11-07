BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'M365Cloning.psd1') -Force
    $script:Valid = Join-Path $PSScriptRoot 'fixtures' 'config.valid.psd1'

    function script:New-Config { Import-M365CloningConfig -Path $script:Valid }
    function script:New-Res($Type, $Name, $Props) {
        @{ displayName = $Name; resourceType = $Type; properties = ($Props + @{ DisplayName = $Name }) }
    }
    function script:New-Snap($Resources) { @{ resources = @($Resources) } }
    function script:Get-Action($Plan, $Name) { @($Plan['Actions'] | Where-Object { $_['Name'] -eq $Name })[0] }
    function script:New-ConfigFile([string]$Text) {
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.psd1')
        Set-Content -LiteralPath $path -Value $Text
        $path
    }

    $script:Group = 'microsoft.entra.group'
    $script:CA = 'microsoft.entra.conditionalaccesspolicy'
    $script:Base = "Prod=@{TenantId='t-prod';ClientId='c';CertThumbprint='x'}; Dev=@{TenantId='t-dev';ClientId='c';CertThumbprint='x'}; BreakGlass=@('bg-user-0001')"
}

Describe 'Conditional Access copy: groups as static, empty copies' {
    It 'copies a Prod group as a static, empty group without members, owners, licences and dynamic rule' {
        $src = script:New-Snap @(script:New-Res $script:Group 'CA-Persona-Internals' @{
                GroupTypes = @('DynamicMembership'); MembershipRule = '(user.department -eq "x")'; MembershipRuleProcessingState = 'On'
                Members = @('user-a'); Owners = @('user-b'); MemberOf = @('Other'); AssignedLicenses = @(@{ SkuId = 'sku-1' }); AssignedToRole = @('Role')
                SecurityEnabled = $true; MailEnabled = $false })
        $a = script:Get-Action (New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)) 'CA-Persona-Internals'
        $a['Status'] | Should -Be 'planned'
        $a['DscResource'] | Should -Be 'AADGroup'
        foreach ($key in 'Members', 'Owners', 'MemberOf', 'AssignedLicenses', 'AssignedToRole', 'MembershipRule', 'MembershipRuleProcessingState', 'GroupTypes') {
            $a['Properties'].Contains($key) | Should -BeFalse
        }
        $a['Properties']['SecurityEnabled'] | Should -BeTrue
        $a['Properties']['MailNickname'] | Should -Be 'CA-Persona-Internals'
        $a['Properties']['Ensure'] | Should -Be 'Present'
    }
    It 'keeps other group types and only removes DynamicMembership' {
        $src = script:New-Snap @(script:New-Res $script:Group 'G' @{ GroupTypes = @('Unified', 'DynamicMembership') })
        $a = script:Get-Action (New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)) 'G'
        $a['Properties']['GroupTypes'] | Should -Contain 'Unified'
        $a['Properties']['GroupTypes'] | Should -Not -Contain 'DynamicMembership'
    }
    It 'creates an empty copy of a persona group that a policy refers to and Dev lacks, before the policy' {
        $src = script:New-Snap @(script:New-Res $script:CA 'CA200-Internals-BaseProtection' @{ IncludeUsers = @(); IncludeGroups = @('CA-Persona-Internals'); ExcludeGroups = @('CA-Persona-Internals-BaseProtection-Exclusions') })
        $plan = New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)
        $g = script:Get-Action $plan 'CA-Persona-Internals'
        $g['ResourceType'] | Should -Be $script:Group
        $g['Operation'] | Should -Be 'Create'
        $g['Status'] | Should -Be 'planned'
        $g['Reason'] | Should -Match 'empty static copy'
        $g['Properties'].Contains('Members') | Should -BeFalse
        $g['Properties']['MailEnabled'] | Should -BeFalse
        (script:Get-Action $plan 'CA-Persona-Internals-BaseProtection-Exclusions')['Status'] | Should -Be 'planned'
        $policy = script:Get-Action $plan 'CA200-Internals-BaseProtection'
        $policy['Status'] | Should -Be 'planned'
        $policy['Properties']['IncludeGroups'] | Should -Contain 'CA-Persona-Internals'
        $plan['Actions'][-1]['Name'] | Should -Be 'CA200-Internals-BaseProtection'
    }
    It 'plans no second copy when Dev already has the group' {
        $src = script:New-Snap @(script:New-Res $script:CA 'CA' @{ IncludeGroups = @('CA-Persona-Admins') })
        $tgt = script:New-Snap @(script:New-Res $script:Group 'CA-Persona-Admins' @{})
        $plan = New-ApplyPlan -Source $src -Target $tgt -Config (script:New-Config)
        @($plan['Actions'] | Where-Object { $_['Name'] -eq 'CA-Persona-Admins' -and $_['Operation'] -eq 'Create' }).Count | Should -Be 0
        (script:Get-Action $plan 'CA')['Status'] | Should -Be 'planned'
    }
    It 'creates the configured break-glass group empty when Dev lacks it and a policy is planned' {
        $src = script:New-Snap @(script:New-Res $script:CA 'CA' @{ IncludeUsers = @('All') })
        $plan = New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)
        $bg = script:Get-Action $plan 'BG-Group'
        $bg['ResourceType'] | Should -Be $script:Group
        $bg['Reason'] | Should -Match 'BreakGlass'
        (script:Get-Action $plan 'CA')['Properties']['ExcludeGroups'] | Should -Contain 'BG-Group'
    }
    It 'plans no break-glass group when no policy is planned' {
        $src = script:New-Snap @(script:New-Res 'microsoft.intune.devicecompliancepolicywindows10' 'C' @{ X = 1 })
        $plan = New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)
        @($plan['Actions'] | Where-Object { $_['ResourceType'] -eq $script:Group }).Count | Should -Be 0
    }
}

Describe 'Conditional Access copy: persona detection' {
    BeforeAll {
        # Persona of a group as the plan sees it: a policy refers to the group, Dev lacks it; the empty copy names the persona.
        function script:Get-PersonaOf($Config, [string]$GroupName) {
            $src = script:New-Snap @(script:New-Res $script:CA 'Probe' @{ IncludeGroups = @($GroupName) })
            $plan = New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config $Config
            $g = script:Get-Action $plan $GroupName
            if ($g -and $g['Operation'] -eq 'Create' -and $g['Reason'] -match 'persona (\w+)') { return $Matches[1] }
            $null
        }
    }
    It 'recognises persona groups by the default naming scheme' {
        $c = script:New-Config
        script:Get-PersonaOf $c 'CA-Persona-Admins' | Should -Be 'Admins'
        script:Get-PersonaOf $c 'ca-persona-guests' | Should -Be 'Guests'
        script:Get-PersonaOf $c 'CA-Persona-Admins-BaseProtection-Exclusions' | Should -Be 'Admins'
        script:Get-PersonaOf $c 'CA-BreakglassAccounts' | Should -Be 'BreakGlass'
        script:Get-PersonaOf $c 'BG-Group' | Should -Be 'BreakGlass'
    }
    It 'does not take a longer persona name for a shorter one' {
        script:Get-PersonaOf (script:New-Config) 'CA-Persona-AdminsX' | Should -BeNullOrEmpty
    }
    It 'knows the further personas of the paper only when they are switched on' {
        script:Get-PersonaOf (script:New-Config) 'CA-Persona-Developers' | Should -BeNullOrEmpty
        $config = script:New-Config
        $config['Personas'] = @('Admins', 'Developers')
        script:Get-PersonaOf $config 'CA-Persona-Developers' | Should -Be 'Developers'
        script:Get-PersonaOf $config 'CA-Persona-Internals' | Should -BeNullOrEmpty
    }
    It 'recognises Prod groups with other names through PersonaMap' {
        $config = script:New-Config
        $config['PersonaMap'] = @{ Admins = @('Tier0 Admins', 'Tier1 Admins'); Guests = 'External Guests' }
        script:Get-PersonaOf $config 'tier0 admins' | Should -Be 'Admins'
        script:Get-PersonaOf $config 'External Guests' | Should -Be 'Guests'
        script:Get-PersonaOf $config 'Somebody Else' | Should -BeNullOrEmpty
    }
    It 'honours a different prefix' {
        $config = script:New-Config
        $config['PersonaPrefix'] = 'ZT-'
        script:Get-PersonaOf $config 'ZT-Internals' | Should -Be 'Internals'
        script:Get-PersonaOf $config 'CA-Persona-Internals' | Should -BeNullOrEmpty
    }
}

Describe 'Conditional Access copy: fail-closed' {
    It 'blocks a policy whose group has no persona and does not exist in Dev (needs-group) and creates no group' {
        $src = script:New-Snap @(script:New-Res $script:CA 'CA' @{ IncludeUsers = @('All'); ExcludeGroups = @('Some Random Group') })
        $plan = New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)
        $a = script:Get-Action $plan 'CA'
        $a['Status'] | Should -Be 'blocked'
        $a['Reason'] | Should -Match 'needs-group'
        $a['Reason'] | Should -Match 'Some Random Group'
        script:Get-Action $plan 'Some Random Group' | Should -BeNullOrEmpty
    }
    It 'notes a referenced group without persona that is copied anyway' {
        $src = script:New-Snap @((script:New-Res $script:CA 'CA' @{ IncludeGroups = @('Plain Group') }), (script:New-Res $script:Group 'Plain Group' @{}))
        $plan = New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)
        (script:Get-Action $plan 'CA')['Status'] | Should -Be 'planned'
        ($plan['Notes'] -join ' ') | Should -Match 'Plain Group'
        (ConvertTo-ApplyPlanMarkdown -Plan $plan -PlanHash 'h') | Should -Match 'Plain Group'
    }
    It 'still always plans Report-only with the break-glass accounts for a copied policy' {
        $src = script:New-Snap @(script:New-Res $script:CA 'CA' @{ State = 'enabled'; IncludeGroups = @('CA-Persona-Guests') })
        $a = script:Get-Action (New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)) 'CA'
        $a['Properties']['State'] | Should -Be 'enabledForReportingButNotEnforced'
        $a['Properties']['ExcludeUsers'] | Should -Contain 'bg-user-0001'
        $a['Properties']['ExcludeGroups'] | Should -Contain 'BG-Group'
    }
    It 'blocks the policy without a break-glass exclusion even if its groups are fine' {
        $config = script:New-Config
        $config.Remove('BreakGlass'); $config.Remove('BreakGlassGroups')
        $src = script:New-Snap @(script:New-Res $script:CA 'CA' @{ IncludeGroups = @('CA-Persona-Admins') })
        (script:Get-Action (New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config $config) 'CA')['Status'] | Should -Be 'blocked'
    }
    It 'never plans a delete or Ensure Absent for the copied groups and policies' {
        $src = script:New-Snap @(script:New-Res $script:CA 'CA' @{ IncludeGroups = @('CA-Persona-Admins') })
        $tgt = script:New-Snap @(script:New-Res $script:Group 'Only in Dev' @{})
        $plan = New-ApplyPlan -Source $src -Target $tgt -Config (script:New-Config)
        ($plan | ConvertTo-Json -Depth 30) | Should -Not -Match 'Absent'
        (script:Get-Action $plan 'Only in Dev')['Operation'] | Should -Be 'SkipDelete'
    }
    It 'gives the same plan hash for the same inputs (the empty copies are deterministic)' {
        $src = script:New-Snap @(script:New-Res $script:CA 'CA' @{ IncludeGroups = @('CA-Persona-Admins', 'CA-Persona-Guests') })
        $h1 = Get-ApplyPlanHash -Plan (New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config))
        $h2 = Get-ApplyPlanHash -Plan (New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config))
        $h1 | Should -Be $h2
    }
}

Describe 'Config: persona settings' {
    It 'accepts the example file with its persona defaults' {
        $c = Import-M365CloningConfig -Path (Join-Path $PSScriptRoot '..' 'config.example.psd1') -AllowPlaceholders
        $c.PersonaPrefix | Should -Be 'CA-Persona-'
        @($c.Personas) | Should -Contain 'Admins'
    }
    It 'rejects an empty prefix' {
        $p = script:New-ConfigFile "@{ $script:Base; PersonaPrefix='' }"
        { Import-M365CloningConfig -Path $p } | Should -Throw '*PersonaPrefix*'
    }
    It 'rejects a persona name with a hyphen' {
        $p = script:New-ConfigFile "@{ $script:Base; Personas=@('Bad-Name') }"
        { Import-M365CloningConfig -Path $p } | Should -Throw '*Personas*'
    }
    It 'rejects a PersonaMap that is not a table' {
        $p = script:New-ConfigFile "@{ $script:Base; PersonaMap=@('x') }"
        { Import-M365CloningConfig -Path $p } | Should -Throw '*PersonaMap*'
    }
    It 'rejects a PersonaMap entry that is not a group name' {
        $p = script:New-ConfigFile "@{ $script:Base; PersonaMap=@{ Admins=@(1) } }"
        { Import-M365CloningConfig -Path $p } | Should -Throw '*PersonaMap*'
    }
    It 'accepts a valid PersonaMap' {
        $p = script:New-ConfigFile "@{ $script:Base; PersonaMap=@{ Admins=@('Tier0 Admins') } }"
        (Import-M365CloningConfig -Path $p).PersonaMap.Admins | Should -Contain 'Tier0 Admins'
    }
}
