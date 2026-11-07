BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'M365Cloning.psd1') -Force
    # Invented SKUs; service plan names are the public ones from Learn (licensing-service-plan-reference).
    function script:Sku($Part, $Plans, $Status = 'Enabled', $Enabled = 25, $Consumed = 0) {
        @{ skuPartNumber = $Part; capabilityStatus = $Status; appliesTo = 'User'; consumedUnits = $Consumed
            prepaidUnits = @{ enabled = $Enabled; warning = 0; suspended = 0; lockedOut = 0 }
            servicePlans = @($Plans | ForEach-Object { @{ servicePlanName = $_; provisioningStatus = 'Success' } }) }
    }
    function script:Lic($Skus) { ConvertTo-TenantLicences -SubscribedSkus @{ value = @($Skus) } }
    function script:Unreadable { [ordered]@{ Readable = $false; Error = 'Forbidden'; Available = [string[]]@(); Skus = [object[]]@() } }
    function script:Snap($Resources) { @{ resources = @($Resources) } }
    function script:Res($Type, $Name, $Props = @{}) { @{ resourceType = $Type; displayName = $Name; properties = $Props } }
    $script:Full = @('INTUNE_A', 'AAD_PREMIUM', 'AAD_PREMIUM_P2')
    $script:ProdFull = Lic @(Sku 'PROD_E5' $script:Full)
    $script:Cfg = @{ DevUsers = @(@{ Type = 'TestUser'; Id = 'test1@example.test'; Persona = 'Internals' }, @{ Type = 'AdminGuest'; Id = 'admin@example.test'; Persona = 'Admins' }) }
    $script:CA = 'microsoft.entra.conditionalaccesspolicy'
}

Describe 'Tenant suitability check' {
    It 'is green when Dev has everything Prod uses' {
        $r = Get-TenantFitAssessment -ProdLicences $script:ProdFull -DevLicences (Lic @(Sku 'DEV_E5' $script:Full)) -ProdSnapshot (Snap @(Res $script:CA 'CA001')) -Config $script:Cfg
        $r.Status | Should -Be 'green'
        $r.Verified | Should -BeTrue
        $r.Schema | Should -Be 'm365cloning.tenantfit/1'
    }
    It 'is yellow when Prod uses risk-based CA and Dev has no P2' {
        $prodSnap = Snap @(Res $script:CA 'CA101' @{ SignInRiskLevels = @('high') })
        $r = Get-TenantFitAssessment -ProdLicences $script:ProdFull -DevLicences (Lic @(Sku 'DEV_E3' @('INTUNE_A', 'AAD_PREMIUM'))) -ProdSnapshot $prodSnap -Config $script:Cfg
        $r.Status | Should -Be 'yellow'
        $f = @($r.Findings | Where-Object { $_.Category -eq 'feature' })[0]
        $f.ServicePlans | Should -Contain 'AAD_PREMIUM_P2'
        $f.AffectedTypes | Should -Contain $script:CA
        $f.AffectedCount | Should -Be 1
    }
    It 'gives no finding for a Prod licence that Prod does not use' {
        $r = Get-TenantFitAssessment -ProdLicences $script:ProdFull -DevLicences (Lic @(Sku 'DEV_E3' @('INTUNE_A', 'AAD_PREMIUM'))) -ProdSnapshot (Snap @(Res $script:CA 'CA001')) -Config $script:Cfg
        $r.Status | Should -Be 'green'
        @($r.Findings | Where-Object { $_.Feature -like '*P2*' }).Count | Should -Be 0
    }
    It 'is red when Dev lacks Intune and Prod uses it' {
        $r = Get-TenantFitAssessment -ProdLicences $script:ProdFull -DevLicences (Lic @(Sku 'DEV_P1' @('AAD_PREMIUM'))) -ProdSnapshot (Snap @(Res 'microsoft.intune.deviceconfigurationpolicywindows10' 'Win10')) -Config $script:Cfg
        $r.Status | Should -Be 'red'
        $r.Verified | Should -BeTrue
        $r.Verdict | Should -Match 'equivalent tenant'
    }
    It 'is red when Dev lacks Conditional Access P1 and Prod uses CA' {
        $r = Get-TenantFitAssessment -ProdLicences $script:ProdFull -DevLicences (Lic @(Sku 'DEV_INTUNE' @('INTUNE_A'))) -ProdSnapshot (Snap @(Res $script:CA 'CA001')) -Config $script:Cfg
        $r.Status | Should -Be 'red'
    }
    It 'counts a suspended SKU as missing and reports its state' {
        $r = Get-TenantFitAssessment -ProdLicences $script:ProdFull -DevLicences (Lic @(Sku 'DEV_E5' $script:Full 'Suspended')) -ProdSnapshot (Snap @(Res $script:CA 'CA001')) -Config $script:Cfg
        $r.Status | Should -Be 'red'
        @($r.Findings | Where-Object { $_.Category -eq 'sku-status' }).Count | Should -Be 1
    }
    It 'is yellow for a SKU in its grace period' {
        $r = Get-TenantFitAssessment -ProdLicences $script:ProdFull -DevLicences (Lic @(Sku 'DEV_E5' $script:Full 'Warning')) -ProdSnapshot (Snap @(Res $script:CA 'CA001')) -Config $script:Cfg
        $r.Status | Should -Be 'yellow'
    }
    It 'is yellow, never red, when there are fewer free units than test users, and does not count admin guests' {
        $r = Get-TenantFitAssessment -ProdLicences $script:ProdFull -DevLicences (Lic @(Sku 'DEV_E5' $script:Full 'Enabled' 3 3)) -ProdSnapshot (Snap @(Res $script:CA 'CA001')) -Config $script:Cfg
        $r.Status | Should -Be 'yellow'
        $c = @($r.Findings | Where-Object { $_.Category -eq 'capacity' })
        $c.Count | Should -BeGreaterThan 0
        @($c | Where-Object { $_.Severity -ne 'yellow' }).Count | Should -Be 0
        $c[0].AffectedCount | Should -Be 1
        $c[0].Message | Should -Match '0 free unit'
    }
    It 'gives no capacity finding when free units (enabled minus assigned) cover the test users' {
        $r = Get-TenantFitAssessment -ProdLicences $script:ProdFull -DevLicences (Lic @(Sku 'DEV_E5' $script:Full 'Enabled' 3 2)) -ProdSnapshot (Snap @(Res $script:CA 'CA001')) -Config $script:Cfg
        @($r.Findings | Where-Object { $_.Category -eq 'capacity' }).Count | Should -Be 0
        $r.Status | Should -Be 'green'
    }
    It 'is grey and not verified when the Dev licence list cannot be read' {
        $r = Get-TenantFitAssessment -ProdLicences $script:ProdFull -DevLicences (Unreadable) -ProdSnapshot (Snap @(Res $script:CA 'CA001')) -Config $script:Cfg
        $r.Status | Should -Be 'grey'
        $r.Verified | Should -BeFalse
        $r.Verdict | Should -Match 'Not verified'
    }
    It 'treats every licensed Prod feature as used without a snapshot' {
        $r = Get-TenantFitAssessment -ProdLicences $script:ProdFull -DevLicences (Lic @(Sku 'DEV_E3' @('INTUNE_A', 'AAD_PREMIUM'))) -ProdSnapshot $null -Config $script:Cfg
        $r.ProdUsageSource | Should -Be 'licences'
        $r.Status | Should -Be 'yellow'
        @($r.Findings | Where-Object { $_.Id -eq 'usage:no-snapshot' }).Count | Should -Be 1
    }
    It 'is grey when neither a Prod snapshot nor Prod licences are available' {
        $r = Get-TenantFitAssessment -ProdLicences (Unreadable) -DevLicences (Lic @(Sku 'DEV_E5' $script:Full)) -ProdSnapshot $null -Config $script:Cfg
        $r.Status | Should -Be 'grey'
        $r.Verdict | Should -Match 'Not verified'
        $r.Verified | Should -BeFalse
    }
    It 'reports an unconfirmed licence rule as info only' {
        $r = Get-TenantFitAssessment -ProdLicences $script:ProdFull -DevLicences (Lic @(Sku 'DEV_E5' $script:Full)) -ProdSnapshot (Snap @(Res 'microsoft.entra.termsofuse' 'ToU')) -Config $script:Cfg
        $r.Status | Should -Be 'green'
        @($r.Findings | Where-Object { $_.Category -eq 'unconfirmed-rule' }).Count | Should -Be 1
    }
    It 'writes JSON and Markdown under History\reports' {
        $r = Get-TenantFitAssessment -ProdLicences $script:ProdFull -DevLicences (Lic @(Sku 'DEV_E5' $script:Full)) -ProdSnapshot (Snap @(Res $script:CA 'CA001')) -Config $script:Cfg
        $files = Export-TenantFitReport -Assessment $r -HistoryRoot (Join-Path $TestDrive 'H')
        Test-Path -LiteralPath $files.Json | Should -BeTrue
        (Get-Content -LiteralPath $files.Markdown -Raw) | Should -Match 'Tenant suitability check'
        (Get-Content -LiteralPath $files.Json -Raw | ConvertFrom-Json).Status | Should -Be 'green'
    }
    It 'reads licences of both tenants with GET only' {
        InModuleScope M365Cloning {
            $script:seen = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-UtcmGraphRequest { $script:seen.Add($Method); [pscustomobject]@{ value = @() } }
            $t = ConvertTo-SecureString 'x' -AsPlainText -Force
            $null = Get-TenantLicences -Token $t
            $null = Get-TenantLicences -Token $t
            @($script:seen | Where-Object { $_ -ne 'GET' }).Count | Should -Be 0
        }
    }
}
