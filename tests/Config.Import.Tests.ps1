BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'M365Cloning.psd1') -Force
    $script:Example = Join-Path $PSScriptRoot '..' 'config.example.psd1'
    $script:Valid = Join-Path $PSScriptRoot 'fixtures' 'config.valid.psd1'
    function script:New-ConfigFile([string]$Text) {
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.psd1')
        Set-Content -LiteralPath $path -Value $Text
        $path
    }
}

Describe 'Import-M365CloningConfig' {
    It 'loads a valid config with one Prod/Dev pair' {
        $c = Import-M365CloningConfig -Path $script:Valid
        $c.Prod.TenantId | Should -Be 'tenant-prod-0001'
        $c.Dev.AllowReset | Should -BeFalse
        $c.ProtectedAccounts | Should -Contain 'admin-0001'
    }
    It 'rejects the example file because of its placeholders' {
        { Import-M365CloningConfig -Path $script:Example } | Should -Throw '*placeholder*'
    }
    It 'accepts the example file with -AllowPlaceholders' {
        { Import-M365CloningConfig -Path $script:Example -AllowPlaceholders } | Should -Not -Throw
    }
    It 'rejects a missing file' {
        { Import-M365CloningConfig -Path (Join-Path $TestDrive 'nope.psd1') } | Should -Throw '*not found*'
    }
    It 'rejects a config without a Dev tenant' {
        $p = script:New-ConfigFile "@{ Prod=@{TenantId='a';ClientId='b';CertThumbprint='c'} }"
        { Import-M365CloningConfig -Path $p } | Should -Throw '*Dev tenant is missing*'
    }
    It 'rejects a config without a Prod tenant' {
        $p = script:New-ConfigFile "@{ Dev=@{TenantId='a';ClientId='b';CertThumbprint='c'} }"
        { Import-M365CloningConfig -Path $p } | Should -Throw '*Prod tenant is missing*'
    }
    It 'rejects identical Prod and Dev tenant IDs' {
        $p = script:New-ConfigFile "@{ Prod=@{TenantId='same';ClientId='b';CertThumbprint='c'}; Dev=@{TenantId='same';ClientId='b';CertThumbprint='c'} }"
        { Import-M365CloningConfig -Path $p } | Should -Throw '*same TenantId*'
    }
    It 'rejects the old Customers list' {
        $p = script:New-ConfigFile "@{ Customers = @( @{ Prod=@{}; Dev=@{} } ) }"
        { Import-M365CloningConfig -Path $p } | Should -Throw '*Customers*'
    }
    It 'loads ApplyAllowed and the break-glass lists, apply is off by default' {
        $c = Import-M365CloningConfig -Path $script:Valid
        $c.Dev.ApplyAllowed | Should -BeFalse
        $c.BreakGlass | Should -Contain 'bg-user-0001'
        $c.BreakGlassGroups | Should -Contain 'BG-Group'
    }
    It 'rejects ApplyAllowed that is not a boolean' {
        $p = script:New-ConfigFile "@{ Prod=@{TenantId='a';ClientId='b';CertThumbprint='c'}; Dev=@{TenantId='d';ClientId='b';CertThumbprint='c';ApplyAllowed='yes'} }"
        { Import-M365CloningConfig -Path $p } | Should -Throw '*ApplyAllowed*'
    }
    It 'rejects a BreakGlass entry that is still a placeholder' {
        $p = script:New-ConfigFile "@{ Prod=@{TenantId='a';ClientId='b';CertThumbprint='c'}; Dev=@{TenantId='d';ClientId='b';CertThumbprint='c'}; BreakGlass=@('<break-glass-upn>') }"
        { Import-M365CloningConfig -Path $p } | Should -Throw '*placeholder*'
    }
}
