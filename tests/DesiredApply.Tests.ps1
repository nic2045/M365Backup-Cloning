# Plan and apply from the desired state of the configuration repository (issue #27 part 2, ADR 0019). Offline only:
# the configuration repository is a new Git repository below TestDrive, the snapshots are invented, tokens are fakes,
# nothing calls a tenant.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'M365Cloning.psd1') -Force
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures'
    $script:Valid = Join-Path $script:Fixtures 'config.valid.psd1'
    $script:Lic = Join-Path $script:Fixtures 'dev.subscribedskus.json'
    $script:Scripts = Join-Path $PSScriptRoot '..' 'scripts'
    $script:ProdFilter = '11111111-2222-3333-4444-555555555555'
    $script:DevFilter = '99999999-2222-3333-4444-555555555555'

    function script:New-ConfigRepo([string]$Name) {
        $path = Join-Path $TestDrive $Name
        $null = New-Item -ItemType Directory -Path $path -Force
        & git -C $path init --quiet 2>&1 | Out-Null
        & git -C $path -c user.name=t -c user.email=t@localhost commit --quiet --allow-empty -m init 2>&1 | Out-Null
        $path
    }
    function script:GitIn([string]$Repo) { & git -C $Repo @args 2>&1 }
    function script:Res([string]$Type, [string]$Name, [hashtable]$Props) {
        $p = [ordered]@{ DisplayName = $Name; Id = [guid]::NewGuid().ToString() }
        foreach ($k in $Props.Keys) { $p[$k] = $Props[$k] }
        [ordered]@{ resourceType = $Type; displayName = $Name; properties = $p }
    }
    function script:Save-Snapshot([object[]]$Resources, [string]$Path) {
        ConvertTo-Json -InputObject ([ordered]@{ displayName = 'test'; resources = $Resources }) -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8
        $Path
    }
    function script:Prod-Resources([int]$MinLength = 12) {
        @(
            (script:Res 'microsoft.intune.deviceandappmanagementassignmentfilter' 'Example filter' @{ Id = $script:ProdFilter; Rule = '(device.osVersion -startsWith "10")'; Platform = 'windows10AndLater' })
            (script:Res 'microsoft.intune.deviceconfigurationpolicywindows10' 'Windows baseline' @{
                    PasswordRequired = $true; PasswordMinimumLength = $MinLength
                    Assignments = @(@{ dataType = '#microsoft.graph.groupAssignmentTarget'; groupId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; groupDisplayName = 'SW-Ring1'
                            collectionId = 'cccccccc-bbbb-cccc-dddd-eeeeeeeeeeee'; deviceAndAppManagementAssignmentFilterId = $script:ProdFilter; deviceAndAppManagementAssignmentFilterType = 'include' })
                })
            (script:Res 'microsoft.entra.group' 'SW-Ring1' @{ Description = 'Ring 1' })
        )
    }
    $script:DevResources = @(
        (script:Res 'microsoft.intune.deviceandappmanagementassignmentfilter' 'Example filter' @{ Id = $script:DevFilter; Rule = '(device.osVersion -startsWith "10")'; Platform = 'windows10AndLater' })
        (script:Res 'microsoft.entra.group' 'SW-Ring1' @{ Description = 'Ring 1'; TenantId = 'tenant-dev-0001' })
    )

    # A configuration repository with an exported desired state, a Prod and a Dev snapshot and a config file.
    function script:New-Setup([string]$Name) {
        $dir = Join-Path $TestDrive $Name
        $null = New-Item -ItemType Directory -Path $dir -Force
        $repo = script:New-ConfigRepo "$Name-repo"
        $cfgText = (Get-Content -LiteralPath $script:Valid -Raw) -replace '(?m)^@\{', "@{`n    ConfigRepository = '$($repo -replace "'", "''")'"
        $cfgPath = Join-Path $dir 'config.psd1'
        Set-Content -LiteralPath $cfgPath -Value $cfgText -Encoding utf8
        $cfg = Import-M365CloningConfig -Path $cfgPath
        $prod = script:Save-Snapshot (script:Prod-Resources) (Join-Path $dir 'prod.json')
        $dev = script:Save-Snapshot $script:DevResources (Join-Path $dir 'dev.json')
        $hist = Join-Path $dir 'History'
        $null = Invoke-DesiredStateExport -Config $cfg -HistoryRoot $hist -SnapshotPath $prod 6>$null
        [pscustomobject]@{ Dir = $dir; Repo = $repo; Config = $cfg; ConfigPath = $cfgPath; Prod = $prod; Dev = $dev; History = $hist }
    }
}

Describe 'ConvertFrom-DesiredStateResource' {
    It 'gives an assignment filter its name as Id and an assignment the filter name as filter ID' {
        $filter = ConvertFrom-DesiredStateResource -Content @{ resourceType = 'microsoft.intune.deviceandappmanagementassignmentfilter'; displayName = 'Example filter'; properties = @{ DisplayName = 'Example filter'; Rule = 'x' } }
        $filter.properties['Id'] | Should -Be 'Example filter'
        $policy = ConvertFrom-DesiredStateResource -Content @{ resourceType = 'microsoft.intune.deviceconfigurationpolicywindows10'; displayName = 'P'; properties = @{
                Assignments = @(@{ groupDisplayName = 'G'; deviceAndAppManagementAssignmentFilterDisplayName = 'Example filter'; deviceAndAppManagementAssignmentFilterType = 'include' }) } }
        $a = $policy.properties['Assignments'][0]
        $a['deviceAndAppManagementAssignmentFilterId'] | Should -Be 'Example filter'
        $a.Contains('deviceAndAppManagementAssignmentFilterDisplayName') | Should -BeFalse
        $a['groupDisplayName'] | Should -Be 'G'
    }
    It 'leaves other resources as they are' {
        $r = ConvertFrom-DesiredStateResource -Content @{ resourceType = 'Microsoft.Entra.Group'; displayName = 'G'; properties = @{ Description = 'd' } }
        $r.resourceType | Should -Be 'microsoft.entra.group'
        $r.properties.Contains('Id') | Should -BeFalse
        $r.properties['Description'] | Should -Be 'd'
    }
}

Describe 'ConvertTo-DesiredComparableSnapshot' {
    It 'removes connection properties and collectionId but keeps the IDs, and does not change its input' {
        $snap = @{ resources = @(
                @{ resourceType = 'microsoft.entra.group'; displayName = 'G'; properties = @{ Id = 'x'; TenantId = 't'; CertificateThumbprint = 'c'; Description = 'd'
                        Assignments = @(@{ groupId = 'g'; collectionId = 'c' }) } }
            ) }
        $out = ConvertTo-DesiredComparableSnapshot -Snapshot $snap
        $p = $out.resources[0].properties
        $p.Contains('TenantId') | Should -BeFalse
        $p.Contains('CertificateThumbprint') | Should -BeFalse
        $p['Id'] | Should -Be 'x'
        $p['Assignments'][0].Contains('collectionId') | Should -BeFalse
        $p['Assignments'][0]['groupId'] | Should -Be 'g'
        $snap.resources[0].properties.Contains('TenantId') | Should -BeTrue
    }
}

Describe 'Read-DesiredStateSnapshot' {
    It 'refuses without ConfigRepository' {
        $cfg = Import-M365CloningConfig -Path $script:Valid
        { Read-DesiredStateSnapshot -Config $cfg } | Should -Throw '*ConfigRepository is not set*'
    }
    It 'refuses a repository without a desired state' {
        $cfg = Import-M365CloningConfig -Path $script:Valid
        $cfg['ConfigRepository'] = script:New-ConfigRepo 'empty-repo'
        { Read-DesiredStateSnapshot -Config $cfg } | Should -Throw "*folder 'desired' is missing*"
    }
    It 'reads every file and names the commit' {
        $s = script:New-Setup 'read'
        $d = Read-DesiredStateSnapshot -Config $s.Config
        $d.Files | Should -Be 3
        $d.Commit | Should -Be ([string](script:GitIn $s.Repo rev-parse HEAD))
        @($d.Snapshot.resources).Count | Should -Be 3
    }
    It 'refuses a changed file that is not committed and names it' {
        $s = script:New-Setup 'dirty'
        $file = Get-ChildItem -LiteralPath (Join-Path $s.Repo 'desired') -Recurse -Filter 'Windows baseline.json' | Select-Object -First 1
        Add-Content -LiteralPath $file.FullName -Value ' '
        { Read-DesiredStateSnapshot -Config $s.Config } | Should -Throw '*not committed*Windows baseline.json*'
    }
    It 'refuses a new file that is not committed' {
        $s = script:New-Setup 'untracked'
        $dir = Join-Path $s.Repo 'desired' 'microsoft.entra.group'
        Set-Content -LiteralPath (Join-Path $dir 'New.json') -Value '{"resourceType":"microsoft.entra.group","displayName":"New","properties":{}}'
        { Read-DesiredStateSnapshot -Config $s.Config } | Should -Throw '*not committed*'
    }
    It 'refuses a committed file in the wrong folder' {
        $s = script:New-Setup 'wrongfolder'
        $dir = Join-Path $s.Repo 'desired' 'microsoft.entra.group'
        Set-Content -LiteralPath (Join-Path $dir 'Odd.json') -Value '{"resourceType":"microsoft.intune.deviceconfigurationpolicywindows10","displayName":"Odd","properties":{}}'
        script:GitIn $s.Repo add --all | Out-Null
        script:GitIn $s.Repo -c user.name=t -c user.email=t@localhost commit --quiet -m odd | Out-Null
        { Read-DesiredStateSnapshot -Config $s.Config } | Should -Throw '*does not match its folder*'
    }
}

Describe 'Plan from the repository' {
    BeforeAll {
        $script:S = script:New-Setup 'plan'
        $script:Desired = Read-DesiredStateSnapshot -Config $script:S.Config
        $dev = Read-UtcmSnapshotFile -Path $script:S.Dev
        $script:RepoPlan = New-ApplyPlan -Source $script:Desired.Snapshot -Target (ConvertTo-DesiredComparableSnapshot -Snapshot $dev) -Config $script:S.Config -SourceInfo @{ Kind = 'Repository'; Commit = $script:Desired.Commit }
        # The same Dev side for both plans: the Dev group carries a connection property (TenantId) that the desired
        # state never holds; the comparable copy leaves it out (otherwise only the live plan would update the group).
        $script:LivePlan = New-ApplyPlan -Source (Read-UtcmSnapshotFile -Path $script:S.Prod) -Target (ConvertTo-DesiredComparableSnapshot -Snapshot $dev) -Config $script:S.Config
    }
    It 'plans the same actions with the same properties as the plan from the Prod snapshot' {
        $key = { param($a) "$($a['ResourceType'])|$($a['Name'])|$($a['Status'])|$($a['Operation'])|$(ConvertTo-Json $a['Properties'] -Depth 20 -Compress)" }
        $repo = @($script:RepoPlan['Actions'] | ForEach-Object { & $key $_ }) | Sort-Object
        $live = @($script:LivePlan['Actions'] | ForEach-Object { & $key $_ }) | Sort-Object
        $repo | Should -Be $live
    }
    It 'maps the filter by name to the Dev filter and sees no difference in the filter and the group' {
        $policy = $script:RepoPlan['Actions'] | Where-Object { $_['Name'] -eq 'Windows baseline' }
        $policy['Status'] | Should -Be 'planned'
        $policy['Properties']['Assignments'][0]['deviceAndAppManagementAssignmentFilterId'] | Should -Be $script:DevFilter
        @($script:RepoPlan['Actions'] | Where-Object { $_['Name'] -in 'Example filter', 'SW-Ring1' }).Count | Should -Be 0
    }
    It 'names the source and the commit, and the commit is part of the hash' {
        $script:RepoPlan['Source']['Kind'] | Should -Be 'Repository'
        $script:RepoPlan['Source']['Commit'] | Should -Be $script:Desired.Commit
        $script:LivePlan.Contains('Source') | Should -BeFalse
        $other = New-ApplyPlan -Source $script:Desired.Snapshot -Target (ConvertTo-DesiredComparableSnapshot -Snapshot (Read-UtcmSnapshotFile -Path $script:S.Dev)) -Config $script:S.Config -SourceInfo @{ Kind = 'Repository'; Commit = ('0' * 40) }
        Get-ApplyPlanHash -Plan $other | Should -Not -Be (Get-ApplyPlanHash -Plan $script:RepoPlan)
        (Get-ApplyPlanHash -Plan $script:RepoPlan) | Should -Not -Be (Get-ApplyPlanHash -Plan $script:LivePlan)
    }
    It 'refuses a source that is not a full commit' {
        { New-ApplyPlan -Source $script:Desired.Snapshot -Target @{ resources = @() } -Config $script:S.Config -SourceInfo @{ Kind = 'Repository'; Commit = 'abc' } } | Should -Throw '*full commit*'
    }
}

Describe 'Invoke-ApplyDev.ps1 -Source Repository' {
    It 'builds the plan from the repository without Prod and writes the source into the plan file' {
        $s = script:New-Setup 'script'
        $null = & (Join-Path $script:Scripts 'Invoke-ApplyDev.ps1') -ConfigPath $s.ConfigPath -HistoryRoot $s.History -Source Repository -TargetSnapshotPath $s.Dev -LicencePath $script:Lic 6>$null
        $file = Get-ChildItem -LiteralPath (Join-Path $s.History 'reports') -Filter 'apply-plan-*.json' | Select-Object -First 1
        $doc = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
        $doc['Plan']['Source']['Kind'] | Should -Be 'Repository'
        $doc['Plan']['Source']['Commit'] | Should -Be ([string](script:GitIn $s.Repo rev-parse HEAD))
        @($doc['Plan']['Notes'] | Where-Object { $_ -like 'Source: the desired state of the configuration repository*' }).Count | Should -Be 1
    }
    It 'gives another hash after a new export changed the desired state' {
        $s = script:New-Setup 'rehash'
        $plan1 = New-ApplyPlan -Source (Read-DesiredStateSnapshot -Config $s.Config).Snapshot -Target @{ resources = @() } -Config $s.Config -SourceInfo @{ Kind = 'Repository'; Commit = (Read-DesiredStateSnapshot -Config $s.Config).Commit }
        $null = Invoke-DesiredStateExport -Config $s.Config -HistoryRoot $s.History -SnapshotPath (script:Save-Snapshot (script:Prod-Resources -MinLength 14) (Join-Path $s.Dir 'prod2.json')) 6>$null
        $d2 = Read-DesiredStateSnapshot -Config $s.Config
        $plan2 = New-ApplyPlan -Source $d2.Snapshot -Target @{ resources = @() } -Config $s.Config -SourceInfo @{ Kind = 'Repository'; Commit = $d2.Commit }
        Get-ApplyPlanHash -Plan $plan2 | Should -Not -Be (Get-ApplyPlanHash -Plan $plan1)
    }
    It 'refuses a Prod snapshot together with the repository' {
        $s = script:New-Setup 'both'
        { & (Join-Path $script:Scripts 'Invoke-ApplyDev.ps1') -ConfigPath $s.ConfigPath -HistoryRoot $s.History -Source Repository -SourceSnapshotPath $s.Prod -TargetSnapshotPath $s.Dev 6>$null } | Should -Throw '*-SourceSnapshotPath is for -Source Live*'
    }
}

Describe 'Web jobs with the repository as source' {
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $script:Signed = [System.Collections.Generic.List[string]]::new()
        $script:FakeToken = { param($Config, [string]$Side) $script:Signed.Add($Side); ConvertTo-SecureString -String "fake-$Side" -AsPlainText -Force }
        $script:Record = { param([string]$Path, [System.Collections.IDictionary]$Parameters, [string]$Log) $script:Calls.Add([pscustomobject]@{ Script = (Split-Path -Leaf $Path); Parameters = $Parameters }); 0 }
    }
    BeforeAll {
        function script:New-JobFile {
            param([string]$Root, [string]$Action, [hashtable]$Options = @{}, [hashtable]$Confirm = @{}, [string]$Id = 'job-20261108-120000-abc123')
            $dir = Join-Path $Root 'jobs'
            $null = New-Item -ItemType Directory -Path $dir -Force
            $path = Join-Path $dir "$Id.json"
            [ordered]@{
                SchemaVersion = '2'; Kind = 'job'
                Job = [ordered]@{ id = $Id; action = $Action; status = 'queued'; role = 'Applier'; actor = 'Test Person'
                    createdUtc = '2026-11-08T12:00:00Z'; updatedUtc = '2026-11-08T12:00:00Z'; startedUtc = $null; finishedUtc = $null
                    options = $Options; steps = @(); message = ''; result = @{} }
                Confirm = $Confirm
            } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
            $path
        }
    }
    It 'plan-apply from the repository signs in to Dev only and passes the source' {
        $root = Join-Path $TestDrive 'job-plan'
        $path = script:New-JobFile -Root $root -Action 'plan-apply' -Options @{ area = 'All'; source = 'Repository' }
        Invoke-WebJob -JobPath $path -HistoryRoot $root -ConfigPath $script:Valid -ScriptRoot $script:Scripts -TokenProvider $script:FakeToken -ScriptRunner $script:Record
        $job = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable)['Job']
        @($script:Signed) | Should -Be @('Dev')
        $script:Calls[0].Parameters['Source'] | Should -Be 'Repository'
        $script:Calls[0].Parameters.Contains('ProdToken') | Should -BeFalse
        ($job['steps'] | Where-Object { $_['key'] -eq 'run' })['title'] | Should -Be 'Read the desired state and Dev and build the plan'
    }
    It 'plan-apply without a source reads Prod as before' {
        $root = Join-Path $TestDrive 'job-live'
        $path = script:New-JobFile -Root $root -Action 'plan-apply' -Options @{ area = 'All' }
        Invoke-WebJob -JobPath $path -HistoryRoot $root -ConfigPath $script:Valid -ScriptRoot $script:Scripts -TokenProvider $script:FakeToken -ScriptRunner $script:Record
        @($script:Signed) | Should -Be @('Prod', 'Dev')
        $script:Calls[0].Parameters.Contains('Source') | Should -BeFalse
    }
    It 'the apply of a plan from the repository takes the source from the plan and signs in to Dev only' {
        $s = script:New-Setup 'job-apply'
        $null = & (Join-Path $script:Scripts 'Invoke-ApplyDev.ps1') -ConfigPath $s.ConfigPath -HistoryRoot $s.History -Source Repository -TargetSnapshotPath $s.Dev -LicencePath $script:Lic 6>$null
        $file = Get-ChildItem -LiteralPath (Join-Path $s.History 'reports') -Filter 'apply-plan-*.json' | Select-Object -First 1
        $hash = (Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json).PlanHash
        $path = script:New-JobFile -Root $s.History -Action apply -Options @{ planId = $file.BaseName; planKind = 'apply' } -Confirm @{ PlanHash = $hash }
        Invoke-WebJob -JobPath $path -HistoryRoot $s.History -ConfigPath $s.ConfigPath -ScriptRoot $script:Scripts -TokenProvider $script:FakeToken -ScriptRunner $script:Record
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable)['Job']['status'] | Should -Be 'succeeded'
        @($script:Signed) | Should -Be @('Dev')
        $c = $script:Calls[0]
        $c.Parameters['Source'] | Should -Be 'Repository'
        $c.Parameters['ConfirmPlanHash'] | Should -Be $hash
        $c.Parameters.Contains('ProdToken') | Should -BeFalse
    }
}

Describe 'Rebuild chain with the repository as source' {
    It 'passes the source to the apply step and no Prod token' {
        $root = Join-Path $TestDrive 'chain'
        $seen = [System.Collections.Generic.List[hashtable]]::new()
        $runner = {
            param($ScriptPath, [hashtable]$Arguments)
            $name = Split-Path $ScriptPath -Leaf
            if ($name -eq 'Invoke-ApplyDev.ps1') { $seen.Add($Arguments) }
            $reports = Join-Path $root 'reports'; $null = New-Item -ItemType Directory -Path $reports -Force
            $prefix = switch ($name) { 'Invoke-DevBaseline.ps1' { 'dev-baseline-plan' } 'Invoke-ApplyDev.ps1' { 'apply-plan' } 'Invoke-DevUsers.ps1' { 'dev-users-plan' } default { 'drift' } }
            if ($Arguments.ContainsKey('Apply')) { return }
            @{ PlanHash = "hash-$prefix"; Plan = @{ Summary = @{ Planned = 1 } } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $reports "$prefix-$([guid]::NewGuid().ToString('N')).json")
        }.GetNewClosure()
        $cfg = Import-M365CloningConfig -Path $script:Valid
        $dev = ConvertTo-SecureString -String 'fake-dev' -AsPlainText -Force
        $prod = ConvertTo-SecureString -String 'fake-prod' -AsPlainText -Force
        $r = Invoke-DevRebuildChain -ScriptRoot '/scripts' -ConfigPath 'c.psd1' -Config $cfg -HistoryRoot $root -ProdToken $prod -DevToken $dev -Source Repository -Runner $runner -Prompt { param($StepName, $PlanHash, $PlanPath) $PlanHash }
        $r.Completed | Should -BeTrue
        $seen.Count | Should -Be 2
        foreach ($a in $seen) { $a['Source'] | Should -Be 'Repository'; $a.ContainsKey('ProdToken') | Should -BeFalse }
    }
}
