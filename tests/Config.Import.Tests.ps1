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
    It 'loads a valid config' {
        $c = Import-M365CloningConfig -Path $script:Valid
        $c.Customers[0].Name | Should -Be 'TestCustomer'
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
    It 'rejects a config without customers' {
        $p = script:New-ConfigFile '@{ Customers = @() }'
        { Import-M365CloningConfig -Path $p } | Should -Throw '*no customer*'
    }
    It 'rejects a customer without a Dev tenant' {
        $p = script:New-ConfigFile "@{ Customers = @( @{ Name='X'; Prod=@{TenantId='a';ClientId='b';CertThumbprint='c'} } ) }"
        { Import-M365CloningConfig -Path $p } | Should -Throw '*Dev tenant is missing*'
    }
    It 'rejects identical Prod and Dev tenant IDs' {
        $p = script:New-ConfigFile "@{ Customers = @( @{ Name='X'; Prod=@{TenantId='same';ClientId='b';CertThumbprint='c'}; Dev=@{TenantId='same';ClientId='b';CertThumbprint='c'} } ) }"
        { Import-M365CloningConfig -Path $p } | Should -Throw '*same TenantId*'
    }
}

Describe 'Get-M365CloningCustomer' {
    It 'returns the only customer without a name' {
        $c = Import-M365CloningConfig -Path $script:Valid
        (Get-M365CloningCustomer -Config $c).Name | Should -Be 'TestCustomer'
    }
    It 'throws for an unknown name' {
        $c = Import-M365CloningConfig -Path $script:Valid
        { Get-M365CloningCustomer -Config $c -Name 'Other' } | Should -Throw '*not in the config*'
    }
}
