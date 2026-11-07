BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'M365Cloning.psd1') -Force
    $script:Valid = Join-Path $PSScriptRoot 'fixtures' 'config.valid.psd1'

    function script:New-Config { Import-M365CloningConfig -Path $script:Valid }
    function script:New-Res($Type, $Name, $Props) {
        @{ displayName = $Name; resourceType = $Type; properties = ($Props + @{ DisplayName = $Name }) }
    }
    function script:New-Snap($Resources) { @{ resources = @($Resources) } }
    function script:Get-Action($Plan, $Name) { @($Plan['Actions'] | Where-Object { $_['Name'] -eq $Name })[0] }
    function script:Plan($Src, $Tgt = @(), $Config = $null) {
        if (-not $Config) { $Config = script:New-Config }
        New-ApplyPlan -Source (script:New-Snap $Src) -Target (script:New-Snap $Tgt) -Config $Config
    }
    function script:Lic($Plans) { [ordered]@{ Readable = $true; Error = ''; Available = [string[]]@($Plans); Skus = [object[]]@() } }

    # Invented values only. A fake object ID (all zeros) stands for a Prod object ID.
    $script:FakeId = '00000000-0000-0000-0000-00000000000a'
    $script:Category = 'microsoft.intune.devicecategory'
    $script:Esp = 'microsoft.intune.deviceenrollmentstatuspagewindows10'
    $script:Context = 'microsoft.entra.authenticationcontextclassreference'
    $script:CA = 'microsoft.entra.conditionalaccesspolicy'
    $script:Mail = 'microsoft.intune.deviceconfigurationemailprofilepolicywindows10'
}

Describe 'Catalog: copy all unless excluded (ADR 0006)' {
    It 'knows every type of the TCM schema data file' {
        $catalog = InModuleScope M365Cloning { Get-ResourceTypeCatalog }
        $catalog.Count | Should -BeGreaterThan 260
        $catalog[$script:Category]['Handling'] | Should -Be 'generic'
        $catalog[$script:CA]['Handling'] | Should -Be 'special'
        $catalog['microsoft.intune.devicecompliancepolicywindows10']['Handling'] | Should -Be 'mapped'
    }
    It 'requests the generic Entra and Intune types in the default snapshot, but not the excluded ones' {
        $defaults = @(Get-M365CloningDefaultResources -Config (script:New-Config))
        foreach ($t in $script:Category, $script:Esp, $script:Context, 'microsoft.intune.windowsautopilotdeploymentprofileazureadjoined') { $defaults | Should -Contain $t }
        foreach ($t in 'microsoft.entra.securitydefaults', 'microsoft.entra.user', 'microsoft.entra.crosstenantaccesspolicyconfigurationpartner', 'microsoft.intune.devicecleanuprule') { $defaults | Should -Not -Contain $t }
    }
    It 'leaves the workloads that are off by default out of the snapshot' {
        $defaults = @(Get-M365CloningDefaultResources -Config (script:New-Config))
        @($defaults | Where-Object { $_ -like 'microsoft.exchange.*' -or $_ -like 'microsoft.teams.*' -or $_ -like 'microsoft.securityandcompliance.*' }).Count | Should -Be 0
    }
    It 'follows Workloads from the configuration' {
        $c = script:New-Config; $c['Workloads'] = @('Intune')
        $defaults = @(Get-M365CloningDefaultResources -Config $c)
        @($defaults | Where-Object { $_ -like 'microsoft.entra.*' }).Count | Should -Be 0
        $defaults | Should -Contain $script:Category
    }
    It 'leaves a type excluded in the configuration out of the snapshot' {
        $c = script:New-Config; $c['ExcludeResourceTypes'] = @($script:Category)
        @(Get-M365CloningDefaultResources -Config $c) | Should -Not -Contain $script:Category
    }
}

Describe 'Plan: a type without a rule of its own runs without code changes' {
    It 'plans a generic type through the same path, with Ensure Present and without the Prod ID' {
        $plan = script:Plan @(script:New-Res $script:Category 'Kiosk' @{ Id = $script:FakeId; Description = 'Kiosk devices' })
        $a = script:Get-Action $plan 'Kiosk'
        $a['Status'] | Should -Be 'planned'
        $a['DscResource'] | Should -Be 'Intunedevicecategory'
        $a['Properties']['Ensure'] | Should -Be 'Present'
        $a['Properties'].Contains('Id') | Should -BeFalse
        $a['Properties']['Description'] | Should -Be 'Kiosk devices'
    }
    It 'still blocks a type that the catalog does not know at all' {
        $a = script:Get-Action (script:Plan @(script:New-Res 'microsoft.intune.nosuchthing' 'X' @{ A = 1 })) 'X'
        $a['Status'] | Should -Be 'blocked'
        $a['Reason'] | Should -Match 'no Microsoft365DSC resource'
    }
    It 'blocks a generic resource that refers to an object by its Prod ID' {
        $a = script:Get-Action (script:Plan @(script:New-Res $script:Esp 'ESP Kiosk' @{ Priority = 1; SelectedMobileAppIds = @($script:FakeId) })) 'ESP Kiosk'
        $a['Status'] | Should -Be 'blocked'
        $a['Reason'] | Should -Match 'SelectedMobileAppIds'
    }
    It 'plans the same generic resource when it names no object ID' {
        (script:Get-Action (script:Plan @(script:New-Res $script:Esp 'ESP Kiosk' @{ Priority = 1; SelectedMobileAppIds = @() })) 'ESP Kiosk')['Status'] | Should -Be 'planned'
    }
    It 'skips the tenant default (priority 0) that every tenant has' {
        $a = script:Get-Action (script:Plan @(script:New-Res $script:Esp 'All users and all devices' @{ Priority = 0 })) 'All users and all devices'
        $a['Status'] | Should -Be 'skipped'
        $a['Reason'] | Should -Match '^tenant default'
    }
}

Describe 'Plan: exclusion list' {
    It 'shows an excluded type from the data file as skipped with an excluded reason' {
        $plan = script:Plan @(script:New-Res 'microsoft.entra.securitydefaults' 'Security defaults' @{ IsEnabled = $true })
        $a = script:Get-Action $plan 'Security defaults'
        $a['Status'] | Should -Be 'skipped'
        $a['Reason'] | Should -Match '^excluded: '
        @($a['Properties'].Keys).Count | Should -Be 0   # empty object: nothing is written (issue #51)
        $plan['Summary']['Excluded'] | Should -Be 1
        $plan['Summary']['Skipped'] | Should -Be 0
    }
    It 'excludes a type from the configuration' {
        $c = script:New-Config; $c['ExcludeResourceTypes'] = @{ $script:Category = 'not needed in Dev' }
        $a = script:Get-Action (script:Plan @(script:New-Res $script:Category 'Kiosk' @{}) @() $c) 'Kiosk'
        $a['Status'] | Should -Be 'skipped'
        $a['Reason'] | Should -Be 'excluded: not needed in Dev'
    }
    It 'excludes a type of a workload that is off' {
        $c = script:New-Config; $c['Workloads'] = @('Intune')
        $a = script:Get-Action (script:Plan @(script:New-Res 'microsoft.entra.attributeset' 'Set1' @{ Id = 'Set1' }) @() $c) 'Set1'
        $a['Reason'] | Should -Match 'workload Entra is off'
    }
    It 'counts per type and lists the excluded types' {
        $plan = script:Plan @((script:New-Res $script:Category 'Kiosk' @{}), (script:New-Res 'microsoft.entra.securitydefaults' 'Security defaults' @{}))
        $row = @($plan['TypeSummary'] | Where-Object { $_['ResourceType'] -eq $script:Category })[0]
        $row['Planned'] | Should -Be 1
        @($plan['ExcludedTypes'] | ForEach-Object { $_['ResourceType'] }) | Should -Contain 'microsoft.entra.user'
        $md = ConvertTo-ApplyPlanMarkdown -Plan $plan -PlanHash 'h'
        $md | Should -Match 'Per resource type'
        $md | Should -Match 'Excluded resource types'
        $md | Should -Match 'Excluded: 1'
    }
}

Describe 'Plan: secrets in generic types' {
    It 'skips a secret-bearing type from the data file' {
        $a = script:Get-Action (script:Plan @(script:New-Res 'microsoft.intune.wificonfigurationpolicyios' 'WLAN' @{ Ssid = 'corp' })) 'WLAN'
        $a['Status'] | Should -Be 'skipped'
        $a['Reason'] | Should -Match '^secret:'
    }
    It 'skips a resource whose secret property is set' {
        $a = script:Get-Action (script:Plan @(script:New-Res $script:Mail 'Mail' @{ Password = 'invented' })) 'Mail'
        $a['Status'] | Should -Be 'skipped'
        $a['Reason'] | Should -Match "secret: the property 'Password'"
        ($a | ConvertTo-Json -Depth 20) | Should -Not -Match 'invented'
    }
}

Describe 'Plan: authentication contexts by key (issue #38)' {
    BeforeAll {
        $script:Ctx = { script:New-Res $script:Context 'Sensitive apps' @{ Id = 'c1'; IsAvailable = $true } }
        $script:Pol = { param($ctx) script:New-Res $script:CA 'CA Step-up' @{ State = 'enabled'; IncludeUsers = @('All'); AuthenticationContexts = $ctx } }
    }
    It 'creates the context with its key before the policy that names it' {
        $plan = script:Plan @((& $script:Ctx), (& $script:Pol @('c1')))
        $c = script:Get-Action $plan 'Sensitive apps'
        $c['Status'] | Should -Be 'planned'
        $c['Properties']['Id'] | Should -Be 'c1'
        (script:Get-Action $plan 'CA Step-up')['Status'] | Should -Be 'planned'
        $names = @($plan['Actions'] | ForEach-Object { $_['Name'] })
        [array]::IndexOf($names, 'Sensitive apps') | Should -BeLessThan ([array]::IndexOf($names, 'CA Step-up'))
    }
    It 'blocks the policy when the context is neither in Dev nor in the plan' {
        $a = script:Get-Action (script:Plan @(& $script:Pol @('c2'))) 'CA Step-up'
        $a['Status'] | Should -Be 'blocked'
        $a['Reason'] | Should -Match "needs-auth-context: AuthenticationContexts 'c2'"
    }
    It 'accepts a context that Dev already has under the same key' {
        $dev = @(script:New-Res $script:Context 'Other name' @{ Id = 'c2' })
        (script:Get-Action (script:Plan @(& $script:Pol @('c2')) $dev) 'CA Step-up')['Status'] | Should -Be 'planned'
    }
}

Describe 'Plan: special handling is not bypassed by the generic path' {
    It 'keeps Conditional Access Report-only with the break-glass exclusion' {
        $a = script:Get-Action (script:Plan @(script:New-Res $script:CA 'CA Base' @{ State = 'enabled'; IncludeUsers = @('All') })) 'CA Base'
        $a['Properties']['State'] | Should -Be 'enabledForReportingButNotEnforced'
        @($a['Properties']['ExcludeUsers']) | Should -Contain 'bg-user-0001'
    }
    It 'keeps groups as empty static copies' {
        $a = script:Get-Action (script:Plan @(script:New-Res 'microsoft.entra.group' 'G1' @{ Members = @('someone'); GroupTypes = @('DynamicMembership'); MembershipRule = 'x' })) 'G1'
        $a['Properties'].Contains('Members') | Should -BeFalse
        $a['Properties'].Contains('MembershipRule') | Should -BeFalse
    }
}

Describe 'Licence check covers new types' {
    It 'blocks a generic Intune type when Dev has no Intune licence' {
        $plan = Add-PlanLicenceCheck -Plan (script:Plan @(script:New-Res $script:Category 'Kiosk' @{})) -Licences (script:Lic @('AAD_PREMIUM'))
        $a = script:Get-Action $plan 'Kiosk'
        $a['Status'] | Should -Be 'blocked'
        $a['Reason'] | Should -Match '^license: Microsoft Intune'
    }
    It 'blocks an authentication context without Entra ID P1' {
        $plan = Add-PlanLicenceCheck -Plan (script:Plan @(script:New-Res $script:Context 'Sensitive apps' @{ Id = 'c1' })) -Licences (script:Lic @('INTUNE_A'))
        (script:Get-Action $plan 'Sensitive apps')['Status'] | Should -Be 'blocked'
    }
}

Describe 'Config: Workloads and ExcludeResourceTypes' {
    It 'rejects an unknown workload' {
        $p = Join-Path $TestDrive 'w.psd1'
        (Get-Content -Raw $script:Valid).Replace('ProtectedAccounts', "Workloads = @('Sharepoint')`n    ProtectedAccounts") | Set-Content $p
        { Import-M365CloningConfig -Path $p } | Should -Throw
    }
    It 'rejects an exclusion that is not a resource type name' {
        $p = Join-Path $TestDrive 'x.psd1'
        (Get-Content -Raw $script:Valid).Replace('ProtectedAccounts', "ExcludeResourceTypes = @('devicecategory')`n    ProtectedAccounts") | Set-Content $p
        { Import-M365CloningConfig -Path $p } | Should -Throw
    }
    It 'accepts both settings' {
        $p = Join-Path $TestDrive 'ok.psd1'
        (Get-Content -Raw $script:Valid).Replace('ProtectedAccounts', "Workloads = @('Intune', 'Entra')`n    ExcludeResourceTypes = @('microsoft.intune.devicecategory')`n    ProtectedAccounts") | Set-Content $p
        { Import-M365CloningConfig -Path $p } | Should -Not -Throw
    }
}
