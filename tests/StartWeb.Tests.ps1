# Start of the web app with one command (issue #79): settings, break-glass account, environment of the two apps.
# The processes, Python and the network are mocked; nothing is installed or started.

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:Root 'scripts/M365CloningWeb.psm1') -Force
    $script:Tenant = '11111111-2222-3333-4444-555555555555'
    $script:Api = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    $script:Ui = 'ffffffff-0000-1111-2222-333333333333'
    $script:Hash = 'scrypt$32768$8$1$c2FsdHNhbHRzYWx0c2FsdA==$aGFzaGhhc2hoYXNoaGFzaGhhc2hoYXNoaGFzaGhhc2g='
    $script:Secret = 'f' * 64
    function script:Entra { @{ TenantId = $script:Tenant; ApiClientId = $script:Api; UiClientId = $script:Ui } }
    function script:Settings([hashtable]$Extra = @{}) {
        $s = @{ Entra = (Entra); LocalAccount = @{ Enabled = $false; User = 'breakglass'; PasswordHash = ''; Role = 'Reader' }; Ports = @{ Api = 8000; Ui = 8080 } }
        foreach ($k in $Extra.Keys) { $s[$k] = $Extra[$k] }
        $s
    }
    function script:Fields($problems) { @($problems | ForEach-Object Field) }
}

Describe 'web.settings.example.psd1' {
    BeforeAll { $script:Example = Join-Path $script:Root 'web.settings.example.psd1' }
    It 'parses and holds placeholders only' {
        { Import-PowerShellDataFile -Path $script:Example } | Should -Not -Throw
        (Get-Content -Raw $script:Example) | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        (Get-Content -Raw $script:Example) | Should -Not -Match 'scrypt\$'
    }
    It 'keeps the break-glass account off, with the role Reader' {
        $s = Import-PowerShellDataFile -Path $script:Example
        $s.LocalAccount.Enabled | Should -BeFalse
        $s.LocalAccount.Role | Should -Be 'Reader'
    }
    It 'is reported as "no sign-in set up" until it is filled in' {
        Fields (Test-M365WebSettings -Settings (Import-PowerShellDataFile -Path $script:Example)) | Should -Contain 'Entra'
    }
    It 'the real settings file and web.local are git-ignored' {
        $ignore = Get-Content (Join-Path $script:Root '.gitignore')
        $ignore | Should -Contain 'web.settings.psd1'
        $ignore | Should -Contain 'web.local/'
    }
}

Describe 'Test-M365WebSettings' {
    It 'accepts a complete Entra setup' {
        @(Test-M365WebSettings -Settings (Settings)).Count | Should -Be 0
    }
    It 'accepts the break-glass account alone' {
        $s = Settings @{ Entra = @{}; LocalAccount = @{ Enabled = $true; User = 'breakglass'; PasswordHash = $script:Hash; Role = 'Reader' } }
        @(Test-M365WebSettings -Settings $s).Count | Should -Be 0
    }
    It 'refuses a setup without any sign-in' {
        Fields (Test-M365WebSettings -Settings (Settings @{ Entra = @{} })) | Should -Contain 'Entra'
    }
    It 'names each missing Entra value' {
        $f = Fields (Test-M365WebSettings -Settings (Settings @{ Entra = @{ TenantId = $script:Tenant } }))
        $f | Should -Contain 'Entra.ApiClientId'
        $f | Should -Contain 'Entra.UiClientId'
    }
    It 'refuses a value that is not an ID' {
        $e = Entra; $e.TenantId = 'contoso.onmicrosoft.com'
        Fields (Test-M365WebSettings -Settings (Settings @{ Entra = $e })) | Should -Contain 'Entra.TenantId'
    }
    It 'refuses the role <_> for the break-glass account and says why' -ForEach @('Applier', 'Resetter', 'Admin') {
        $s = Settings @{ LocalAccount = @{ Enabled = $true; User = 'breakglass'; PasswordHash = $script:Hash; Role = $_ } }
        $p = @(Test-M365WebSettings -Settings $s) | Where-Object Field -EQ 'LocalAccount.Role'
        $p | Should -Not -BeNullOrEmpty
        $p.Problem | Should -Match 'break-glass'
        $p.Fix | Should -Match "Role = 'Reader'"
    }
    It 'asks for the password when the break-glass account has no hash' {
        $s = Settings @{ LocalAccount = @{ Enabled = $true; User = 'breakglass'; PasswordHash = ''; Role = 'Reader' } }
        $p = @(Test-M365WebSettings -Settings $s) | Where-Object Field -EQ 'LocalAccount.PasswordHash'
        $p.Fix | Should -Match '-SetLocalPassword'
    }
    It 'refuses a password instead of a hash, without repeating it' {
        $s = Settings @{ LocalAccount = @{ Enabled = $true; User = 'breakglass'; PasswordHash = 'plain words, no hash'; Role = 'Reader' } }
        $p = @(Test-M365WebSettings -Settings $s)
        Fields $p | Should -Contain 'LocalAccount.PasswordHash'
        ($p | Out-String) | Should -Not -Match 'plain words, no hash'
    }
    It 'refuses the same port twice and ports out of range' {
        Fields (Test-M365WebSettings -Settings (Settings @{ Ports = @{ Api = 8080; Ui = 8080 } })) | Should -Contain 'Ports'
        Fields (Test-M365WebSettings -Settings (Settings @{ Ports = @{ Api = 80; Ui = 8080 } })) | Should -Contain 'Ports.Api'
    }
    It 'refuses a redirect address whose port is not the port of the interface' {
        $e = Entra; $e.RedirectUri = 'http://localhost:9999/auth/callback'
        Fields (Test-M365WebSettings -Settings (Settings @{ Entra = $e })) | Should -Contain 'Entra.RedirectUri'
    }
}

Describe 'ConvertTo-M365WebEnvironment' {
    It 'binds the API to 127.0.0.1 and points the interface to it' {
        $e = ConvertTo-M365WebEnvironment -Settings (Settings) -TokenSecret $script:Secret
        $e.Api.M365CLONING_API_HOST | Should -Be '127.0.0.1'
        $e.Api.M365CLONING_API_PORT | Should -Be '8000'
        $e.Ui.M365_UI_API_BASE | Should -Be 'http://127.0.0.1:8000'
    }
    It 'fills the Entra values of both apps' {
        $e = ConvertTo-M365WebEnvironment -Settings (Settings) -TokenSecret $script:Secret
        $e.Api.M365CLONING_AUTH_TENANT_ID | Should -Be $script:Tenant
        $e.Api.M365CLONING_AUTH_AUDIENCE | Should -Be "$script:Api,api://$script:Api"
        $e.Ui.M365_UI_OIDC_CLIENT_ID | Should -Be $script:Ui
        $e.Ui.M365_UI_OIDC_API_SCOPE | Should -Be "api://$script:Api/access_as_user"
        $e.Ui.M365_UI_OIDC_REDIRECT_URI | Should -Be 'http://localhost:8080/auth/callback'
        $e.Ui.Keys | Should -Not -Contain 'M365_UI_OIDC_CLIENT_SECRET'
    }
    It 'gives the break-glass account the role Reader whatever the file says' {
        $s = Settings @{ LocalAccount = @{ Enabled = $true; User = 'breakglass'; PasswordHash = $script:Hash; Role = 'Resetter' } }
        $e = ConvertTo-M365WebEnvironment -Settings $s -TokenSecret $script:Secret
        $e.Ui.M365_UI_LOCAL_LOGIN | Should -Be '1'
        $e.Ui.M365_UI_LOCAL_ROLE | Should -Be 'Reader'
    }
    It 'leaves the local account off when it is not switched on' {
        (ConvertTo-M365WebEnvironment -Settings (Settings) -TokenSecret $script:Secret).Ui.Keys | Should -Not -Contain 'M365_UI_LOCAL_LOGIN'
    }
    It 'gives the same token secret to both apps' {
        $e = ConvertTo-M365WebEnvironment -Settings (Settings) -TokenSecret $script:Secret
        $e.Api.M365CLONING_LOCAL_TOKEN_SECRET | Should -Be $script:Secret
        $e.Ui.M365CLONING_LOCAL_TOKEN_SECRET | Should -Be $script:Secret
    }
}

Describe 'Format-M365WebSummary' {
    It 'shows no ID, hash or secret' {
        $s = Settings @{ LocalAccount = @{ Enabled = $true; User = 'breakglass'; PasswordHash = $script:Hash; Role = 'Reader' } }
        $text = Format-M365WebSummary -Settings $s | Out-String
        $text | Should -Match 'Break-glass account : on'
        foreach ($v in $script:Tenant, $script:Api, $script:Ui, $script:Hash) { $text | Should -Not -Match ([regex]::Escape($v)) }
    }
}

Describe 'Get-M365WebTokenSecret' {
    It 'makes a secret of 64 hex characters once and keeps it' {
        $path = Join-Path $TestDrive 'web.local/token.secret'
        $first = Get-M365WebTokenSecret -Path $path
        $first | Should -Match '^[0-9a-f]{64}$'
        Get-M365WebTokenSecret -Path $path | Should -Be $first
    }
    It 'limits the file to the current user' -Skip:$IsWindows {
        $path = Join-Path $TestDrive 'perm/token.secret'
        Get-M365WebTokenSecret -Path $path | Out-Null
        [int](Get-Item $path).UnixFileMode | Should -Be ([int][System.IO.UnixFileMode]'UserRead, UserWrite')
    }
}

Describe 'Set-M365WebPasswordHash' {
    It 'writes only the hash into the settings file' {
        $path = Join-Path $TestDrive 'web.settings.psd1'
        Copy-Item (Join-Path $script:Root 'web.settings.example.psd1') $path
        Set-M365WebPasswordHash -Path $path -Hash $script:Hash
        (Import-PowerShellDataFile $path).LocalAccount.PasswordHash | Should -Be $script:Hash
    }
    It 'refuses anything that is not a hash' {
        $path = Join-Path $TestDrive 'web.settings2.psd1'
        Copy-Item (Join-Path $script:Root 'web.settings.example.psd1') $path
        { Set-M365WebPasswordHash -Path $path -Hash 'plain password' } | Should -Throw '*did not return a hash*'
    }
}

Describe 'Invoke-M365CloningWeb' {
    BeforeAll {
        $script:Run = Join-Path $TestDrive 'run'
        New-Item -ItemType Directory -Path (Join-Path $script:Run 'web/api'), (Join-Path $script:Run 'web/ui') -Force | Out-Null
        'x' | Set-Content (Join-Path $script:Run 'web/api/requirements.txt')
        'x' | Set-Content (Join-Path $script:Run 'web/ui/requirements.txt')
        function script:WriteSettings([string]$Role = 'Reader') {
            $text = (Get-Content -Raw (Join-Path $script:Root 'web.settings.example.psd1')).
                Replace("TenantId    = ''", "TenantId    = '$script:Tenant'").
                Replace("ApiClientId = ''", "ApiClientId = '$script:Api'").
                Replace("UiClientId  = ''", "UiClientId  = '$script:Ui'").
                Replace('Enabled      = $false', 'Enabled      = $true').
                Replace("PasswordHash = ''", "PasswordHash = '$script:Hash'").
                Replace("Role         = 'Reader'", "Role         = '$Role'")
            Set-Content -Path (Join-Path $script:Run 'web.settings.psd1') -Value $text
        }
    }
    BeforeEach {
        Remove-Item (Join-Path $script:Run 'web.local') -Recurse -Force -ErrorAction SilentlyContinue
        WriteSettings
        Mock -ModuleName M365CloningWeb Find-M365WebPython { [pscustomobject]@{ Path = '/fake/python3.12'; Version = '3.12' } }
        Mock -ModuleName M365CloningWeb Initialize-M365WebVenv { "/fake/$(Split-Path -Leaf $Venv)/python" }
        Mock -ModuleName M365CloningWeb Test-M365WebPortFree { $true }
        Mock -ModuleName M365CloningWeb Wait-M365WebReady { $true }
        Mock -ModuleName M365CloningWeb Open-M365WebBrowser { }
        Mock -ModuleName M365CloningWeb Stop-M365WebProcess { }
        Mock -ModuleName M365CloningWeb Start-M365WebProcess { [pscustomobject]@{ HasExited = $true; Id = 1 } }
    }

    It 'with -Check starts nothing and creates nothing' {
        $out = Invoke-M365CloningWeb -Root $script:Run -Check 6>&1
        $out[-1] | Should -Be 0
        Should -Invoke -ModuleName M365CloningWeb Start-M365WebProcess -Times 0
        Should -Invoke -ModuleName M365CloningWeb Initialize-M365WebVenv -Times 0
        Test-Path (Join-Path $script:Run 'web.local') | Should -BeFalse
    }
    It 'starts API and interface on 127.0.0.1 with their own environment only' {
        $before = [Environment]::GetEnvironmentVariable('M365CLONING_LOCAL_TOKEN_SECRET')
        $null = Invoke-M365CloningWeb -Root $script:Run -NoBrowser 6>&1
        Should -Invoke -ModuleName M365CloningWeb Start-M365WebProcess -Times 1 -ParameterFilter {
            $Arguments -contains 'm365api' -and $Environment.M365CLONING_API_HOST -eq '127.0.0.1' }
        Should -Invoke -ModuleName M365CloningWeb Start-M365WebProcess -Times 1 -ParameterFilter {
            $Arguments -contains 'm365ui.main:app' -and $Arguments -contains '127.0.0.1' -and $Environment.M365_UI_LOCAL_ROLE -eq 'Reader' }
        Should -Invoke -ModuleName M365CloningWeb Open-M365WebBrowser -Times 0
        [Environment]::GetEnvironmentVariable('M365CLONING_LOCAL_TOKEN_SECRET') | Should -Be $before
        Test-Path (Join-Path $script:Run 'web.local/token.secret') | Should -BeTrue
    }
    It 'prints no secret, hash or ID' {
        $text = Invoke-M365CloningWeb -Root $script:Run -NoBrowser 6>&1 | Out-String
        $secret = (Get-Content -Raw (Join-Path $script:Run 'web.local/token.secret')).Trim()
        foreach ($v in $secret, $script:Hash, $script:Tenant, $script:Api, $script:Ui) { $text | Should -Not -Match ([regex]::Escape($v)) }
        $text | Should -Match 'Break-glass account : on'
    }
    It 'refuses the role <_> for the break-glass account with a clear message and starts nothing' -ForEach @('Applier', 'Resetter') {
        WriteSettings -Role $_
        $out = Invoke-M365CloningWeb -Root $script:Run -NoBrowser 6>&1
        $out[-1] | Should -Be 2
        ($out | Out-String) | Should -Match 'break-glass account for management only'
        Should -Invoke -ModuleName M365CloningWeb Start-M365WebProcess -Times 0
    }
    It 'says what to do when the settings file is missing' {
        Remove-Item (Join-Path $script:Run 'web.settings.psd1')
        $out = Invoke-M365CloningWeb -Root $script:Run 6>&1
        $out[-1] | Should -Be 2
        ($out | Out-String) | Should -Match 'Copy web.settings.example.psd1 to web.settings.psd1'
    }
    It 'says what to do without Python 3.12' {
        Mock -ModuleName M365CloningWeb Find-M365WebPython { throw 'Python 3.12 is needed (the lock files are made for it). No Python found.' }
        $out = Invoke-M365CloningWeb -Root $script:Run 6>&1
        $out[-1] | Should -Be 2
        ($out | Out-String) | Should -Match 'Python 3.12 is needed'
    }
    It 'stops when a port is taken' {
        Mock -ModuleName M365CloningWeb Test-M365WebPortFree { $false }
        $out = Invoke-M365CloningWeb -Root $script:Run -NoBrowser 6>&1
        $out[-1] | Should -Be 2
        ($out | Out-String) | Should -Match 'Port 8000 is in use'
        Should -Invoke -ModuleName M365CloningWeb Start-M365WebProcess -Times 0
    }
    It 'stops the API when the interface does not come up' {
        Mock -ModuleName M365CloningWeb Wait-M365WebReady { $Url -like '*/api/status' }
        $out = Invoke-M365CloningWeb -Root $script:Run -NoBrowser 6>&1
        $out[-1] | Should -Be 2
        Should -Invoke -ModuleName M365CloningWeb Stop-M365WebProcess -Times 2
    }
}
