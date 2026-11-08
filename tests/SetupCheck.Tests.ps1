# Setup check (issue #18): read only, every check green/yellow/red/grey with what to do, nothing about the tenants in
# the file. Offline only: tokens are fakes, Graph is mocked, the certificate store is replaced.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'M365Cloning.psd1') -Force
    . (Join-Path $PSScriptRoot 'contract' 'ContractHelpers.ps1')
    $script:Valid = Join-Path $PSScriptRoot 'fixtures' 'config.valid.psd1'
    $script:Now = [datetime]::new(2026, 11, 7, 12, 0, 0, [System.DateTimeKind]::Utc)
    $script:Req = Import-PowerShellDataFile (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'Data' 'SetupRequirements.psd1')

    function script:New-FakeToken([string[]]$Roles) {
        $enc = { param($o) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($o | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
        ConvertTo-SecureString -AsPlainText -Force ('{0}.{1}.sig' -f (& $enc @{ alg = 'none' }), (& $enc @{ roles = $Roles }))
    }
    $script:AllRoles = @{
        Prod = [string[]]@($script:Req.Prod.Required.Permission + $script:Req.Prod.Features.Permission)
        Dev  = [string[]]@($script:Req.Dev.Required.Permission + $script:Req.Dev.Features.Permission)
    }
    $script:GoodCert = { param($t) @{ Supported = $true; Found = $true; HasPrivateKey = $true; NotAfter = [datetime]'2027-06-30' } }
    function script:Invoke-Check {
        param([string]$Root, [hashtable]$Roles = $script:AllRoles, [scriptblock]$Cert = $script:GoodCert, [string]$Scope = 'All',
            [string]$Config = $script:Valid, [scriptblock]$Tokens)
        # Tokens are made here: a closure cannot call the functions of this script.
        $made = @{ Prod = script:New-FakeToken $Roles.Prod; Dev = script:New-FakeToken $Roles.Dev }
        $tp = if ($Tokens) { $Tokens } else { { param($c, $s) $made[$s] }.GetNewClosure() }
        Invoke-SetupCheck -ConfigPath $Config -HistoryRoot $Root -Scope $Scope -Now $script:Now -TokenProvider $tp -CertificateProvider $Cert
    }
    function script:Check([object]$Result, [string]$Id) { @($Result.Checks | Where-Object { $_.Id -eq $Id })[0] }
    function script:Set-Graph {
        param([hashtable]$Answers = @{})
        $script:Answers = $Answers
        Mock -ModuleName M365Cloning Invoke-UtcmGraphRequest {
            foreach ($k in $script:Answers.Keys) { if ($Uri -match $k) { $a = $script:Answers[$k]; if ($a -is [scriptblock]) { return & $a } return $a } }
            if ($Uri -match "servicePrincipals\?.*appId eq") { return @{ value = @(@{ id = 'sp-1'; accountEnabled = $true }) } }
            if ($Uri -match 'appRoleAssignments') { return @{ value = @(@{ appRoleId = 'r1' }, @{ appRoleId = 'r2' }) } }
            if ($Uri -match '/users/') { return @{ id = 'u-1'; accountEnabled = $true } }
            if ($Uri -match '/groups\?') { return @{ value = @(@{ id = 'g-1' }) } }
            throw "unexpected request $Uri"
        }
    }
}

Describe 'Invoke-SetupCheck' {
    BeforeEach { script:Set-Graph }

    It 'is green with everything in place, writes a file that follows the schema, and sends GET only' {
        $root = Join-Path $TestDrive 'green'
        $fit = Join-Path $root 'reports'; $null = New-Item -ItemType Directory $fit -Force
        @{ SchemaVersion = '2'; Kind = 'tenantfit'; CreatedUtc = '2026-11-06T12:00:00Z'; Status = 'green'; Verdict = 'Dev is enough.' } |
            ConvertTo-Json | Set-Content (Join-Path $fit 'tenantfit-20261106-120000.json')
        $r = script:Invoke-Check -Root $root
        $r.Status | Should -Be 'green' -Because (($r.Checks | Where-Object Status -ne 'green' | ForEach-Object { "$($_.Id): $($_.Detail)" }) -join '; ')
        $r.Path | Should -BeLike '*setup-check-20261107-120000.json'
        (script:Check $r 'licences').ReportId | Should -Be 'tenantfit-20261106-120000'
        $work = Join-Path $TestDrive 'schema'; $null = New-Item -ItemType Directory $work -Force
        Test-ContractJson -Json (Get-Content $r.Path -Raw) -Definition 'SetupCheck' -Folder $work | Should -BeNullOrEmpty
        Should -Invoke -ModuleName M365Cloning Invoke-UtcmGraphRequest -ParameterFilter { $Method -ne 'GET' } -Times 0 -Exactly
    }
    It 'reports an unreadable config as red and checks nothing else that needs it' {
        $r = script:Invoke-Check -Root (Join-Path $TestDrive 'noconfig') -Config (Join-Path $TestDrive 'missing.psd1')
        $r.Status | Should -Be 'red'
        (script:Check $r 'config-readable').Status | Should -Be 'red'
        (script:Check $r 'config-readable').Hint | Should -BeLike '*config.example.psd1*'
        @($r.Checks | Where-Object { $_.Group -in 'Certificates', 'Permissions', 'UTCM', 'BreakGlass' } | ForEach-Object Status | Select-Object -Unique) | Should -Be @('grey')
        Should -Invoke -ModuleName M365Cloning Invoke-UtcmGraphRequest -Times 0 -Exactly
    }
    It 'signs in nowhere with -Scope Config' {
        $script:SignedIn = 0
        $r = script:Invoke-Check -Root (Join-Path $TestDrive 'config') -Scope Config -Tokens { param($c, $s) $script:SignedIn++; throw 'must not sign in' }
        $script:SignedIn | Should -Be 0
        $r.Scope | Should -Be 'Config'
        (script:Check $r 'permissions-skipped').Status | Should -Be 'grey'
        (script:Check $r 'utcm-skipped').Status | Should -Be 'grey'
        Should -Invoke -ModuleName M365Cloning Invoke-UtcmGraphRequest -Times 0 -Exactly
    }
    It 'grades the certificate: <Name>' -ForEach @(
        @{ Name = 'missing'; Cert = @{ Supported = $true; Found = $false }; Status = 'red'; Title = 'Certificate not found' }
        @{ Name = 'no private key'; Cert = @{ Supported = $true; Found = $true; HasPrivateKey = $false; NotAfter = [datetime]'2027-01-01' }; Status = 'red'; Title = 'Certificate without private key' }
        @{ Name = 'expired'; Cert = @{ Supported = $true; Found = $true; HasPrivateKey = $true; NotAfter = [datetime]'2026-11-01' }; Status = 'red'; Title = 'Certificate expired' }
        @{ Name = 'ends soon'; Cert = @{ Supported = $true; Found = $true; HasPrivateKey = $true; NotAfter = [datetime]'2026-11-20' }; Status = 'yellow'; Title = 'Certificate expires soon' }
        @{ Name = 'valid'; Cert = @{ Supported = $true; Found = $true; HasPrivateKey = $true; NotAfter = [datetime]'2027-11-20' }; Status = 'green'; Title = 'Certificate valid' }
        @{ Name = 'not Windows'; Cert = @{ Supported = $false }; Status = 'grey'; Title = 'Certificate not checked' }
    ) {
        $c = $Cert
        $r = script:Invoke-Check -Root (Join-Path $TestDrive "cert-$Name") -Cert { param($t) $c }.GetNewClosure()
        foreach ($id in 'certificate-prod', 'certificate-dev') {
            (script:Check $r $id).Status | Should -Be $Status
            (script:Check $r $id).Title | Should -Be $Title
        }
    }
    It 'passes the thumbprint of each tenant to the certificate store' {
        $script:Thumbs = [System.Collections.Generic.List[string]]::new()
        $null = script:Invoke-Check -Root (Join-Path $TestDrive 'thumbs') -Cert { param($t) $script:Thumbs.Add($t); @{ Supported = $true; Found = $false } }
        @($script:Thumbs) | Should -Be @('thumb-prod-0001', 'thumb-dev-0001')
    }
    It 'is red when a required permission is missing and yellow when only a feature lacks one' {
        $roles = @{ Prod = $script:AllRoles.Prod; Dev = [string[]]@($script:AllRoles.Dev | Where-Object { $_ -ne 'LicenseAssignment.Read.All' -and $_ -ne 'User.Invite.All' }) }
        $r = script:Invoke-Check -Root (Join-Path $TestDrive 'perm') -Roles $roles
        $dev = script:Check $r 'permissions-dev'
        $dev.Status | Should -Be 'red'
        $dev.Detail | Should -BeLike '*Missing (needed): LicenseAssignment.Read.All*'
        $dev.Detail | Should -BeLike '*Missing for features: User.Invite.All*'
        $roles.Dev += 'LicenseAssignment.Read.All'
        $r2 = script:Invoke-Check -Root (Join-Path $TestDrive 'perm2') -Roles $roles
        (script:Check $r2 'permissions-dev').Status | Should -Be 'yellow'
        (script:Check $r2 'permissions-prod').Status | Should -Be 'green'
    }
    It 'is red when the Prod registration may write (Prod is only read)' {
        $roles = @{ Prod = [string[]]@($script:AllRoles.Prod + 'Group.ReadWrite.All'); Dev = $script:AllRoles.Dev }
        $p = script:Check (script:Invoke-Check -Root (Join-Path $TestDrive 'prodwrite') -Roles $roles) 'permissions-prod'
        $p.Status | Should -Be 'red'
        $p.Detail | Should -BeLike '*Write permissions on Prod: Group.ReadWrite.All*'
        $p.Detail | Should -Not -BeLike '*ConfigurationMonitoring.ReadWrite.All.*Write*'
    }
    It 'reports a failed sign-in as red and does not read that tenant' {
        $devToken = script:New-FakeToken $script:AllRoles.Dev
        $tokens = { param($c, $s) if ($s -eq 'Prod') { throw 'AADSTS700027: certificate not registered' } $devToken }.GetNewClosure()
        $r = script:Invoke-Check -Root (Join-Path $TestDrive 'signin') -Tokens $tokens
        (script:Check $r 'signin-prod').Status | Should -Be 'red'
        (script:Check $r 'signin-prod').Detail | Should -BeLike 'AADSTS700027*'
        (script:Check $r 'permissions-prod').Status | Should -Be 'grey'
        (script:Check $r 'utcm-prod').Status | Should -Be 'grey'
        (script:Check $r 'signin-dev').Status | Should -Be 'green'
    }
    It 'checks the UTCM service principal: <Name>' -ForEach @(
        @{ Name = 'missing'; Answers = @{ "03b07b79" = @{ value = @() } }; Status = 'red'; Title = 'UTCM service principal missing' }
        @{ Name = 'disabled'; Answers = @{ "03b07b79" = @{ value = @(@{ id = 'sp'; accountEnabled = $false }) } }; Status = 'red'; Title = 'UTCM service principal disabled' }
        @{ Name = 'no permissions'; Answers = @{ 'appRoleAssignments' = @{ value = @() } }; Status = 'yellow'; Title = 'UTCM partly ready' }
        @{ Name = 'admin services missing'; Answers = @{ "6b91db1b" = @{ value = @() } }; Status = 'yellow'; Title = 'UTCM partly ready' }
        @{ Name = 'not allowed to read'; Answers = @{ 'servicePrincipals' = { throw 'Response status code does not indicate success: 403 (Forbidden).' } }; Status = 'grey'; Title = 'UTCM not checked' }
    ) {
        script:Set-Graph -Answers $Answers
        $r = script:Invoke-Check -Root (Join-Path $TestDrive "utcm-$Name")
        (script:Check $r 'utcm-dev').Status | Should -Be $Status
        (script:Check $r 'utcm-dev').Title | Should -Be $Title
    }
    It 'names break-glass entries by position, never by account, when they are missing in Dev' {
        script:Set-Graph -Answers @{ '/users/' = { throw 'Response status code does not indicate success: 404 (Not Found).' } }
        $r = script:Invoke-Check -Root (Join-Path $TestDrive 'bg')
        $bg = script:Check $r 'breakglass-dev'
        $bg.Status | Should -Be 'red'
        $bg.Detail | Should -Be 'Not found in Dev: BreakGlass entry 1.'
        (Get-Content $r.Path -Raw) | Should -Not -Match 'bg-user-0001|BG-Group|admin-0001'
    }
    It 'is yellow when only a break-glass group is missing in Dev' {
        script:Set-Graph -Answers @{ '/groups\?' = @{ value = @() } }
        $bg = script:Check (script:Invoke-Check -Root (Join-Path $TestDrive 'bggroup')) 'breakglass-dev'
        $bg.Status | Should -Be 'yellow'
        $bg.Hint | Should -BeLike '*base state*'
    }
    It 'is red when the config lists neither break-glass nor protected accounts' {
        $cfg = Join-Path $TestDrive 'nobg.psd1'
        (Get-Content $script:Valid -Raw) -replace "BreakGlass = @\('bg-user-0001'\)", 'BreakGlass = @()' -replace "ProtectedAccounts = @\('admin-0001'\)", 'ProtectedAccounts = @()' | Set-Content $cfg
        $r = script:Invoke-Check -Root (Join-Path $TestDrive 'nobg') -Config $cfg -Scope Config
        (script:Check $r 'breakglass-list').Status | Should -Be 'red'
    }
    It 'takes the licences from the newest suitability check: <Name>' -ForEach @(
        @{ Name = 'none'; Files = @(); Status = 'grey' }
        @{ Name = 'current red'; Files = @(@{ N = 'tenantfit-20261107-100000'; C = '2026-11-07T10:00:00Z'; S = 'red' }, @{ N = 'tenantfit-20261101-100000'; C = '2026-11-01T10:00:00Z'; S = 'green' }); Status = 'red' }
        @{ Name = 'old'; Files = @(@{ N = 'tenantfit-20261020-100000'; C = '2026-10-20T10:00:00Z'; S = 'green' }); Status = 'yellow' }
    ) {
        $root = Join-Path $TestDrive "lic-$Name"; $rep = Join-Path $root 'reports'; $null = New-Item -ItemType Directory $rep -Force
        foreach ($f in $Files) { @{ SchemaVersion = '2'; Kind = 'tenantfit'; CreatedUtc = $f.C; Status = $f.S; Verdict = 'x' } | ConvertTo-Json | Set-Content (Join-Path $rep "$($f.N).json") }
        $l = script:Check (script:Invoke-Check -Root $root -Scope Config) 'licences'
        $l.Status | Should -Be $Status
    }
    It 'writes one audit line with the colour and the count per colour only (issue #76)' {
        $root = Join-Path $TestDrive 'audit'
        $r = script:Invoke-Check -Root $root -Scope Config
        $lines = @(Get-Content (Join-Path $root 'audit.jsonl'))
        $lines.Count | Should -Be 1
        $line = $lines[0] | ConvertFrom-Json -AsHashtable
        $line.Mode | Should -Be 'setupcheck'
        $line.Reason | Should -Be "setup check (Config): $($r.Status)"
        $line.TargetTenant | Should -Be ''
        foreach ($c in 'Red', 'Yellow', 'Green', 'Grey') { $line.Counts[$c] | Should -Be $r.Summary[$c] -Because $c }
        $work = Join-Path $TestDrive 'schema-audit'; $null = New-Item -ItemType Directory $work -Force
        Test-ContractJson -Json $lines[0] -Definition 'AuditEntry' -Folder $work | Should -BeNullOrEmpty
        Get-ContractConfigLeak -Text $lines[0] | Should -BeNullOrEmpty
        $lines[0] | Should -Not -Match 'tenant-(prod|dev)-0001'
    }
    It 'writes no client ID, thumbprint or tenant ID of the config' {
        $r = script:Invoke-Check -Root (Join-Path $TestDrive 'leak')
        Get-ContractConfigLeak -Text (Get-Content $r.Path -Raw) | Should -BeNullOrEmpty
        (Get-Content $r.Path -Raw) | Should -Not -Match 'tenant-(prod|dev)-0001'
    }
}

Describe 'Get-TokenAppRole' {
    It 'lists the roles of the token, sorted and without duplicates' {
        InModuleScope M365Cloning -Parameters @{ T = (script:New-FakeToken @('B.Read', 'A.Read', 'B.Read')) } {
            param($T)
            Get-TokenAppRole -Token $T | Should -Be @('A.Read', 'B.Read')
        }
    }
    It 'returns nothing for a token without roles and refuses a value that is not a token' {
        InModuleScope M365Cloning -Parameters @{ T = (script:New-FakeToken @()); Bad = (ConvertTo-SecureString 'abc' -AsPlainText -Force) } {
            param($T, $Bad)
            @(Get-TokenAppRole -Token $T).Count | Should -Be 0
            { Get-TokenAppRole -Token $Bad } | Should -Throw '*not a JSON Web Token*'
        }
    }
}
