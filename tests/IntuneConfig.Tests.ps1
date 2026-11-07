BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'M365Cloning.psd1') -Force
    $script:Valid = Join-Path $PSScriptRoot 'fixtures' 'config.valid.psd1'

    function script:New-Config { Import-M365CloningConfig -Path $script:Valid }
    function script:New-Res($Type, $Name, $Props) {
        @{ displayName = $Name; resourceType = $Type; properties = ($Props + @{ DisplayName = $Name }) }
    }
    function script:New-Snap($Resources) { @{ resources = @($Resources) } }
    function script:Get-Action($Plan, $Name) { @($Plan['Actions'] | Where-Object { $_['Name'] -eq $Name })[0] }

    $script:Filter = 'microsoft.intune.deviceandappmanagementassignmentfilter'
    $script:Compliance = 'microsoft.intune.devicecompliancepolicywindows10'
    $script:Ring = 'microsoft.intune.windowsupdateforbusinessringupdateprofilewindows10'
    $script:AccountProtection = 'microsoft.intune.accountprotectionpolicy'
    $script:Custom = 'microsoft.intune.deviceconfigurationcustompolicywindows10'
    $script:Group = 'microsoft.entra.group'
    $script:WithFilter = { param($filterId) @{ dataType = '#microsoft.graph.allDevicesAssignmentTarget'; deviceAndAppManagementAssignmentFilterType = 'include'; deviceAndAppManagementAssignmentFilterId = $filterId } }
}

Describe 'Resource map: every type has a source or is never copied' {
    It 'names a Microsoft365DSC resource and a source for every type that is applied' {
        $map = InModuleScope M365Cloning { Get-DscResourceMap }
        foreach ($type in $map.Keys) {
            $e = $map[$type]
            $type | Should -Match '^microsoft\.(intune|entra)\.[a-z0-9]+$'
            [string]$e.Source | Should -Not -BeNullOrEmpty
            if (-not $e.Secret) {
                [string]$e.Dsc | Should -Match '^(Intune|AAD)[A-Za-z0-9]+$'
                [string]$e.AssignmentClass | Should -Match '^MSFT_[A-Za-z0-9]+Assignments$'
            }
            else { [string]$e.Dsc | Should -BeNullOrEmpty }
        }
    }
    It 'covers compliance, configuration, endpoint security, update rings and filters' {
        $map = InModuleScope M365Cloning { Get-DscResourceMap }
        foreach ($t in $script:Compliance, $script:Ring, $script:Filter, 'microsoft.intune.settingcatalogcustompolicywindows10', 'microsoft.intune.antiviruspolicywindows10settingcatalog') {
            $map.ContainsKey($t) | Should -BeTrue
        }
        $map[$script:AccountProtection].AssignmentClass | Should -Be 'MSFT_IntuneAccountProtectionPolicyAssignments'
    }
    It 'requests every mapped type in the default snapshot' {
        $map = InModuleScope M365Cloning { Get-DscResourceMap }
        $defaults = @(Get-M365CloningDefaultResources)
        foreach ($type in $map.Keys) { $defaults | Should -Contain $type }
    }
}

Describe 'Intune policies: secrets are never copied' {
    It 'skips a secret-bearing type (Wi-Fi) with a secret reason' {
        $src = script:New-Snap @(script:New-Res 'microsoft.intune.wificonfigurationpolicywindows10' 'Office Wi-Fi' @{ Ssid = 'x' })
        $a = script:Get-Action (New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)) 'Office Wi-Fi'
        $a['Status'] | Should -Be 'skipped'
        $a['Reason'] | Should -Match '^secret:'
        $a['Properties'] | Should -BeNullOrEmpty
    }
    It 'skips a custom profile with an encrypted OMA-URI value' {
        $oma = @(@{ OmaUri = './Device/Vendor/X'; IsEncrypted = $true; SecretReferenceValueId = 'ref-0001'; Value = '****' })
        $src = script:New-Snap @(script:New-Res $script:Custom 'Custom secret' @{ OmaSettings = $oma })
        $a = script:Get-Action (New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)) 'Custom secret'
        $a['Status'] | Should -Be 'skipped'
        $a['Reason'] | Should -Match '^secret:'
    }
    It 'plans a custom profile without encrypted values' {
        $oma = @(@{ OmaUri = './Device/Vendor/Y'; IsEncrypted = $false; Value = '1' })
        $src = script:New-Snap @(script:New-Res $script:Custom 'Custom plain' @{ OmaSettings = $oma })
        (script:Get-Action (New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)) 'Custom plain')['Status'] | Should -Be 'planned'
    }
}

Describe 'Intune policies: assignment filters by name' {
    It 'maps the Prod filter ID to the ID of the Dev filter with the same name' {
        $src = script:New-Snap @(
            (script:New-Res $script:Filter 'Corporate devices' @{ Identity = 'id-prod-f1'; Rule = '(device.deviceOwnership -eq "Corporate")'; Platform = 'windows10AndLater' }),
            (script:New-Res $script:Compliance 'Compliance W' @{ Assignments = @((& $script:WithFilter 'id-prod-f1')) }))
        $tgt = script:New-Snap @(script:New-Res $script:Filter 'Corporate devices' @{ Identity = 'id-dev-f9'; Rule = '(device.deviceOwnership -eq "Corporate")'; Platform = 'windows10AndLater' })
        $a = script:Get-Action (New-ApplyPlan -Source $src -Target $tgt -Config (script:New-Config)) 'Compliance W'
        $a['Status'] | Should -Be 'planned'
        $a['Properties']['Assignments'][0]['deviceAndAppManagementAssignmentFilterId'] | Should -Be 'id-dev-f9'
        $a['AssignmentClass'] | Should -Be 'MSFT_DeviceManagementConfigurationPolicyAssignments'
    }
    It 'creates a filter that Dev lacks and blocks the policy until the next run (needs-filter)' {
        $src = script:New-Snap @(
            (script:New-Res $script:Filter 'Kiosk' @{ Identity = 'id-prod-f2'; Rule = '(device.model -eq "K")'; Platform = 'windows10AndLater' }),
            (script:New-Res $script:Ring 'Ring 1' @{ Assignments = @((& $script:WithFilter 'id-prod-f2')) }))
        $plan = New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)
        $f = script:Get-Action $plan 'Kiosk'
        $f['Operation'] | Should -Be 'Create'
        $f['Status'] | Should -Be 'planned'
        $f['Properties']['Rule'] | Should -Be '(device.model -eq "K")'
        $f['Properties'].Contains('Identity') | Should -BeFalse
        $r = script:Get-Action $plan 'Ring 1'
        $r['Status'] | Should -Be 'blocked'
        $r['Reason'] | Should -Match 'needs-filter'
    }
    It 'blocks a policy whose filter is not in the Prod snapshot' {
        $src = script:New-Snap @(script:New-Res $script:Ring 'Ring 2' @{ Assignments = @((& $script:WithFilter 'id-prod-unknown')) })
        $a = script:Get-Action (New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)) 'Ring 2'
        $a['Status'] | Should -Be 'blocked'
        $a['Reason'] | Should -Match 'filter'
    }
}

Describe 'Intune policies: assignment groups by name' {
    It 'keeps the group by name, without the Prod group ID, and copies a missing inclusion group empty' {
        $asg = @{ dataType = '#microsoft.graph.groupAssignmentTarget'; groupId = 'id-prod-g7'; groupDisplayName = 'CA_Personas_Internals' }
        $src = script:New-Snap @(script:New-Res $script:AccountProtection 'Account protection' @{ Assignments = @($asg) })
        $plan = New-ApplyPlan -Source $src -Target (script:New-Snap @()) -Config (script:New-Config)
        $a = script:Get-Action $plan 'Account protection'
        $a['Status'] | Should -Be 'planned'
        $a['AssignmentClass'] | Should -Be 'MSFT_IntuneAccountProtectionPolicyAssignments'
        $a['Properties']['Assignments'][0]['groupDisplayName'] | Should -Be 'CA_Personas_Internals'
        $a['Properties']['Assignments'][0].Contains('groupId') | Should -BeFalse
        $g = script:Get-Action $plan 'CA_Personas_Internals'
        $g['ResourceType'] | Should -Be $script:Group
        $g['Reason'] | Should -Match 'empty static copy'
        @($plan['Actions'] | Where-Object { $_['Name'] -eq 'CA_Personas_Internals' }).Count | Should -Be 1
    }
    It 'never deletes an Intune policy that exists only in Dev' {
        $plan = New-ApplyPlan -Source (script:New-Snap @()) -Target (script:New-Snap @(script:New-Res $script:Ring 'Dev ring' @{ X = 1 })) -Config (script:New-Config)
        (script:Get-Action $plan 'Dev ring')['Status'] | Should -Be 'skipped'
        ($plan | ConvertTo-Json -Depth 30) | Should -Not -Match 'Absent'
    }
}
