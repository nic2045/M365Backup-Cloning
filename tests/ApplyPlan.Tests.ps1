BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'M365Cloning.psd1') -Force
    $script:Valid = Join-Path $PSScriptRoot 'fixtures' 'config.valid.psd1'

    function script:New-Config { Import-M365CloningConfig -Path $script:Valid }
    function script:New-Res($Type, $Name, $Props) {
        @{ displayName = $Name; resourceType = $Type; properties = ($Props + @{ DisplayName = $Name }) }
    }
    function script:New-Snap($Resources) { @{ resources = @($Resources) } }
    function script:Get-Action($Plan, $Name) { @($Plan['Actions'] | Where-Object { $_['Name'] -eq $Name })[0] }

    $script:Policy = 'microsoft.intune.deviceconfigurationpolicywindows10'
    $script:Group = 'microsoft.entra.group'
    $script:CA = 'microsoft.entra.conditionalaccesspolicy'
    $script:Role = 'microsoft.intune.roledefinition'
    $script:Assign = { param($name, $type = '#microsoft.graph.groupAssignmentTarget') @{ dataType = $type; groupId = "id-prod-$name"; groupDisplayName = $name } }
}

Describe 'New-ApplyPlan: operations' {
    It 'plans a Create for a resource only in Prod, without ids, with Ensure Present' {
        $src = script:New-Snap @(script:New-Res $script:Policy 'P' @{ Id = 'id-prod-1'; Len = 8 })
        $plan = New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)
        $a = script:Get-Action $plan 'P'
        $a['Operation'] | Should -Be 'Create'
        $a['Status'] | Should -Be 'planned'
        $a['DscResource'] | Should -Be 'IntuneDeviceConfigurationPolicyWindows10'
        $a['Properties']['Ensure'] | Should -Be 'Present'
        $a['Properties'].Contains('Id') | Should -BeFalse
        $a['Properties']['Len'] | Should -Be 8
        $plan['Direction'] | Should -Be 'Prod -> Dev'
        $plan['TargetTenant'] | Should -Be 'tenant-d...'
        $plan['TargetTenantHash'] | Should -Be (Get-TenantIdHash -TenantId 'tenant-dev-0001')
    }
    It 'plans an Update with the differences for a changed resource' {
        $src = script:New-Snap @(script:New-Res $script:Policy 'P' @{ Len = 8 })
        $tgt = script:New-Snap @(script:New-Res $script:Policy 'P' @{ Len = 12 })
        $a = script:Get-Action (New-ApplyPlan -Source $src -Target $tgt -Config (script:New-Config)) 'P'
        $a['Operation'] | Should -Be 'Update'
        $a['Differences'][0]['Property'] | Should -Be 'Len'
        $a['Properties']['Len'] | Should -Be 8
    }
    It 'never deletes: a resource only in Dev is skipped and no Ensure Absent is planned' {
        $tgt = script:New-Snap @(script:New-Res $script:Policy 'Only in Dev' @{ X = 1 })
        $plan = New-ApplyPlan -Source (script:New-Snap @()) -Target $tgt -Config (script:New-Config)
        $a = script:Get-Action $plan 'Only in Dev'
        $a['Operation'] | Should -Be 'SkipDelete'
        $a['Status'] | Should -Be 'skipped'
        @($a['Properties'].Keys).Count | Should -Be 0   # empty object: nothing is written (issue #51)
        ($plan | ConvertTo-Json -Depth 30) | Should -Not -Match 'Absent'
    }
    It 'plans nothing for identical tenants' {
        $s = script:New-Snap @(script:New-Res $script:Policy 'P' @{ X = 1 })
        $plan = New-ApplyPlan -Source $s -Target $s -Config (script:New-Config)
        @($plan['Actions']).Count | Should -Be 0
    }
    It 'blocks a resource type without a Microsoft365DSC mapping' {
        $src = script:New-Snap @(script:New-Res 'microsoft.exchange.unknownthing' 'U' @{ X = 1 })
        $a = script:Get-Action (New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)) 'U'
        $a['Status'] | Should -Be 'blocked'
        $a['Reason'] | Should -Match 'no Microsoft365DSC resource'
    }
    It 'blocks duplicate names in the snapshot' {
        $src = script:New-Snap @((script:New-Res $script:Policy 'D' @{ X = 1 }), (script:New-Res $script:Policy 'D' @{ X = 2 }))
        $plan = New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)
        (@($plan['Actions'] | Where-Object { $_['Status'] -eq 'blocked' })).Count | Should -Be 1
    }
}

Describe 'New-ApplyPlan: groups and assignments (fail-closed)' {
    It 'keeps an assignment whose group exists in Dev, by name, without the group id' {
        $src = script:New-Snap @(script:New-Res $script:Policy 'P' @{ Assignments = @((& $script:Assign 'SW-Ring1')) })
        $tgt = script:New-Snap @(script:New-Res $script:Group 'SW-Ring1' @{})
        $a = script:Get-Action (New-ApplyPlan -Source $src -Target $tgt -Config (script:New-Config)) 'P'
        $a['Status'] | Should -Be 'planned'
        $a['Properties']['Assignments'][0]['groupDisplayName'] | Should -Be 'SW-Ring1'
        $a['Properties']['Assignments'][0].Contains('groupId') | Should -BeFalse
    }
    It 'plans the group first when the group is created in the same plan' {
        $src = script:New-Snap @((script:New-Res $script:Policy 'P' @{ Assignments = @((& $script:Assign 'SW-New')) }), (script:New-Res $script:Group 'SW-New' @{}))
        $plan = New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)
        (script:Get-Action $plan 'P')['Status'] | Should -Be 'planned'
        $names = @($plan['Actions'] | ForEach-Object { $_['Name'] })
        [array]::IndexOf($names, 'SW-New') | Should -BeLessThan ([array]::IndexOf($names, 'P'))
    }
    It 'plans an empty static copy for an inclusion group that Dev lacks, before the policy' {
        $src = script:New-Snap @(script:New-Res $script:Policy 'P' @{ Assignments = @((& $script:Assign 'SW-Missing')) })
        $plan = New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)
        (script:Get-Action $plan 'P')['Status'] | Should -Be 'planned'
        $g = script:Get-Action $plan 'SW-Missing'
        $g['Operation'] | Should -Be 'Create'
        $g['Properties'].Contains('Members') | Should -BeFalse
        $names = @($plan['Actions'] | ForEach-Object { $_['Name'] })
        [array]::IndexOf($names, 'SW-Missing') | Should -BeLessThan ([array]::IndexOf($names, 'P'))
    }
    It 'blocks an exclusion group that Dev lacks (an empty exclusion would widen the scope)' {
        $src = script:New-Snap @(script:New-Res $script:Policy 'P' @{ Assignments = @((& $script:Assign 'SW-Excl' '#microsoft.graph.exclusionGroupAssignmentTarget')) })
        $plan = New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)
        $a = script:Get-Action $plan 'P'
        $a['Status'] | Should -Be 'blocked'
        $a['Reason'] | Should -Match "'SW-Excl' does not exist in Dev"
        @($a['Properties'].Keys).Count | Should -Be 0   # empty object: nothing is written (issue #51)
        @($plan['Actions'] | Where-Object { $_['Name'] -eq 'SW-Excl' }).Count | Should -Be 0
    }
    It 'blocks an unresolved exclusion group instead of widening the scope' {
        $assignments = @((& $script:Assign 'SW-Ring1'), (& $script:Assign 'SW-Excluded' '#microsoft.graph.exclusionGroupAssignmentTarget'))
        $src = script:New-Snap @(script:New-Res $script:Policy 'P' @{ Assignments = $assignments })
        $tgt = script:New-Snap @(script:New-Res $script:Group 'SW-Ring1' @{})
        $a = script:Get-Action (New-ApplyPlan -Source $src -Target $tgt -Config (script:New-Config)) 'P'
        $a['Status'] | Should -Be 'blocked'
        $a['Reason'] | Should -Match 'SW-Excluded'
    }
    It 'blocks a group assignment without a group name' {
        $src = script:New-Snap @(script:New-Res $script:Policy 'P' @{ Assignments = @(@{ dataType = '#microsoft.graph.groupAssignmentTarget'; groupId = 'id-prod-1' }) })
        (script:Get-Action (New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)) 'P')['Status'] | Should -Be 'blocked'
    }
    It 'blocks an assignment filter (filters cannot be matched by name)' {
        $a1 = @{ dataType = '#microsoft.graph.allDevicesAssignmentTarget'; deviceAndAppManagementAssignmentFilterType = 'include'; deviceAndAppManagementAssignmentFilterId = 'id-prod-f1' }
        $src = script:New-Snap @(script:New-Res $script:Policy 'P' @{ Assignments = @($a1) })
        $a = script:Get-Action (New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)) 'P'
        $a['Status'] | Should -Be 'blocked'
        $a['Reason'] | Should -Match 'filter'
    }
    It 'allows an all-devices assignment without a group' {
        $src = script:New-Snap @(script:New-Res $script:Policy 'P' @{ Assignments = @(@{ dataType = '#microsoft.graph.allDevicesAssignmentTarget' }) })
        (script:Get-Action (New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)) 'P')['Status'] | Should -Be 'planned'
    }
    It 'does not carry users over into a group' {
        $src = script:New-Snap @(script:New-Res $script:Group 'G' @{ Members = @('user-a'); Owners = @('user-b'); GroupAsMembers = @('G2') })
        $a = script:Get-Action (New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)) 'G'
        $a['Properties'].Contains('Members') | Should -BeFalse
        $a['Properties'].Contains('Owners') | Should -BeFalse
        $a['Properties'].Contains('GroupAsMembers') | Should -BeFalse   # a group in a group would bring its members
    }
}

Describe 'New-ApplyPlan: Conditional Access' {
    It 'always plans Report-only and adds the break-glass users and groups' {
        $src = script:New-Snap @(script:New-Res $script:CA 'CA MFA' @{ State = 'enabled'; IncludeUsers = @('All'); ExcludeUsers = @('GuestsOrExternalUsers') })
        $a = script:Get-Action (New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)) 'CA MFA'
        $a['Status'] | Should -Be 'planned'
        $a['Properties']['State'] | Should -Be 'enabledForReportingButNotEnforced'
        $a['Properties']['ExcludeUsers'] | Should -Contain 'bg-user-0001'
        $a['Properties']['ExcludeUsers'] | Should -Contain 'GuestsOrExternalUsers'
        $a['Properties']['ExcludeGroups'] | Should -Contain 'BG-Group'
    }
    It 'plans Report-only also for a policy that is disabled or already enabled in Dev' {
        $src = script:New-Snap @(script:New-Res $script:CA 'CA' @{ State = 'disabled'; IncludeUsers = @('All') })
        $tgt = script:New-Snap @(script:New-Res $script:CA 'CA' @{ State = 'enabled'; IncludeUsers = @('All') })
        (script:Get-Action (New-ApplyPlan -Source $src -Target $tgt -Config (script:New-Config)) 'CA')['Properties']['State'] | Should -Be 'enabledForReportingButNotEnforced'
    }
    It 'does not duplicate a break-glass user that Prod already excludes' {
        $src = script:New-Snap @(script:New-Res $script:CA 'CA' @{ IncludeUsers = @('All'); ExcludeUsers = @('bg-user-0001') })
        $a = script:Get-Action (New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)) 'CA'
        @($a['Properties']['ExcludeUsers'] | Where-Object { $_ -eq 'bg-user-0001' }).Count | Should -Be 1
    }
    It 'blocks a Conditional Access policy when no break-glass exclusion is configured' {
        $config = script:New-Config
        $config.Remove('BreakGlass'); $config.Remove('BreakGlassGroups')
        $src = script:New-Snap @(script:New-Res $script:CA 'CA' @{ IncludeUsers = @('All') })
        $a = script:Get-Action (New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config $config) 'CA'
        $a['Status'] | Should -Be 'blocked'
        $a['Reason'] | Should -Match 'break-glass'
    }
    It 'blocks a policy that names a specific user (users are not mirrored)' {
        $src = script:New-Snap @(script:New-Res $script:CA 'CA' @{ IncludeUsers = @('All'); ExcludeUsers = @('someone@example.test') })
        $a = script:Get-Action (New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)) 'CA'
        $a['Status'] | Should -Be 'blocked'
        $a['Reason'] | Should -Match 'specific user'
    }
    It 'blocks a policy whose group does not exist in Dev' {
        $src = script:New-Snap @(script:New-Res $script:CA 'CA' @{ IncludeUsers = @('All'); ExcludeGroups = @('SW-Missing') })
        (script:Get-Action (New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)) 'CA')['Status'] | Should -Be 'blocked'
    }
    It 'applies Conditional Access last' {
        $src = script:New-Snap @((script:New-Res $script:CA 'CA' @{ IncludeUsers = @('All') }), (script:New-Res $script:Policy 'P' @{ X = 1 }), (script:New-Res $script:Group 'G' @{}))
        $plan = New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)
        $plan['Actions'][-1]['Name'] | Should -Be 'CA'
        $plan['Actions'][0]['ResourceType'] | Should -Be $script:Group   # groups first (the break-glass group copy and 'G')
        @($plan['Actions'] | Where-Object { $_['Name'] -eq 'G' }).Count | Should -Be 1
    }
}

Describe 'New-ApplyPlan: roles' {
    It 'blocks a role that assigns users' {
        $src = script:New-Snap @(script:New-Res $script:Role 'R' @{ Members = @('user-a') })
        $a = script:Get-Action (New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)) 'R'
        $a['Status'] | Should -Be 'blocked'
        $a['Reason'] | Should -Match 'groups only'
    }
    It 'plans a role without users' {
        $src = script:New-Snap @(script:New-Res $script:Role 'R' @{ Description = 'x' })
        (script:Get-Action (New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)) 'R')['Status'] | Should -Be 'planned'
    }
}

Describe 'New-ApplyPlan: target tenant' {
    It 'refuses a target tenant ID that equals the Prod tenant ID' {
        $config = script:New-Config
        $config['Dev']['TenantId'] = $config['Prod']['TenantId']
        { New-ApplyPlan -Source (script:New-Snap @()) -Target (script:New-Snap @()) -Config $config } | Should -Throw '*Prod tenant ID*'
    }
    It 'refuses a config without a Dev tenant ID' {
        $config = script:New-Config
        $config['Dev'].Remove('TenantId')
        { New-ApplyPlan -Source (script:New-Snap @()) -Target (script:New-Snap @()) -Config $config } | Should -Throw '*Dev tenant ID*'
    }
}

Describe 'Get-ApplyPlanHash' {
    It 'is stable for the same inputs and changes with the content' {
        $src = script:New-Snap @(script:New-Res $script:Policy 'P' @{ Len = 8 })
        $p1 = New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)
        $p2 = New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)
        (Get-ApplyPlanHash -Plan $p1) | Should -Be (Get-ApplyPlanHash -Plan $p2)
        $other = script:New-Snap @(script:New-Res $script:Policy 'P' @{ Len = 9 })
        $p3 = New-ApplyPlan -Source $other -Target (script:New-Snap @()) -Config (script:New-Config)
        (Get-ApplyPlanHash -Plan $p3) | Should -Not -Be (Get-ApplyPlanHash -Plan $p1)
    }
    It 'is the same after the plan went through a JSON file' {
        $src = script:New-Snap @(script:New-Res $script:Policy 'P' @{ Len = 8; Tags = @('a', 'b') }, (script:New-Res $script:CA 'CA' @{ IncludeUsers = @('All') }))
        $plan = New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)
        $again = $plan | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable -Depth 30
        (Get-ApplyPlanHash -Plan $again) | Should -Be (Get-ApplyPlanHash -Plan $plan)
    }
}

Describe 'Export-ApplyPlan' {
    It 'writes JSON and Markdown with the hash and writes nothing else' {
        $src = script:New-Snap @(script:New-Res $script:Policy 'P' @{ Len = 8 })
        $plan = New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)
        $files = Export-ApplyPlan -Plan $plan -HistoryRoot (Join-Path $TestDrive 'History')
        (Get-Content -Raw $files.Markdown) | Should -Match $files.PlanHash
        (Get-Content -Raw $files.Json) | Should -Match 'PlanHash'
        $files.Json | Should -BeLike '*reports*'
    }
}
