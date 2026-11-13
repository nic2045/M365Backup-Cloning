# The console scripts sign in with the certificate of the configuration when no token is passed (issue #87, ADR 0021).
# Offline only: the sign-in is a fake, no tenant is called, no certificate is read.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'M365Cloning.psd1') -Force
    $script:Scripts = Join-Path $PSScriptRoot '..' 'scripts'
    $script:Config = @{
        Prod = @{ TenantId = 'tenant-prod-0001'; ClientId = 'client-prod-0001'; CertThumbprint = 'THUMB-PROD-0001' }
        Dev  = @{ TenantId = 'tenant-dev-0001'; ClientId = 'client-dev-0001'; CertThumbprint = 'THUMB-DEV-0001' }
    }
    $script:Fake = ConvertTo-SecureString -String 'fake-token-from-the-certificate' -AsPlainText -Force
}

Describe 'Resolve-M365CloningToken' {
    It 'returns a token that was passed and does not sign in' {
        $passed = ConvertTo-SecureString -String 'passed-token' -AsPlainText -Force
        $calls = [System.Collections.Generic.List[string]]::new()
        $fake = $script:Fake
        $provider = { param($t, $c, $p) $calls.Add($t); $fake }.GetNewClosure()
        $result = Resolve-M365CloningToken -Config $script:Config -Side Dev -Token $passed -TokenProvider $provider
        ConvertFrom-SecureString -SecureString $result -AsPlainText | Should -Be 'passed-token'
        $calls.Count | Should -Be 0
    }

    It 'signs in with tenant, client and certificate of the side that is asked for' {
        $seen = [System.Collections.Generic.List[string]]::new()
        $fake = $script:Fake
        $provider = { param($t, $c, $p) $seen.Add("$t|$c|$p"); $fake }.GetNewClosure()
        $result = Resolve-M365CloningToken -Config $script:Config -Side Prod -TokenProvider $provider
        $result | Should -BeOfType [securestring]
        @($seen) | Should -Be @('tenant-prod-0001|client-prod-0001|THUMB-PROD-0001')
        $seen.Clear()
        $null = Resolve-M365CloningToken -Config $script:Config -Side Dev -TokenProvider $provider
        @($seen) | Should -Be @('tenant-dev-0001|client-dev-0001|THUMB-DEV-0001')
    }

    It 'names the side and where to look when the sign-in fails, without a token or a thumbprint in the text' {
        $provider = { param($t, $c, $p) throw 'AADSTS700027: client assertion contains an invalid signature' }
        $message = try { Resolve-M365CloningToken -Config $script:Config -Side Dev -TokenProvider $provider; '' } catch { $_.Exception.Message }
        $message | Should -BeLike 'No -DevToken was passed and the sign-in of the Dev app registration with its certificate failed: AADSTS700027*'
        $message | Should -BeLike '*Dev.CertThumbprint*'
        $message | Should -Not -Match 'THUMB-DEV-0001'
    }

    It 'refuses an answer that is not a SecureString and a configuration without the side' {
        $plain = { param($t, $c, $p) 'plain text token' }
        { Resolve-M365CloningToken -Config $script:Config -Side Dev -TokenProvider $plain } | Should -Throw '*gave no token*'
        { Resolve-M365CloningToken -Config @{ Prod = @{} } -Side Dev -TokenProvider $plain } | Should -Throw '*Dev tenant is missing*'
    }

    It 'uses the sign-in of the web jobs (Az.Accounts, no own token code) when no provider is given' {
        InModuleScope M365Cloning {
            Mock Get-WebJobGraphToken { ConvertTo-SecureString -String 'from-az' -AsPlainText -Force }
            $config = @{ Dev = @{ TenantId = 'tenant-dev-0001'; ClientId = 'client-dev-0001'; CertThumbprint = 'THUMB-DEV-0001' } }
            $token = Resolve-M365CloningToken -Config $config -Side Dev
            ConvertFrom-SecureString -SecureString $token -AsPlainText | Should -Be 'from-az'
            Should -Invoke Get-WebJobGraphToken -Times 1 -ParameterFilter { $TenantId -eq 'tenant-dev-0001' -and $ClientId -eq 'client-dev-0001' -and $CertThumbprint -eq 'THUMB-DEV-0001' }
        }
    }
}

Describe 'The console scripts ask for the token through the configuration' {
    It 'every script that takes a token resolves it with Resolve-M365CloningToken instead of stopping' {
        foreach ($name in 'Get-DriftReport', 'Invoke-ApplyDev', 'Invoke-DevBaseline', 'Invoke-DevReset', 'Invoke-DevUsers', 'Export-DesiredState', 'Invoke-IntuneBackup') {
            $text = Get-Content -LiteralPath (Join-Path $script:Scripts "$name.ps1") -Raw
            $text | Should -Match 'Resolve-M365CloningToken -Config \$config -Side (Prod|Dev)' -Because $name
            $text | Should -Not -Match "throw 'Pass -(Prod|Dev)Token" -Because "$name no longer stops without a token"
        }
    }

    It 'is exported and has no own token or signature code (ADR 0013)' {
        (Get-Command -Module M365Cloning -Name Resolve-M365CloningToken).CommandType | Should -Be 'Function'
        $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'Public' 'Resolve-M365CloningToken.ps1') -Raw
        $text | Should -Not -Match 'client_assertion|X509Certificate2|SignData|RSA'
    }
}
