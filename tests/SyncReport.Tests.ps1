# Sync report (issue #27 part 3, ADR 0020): the drift report compares desired/ of the configuration repository with
# Dev. Offline only: the configuration repository is a new Git repository below TestDrive, the snapshots are invented,
# tokens are fakes, nothing calls a tenant.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'M365Cloning.psd1') -Force
    $script:Valid = Join-Path $PSScriptRoot 'fixtures' 'config.valid.psd1'
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Get-DriftReport.ps1'
    $script:ProdFilter = '11111111-2222-3333-4444-555555555555'
    $script:DevFilter = '99999999-2222-3333-4444-555555555555'
    $script:Commit = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678'

    function script:Res([string]$Type, [string]$Name, [hashtable]$Props) {
        $p = [ordered]@{ DisplayName = $Name; Id = [guid]::NewGuid().ToString() }
        foreach ($k in $Props.Keys) { $p[$k] = $Props[$k] }
        [ordered]@{ resourceType = $Type; displayName = $Name; properties = $p }
    }
    function script:Save-Snapshot([object[]]$Resources, [string]$Path) {
        ConvertTo-Json -InputObject ([ordered]@{ displayName = 'test'; resources = $Resources }) -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8
        $Path
    }
    # Prod and Dev differ only in their IDs (filter ID, object IDs) when $MinLength is the same.
    function script:Tenant-Resources([string]$FilterId, [int]$MinLength) {
        @(
            (script:Res 'microsoft.intune.deviceandappmanagementassignmentfilter' 'Example filter' @{ Id = $FilterId; Rule = '(device.osVersion -startsWith "10")'; Platform = 'windows10AndLater' })
            (script:Res 'microsoft.intune.deviceconfigurationpolicywindows10' 'Windows baseline' @{
                    PasswordRequired = $true; PasswordMinimumLength = $MinLength
                    Assignments = @(@{ dataType = '#microsoft.graph.groupAssignmentTarget'; groupId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; groupDisplayName = 'SW-Ring1'
                            deviceAndAppManagementAssignmentFilterId = $FilterId; deviceAndAppManagementAssignmentFilterType = 'include' })
                })
            (script:Res 'microsoft.entra.group' 'SW-Ring1' @{ Description = 'Ring 1' })
        )
    }
    # A configuration repository with the desired state exported from an invented Prod snapshot, and a config file.
    function script:New-Setup([string]$Name) {
        $dir = Join-Path $TestDrive $Name
        $repo = Join-Path $TestDrive "$Name-repo"
        $null = New-Item -ItemType Directory -Path $dir, $repo -Force
        & git -C $repo init --quiet 2>&1 | Out-Null
        & git -C $repo -c user.name=t -c user.email=t@localhost commit --quiet --allow-empty -m init 2>&1 | Out-Null
        $cfgText = (Get-Content -LiteralPath $script:Valid -Raw) -replace '(?m)^@\{', "@{`n    ConfigRepository = '$($repo -replace "'", "''")'"
        $cfgPath = Join-Path $dir 'config.psd1'
        Set-Content -LiteralPath $cfgPath -Value $cfgText -Encoding utf8
        $cfg = Import-M365CloningConfig -Path $cfgPath
        $prod = script:Save-Snapshot (script:Tenant-Resources $script:ProdFilter 12) (Join-Path $dir 'prod.json')
        $hist = Join-Path $dir 'History'
        $null = Invoke-DesiredStateExport -Config $cfg -HistoryRoot $hist -SnapshotPath $prod 6>$null
        [pscustomobject]@{ Dir = $dir; Repo = $repo; ConfigPath = $cfgPath; History = $hist; Commit = [string](& git -C $repo rev-parse HEAD) }
    }
    # Runs the script in its own process, so its exit code is the one a schedule sees.
    # The error view of the child wraps long lines at the console width and colours them (ANSI escapes break the
    # NUnit report of the CI); NO_COLOR gives plain text, and the output is joined into one line without escapes.
    function script:Invoke-Drift([string[]]$Arguments) {
        $before = $env:NO_COLOR
        $env:NO_COLOR = '1'
        try { $out = & pwsh -NoProfile -NonInteractive -File $script:Script @Arguments 2>&1; $code = $LASTEXITCODE }
        finally { $env:NO_COLOR = $before }
        $text = (($out | ForEach-Object { [string]$_ }) -join ' ') -replace "\x1b\[[0-9;]*[A-Za-z]", '' -replace '\s*\|\s*', ' ' -replace '\s+', ' '
        [pscustomobject]@{ Exit = $code; Output = $text }
    }
    function script:Newest-Report([string]$History) {
        Get-ChildItem -LiteralPath (Join-Path $History 'reports') -Filter 'drift-*.json' -File | Sort-Object LastWriteTimeUtc, Name | Select-Object -Last 1
    }
}

Describe 'Compare-TenantSnapshot with a source' {
    It 'names the repository and the commit, and keeps the shape without a source' {
        $s = @{ resources = @((script:Res 'microsoft.entra.group' 'G' @{ Description = 'a' })) }
        $t = @{ resources = @((script:Res 'microsoft.entra.group' 'G' @{ Description = 'b' })) }
        $live = Compare-TenantSnapshot -Source $s -Target $t
        $live.Direction | Should -BeLike 'Prod -> Dev*'
        $live.PSObject.Properties.Name | Should -Not -Contain 'Source'
        $repo = Compare-TenantSnapshot -Source $s -Target $t -SourceInfo @{ Kind = 'Repository'; Commit = $script:Commit }
        $repo.Direction | Should -BeLike 'Configuration repository -> Dev*a1b2c3d4e5f6*'
        $repo.Source['Kind'] | Should -Be 'Repository'
        $repo.Source['Commit'] | Should -Be $script:Commit
        $repo.Summary.Changed | Should -Be $live.Summary.Changed
    }
    It 'refuses a source without the full commit' {
        { Compare-TenantSnapshot -Source @{ resources = @() } -Target @{ resources = @() } -SourceInfo @{ Kind = 'Repository'; Commit = 'abc' } } | Should -Throw '*full commit ID*'
        { Compare-TenantSnapshot -Source @{ resources = @() } -Target @{ resources = @() } -SourceInfo @{ Kind = 'Prod'; Commit = $script:Commit } } | Should -Throw '*Kind = Repository*'
    }
}

Describe 'ConvertTo-DriftReportMarkdown with a source' {
    It 'names the commit and calls the desired column Desired' {
        $s = @{ resources = @((script:Res 'microsoft.entra.group' 'G' @{ Description = 'a' })) }
        $t = @{ resources = @((script:Res 'microsoft.entra.group' 'G' @{ Description = 'b' })) }
        $md = ConvertTo-DriftReportMarkdown -Report (Compare-TenantSnapshot -Source $s -Target $t -SourceInfo @{ Kind = 'Repository'; Commit = $script:Commit })
        $md | Should -BeLike "*Desired state: configuration repository, commit $($script:Commit). Prod was not read.*"
        $md | Should -BeLike '*| Property | Desired | Dev |*'
        $live = ConvertTo-DriftReportMarkdown -Report (Compare-TenantSnapshot -Source $s -Target $t)
        $live | Should -BeLike '*| Property | Prod | Dev |*'
        $live | Should -Not -BeLike '*configuration repository*'
    }
}

Describe 'Get-DriftReport.ps1 -Source Repository' {
    It 'compares desired/ with Dev, names source and commit and reads no Prod' {
        $s = script:New-Setup 'sync-diff'
        $dev = script:Save-Snapshot (script:Tenant-Resources $script:DevFilter 8) (Join-Path $s.Dir 'dev.json')
        $r = script:Invoke-Drift @('-ConfigPath', $s.ConfigPath, '-HistoryRoot', $s.History, '-Source', 'Repository', '-TargetSnapshotPath', $dev)
        $r.Exit | Should -Be 0 -Because $r.Output
        $r.Output | Should -BeLike '*Prod is not read*'
        $file = script:Newest-Report $s.History
        $doc = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
        $doc['Source']['Kind'] | Should -Be 'Repository'
        $doc['Source']['Commit'] | Should -Be $s.Commit
        $doc['Direction'] | Should -BeLike 'Configuration repository -> Dev*'
        $doc['Summary']['Changed'] | Should -Be 1
        $changed = @($doc['Types'] | Where-Object { $_['ResourceType'] -eq 'microsoft.intune.deviceconfigurationpolicywindows10' })[0]['Changed'][0]
        @($changed['Differences'] | ForEach-Object { $_['Property'] }) | Should -Be @('PasswordMinimumLength')
        @(Get-ChildItem -LiteralPath (Join-Path $s.History 'Tenants') -Recurse -ErrorAction SilentlyContinue).Count | Should -Be 0
        $audit = @(Get-Content -LiteralPath (Join-Path $s.History 'audit.jsonl') | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable } | Where-Object { $_['Mode'] -eq 'report' })
        $audit[-1]['Reason'] | Should -BeLike "drift desired/ $($s.Commit.Substring(0, 12)) -> Dev (offline): 0 added, 0 removed, 1 changed"
    }
    It 'exits 0 without and 1 with differences when -ReportExitCode is set' {
        $s = script:New-Setup 'sync-codes'
        $same = script:Save-Snapshot (script:Tenant-Resources $script:DevFilter 12) (Join-Path $s.Dir 'same.json')
        $diff = script:Save-Snapshot (script:Tenant-Resources $script:DevFilter 8) (Join-Path $s.Dir 'diff.json')
        $r0 = script:Invoke-Drift @('-ConfigPath', $s.ConfigPath, '-HistoryRoot', $s.History, '-Source', 'Repository', '-TargetSnapshotPath', $same, '-ReportExitCode')
        $r0.Exit | Should -Be 0 -Because $r0.Output
        $r0.Output | Should -BeLike '*No differences.*'
        $r1 = script:Invoke-Drift @('-ConfigPath', $s.ConfigPath, '-HistoryRoot', $s.History, '-Source', 'Repository', '-TargetSnapshotPath', $diff, '-ReportExitCode')
        $r1.Exit | Should -Be 1 -Because $r1.Output
    }
    It 'exits 3 (not verified) and writes no report when desired/ has an uncommitted change' {
        $s = script:New-Setup 'sync-dirty'
        $dev = script:Save-Snapshot (script:Tenant-Resources $script:DevFilter 12) (Join-Path $s.Dir 'dev.json')
        $file = Get-ChildItem -LiteralPath (Join-Path $s.Repo 'desired') -Recurse -Filter 'Windows baseline.json' | Select-Object -First 1
        Add-Content -LiteralPath $file.FullName -Value ' '
        $r = script:Invoke-Drift @('-ConfigPath', $s.ConfigPath, '-HistoryRoot', $s.History, '-Source', 'Repository', '-TargetSnapshotPath', $dev, '-ReportExitCode')
        $r.Exit | Should -Be 3
        ($r.Output -replace '\s', '') | Should -BeLike '*Notverified*notcommitted*'
        script:Newest-Report $s.History | Should -BeNullOrEmpty
    }
    It 'stops with an error without -ReportExitCode and refuses a Prod snapshot path' {
        $s = script:New-Setup 'sync-refuse'
        $dev = script:Save-Snapshot (script:Tenant-Resources $script:DevFilter 12) (Join-Path $s.Dir 'dev.json')
        $r = script:Invoke-Drift @('-ConfigPath', $s.ConfigPath, '-HistoryRoot', $s.History, '-Source', 'Repository', '-SourceSnapshotPath', $dev, '-TargetSnapshotPath', $dev)
        $r.Exit | Should -Not -Be 0
        # Compared without blanks: the error view may wrap the message at any blank.
        ($r.Output -replace '\s', '') | Should -BeLike '*-SourceSnapshotPathisfor-SourceLive*'
    }
    It 'keeps Live as the default: a Prod and a Dev snapshot, no source in the report' {
        $s = script:New-Setup 'sync-live'
        $prod = script:Save-Snapshot (script:Tenant-Resources $script:ProdFilter 12) (Join-Path $s.Dir 'p.json')
        $dev = script:Save-Snapshot (script:Tenant-Resources $script:DevFilter 12) (Join-Path $s.Dir 'd.json')
        $r = script:Invoke-Drift @('-ConfigPath', $s.ConfigPath, '-HistoryRoot', $s.History, '-SourceSnapshotPath', $prod, '-TargetSnapshotPath', $dev)
        $r.Exit | Should -Be 0 -Because $r.Output
        $doc = Get-Content -LiteralPath (script:Newest-Report $s.History).FullName -Raw | ConvertFrom-Json -AsHashtable
        $doc.Contains('Source') | Should -BeFalse
        $doc['Direction'] | Should -BeLike 'Prod -> Dev*'
    }
}

Describe 'Rebuild chain from the repository ends with the sync report' {
    It 'runs the drift report with the repository as source and no Prod token' {
        $root = Join-Path $TestDrive 'chain'
        $drift = [System.Collections.Generic.List[hashtable]]::new()
        $runner = {
            param($ScriptPath, [hashtable]$Arguments)
            $name = Split-Path $ScriptPath -Leaf
            $reports = Join-Path $root 'reports'; $null = New-Item -ItemType Directory -Path $reports -Force
            if ($name -eq 'Get-DriftReport.ps1') { $drift.Add($Arguments); '{}' | Set-Content -LiteralPath (Join-Path $reports "drift-$([guid]::NewGuid().ToString('N')).json"); return }
            $prefix = switch ($name) { 'Invoke-DevBaseline.ps1' { 'dev-baseline-plan' } 'Invoke-ApplyDev.ps1' { 'apply-plan' } default { 'dev-users-plan' } }
            if ($Arguments.ContainsKey('Apply')) { return }
            @{ PlanHash = "hash-$prefix"; Plan = @{ Summary = @{ Planned = 0 } } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $reports "$prefix-$([guid]::NewGuid().ToString('N')).json")
        }.GetNewClosure()
        $cfg = Import-M365CloningConfig -Path $script:Valid
        $dev = ConvertTo-SecureString -String 'fake-dev' -AsPlainText -Force
        $prod = ConvertTo-SecureString -String 'fake-prod' -AsPlainText -Force
        $r = Invoke-DevRebuildChain -ScriptRoot '/scripts' -ConfigPath 'c.psd1' -Config $cfg -HistoryRoot $root -ProdToken $prod -DevToken $dev -Source Repository -Runner $runner -Prompt { param($StepName, $PlanHash, $PlanPath) $PlanHash }
        $r.Completed | Should -BeTrue
        $drift.Count | Should -Be 1
        $drift[0]['Source'] | Should -Be 'Repository'
        $drift[0].ContainsKey('ProdToken') | Should -BeFalse
        $r.Report | Should -Not -BeNullOrEmpty
    }
    It 'keeps Prod -> Dev for a live rebuild' {
        $root = Join-Path $TestDrive 'chain-live'
        $drift = [System.Collections.Generic.List[hashtable]]::new()
        $runner = {
            param($ScriptPath, [hashtable]$Arguments)
            $reports = Join-Path $root 'reports'; $null = New-Item -ItemType Directory -Path $reports -Force
            if ((Split-Path $ScriptPath -Leaf) -eq 'Get-DriftReport.ps1') { $drift.Add($Arguments); return }
            @{ PlanHash = 'h'; Plan = @{ Summary = @{ Planned = 0 } } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $reports "$((Split-Path $ScriptPath -Leaf) -replace 'Invoke-DevBaseline.ps1','dev-baseline-plan' -replace 'Invoke-ApplyDev.ps1','apply-plan' -replace 'Invoke-DevUsers.ps1','dev-users-plan')-$([guid]::NewGuid().ToString('N')).json")
        }.GetNewClosure()
        $cfg = Import-M365CloningConfig -Path $script:Valid
        $dev = ConvertTo-SecureString -String 'fake-dev' -AsPlainText -Force
        $prod = ConvertTo-SecureString -String 'fake-prod' -AsPlainText -Force
        $null = Invoke-DevRebuildChain -ScriptRoot '/scripts' -ConfigPath 'c.psd1' -Config $cfg -HistoryRoot $root -ProdToken $prod -DevToken $dev -Runner $runner -Prompt { param($StepName, $PlanHash, $PlanPath) $PlanHash }
        $drift.Count | Should -Be 1
        $drift[0].ContainsKey('Source') | Should -BeFalse
        $drift[0].ContainsKey('ProdToken') | Should -BeTrue
    }
}

Describe 'Web job: drift report with a source' {
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $script:Signed = [System.Collections.Generic.List[string]]::new()
        $script:FakeToken = { param($Config, [string]$Side) $script:Signed.Add($Side); ConvertTo-SecureString -String "fake-$Side" -AsPlainText -Force }
        $script:Record = { param([string]$Path, [System.Collections.IDictionary]$Parameters, [string]$Log) $script:Calls.Add([pscustomobject]@{ Script = (Split-Path -Leaf $Path); Parameters = $Parameters }); 0 }
        $script:Scripts = Join-Path $PSScriptRoot '..' 'scripts'
    }
    BeforeAll {
        function script:New-JobFile([string]$Root, [hashtable]$Options) {
            $dir = Join-Path $Root 'jobs'
            $null = New-Item -ItemType Directory -Path $dir -Force
            $path = Join-Path $dir 'job-20261108-120000-abc123.json'
            [ordered]@{
                SchemaVersion = '2'; Kind = 'job'
                Job = [ordered]@{ id = 'job-20261108-120000-abc123'; action = 'drift'; status = 'queued'; role = 'Applier'; actor = 'Test Person'
                    createdUtc = '2026-11-08T12:00:00Z'; updatedUtc = '2026-11-08T12:00:00Z'; startedUtc = $null; finishedUtc = $null
                    options = $Options; steps = @(); message = ''; result = @{} }
                Confirm = @{}
            } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
            $path
        }
    }
    It 'the sync report signs in to Dev only and passes the source' {
        $root = Join-Path $TestDrive 'job-sync'
        $path = script:New-JobFile -Root $root -Options @{ source = 'Repository' }
        Invoke-WebJob -JobPath $path -HistoryRoot $root -ConfigPath $script:Valid -ScriptRoot $script:Scripts -TokenProvider $script:FakeToken -ScriptRunner $script:Record
        $job = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable)['Job']
        $job['status'] | Should -Be 'succeeded'
        @($script:Signed) | Should -Be @('Dev')
        $script:Calls[0].Script | Should -Be 'Get-DriftReport.ps1'
        $script:Calls[0].Parameters['Source'] | Should -Be 'Repository'
        $script:Calls[0].Parameters.Contains('ProdToken') | Should -BeFalse
        ($job['steps'] | Where-Object { $_['key'] -eq 'run' })['title'] | Should -Be 'Read the desired state and Dev and compare'
    }
    It 'a drift report with the default source reads Prod and Dev as before' {
        $root = Join-Path $TestDrive 'job-drift-live'
        $path = script:New-JobFile -Root $root -Options @{ source = 'Live' }
        Invoke-WebJob -JobPath $path -HistoryRoot $root -ConfigPath $script:Valid -ScriptRoot $script:Scripts -TokenProvider $script:FakeToken -ScriptRunner $script:Record
        @($script:Signed) | Should -Be @('Prod', 'Dev')
        $script:Calls[0].Parameters.Contains('Source') | Should -BeFalse
    }
}
