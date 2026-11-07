BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'M365Cloning.psd1') -Force
    $script:Token = ConvertTo-SecureString 'not-a-real-token' -AsPlainText -Force
    $script:Graph = 'https://graph.microsoft.com/v1.0'
}

Describe 'Invoke-UtcmGraphRequest (write guard)' {
    BeforeEach {
        Mock -ModuleName M365Cloning Invoke-RestMethod { [pscustomobject]@{ ok = $true } }
    }
    It 'allows GET' {
        InModuleScope M365Cloning -Parameters @{ T = $script:Token; G = $script:Graph } {
            param($T, $G)
            Invoke-UtcmGraphRequest -Method GET -Uri "$G/admin/configurationManagement/configurationSnapshotJobs/x" -Token $T | Out-Null
        }
        Should -Invoke -ModuleName M365Cloning Invoke-RestMethod -Times 1 -Exactly
    }
    It 'allows exactly one POST: createSnapshot' {
        InModuleScope M365Cloning -Parameters @{ T = $script:Token; G = $script:Graph } {
            param($T, $G)
            Invoke-UtcmGraphRequest -Method POST -Uri "$G/admin/configurationManagement/configurationSnapshots/createSnapshot" -Token $T -Body @{ displayName = 'x' } | Out-Null
        }
        Should -Invoke -ModuleName M365Cloning Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }
    It 'blocks POST to any other path' {
        InModuleScope M365Cloning -Parameters @{ T = $script:Token; G = $script:Graph } {
            param($T, $G)
            { Invoke-UtcmGraphRequest -Method POST -Uri "$G/deviceManagement/deviceConfigurations" -Token $T -Body @{} } | Should -Throw '*Blocked*'
        }
        Should -Invoke -ModuleName M365Cloning Invoke-RestMethod -Times 0 -Exactly
    }
    It 'refuses PATCH, PUT and DELETE (not in the allowed methods)' {
        InModuleScope M365Cloning -Parameters @{ T = $script:Token; G = $script:Graph } {
            param($T, $G)
            foreach ($m in 'PATCH', 'PUT', 'DELETE') {
                { Invoke-UtcmGraphRequest -Method $m -Uri "$G/x" -Token $T } | Should -Throw
            }
        }
        Should -Invoke -ModuleName M365Cloning Invoke-RestMethod -Times 0 -Exactly
    }
    It 'refuses a plain http URL' {
        InModuleScope M365Cloning -Parameters @{ T = $script:Token } {
            param($T)
            { Invoke-UtcmGraphRequest -Method GET -Uri 'http://graph.microsoft.com/v1.0/x' -Token $T } | Should -Throw '*https*'
        }
    }
}

Describe 'Get-UtcmTenantSnapshot (mocked Graph)' {
    BeforeEach {
        $global:UtcmTestPolls = 0
        Mock -ModuleName M365Cloning Invoke-UtcmGraphRequest {
            if ($Method -eq 'POST') { return [pscustomobject]@{ id = 'job-0001'; status = 'notStarted' } }
            if ($Uri -like '*configurationSnapshotJobs/job-0001*') {
                $global:UtcmTestPolls++
                if ($global:UtcmTestPolls -lt 2) { return [pscustomobject]@{ id = 'job-0001'; status = 'running' } }
                return [pscustomobject]@{ id = 'job-0001'; status = 'succeeded'; resourceLocation = 'https://example.invalid/snapshot/job-0001'; resources = @('microsoft.entra.group') }
            }
            if ($Uri -eq 'https://example.invalid/snapshot/job-0001') {
                return [pscustomobject]@{ resources = @(@{ displayName = 'G'; resourceType = 'microsoft.entra.group'; properties = @{ DisplayName = 'G' } }) }
            }
            throw "unexpected call: $Method $Uri"
        }
    }
    AfterEach { Remove-Variable -Name UtcmTestPolls -Scope Global -ErrorAction SilentlyContinue }

    It 'starts, waits, downloads and keeps the snapshot under History/Tenants/<Side>/<stamp>' {
        $path = Get-UtcmTenantSnapshot -Token $script:Token -Side Prod -TenantId 'tenant-prod-0001' `
            -Resources @('microsoft.entra.group') -HistoryRoot (Join-Path $TestDrive 'History') -PollSeconds 0
        Test-Path $path | Should -BeTrue
        $path | Should -BeLike '*Tenants*Prod*snapshot.json'
        (Join-Path (Split-Path $path) 'meta.json') | Should -Exist
        (Read-UtcmSnapshotFile -Path $path).resources[0].displayName | Should -Be 'G'
    }
    It 'makes exactly one POST (createSnapshot) and otherwise only GET calls' {
        Get-UtcmTenantSnapshot -Token $script:Token -Side Dev -TenantId 'tenant-dev-0001' `
            -Resources @('microsoft.entra.group') -HistoryRoot (Join-Path $TestDrive 'History') -PollSeconds 0 | Out-Null
        Should -Invoke -ModuleName M365Cloning Invoke-UtcmGraphRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*createSnapshot' }
        Should -Invoke -ModuleName M365Cloning Invoke-UtcmGraphRequest -Times 0 -Exactly -ParameterFilter { $Method -notin 'GET', 'POST' }
    }
}

Describe 'Wait-UtcmSnapshot' {
    It 'throws with the error details when the job failed' {
        Mock -ModuleName M365Cloning Invoke-UtcmGraphRequest { [pscustomobject]@{ id = 'j'; status = 'failed'; errorDetails = @('boom') } }
        { Wait-UtcmSnapshot -Token $script:Token -JobId 'j' -PollSeconds 0 } | Should -Throw '*boom*'
    }
    It 'throws when the job does not finish in time' {
        Mock -ModuleName M365Cloning Invoke-UtcmGraphRequest { [pscustomobject]@{ id = 'j'; status = 'running' } }
        { Wait-UtcmSnapshot -Token $script:Token -JobId 'j' -TimeoutSeconds 0 -PollSeconds 0 } | Should -Throw '*did not finish*'
    }
    It 'returns a partiallySuccessful job with a warning' {
        Mock -ModuleName M365Cloning Invoke-UtcmGraphRequest { [pscustomobject]@{ id = 'j'; status = 'partiallySuccessful'; errorDetails = @('x') } }
        $job = Wait-UtcmSnapshot -Token $script:Token -JobId 'j' -PollSeconds 0 -WarningAction SilentlyContinue
        $job.status | Should -Be 'partiallySuccessful'
    }
}

Describe 'Get-DriftReport.ps1' {
    BeforeAll {
        $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Get-DriftReport.ps1'
        $script:Cfg = Join-Path $PSScriptRoot 'fixtures' 'config.valid.psd1'
        $script:Fx = Join-Path $PSScriptRoot 'fixtures'
    }
    It 'compares two saved snapshots offline and writes the report' {
        $hist = Join-Path $TestDrive 'H'
        & $script:Script -ConfigPath $script:Cfg -HistoryRoot $hist `
            -SourceSnapshotPath (Join-Path $script:Fx 'prod.snapshot.json') `
            -TargetSnapshotPath (Join-Path $script:Fx 'dev.snapshot.json') 6>$null | Out-Null
        $json = Get-ChildItem -Path (Join-Path $hist 'reports') -Filter 'drift-*.json'
        $json | Should -Not -BeNullOrEmpty
    }
    It 'sends nothing and writes nothing in a dry run' {
        $hist = Join-Path $TestDrive 'H2'
        & $script:Script -ConfigPath $script:Cfg -HistoryRoot $hist -DryRun 6>$null | Out-Null
        Test-Path $hist | Should -BeFalse
    }
    It 'needs both tokens online' {
        { & $script:Script -ConfigPath $script:Cfg -HistoryRoot (Join-Path $TestDrive 'H3') } | Should -Throw '*-ProdToken*'
    }
}
