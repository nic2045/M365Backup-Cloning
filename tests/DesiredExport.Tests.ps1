# Export of the Prod desired state into the configuration repository (issue #27 part 1, ADR 0018). Offline only:
# the Prod snapshot is an invented snapshot.json below TestDrive, the configuration repository is a new Git repository
# below TestDrive, nothing calls a tenant.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'M365Cloning.psd1') -Force
    . (Join-Path $PSScriptRoot 'contract' 'ContractHelpers.ps1')
    $script:Valid = Join-Path $PSScriptRoot 'fixtures' 'config.valid.psd1'
    $script:Scripts = Join-Path $PSScriptRoot '..' 'scripts'

    function script:New-ConfigRepo([string]$Name) {
        $path = Join-Path $TestDrive $Name
        $null = New-Item -ItemType Directory -Path $path -Force
        & git -C $path init --quiet 2>&1 | Out-Null
        & git -C $path -c user.name=t -c user.email=t@localhost commit --quiet --allow-empty -m init 2>&1 | Out-Null
        $path
    }
    function script:New-Config([string]$Repo) {
        $c = Import-M365CloningConfig -Path $script:Valid
        $c['ConfigRepository'] = $Repo
        $c
    }
    function script:GitIn([string]$Repo) { & git -C $Repo @args 2>&1 }
    $script:FilterId = '11111111-2222-3333-4444-555555555555'
    function script:New-Snapshot([object[]]$Resources, [string]$Name = 'snap.json') {
        $path = Join-Path $TestDrive $Name
        ConvertTo-Json -InputObject ([ordered]@{ displayName = 'test'; resources = $Resources }) -Depth 30 | Set-Content -LiteralPath $path -Encoding utf8
        $path
    }
    function script:Res([string]$Type, [string]$Name, [hashtable]$Props) {
        $p = [ordered]@{ DisplayName = $Name; Id = [guid]::NewGuid().ToString() }
        foreach ($k in $Props.Keys) { $p[$k] = $Props[$k] }
        [ordered]@{ resourceType = $Type; displayName = $Name; properties = $p }
    }
    $script:Base = @(
        (script:Res 'microsoft.intune.deviceandappmanagementassignmentfilter' 'Example filter' @{ Id = $script:FilterId; Rule = '(device.osVersion -startsWith "10")' })
        (script:Res 'microsoft.intune.deviceconfigurationpolicywindows10' 'Windows baseline' @{
                PasswordRequired = $true; PasswordMinimumLength = 12
                Assignments = @(@{ dataType = '#microsoft.graph.groupAssignmentTarget'; groupId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; groupDisplayName = 'SW-Ring1'
                        deviceAndAppManagementAssignmentFilterId = $script:FilterId; deviceAndAppManagementAssignmentFilterType = 'include' })
            })
        (script:Res 'microsoft.entra.group' 'SW-Ring1' @{ Description = 'Ring 1' })
        (script:Res 'microsoft.entra.conditionalaccesspolicy' 'CA require MFA' @{ State = 'enabled'; IncludeGroups = @('SW-Ring1') })
    )
}

Describe 'ConvertTo-DesiredStateFile' {
    BeforeAll {
        $script:Cfg = Import-M365CloningConfig -Path $script:Valid
        $snap = Read-UtcmSnapshotFile -Path (script:New-Snapshot $script:Base 'pure.json')
        $script:Out = ConvertTo-DesiredStateFile -Snapshot $snap -Config $script:Cfg
        $script:ByName = @{}; foreach ($o in $script:Out) { $script:ByName[$o.Name] = $o }
    }
    It 'writes one file per resource below desired, a folder per type, named by display name' {
        $script:ByName['Windows baseline'].Status | Should -Be 'written'
        $script:ByName['Windows baseline'].RelativePath | Should -Be 'desired/microsoft.intune.deviceconfigurationpolicywindows10/Windows baseline.json'
        @($script:Out | Where-Object Status -eq 'written').Count | Should -Be 4
    }
    It 'removes Id and the group ID and names the filter instead of its ID' {
        $c = $script:ByName['Windows baseline'].Content
        $c.properties.Contains('Id') | Should -BeFalse
        $a = $c.properties.Assignments[0]
        $a.Contains('groupId') | Should -BeFalse
        $a.Contains('deviceAndAppManagementAssignmentFilterId') | Should -BeFalse
        $a.groupDisplayName | Should -Be 'SW-Ring1'
        $a.deviceAndAppManagementAssignmentFilterDisplayName | Should -Be 'Example filter'
        $script:ByName['Windows baseline'].ObjectIds | Should -BeFalse
    }
    It 'keeps the Prod state of Conditional Access as it is (the apply makes it Report-only)' {
        $script:ByName['CA require MFA'].Content.properties.State | Should -Be 'enabled'
    }
    It 'sorts the keys, so the same content gives the same file' {
        $keys = @($script:ByName['Windows baseline'].Content.properties.Keys)
        $sorted = [string[]]$keys.Clone(); [Array]::Sort($sorted, [StringComparer]::Ordinal)
        $keys | Should -Be $sorted
    }
    It 'skips secret types, encrypted OMA-URI values and secret properties' {
        $res = @(
            (script:Res 'microsoft.intune.wificonfigurationpolicywindows10' 'Office Wi-Fi' @{ Ssid = 'x' })
            (script:Res 'microsoft.intune.deviceconfigurationcustompolicywindows10' 'Custom' @{ OmaSettings = @(@{ IsEncrypted = $true; OmaUri = './x' }) })
        )
        $out = ConvertTo-DesiredStateFile -Snapshot (Read-UtcmSnapshotFile -Path (script:New-Snapshot $res 'secret.json')) -Config $script:Cfg
        foreach ($o in $out) { $o.Status | Should -Be 'skipped'; $o.Reason | Should -BeLike 'secret:*' }
    }
    It 'skips a resource whose assignment filter is not in the snapshot (it would be wider than Prod)' {
        $res = @(script:Res 'microsoft.intune.deviceconfigurationpolicywindows10' 'No filter here' @{
                Assignments = @(@{ dataType = '#microsoft.graph.groupAssignmentTarget'; groupDisplayName = 'G'; deviceAndAppManagementAssignmentFilterId = '99999999-2222-3333-4444-555555555555'; deviceAndAppManagementAssignmentFilterType = 'exclude' })
            })
        $o = ConvertTo-DesiredStateFile -Snapshot (Read-UtcmSnapshotFile -Path (script:New-Snapshot $res 'nofilter.json')) -Config $script:Cfg
        $o.Status | Should -Be 'skipped'
        $o.Reason | Should -BeLike 'needs-filter:*'
    }
    It 'removes connection properties and skips a resource that still holds the Prod tenant ID' {
        $res = @(
            (script:Res 'microsoft.entra.group' 'With connection' @{ TenantId = 'tenant-prod-0001'; ApplicationId = 'x'; CertificateThumbprint = 'y' })
            (script:Res 'microsoft.entra.group' 'Tenant in text' @{ Description = 'see tenant-prod-0001' })
        )
        $out = ConvertTo-DesiredStateFile -Snapshot (Read-UtcmSnapshotFile -Path (script:New-Snapshot $res 'tenant.json')) -Config $script:Cfg
        $w = $out | Where-Object Name -eq 'With connection'
        $w.Status | Should -Be 'written'
        foreach ($k in 'TenantId', 'ApplicationId', 'CertificateThumbprint') { $w.Content.properties.Contains($k) | Should -BeFalse }
        $t = $out | Where-Object Name -eq 'Tenant in text'
        $t.Status | Should -Be 'skipped'
        $t.Reason | Should -BeLike 'tenant id:*'
    }
    It 'skips a type the apply does not know and marks files that still hold a Prod object ID' {
        $res = @(
            (script:Res 'microsoft.example.unknowntype' 'Unknown' @{})
            (script:Res 'microsoft.entra.group' 'With object id' @{ SomeRoleId = 'bbbbbbbb-1111-2222-3333-444444444444' })
        )
        $out = ConvertTo-DesiredStateFile -Snapshot (Read-UtcmSnapshotFile -Path (script:New-Snapshot $res 'unknown.json')) -Config $script:Cfg
        ($out | Where-Object Name -eq 'Unknown').Reason | Should -BeLike 'unknown type:*'
        ($out | Where-Object Name -eq 'With object id').ObjectIds | Should -BeTrue
    }
    It 'makes file names safe for Windows and keeps names apart that differ only in case' {
        InModuleScope M365Cloning {
            Get-DesiredStateFileName -Name 'A/B: C?' | Should -Be 'A_B_ C_'
            Get-DesiredStateFileName -Name 'CON' | Should -Be '_CON'
            Get-DesiredStateFileName -Name 'trailing. ' | Should -Be 'trailing'
            (Get-DesiredStateFileName -Name ('x' * 200)).Length | Should -Be 120
        }
        $res = @((script:Res 'microsoft.entra.group' 'Pilot' @{}), (script:Res 'microsoft.entra.group' 'pilot' @{}))
        $out = ConvertTo-DesiredStateFile -Snapshot (Read-UtcmSnapshotFile -Path (script:New-Snapshot $res 'case.json')) -Config $script:Cfg
        @($out.RelativePath | Sort-Object -Unique).Count | Should -Be 2
    }
}

Describe 'Invoke-DesiredStateExport' {
    It 'writes desired/ into the configuration repository and commits only that folder' {
        $repo = script:New-ConfigRepo 'repo1'
        Set-Content -LiteralPath (Join-Path $repo 'other.txt') -Value 'not mine'
        $null = script:GitIn $repo add other.txt
        $hist = Join-Path $TestDrive 'h1'
        $r = Invoke-DesiredStateExport -Config (script:New-Config $repo) -HistoryRoot $hist -SnapshotPath (script:New-Snapshot $script:Base 's1.json') -Now ([datetime]'2026-11-08T12:00:00Z')
        $file = Join-Path $repo 'desired' 'microsoft.intune.deviceconfigurationpolicywindows10' 'Windows baseline.json'
        Test-Path -LiteralPath $file | Should -BeTrue
        $text = [IO.File]::ReadAllText($file)
        $text | Should -Not -Match "`r"
        $text.EndsWith("`n") | Should -BeTrue
        [IO.File]::ReadAllBytes($file)[0] | Should -Be ([byte][char]'{')
        $r.Report.Added | Should -Be 4
        $r.Report.Commit | Should -Match '^[0-9a-f]{40}$'
        @(script:GitIn $repo show --name-only --format= HEAD) | ForEach-Object { $_ | Should -BeLike 'desired/*' }
        @(script:GitIn $repo diff --cached --name-only) | Should -Be @('other.txt')
        (script:GitIn $repo log -1 --format=%an) | Should -Be 'M365Cloning export'
        Split-Path -Leaf $r.Path | Should -Be 'desired-export-20261108-120000.json'
        Test-Path (Join-Path $hist 'tmp' 'desired-export-20261108-120000') | Should -BeFalse
    }

    It 'shows added, changed and removed files of the next export; no change, no commit' {
        $repo = script:New-ConfigRepo 'repo2'
        $hist = Join-Path $TestDrive 'h2'
        $cfg = script:New-Config $repo
        $null = Invoke-DesiredStateExport -Config $cfg -HistoryRoot $hist -SnapshotPath (script:New-Snapshot $script:Base 's2a.json') -Now ([datetime]'2026-11-08T12:00:00Z')
        $next = @($script:Base[0], $script:Base[2], $script:Base[3], (script:Res 'microsoft.entra.group' 'SW-Ring2' @{}))
        $next[1] = script:Res 'microsoft.entra.group' 'SW-Ring1' @{ Description = 'Ring 1 changed' }
        $r = Invoke-DesiredStateExport -Config $cfg -HistoryRoot $hist -SnapshotPath (script:New-Snapshot $next 's2b.json') -Now ([datetime]'2026-11-08T13:00:00Z')
        ($r.Report.Added, $r.Report.Changed, $r.Report.Removed) | Should -Be @(1, 1, 1)
        $head = script:GitIn $repo rev-parse HEAD
        $r2 = Invoke-DesiredStateExport -Config $cfg -HistoryRoot $hist -SnapshotPath (script:New-Snapshot $next 's2c.json') -Now ([datetime]'2026-11-08T14:00:00Z')
        $r2.Report.Unchanged | Should -BeTrue
        $r2.Report.Commit | Should -Be ''
        (script:GitIn $repo rev-parse HEAD) | Should -Be $head
    }

    It 'leaves the repository as it was when nothing can be written' {
        $repo = script:New-ConfigRepo 'repo3'
        $hist = Join-Path $TestDrive 'h3'
        $cfg = script:New-Config $repo
        $null = Invoke-DesiredStateExport -Config $cfg -HistoryRoot $hist -SnapshotPath (script:New-Snapshot $script:Base 's3a.json')
        $head = script:GitIn $repo rev-parse HEAD
        { Invoke-DesiredStateExport -Config $cfg -HistoryRoot $hist -SnapshotPath (script:New-Snapshot @((script:Res 'microsoft.example.unknowntype' 'x' @{})) 's3b.json') } | Should -Throw '*not changed*'
        (script:GitIn $repo rev-parse HEAD) | Should -Be $head
        Test-Path (Join-Path $repo 'desired' 'microsoft.entra.group' 'SW-Ring1.json') | Should -BeTrue
    }

    It 'writes the report in the schema and one audit line with counts only' {
        $repo = script:New-ConfigRepo 'repo4'
        $hist = Join-Path $TestDrive 'h4'
        $res = $script:Base + @(script:Res 'microsoft.intune.wificonfigurationpolicywindows10' 'Office Wi-Fi' @{})
        $r = Invoke-DesiredStateExport -Config (script:New-Config $repo) -HistoryRoot $hist -SnapshotPath (script:New-Snapshot $res 's4.json')
        $work = Join-Path $TestDrive 'schema4'; $null = New-Item -ItemType Directory -Path $work -Force
        Test-ContractJson -Json (Get-Content $r.Path -Raw) -Definition 'DesiredExport' -Folder $work | Should -BeNullOrEmpty
        @($r.Report.Skipped).Count | Should -Be 1
        $line = Get-Content (Join-Path $hist 'audit.jsonl') | Select-Object -Last 1
        Test-ContractJson -Json $line -Definition 'AuditEntry' -Folder $work | Should -BeNullOrEmpty
        $entry = $line | ConvertFrom-Json
        $entry.Mode | Should -Be 'export'
        $entry.Reason | Should -Match '4 added, 0 changed, 0 removed, 1 skipped'
        $entry.Reason | Should -Not -Match 'Windows baseline'
    }

    It 'never writes the Prod or Dev tenant ID into the repository' {
        $repo = script:New-ConfigRepo 'repo5'
        $null = Invoke-DesiredStateExport -Config (script:New-Config $repo) -HistoryRoot (Join-Path $TestDrive 'h5') -SnapshotPath (script:New-Snapshot $script:Base 's5.json')
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $repo 'desired') -Recurse -File) {
            $t = Get-Content -LiteralPath $f.FullName -Raw
            $t | Should -Not -Match 'tenant-prod-0001'
            $t | Should -Not -Match 'tenant-dev-0001'
        }
    }
}

Describe 'Invoke-DesiredStateExport: where it may write' {
    It 'refuses a config without ConfigRepository' {
        $c = Import-M365CloningConfig -Path $script:Valid
        { Invoke-DesiredStateExport -Config $c -HistoryRoot $TestDrive -SnapshotPath 'x' } | Should -Throw '*ConfigRepository is not set*'
    }
    It 'refuses a folder that is not a Git repository' {
        $plain = Join-Path $TestDrive 'plain'; $null = New-Item -ItemType Directory -Path $plain -Force
        { Invoke-DesiredStateExport -Config (script:New-Config $plain) -HistoryRoot $TestDrive -SnapshotPath 'x' } | Should -Throw '*not a Git repository*'
    }
    It 'refuses this toolkit as configuration repository' {
        $toolkit = Join-Path $PSScriptRoot '..'
        { Invoke-DesiredStateExport -Config (script:New-Config $toolkit) -HistoryRoot $TestDrive -SnapshotPath 'x' } | Should -Throw '*not this toolkit*'
    }
}

Describe 'scripts/Export-DesiredState.ps1' {
    It 'reads Prod only and sends nothing in a dry run' {
        $cfgPath = Join-Path $TestDrive 'dry.psd1'
        (Get-Content $script:Valid -Raw) -replace '\}\s*$', "    ConfigRepository = 'C:\\example-config'`n}" | Set-Content $cfgPath
        $out = & (Join-Path $script:Scripts 'Export-DesiredState.ps1') -ConfigPath $cfgPath -HistoryRoot (Join-Path $TestDrive 'hd') -DryRun 6>&1 | Out-String
        $out | Should -Match 'nothing is read or written'
        $out | Should -Match 'Dev is not read'
        Test-Path (Join-Path $TestDrive 'hd') | Should -BeFalse
    }
}
