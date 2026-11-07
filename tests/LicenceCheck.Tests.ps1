BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'M365Cloning.psd1') -Force
    $script:SkuFile = Join-Path $PSScriptRoot 'fixtures' 'dev.subscribedskus.json'
    function script:New-Action($Type, $Name, $Op = 'Create', $Props = $null, $Status = 'planned') {
        [ordered]@{ ResourceType = $Type; Name = $Name; Operation = $Op; Status = $Status; Reason = ''; DscResource = ''; Differences = [object[]]@(); Properties = $Props }
    }
    function script:New-Plan($Actions) {
        [ordered]@{ TargetTenantId = 'tenant-dev-0001'; Actions = [object[]]@($Actions); Notes = [string[]]@(); Summary = [ordered]@{ Planned = @($Actions).Count; Blocked = 0; Skipped = 0 } }
    }
    function script:Lic($Plans) { [ordered]@{ Readable = $true; Error = ''; Available = [string[]]@($Plans); Skus = [object[]]@() } }
    function script:Get-Action($Plan, $Name) { @($Plan['Actions'] | Where-Object { $_['Name'] -eq $Name })[0] }
    $script:CA = 'microsoft.entra.conditionalaccesspolicy'
}

Describe 'Licence view from subscribedSkus' {
    It 'counts only Success plans of Enabled or Warning SKUs' {
        $l = Get-TenantLicences -Path $script:SkuFile
        $l.Readable | Should -BeTrue
        $l.Available | Should -Contain 'AAD_PREMIUM'
        $l.Available | Should -Contain 'INTUNE_A'
        $l.Available | Should -Not -Contain 'AAD_PREMIUM_P2'
    }
    It 'does not count PendingActivation' {
        $l = ConvertTo-TenantLicences -SubscribedSkus @{ value = @(@{ skuPartNumber = 'X'; capabilityStatus = 'Enabled'; servicePlans = @(@{ servicePlanName = 'INTUNE_A'; provisioningStatus = 'PendingActivation' }) }) }
        $l.Available.Count | Should -Be 0
    }
    It 'returns Readable false for a missing file instead of throwing' {
        $l = Get-TenantLicences -Path (Join-Path $TestDrive 'nope.json')
        $l.Readable | Should -BeFalse
        $l.Error | Should -Match 'not found'
    }
    It 'reads online with GET only' {
        InModuleScope M365Cloning {
            $script:seen = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-UtcmGraphRequest { $script:seen.Add("$Method $Uri"); [pscustomobject]@{ value = @([pscustomobject]@{ skuPartNumber = 'X'; capabilityStatus = 'Enabled'; servicePlans = @([pscustomobject]@{ servicePlanName = 'AAD_PREMIUM'; provisioningStatus = 'Success' }) }) } }
            $l = Get-TenantLicences -Token (ConvertTo-SecureString 'x' -AsPlainText -Force)
            $l.Available | Should -Contain 'AAD_PREMIUM'
            @($script:seen) | Should -Be @('GET https://graph.microsoft.com/v1.0/subscribedSkus')
        }
    }
    It 'returns Readable false when Graph fails' {
        InModuleScope M365Cloning {
            Mock Invoke-UtcmGraphRequest { throw 'Forbidden' }
            (Get-TenantLicences -Token (ConvertTo-SecureString 'x' -AsPlainText -Force)).Readable | Should -BeFalse
        }
    }
}

Describe 'Licence check in the plan' {
    It 'blocks a risk-based Conditional Access policy without P2' {
        $plan = New-Plan @(New-Action $script:CA 'CA401-Risk' 'Create' @{ SignInRiskLevels = @('high') })
        $plan = Add-PlanLicenceCheck -Plan $plan -Licences (Lic @('AAD_PREMIUM'))
        $a = Get-Action $plan 'CA401-Risk'
        $a['Status'] | Should -Be 'blocked'
        $a['Reason'] | Should -Match 'license: Risk-based Conditional Access'
        $plan['Summary']['Blocked'] | Should -Be 1
        $plan['Summary']['Planned'] | Should -Be 0
        @($plan['Licences']['Missing']).Count | Should -Be 1
    }
    It 'keeps a risk-based policy when P2 is there' {
        $plan = New-Plan @(New-Action $script:CA 'CA401-Risk' 'Create' @{ SignInRiskLevels = @('high') })
        $plan = Add-PlanLicenceCheck -Plan $plan -Licences (Lic @('AAD_PREMIUM', 'AAD_PREMIUM_P2'))
        (Get-Action $plan 'CA401-Risk')['Status'] | Should -Be 'planned'
        @($plan['Licences']['Missing']).Count | Should -Be 0
    }
    It 'needs only P1 for a policy without risk' {
        $plan = New-Plan @(New-Action $script:CA 'CA001-Global' 'Update' @{ SignInRiskLevels = @(); UserRiskLevels = $null })
        $plan = Add-PlanLicenceCheck -Plan $plan -Licences (Lic @('AAD_PREMIUM'))
        (Get-Action $plan 'CA001-Global')['Status'] | Should -Be 'planned'
    }
    It 'blocks Intune policies without an Intune plan and accepts Intune for Education' {
        $plan = New-Plan @(New-Action 'microsoft.intune.devicecompliancepolicywindows10' 'Win-Compliance')
        $plan = Add-PlanLicenceCheck -Plan $plan -Licences (Lic @('AAD_PREMIUM'))
        (Get-Action $plan 'Win-Compliance')['Status'] | Should -Be 'blocked'
        $plan2 = New-Plan @(New-Action 'microsoft.intune.devicecompliancepolicywindows10' 'Win-Compliance')
        (Get-Action (Add-PlanLicenceCheck -Plan $plan2 -Licences (Lic @('INTUNE_EDU'))) 'Win-Compliance')['Status'] | Should -Be 'planned'
    }
    It 'blocks named locations, strengths and the cross-tenant partner without P1' {
        $plan = New-Plan @(
            New-Action 'microsoft.entra.namedlocationpolicy' 'Office'
            New-Action 'microsoft.entra.authenticationstrengthpolicy' 'Custom-Strength'
            New-Action 'microsoft.entra.crosstenantaccesspolicyconfigurationpartner' 'Prod partner'
        )
        $plan = Add-PlanLicenceCheck -Plan $plan -Licences (Lic @())
        @($plan['Actions'] | Where-Object { $_['Status'] -eq 'blocked' }).Count | Should -Be 3
    }
    It 'leaves free types alone (groups, users, invitations)' {
        $plan = New-Plan @(
            New-Action 'microsoft.entra.group' 'CA-Persona-Admins'
            New-Action 'microsoft.graph.user' 'test.user'
            New-Action 'microsoft.graph.invitation' 'admin.guest'
        )
        $plan = Add-PlanLicenceCheck -Plan $plan -Licences (Lic @())
        @($plan['Actions'] | Where-Object { $_['Status'] -eq 'planned' }).Count | Should -Be 3
    }
    It 'gives only a warning for a rule that Learn does not confirm' {
        $plan = New-Plan @(New-Action 'microsoft.entra.termsofuse' 'ToU')
        $plan = Add-PlanLicenceCheck -Plan $plan -Licences (Lic @())
        (Get-Action $plan 'ToU')['Status'] | Should -Be 'planned'
        @($plan['Licences']['Warnings']).Count | Should -Be 1
    }
    It 'blocks entries with a known requirement when the list is not readable' {
        $plan = New-Plan @(
            New-Action $script:CA 'CA001-Global'
            New-Action 'microsoft.entra.group' 'CA-Persona-Admins'
        )
        $plan = Add-PlanLicenceCheck -Plan $plan -Licences ([ordered]@{ Readable = $false; Error = 'Forbidden'; Available = [string[]]@(); Skus = [object[]]@() })
        (Get-Action $plan 'CA001-Global')['Status'] | Should -Be 'blocked'
        (Get-Action $plan 'CA001-Global')['Reason'] | Should -Match 'not verified'
        (Get-Action $plan 'CA-Persona-Admins')['Status'] | Should -Be 'planned'
        $plan['Licences']['Readable'] | Should -BeFalse
    }
    It 'never touches deletes or entries that are not planned' {
        $plan = New-Plan @(
            New-Action $script:CA 'Old-Policy' 'Delete'
            New-Action $script:CA 'Skipped' 'Update' $null 'skipped'
        )
        $plan = Add-PlanLicenceCheck -Plan $plan -Licences (Lic @())
        (Get-Action $plan 'Old-Policy')['Status'] | Should -Be 'planned'
        (Get-Action $plan 'Skipped')['Status'] | Should -Be 'skipped'
    }
    It 'keeps InBaseline consistent for the baseline plan' {
        $plan = New-Plan @(New-Action 'microsoft.entra.crosstenantaccesspolicyconfigurationpartner' 'Prod partner')
        $plan['Summary']['InBaseline'] = $false
        $plan = Add-PlanLicenceCheck -Plan $plan -Licences (Lic @())
        $plan['Summary']['InBaseline'] | Should -BeFalse
    }
    It 'shows a Licences section in the preview and changes the plan hash' {
        $plan = New-Plan @(New-Action $script:CA 'CA001-Global')
        $before = Get-ApplyPlanHash -Plan $plan
        $plan = Add-PlanLicenceCheck -Plan $plan -Licences (Lic @())
        (Get-ApplyPlanHash -Plan $plan) | Should -Not -Be $before
        $md = ConvertTo-ApplyPlanMarkdown -Plan $plan -PlanHash 'h'
        $md | Should -Match '## Licences'
        $md | Should -Match 'AAD_PREMIUM'
    }
    It 'is deterministic: same plan and licences give the same hash' {
        $one = Add-PlanLicenceCheck -Plan (New-Plan @(New-Action $script:CA 'A'; New-Action 'microsoft.intune.roledefinition' 'B')) -Licences (Lic @('INTUNE_A'))
        $two = Add-PlanLicenceCheck -Plan (New-Plan @(New-Action $script:CA 'A'; New-Action 'microsoft.intune.roledefinition' 'B')) -Licences (Lic @('INTUNE_A'))
        (Get-ApplyPlanHash -Plan $one) | Should -Be (Get-ApplyPlanHash -Plan $two)
    }
    It 'has a Learn source for every rule' {
        InModuleScope M365Cloning {
            foreach ($r in @(Get-LicenceRequirementMap)) { $r.Source | Should -Not -BeNullOrEmpty }
        }
    }
}
