# Conditional Access dependencies (issue #33): named locations, authentication strengths, authentication methods.
# Invented values only; IP ranges from the documentation networks (RFC 5737, RFC 3849).
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'M365Cloning.psd1') -Force
    $script:Valid = Join-Path $PSScriptRoot 'fixtures' 'config.valid.psd1'

    function script:New-Config { Import-M365CloningConfig -Path $script:Valid }
    function script:New-Res($Type, $Name, $Props) {
        @{ displayName = $Name; resourceType = $Type; properties = ($Props + @{ DisplayName = $Name }) }
    }
    function script:New-Snap($Resources) { @{ resources = @($Resources) } }
    function script:Get-Action($Plan, $Name) { @($Plan['Actions'] | Where-Object { $_['Name'] -eq $Name })[0] }
    function script:Plan($Src, $Tgt) { New-ApplyPlan -Source (script:New-Snap $Src) -Target (script:New-Snap $Tgt) -Config (script:New-Config) }

    $script:CA = 'microsoft.entra.conditionalaccesspolicy'
    $script:Loc = 'microsoft.entra.namedlocationpolicy'
    $script:Strength = 'microsoft.entra.authenticationstrengthpolicy'
    $script:Method = 'microsoft.entra.authenticationmethodpolicyfido2'
    $script:Office = { script:New-Res $script:Loc 'Office Network' @{ OdataType = '#microsoft.graph.ipNamedLocation'; IpRanges = @('192.0.2.0/24', '2001:db8::/32'); IsTrusted = $true; Id = 'loc-prod-0001' } }
    $script:Policy = {
        param($Extra)
        $p = @{ State = 'enabled'; IncludeUsers = @('All'); BuiltInControls = @('mfa') }
        foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] }
        script:New-Res $script:CA 'CA200-Internals-BaseProtection' $p
    }
}

Describe 'Resource map: Conditional Access dependencies' {
    It 'maps named locations and authentication strengths before Conditional Access' {
        $map = InModuleScope M365Cloning { Get-DscResourceMap }
        $map[$script:Loc].Dsc | Should -Be 'AADNamedLocationPolicy'
        $map[$script:Strength].Dsc | Should -Be 'AADAuthenticationStrengthPolicy'
        $map[$script:Loc].Order | Should -BeLessThan $map[$script:CA].Order
        $map[$script:Strength].Order | Should -BeLessThan $map[$script:CA].Order
    }
    It 'marks the authentication method policies as report-only and requests them in the snapshot' {
        $map = InModuleScope M365Cloning { Get-DscResourceMap }
        $methods = @($map.Keys | Where-Object { $_ -like 'microsoft.entra.authenticationmethodpolicy*' })
        $methods.Count | Should -BeGreaterThan 1
        foreach ($m in $methods) { $map[$m].ReportOnly | Should -BeTrue; [string]$map[$m].Dsc | Should -BeNullOrEmpty }
        $defaults = @(Get-M365CloningDefaultResources)
        foreach ($t in @($script:Loc, $script:Strength) + $methods) { $defaults | Should -Contain $t }
    }
}

Describe 'Apply plan: named locations' {
    It 'creates a missing named location before the policy that names it, both planned' {
        $plan = script:Plan @((& $script:Office), (& $script:Policy @{ IncludeLocations = @('All'); ExcludeLocations = @('Office Network') })) @()
        $loc = script:Get-Action $plan 'Office Network'
        $loc['Status'] | Should -Be 'planned'
        $loc['DscResource'] | Should -Be 'AADNamedLocationPolicy'
        $loc['Properties'].Contains('Id') | Should -BeFalse
        $loc['Properties']['IpRanges'] | Should -Contain '192.0.2.0/24'
        $ca = script:Get-Action $plan 'CA200-Internals-BaseProtection'
        $ca['Status'] | Should -Be 'planned'
        $ca['Properties']['ExcludeLocations'] | Should -Contain 'Office Network'
        $names = @($plan['Actions'] | ForEach-Object { $_['Name'] })
        [array]::IndexOf($names, 'Office Network') | Should -BeLessThan ([array]::IndexOf($names, 'CA200-Internals-BaseProtection'))
    }
    It 'resolves a location that already exists in Dev by name' {
        $plan = script:Plan @((& $script:Office), (& $script:Policy @{ IncludeLocations = @('Office Network') })) @((& $script:Office))
        (script:Get-Action $plan 'CA200-Internals-BaseProtection')['Status'] | Should -Be 'planned'
    }
    It 'blocks a policy whose location is neither in Dev nor in the plan (fail-closed)' {
        $a = script:Get-Action (script:Plan @((& $script:Policy @{ ExcludeLocations = @('Branch Office') })) @()) 'CA200-Internals-BaseProtection'
        $a['Status'] | Should -Be 'blocked'
        $a['Reason'] | Should -Match 'needs-location'
        $a['Properties'] | Should -BeNullOrEmpty
    }
    It 'keeps the keywords All and AllTrusted' {
        $a = script:Get-Action (script:Plan @((& $script:Policy @{ IncludeLocations = @('All'); ExcludeLocations = @('AllTrusted') })) @()) 'CA200-Internals-BaseProtection'
        $a['Status'] | Should -Be 'planned'
    }
    It 'blocks a location that is named by object ID' {
        $a = script:Get-Action (script:Plan @((& $script:Policy @{ IncludeLocations = @('00000000-0000-0000-0000-00000000aaaa') })) @()) 'CA200-Internals-BaseProtection'
        $a['Status'] | Should -Be 'blocked'
        $a['Reason'] | Should -Match 'by ID'
    }
    It 'never deletes a named location that exists only in Dev' {
        $a = script:Get-Action (script:Plan @() @((& $script:Office))) 'Office Network'
        $a['Operation'] | Should -Be 'SkipDelete'
        $a['Status'] | Should -Be 'skipped'
    }
}

Describe 'Apply plan: authentication strengths' {
    It 'creates a custom strength before the policy and resolves it by name' {
        $custom = script:New-Res $script:Strength 'Admin Phishing-Resistant' @{ AllowedCombinations = @('fido2', 'windowsHelloForBusiness') }
        $plan = script:Plan @($custom, (& $script:Policy @{ AuthenticationStrength = 'Admin Phishing-Resistant'; BuiltInControls = @() })) @()
        (script:Get-Action $plan 'Admin Phishing-Resistant')['Status'] | Should -Be 'planned'
        (script:Get-Action $plan 'CA200-Internals-BaseProtection')['Status'] | Should -Be 'planned'
    }
    It 'accepts a built-in strength without copying it' {
        $a = script:Get-Action (script:Plan @((& $script:Policy @{ AuthenticationStrength = 'Phishing-resistant MFA'; BuiltInControls = @() })) @()) 'CA200-Internals-BaseProtection'
        $a['Status'] | Should -Be 'planned'
    }
    It 'never changes a built-in strength' {
        $a = script:Get-Action (script:Plan @((script:New-Res $script:Strength 'Passwordless MFA' @{ AllowedCombinations = @('fido2') })) @()) 'Passwordless MFA'
        $a['Status'] | Should -Be 'skipped'
        $a['Reason'] | Should -Match 'built-in'
    }
    It 'blocks a policy whose strength is missing in Dev and not in the plan' {
        $a = script:Get-Action (script:Plan @((& $script:Policy @{ AuthenticationStrength = 'Unknown Strength'; BuiltInControls = @() })) @()) 'CA200-Internals-BaseProtection'
        $a['Status'] | Should -Be 'blocked'
        $a['Reason'] | Should -Match 'needs-auth-strength'
    }
}

Describe 'Apply plan: authentication methods are report-only' {
    It 'shows a method policy difference but never applies it' {
        $plan = script:Plan @((script:New-Res $script:Method 'Fido2' @{ State = 'enabled'; Id = 'Fido2' })) @((script:New-Res $script:Method 'Fido2' @{ State = 'disabled'; Id = 'Fido2' }))
        $a = script:Get-Action $plan 'Fido2'
        $a['Operation'] | Should -Be 'Update'
        $a['Status'] | Should -Be 'skipped'
        $a['Reason'] | Should -Match '^report-only:'
        $a['Properties'] | Should -BeNullOrEmpty
    }
}

Describe 'Reset: Conditional Access dependencies' {
    BeforeAll {
        $script:ResetBase = "Prod=@{TenantId='tenant-prod-0001';ClientId='c';CertThumbprint='x'}; Dev=@{TenantId='tenant-dev-0001';ClientId='client-dev-0001';CertThumbprint='x';AllowReset=`$true}; BreakGlass=@('bg-user@dev.example'); BreakGlassGroups=@('CA-BreakglassAccounts'); ProtectedAccounts=@('dev.admin@dev.example')"
        function script:New-ResetConfig {
            $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.psd1')
            Set-Content -LiteralPath $path -Value "@{ $script:ResetBase }"
            Import-M365CloningConfig -Path $path
        }
        function script:New-ResetInventory {
            @{
                ProdGlobalAdmins = @(@{ id = 'prod-admin-0001'; userPrincipalName = 'admin.one@prod.example'; mail = 'admin.one@prod.example' })
                ProdReadError    = ''
                Dev              = @{
                    Users                     = @(
                        @{ id = 'user-admin-0001'; userPrincipalName = 'dev.admin@dev.example'; mail = ''; userType = 'Member' }
                        @{ id = 'user-bg-0001'; userPrincipalName = 'bg-user@dev.example'; mail = ''; userType = 'Member' }
                    )
                    Groups                    = @(@{ id = 'group-bg-0001'; displayName = 'CA-BreakglassAccounts'; groupTypes = @() })
                    ConditionalAccessPolicies = @(
                        @{ id = 'ca-bg-0001'; displayName = 'CA900-BreakGlass-Block-Untrusted'; state = 'enabled'
                            conditions = @{ users = @{ includeUsers = @(); includeGroups = @('group-bg-0001') }; locations = @{ includeLocations = @('All'); excludeLocations = @('loc-bg-0001') } } }
                        @{ id = 'ca-0002'; displayName = 'CA200-Internals-Base'; state = 'enabled'
                            conditions = @{ users = @{ includeUsers = @('All'); includeGroups = @() }; locations = @{ includeLocations = @('loc-old-0001') } } }
                    )
                    NamedLocations            = @(
                        @{ id = 'loc-bg-0001'; displayName = 'Emergency Network'; isTrusted = $false }
                        @{ id = 'loc-trusted-0001'; displayName = 'Office Network'; isTrusted = $true }
                        @{ id = 'loc-old-0001'; displayName = 'Old Branch'; isTrusted = $false }
                    )
                    AuthenticationStrengths   = @(
                        @{ id = '00000000-0000-0000-0000-000000000004'; displayName = 'Phishing-resistant MFA'; policyType = 'builtIn' }
                        @{ id = 'str-0001'; displayName = 'Dev Trial Strength'; policyType = 'custom' }
                    )
                    DeviceConfigurations = @(); DeviceCompliancePolicies = @(); ConfigurationPolicies = @(); Intents = @(); AssignmentFilters = @()
                    ManagedDevices = @(); CrossTenantPartners = @(); ToolkitServicePrincipals = @()
                }
            }
        }
    }
    It 'protects the named location of a break-glass policy and never plans to delete it' {
        $plan = New-DevResetPlan -Config (script:New-ResetConfig) -Inventory (script:New-ResetInventory) -Mode Full
        @($plan['Protected'] | Where-Object { $_['Kind'] -eq 'NamedLocation' -and $_['Name'] -eq 'Emergency Network' }).Count | Should -Be 1
        @($plan['Actions'] | Where-Object { $_['Name'] -eq 'Emergency Network' }).Count | Should -Be 0
    }
    It 'keeps trusted locations and built-in strengths, deletes the rest after the policies (Full)' {
        $plan = New-DevResetPlan -Config (script:New-ResetConfig) -Inventory (script:New-ResetInventory) -Mode Full
        $trusted = script:Get-Action $plan 'Office Network'
        $trusted['Status'] | Should -Be 'skipped'
        $trusted['Reason'] | Should -Match 'trusted'
        @($plan['Actions'] | Where-Object { $_['Name'] -eq 'Phishing-resistant MFA' }).Count | Should -Be 0
        (script:Get-Action $plan 'Old Branch')['Status'] | Should -Be 'planned'
        (script:Get-Action $plan 'Dev Trial Strength')['Status'] | Should -Be 'planned'
        $deletes = @($plan['Actions'] | Where-Object { $_['Operation'] -eq 'Delete' } | ForEach-Object { $_['ResourceType'] })
        [array]::LastIndexOf($deletes, 'ConditionalAccessPolicy') | Should -BeLessThan ([array]::IndexOf($deletes, 'NamedLocation'))
    }
    It 'deletes only Dev-only locations and strengths in Align mode' {
        $comparison = [pscustomobject]@{ Types = @(
                [pscustomobject]@{ ResourceType = $script:Loc; Added = @(); Removed = @('Old Branch'); Changed = @(); Unchanged = 1 }
                [pscustomobject]@{ ResourceType = $script:Strength; Added = @(); Removed = @(); Changed = @(); Unchanged = 1 }
            ) }
        $plan = New-DevResetPlan -Config (script:New-ResetConfig) -Inventory (script:New-ResetInventory) -Mode Align -Comparison $comparison
        (script:Get-Action $plan 'Old Branch')['Status'] | Should -Be 'planned'
        (script:Get-Action $plan 'Dev Trial Strength')['Operation'] | Should -Be 'Keep'
    }
    It 'allows only the documented delete paths for the new kinds' {
        $cfg = script:New-ResetConfig
        InModuleScope M365Cloning -Parameters @{ Cfg = $cfg } {
            param($Cfg)
            { Assert-DevResetWriteAllowed -Method DELETE -Uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/namedLocations/loc-old-0001' -TenantId 'tenant-dev-0001' -Config $Cfg } | Should -Not -Throw
            { Assert-DevResetWriteAllowed -Method DELETE -Uri 'https://graph.microsoft.com/v1.0/policies/authenticationStrengthPolicies/str-0001' -TenantId 'tenant-dev-0001' -Config $Cfg } | Should -Not -Throw
            { Assert-DevResetWriteAllowed -Method PATCH -Uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/namedLocations/loc-old-0001' -Body @{ isTrusted = $false } -TenantId 'tenant-dev-0001' -Config $Cfg } | Should -Throw
            { Assert-DevResetWriteAllowed -Method DELETE -Uri 'https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy' -TenantId 'tenant-dev-0001' -Config $Cfg } | Should -Throw
            Get-DevResetEndpoint -Kind 'NamedLocation' | Should -Be 'v1.0/identity/conditionalAccess/namedLocations'
        }
    }
    It 'refuses a plan that deletes a protected named location' {
        $cfg = script:New-ResetConfig
        $plan = New-DevResetPlan -Config $cfg -Inventory (script:New-ResetInventory) -Mode Full
        $plan['Actions'] = [object[]]@($plan['Actions']) + @([ordered]@{ ResourceType = 'NamedLocation'; Name = 'Emergency Network'; Operation = 'Delete'; Status = 'planned'; Reason = 'x'; DscResource = ''; Differences = @(); Properties = [ordered]@{ Id = 'loc-bg-0001'; Kind = 'NamedLocation' } })
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $writes = [System.Collections.Generic.List[object]]::new()
        $w = { param($Method, $Uri, $Body, $TenantId, $Config) $writes.Add($Uri); $null }.GetNewClosure()
        { Invoke-DevResetPlan -Plan $plan -Config $cfg -ConfirmPlanHash (Get-ApplyPlanHash -Plan $plan) -ConfirmTenant 'tenant-dev-0001' -GraphWriter $w -HistoryRoot $root } | Should -Throw '*protection list*'
        $writes.Count | Should -Be 0
    }
}
