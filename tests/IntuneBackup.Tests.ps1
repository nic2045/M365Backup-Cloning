# Intune backup with IntuneCD (issue #68, ADR 0014). Offline only: the IntuneCD call is replaced by a script block
# that writes invented files, the configuration repository is a new Git repository below TestDrive, nothing calls a
# tenant.
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
    function script:New-Config([string]$Repo, [hashtable]$Backup = @{}) {
        $c = Import-M365CloningConfig -Path $script:Valid
        $c['ConfigRepository'] = $Repo
        if ($Backup.Count) { $c['IntuneBackup'] = $Backup }
        $c
    }
    # Stand-in for IntuneCD: per side the files of $script:Files[side] (path -> content).
    $script:Runner = {
        param($Side, $Folder, [securestring]$Token, [string[]]$Exclude, $Settings)
        $script:Seen.Add([pscustomobject]@{ Side = $Side; Token = [System.Net.NetworkCredential]::new('', $Token).Password; Exclude = $Exclude; IncludeScripts = $Settings.IncludeScripts })
        foreach ($rel in $script:Files[$Side].Keys) {
            $path = Join-Path $Folder $rel
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
            Set-Content -LiteralPath $path -Value $script:Files[$Side][$rel] -Encoding utf8
        }
        0
    }
    $script:Prod = ConvertTo-SecureString 'fake-prod' -AsPlainText -Force
    $script:Dev = ConvertTo-SecureString 'fake-dev' -AsPlainText -Force
    function script:GitIn([string]$Repo) { & git -C $Repo @args 2>&1 }
}

Describe 'Invoke-IntuneBackup' {
    BeforeEach {
        $script:Seen = [System.Collections.Generic.List[object]]::new()
        $script:Files = @{
            Prod = @{ 'Settings Catalog/Windows - Example baseline.json' = '{"a":1}'; 'Compliance Policies/Policies/Windows [Pilot].json' = '{"b":1}' }
            Dev  = @{ 'Settings Catalog/Windows - Example baseline.json' = '{"a":0}' }
        }
    }

    It 'backs up both tenants into intune/prod and intune/dev and commits only that folder' {
        $repo = script:New-ConfigRepo 'repo1'
        Set-Content -LiteralPath (Join-Path $repo 'other.txt') -Value 'not mine'
        $null = script:GitIn $repo add other.txt
        $hist = Join-Path $TestDrive 'h1'
        $r = Invoke-IntuneBackup -Config (script:New-Config $repo) -HistoryRoot $hist -ProdToken $script:Prod -DevToken $script:Dev -BackupRunner $script:Runner -Now ([datetime]'2026-11-07T12:00:00Z')
        @($script:Seen.Side) | Should -Be @('Prod', 'Dev')
        @($script:Seen.Token) | Should -Be @('fake-prod', 'fake-dev')
        Test-Path (Join-Path $repo 'intune' 'prod' 'Settings Catalog' 'Windows - Example baseline.json') | Should -BeTrue
        $r.Report.Commit | Should -Match '^[0-9a-f]{40}$'
        $r.Report.Unchanged | Should -BeFalse
        $r.Report.Tenants[0].Added | Should -Be 2
        Test-Path -LiteralPath (Join-Path $repo 'intune' 'prod' 'Compliance Policies' 'Policies' 'Windows [Pilot].json') | Should -BeTrue
        $r.Report.Tenants[1].Added | Should -Be 1
        # Only the intune folder is in the commit; the operator's own staged file stays staged and uncommitted.
        @(script:GitIn $repo show --name-only --format= HEAD) | ForEach-Object { $_ | Should -BeLike 'intune/*' }
        @(script:GitIn $repo diff --cached --name-only) | Should -Be @('other.txt')
        (script:GitIn $repo log -1 --format=%an) | Should -Be 'M365Cloning backup'
        (script:GitIn $repo log -1 --format=%s) | Should -Be 'Intune backup 2026-11-07T12:00:00Z'
        Split-Path -Leaf $r.Path | Should -Be 'intune-backup-20261107-120000.json'
        Test-Path (Join-Path $hist 'tmp' 'intune-backup-20261107-120000') | Should -BeFalse
    }

    It 'shows added, changed and removed files of the next run, per tenant' {
        $repo = script:New-ConfigRepo 'repo2'
        $hist = Join-Path $TestDrive 'h2'
        $cfg = script:New-Config $repo
        $null = Invoke-IntuneBackup -Config $cfg -HistoryRoot $hist -ProdToken $script:Prod -DevToken $script:Dev -BackupRunner $script:Runner -Now ([datetime]'2026-11-07T12:00:00Z')
        $script:Files.Prod = @{ 'Settings Catalog/Windows - Example baseline.json' = '{"a":2}'; 'Filters/New filter.json' = '{}' }
        $r = Invoke-IntuneBackup -Config $cfg -HistoryRoot $hist -ProdToken $script:Prod -DevToken $script:Dev -BackupRunner $script:Runner -Now ([datetime]'2026-11-07T13:00:00Z')
        $prod = $r.Report.Tenants[0]
        ($prod.Added, $prod.Changed, $prod.Removed) | Should -Be @(1, 1, 1)
        $map = @{}; foreach ($c in $prod.Changes) { $map[$c.Path] = $c.Change }
        $map['Filters/New filter.json'] | Should -Be 'added'
        $map['Settings Catalog/Windows - Example baseline.json'] | Should -Be 'changed'
        $map['Compliance Policies/Policies/Windows [Pilot].json'] | Should -Be 'removed'
        $r.Report.Tenants[1].Changes.Count | Should -Be 0
        @(script:GitIn $repo log --format=%s).Count | Should -Be 3
    }

    It 'commits nothing when nothing changed and says so' {
        $repo = script:New-ConfigRepo 'repo3'
        $hist = Join-Path $TestDrive 'h3'
        $cfg = script:New-Config $repo
        $null = Invoke-IntuneBackup -Config $cfg -HistoryRoot $hist -ProdToken $script:Prod -DevToken $script:Dev -BackupRunner $script:Runner -Now ([datetime]'2026-11-07T12:00:00Z')
        $r = Invoke-IntuneBackup -Config $cfg -HistoryRoot $hist -ProdToken $script:Prod -DevToken $script:Dev -BackupRunner $script:Runner -Now ([datetime]'2026-11-07T13:00:00Z')
        $r.Report.Unchanged | Should -BeTrue
        $r.Report.Commit | Should -Be ''
        @(script:GitIn $repo log --format=%s).Count | Should -Be 2
    }

    It 'leaves the repository as it was when a tenant fails' {
        $repo = script:New-ConfigRepo 'repo4'
        $hist = Join-Path $TestDrive 'h4'
        $cfg = script:New-Config $repo
        $null = Invoke-IntuneBackup -Config $cfg -HistoryRoot $hist -ProdToken $script:Prod -DevToken $script:Dev -BackupRunner $script:Runner -Now ([datetime]'2026-11-07T12:00:00Z')
        $failDev = { param($Side, $Folder, $Token, $Exclude, $Settings) if ($Side -eq 'Dev') { 4 } else { Set-Content (Join-Path $Folder 'x.json') '{}'; 0 } }
        { Invoke-IntuneBackup -Config $cfg -HistoryRoot $hist -ProdToken $script:Prod -DevToken $script:Dev -BackupRunner $failDev -Now ([datetime]'2026-11-07T13:00:00Z') } |
            Should -Throw '*Dev ended with exit code 4*not changed*'
        Test-Path (Join-Path $repo 'intune' 'prod' 'x.json') | Should -BeFalse
        @(script:GitIn $repo status --porcelain) | Should -BeNullOrEmpty
        Test-Path (Join-Path $hist 'tmp' 'intune-backup-20261107-130000') | Should -BeFalse
        Test-Path (Join-Path $hist 'reports' 'intune-backup-20261107-130000.json') | Should -BeFalse
    }

    It 'refuses a backup without any file (missing permissions)' {
        $repo = script:New-ConfigRepo 'repo5'
        $empty = { param($Side, $Folder, $Token, $Exclude, $Settings) 0 }
        { Invoke-IntuneBackup -Config (script:New-Config $repo) -HistoryRoot (Join-Path $TestDrive 'h5') -ProdToken $script:Prod -DevToken $script:Dev -BackupRunner $empty } |
            Should -Throw '*wrote no file*'
    }

    It 'writes the report in the schema and one audit line with counts only' {
        $repo = script:New-ConfigRepo 'repo6'
        $hist = Join-Path $TestDrive 'h6'
        $actor = $env:M365CLONING_ACTOR
        $env:M365CLONING_ACTOR = 'Test Person'
        try { $r = Invoke-IntuneBackup -Config (script:New-Config $repo) -HistoryRoot $hist -ProdToken $script:Prod -DevToken $script:Dev -BackupRunner $script:Runner }
        finally { $env:M365CLONING_ACTOR = $actor }
        $work = Join-Path $TestDrive 'schema6'; $null = New-Item -ItemType Directory -Path $work -Force
        Test-ContractJson -Json (Get-Content $r.Path -Raw) -Definition 'IntuneBackup' -Folder $work | Should -BeNullOrEmpty
        $line = Get-Content (Join-Path $hist 'audit.jsonl') | Select-Object -Last 1
        Test-ContractJson -Json $line -Definition 'AuditEntry' -Folder $work | Should -BeNullOrEmpty
        $entry = $line | ConvertFrom-Json
        $entry.Mode | Should -Be 'backup'
        $entry.Actor | Should -Be 'Test Person'
        $entry.Reason | Should -Match 'Prod 2 added, 0 changed, 0 removed; Dev 1 added'
        $entry.Reason | Should -Not -Match 'Example baseline'
        (script:GitIn $repo log -1 --format=%b) -join "`n" | Should -Match 'Started by: Test Person'
    }

    It 'passes the extra types of the config to IntuneCD' {
        $repo = script:New-ConfigRepo 'repo7'
        $cfg = script:New-Config $repo @{ Exclude = @('PowershellScripts', 'ShellScripts') }
        $null = Invoke-IntuneBackup -Config $cfg -HistoryRoot (Join-Path $TestDrive 'h7') -ProdToken $script:Prod -DevToken $script:Dev -BackupRunner $script:Runner
        @($script:Seen[0].Exclude) | Should -Be @('PowershellScripts', 'ShellScripts')
    }

    It 'leaves the script types out unless IncludeScripts is set (issue #74)' {
        $repo = script:New-ConfigRepo 'repo9'
        $null = Invoke-IntuneBackup -Config (script:New-Config $repo) -HistoryRoot (Join-Path $TestDrive 'h9') -ProdToken $script:Prod -DevToken $script:Dev -BackupRunner $script:Runner
        $script:Seen[0].IncludeScripts | Should -BeFalse
        $script:Seen.Clear()
        $repo2 = script:New-ConfigRepo 'repo10'
        $null = Invoke-IntuneBackup -Config (script:New-Config $repo2 @{ IncludeScripts = $true }) -HistoryRoot (Join-Path $TestDrive 'h10') -ProdToken $script:Prod -DevToken $script:Dev -BackupRunner $script:Runner
        $script:Seen[0].IncludeScripts | Should -BeTrue
    }
}

Describe 'Invoke-IntuneBackup: where it may write' {
    It 'refuses a config without ConfigRepository' {
        $c = Import-M365CloningConfig -Path $script:Valid
        { Invoke-IntuneBackup -Config $c -HistoryRoot $TestDrive -ProdToken $script:Prod -DevToken $script:Dev -BackupRunner { 0 } } | Should -Throw '*ConfigRepository is not set*'
    }
    It 'refuses a folder that is not a Git repository' {
        $plain = Join-Path $TestDrive 'plain'; $null = New-Item -ItemType Directory -Path $plain -Force
        { Invoke-IntuneBackup -Config (script:New-Config $plain) -HistoryRoot $TestDrive -ProdToken $script:Prod -DevToken $script:Dev -BackupRunner { 0 } } | Should -Throw '*not a Git repository*'
    }
    It 'refuses this toolkit as configuration repository (its data would be published)' {
        $toolkit = Join-Path $PSScriptRoot '..'
        { Invoke-IntuneBackup -Config (script:New-Config $toolkit) -HistoryRoot $TestDrive -ProdToken $script:Prod -DevToken $script:Dev -BackupRunner { 0 } } | Should -Throw '*not this toolkit*'
    }
    It 'refuses a path that does not exist' {
        { Invoke-IntuneBackup -Config (script:New-Config (Join-Path $TestDrive 'nope')) -HistoryRoot $TestDrive -ProdToken $script:Prod -DevToken $script:Dev -BackupRunner { 0 } } | Should -Throw '*does not exist*'
    }
    It 'refuses an exclude entry that is not a type name' {
        $repo = script:New-ConfigRepo 'repo8'
        { Invoke-IntuneBackup -Config (script:New-Config $repo @{ Exclude = @('a b') }) -HistoryRoot $TestDrive -ProdToken $script:Prod -DevToken $script:Dev -BackupRunner { 0 } } | Should -Throw '*not an IntuneCD type name*'
    }
}

Describe 'Config: ConfigRepository and IntuneBackup' {
    BeforeAll {
        function script:Write-Cfg([string]$Extra) {
            $text = (Get-Content -LiteralPath $script:Valid -Raw).TrimEnd()
            $text = $text.Substring(0, $text.Length - 1) + "`n$Extra`n}"
            $path = Join-Path $TestDrive ("cfg-{0}.psd1" -f [guid]::NewGuid().ToString('N'))
            Set-Content -LiteralPath $path -Value $text
            $path
        }
    }
    It 'accepts both settings' {
        $p = script:Write-Cfg "ConfigRepository = 'C:\repo'`nIntuneBackup = @{ Python = 'py'; Exclude = @('PowershellScripts') }"
        (Import-M365CloningConfig -Path $p).IntuneBackup.Python | Should -Be 'py'
    }
    It 'accepts IncludeScripts as a boolean and refuses anything else' {
        $p = script:Write-Cfg "IntuneBackup = @{ IncludeScripts = `$true }"
        (Import-M365CloningConfig -Path $p).IntuneBackup.IncludeScripts | Should -BeTrue
        $bad = script:Write-Cfg "IntuneBackup = @{ IncludeScripts = 'yes' }"
        { Import-M365CloningConfig -Path $bad } | Should -Throw '*IncludeScripts must be*'
    }
    It 'refuses an unknown key under IntuneBackup' {
        $p = script:Write-Cfg "IntuneBackup = @{ Update = `$true }"
        { Import-M365CloningConfig -Path $p } | Should -Throw "*unknown key 'Update'*"
    }
    It 'refuses an exclude entry that is not a type name' {
        $p = script:Write-Cfg "IntuneBackup = @{ Exclude = @('Power Shell') }"
        { Import-M365CloningConfig -Path $p } | Should -Throw '*not an IntuneCD type name*'
    }
}

Describe 'Invoke-IntuneCdProcess' {
    It 'puts the token on stdin, never on the command line' {
        $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'Public' 'Invoke-IntuneBackup.ps1') -Raw
        $text | Should -Match '\$plain \| & \$Settings\.Python @arguments'
        $text | Should -Not -Match "'--token'"
        $text | Should -Not -Match 'env:[A-Z_]*TOKEN'
    }
    It 'never calls the update of IntuneCD' {
        $folders = @((Join-Path $PSScriptRoot '..' 'src'), (Join-Path $PSScriptRoot '..' 'scripts'), (Join-Path $PSScriptRoot '..' 'tools' 'intunecd'))
        $files = @(foreach ($d in $folders) { Get-ChildItem -LiteralPath $d -Recurse -File -Include '*.ps1', '*.py' | Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' } })
        $files.Count | Should -BeGreaterThan 10  # the check must look at real files
        ($files.Name) | Should -Contain 'Invoke-IntuneBackup.ps1'
        ($files.Name) | Should -Contain 'intunecd_backup.py'
        foreach ($f in $files) {
            Get-Content -LiteralPath $f.FullName -Raw | Should -Not -Match '(?i)IntuneCD-startupdate|run_update|update_intune' -Because $f.Name
        }
    }
    It 'passes --include-scripts only when IncludeScripts is set' {
        $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'Public' 'Invoke-IntuneBackup.ps1') -Raw
        $text | Should -Match 'IncludeScripts\) \{ \$arguments \+= ''--include-scripts'' \}'
    }
    It 'names the missing Python with the install hint' {
        $settings = [pscustomobject]@{ Python = 'no-such-python-3x'; Repository = ''; Exclude = @() }
        { & (Get-Module M365Cloning) { param($s, $t) Invoke-IntuneCdProcess -Side Prod -Folder $TestDrive -Token $t -Settings $s } $settings $script:Prod } |
            Should -Throw '*Python was not found*requirements.txt*'
    }
}

Describe 'Invoke-WebJob: intune-backup' {
    It 'runs the backup script with both tokens and links the result' {
        $root = Join-Path $TestDrive 'job'
        $dir = Join-Path $root 'jobs'; $null = New-Item -ItemType Directory -Path $dir -Force
        $id = 'job-20261107-120000-bak001'
        $path = Join-Path $dir "$id.json"
        [ordered]@{ SchemaVersion = '2'; Kind = 'job'; Confirm = @{}
            Job = [ordered]@{ id = $id; action = 'intune-backup'; status = 'queued'; role = 'Applier'; actor = 'Test Person'
                createdUtc = '2026-11-07T12:00:00Z'; updatedUtc = '2026-11-07T12:00:00Z'; startedUtc = $null; finishedUtc = $null
                options = @{}; steps = @(); message = ''; result = @{} } } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path
        $script:Called = $null
        $runner = {
            param([string]$Path, [System.Collections.IDictionary]$Parameters, [string]$Log)
            $script:Called = [pscustomobject]@{ Script = (Split-Path -Leaf $Path); Keys = @($Parameters.Keys) }
            $reports = Join-Path $Parameters['HistoryRoot'] 'reports'; $null = New-Item -ItemType Directory -Path $reports -Force
            Set-Content (Join-Path $reports 'intune-backup-20991231-000000.json') '{}'
            0
        }
        $tokens = { param($Config, [string]$Side) ConvertTo-SecureString "fake-$Side" -AsPlainText -Force }
        Invoke-WebJob -JobPath $path -HistoryRoot $root -ConfigPath $script:Valid -ScriptRoot $script:Scripts -TokenProvider $tokens -ScriptRunner $runner
        $job = (Get-Content $path -Raw | ConvertFrom-Json -AsHashtable)['Job']
        $job['status'] | Should -Be 'succeeded'
        $job['result']['reportId'] | Should -Be 'intune-backup-20991231-000000'
        $job['message'] | Should -BeLike '*Intune changes*'
        $script:Called.Script | Should -Be 'Invoke-IntuneBackup.ps1'
        $script:Called.Keys | Should -Contain 'ProdToken'
        $script:Called.Keys | Should -Contain 'DevToken'
        $work = Join-Path $TestDrive 'schemaJob'; $null = New-Item -ItemType Directory -Path $work -Force
        Test-ContractJson -Json (Get-Content $path -Raw) -Definition 'JobFile' -Folder $work | Should -BeNullOrEmpty
    }
    It 'the script refuses to run without tokens and has a dry run that reads nothing' {
        $repo = script:New-ConfigRepo 'repoDry'
        $cfgPath = Join-Path $TestDrive 'dry.psd1'
        $text = (Get-Content -LiteralPath $script:Valid -Raw).TrimEnd()
        Set-Content -LiteralPath $cfgPath -Value ($text.Substring(0, $text.Length - 1) + "`nConfigRepository = '$repo'`n}")
        $out = & (Join-Path $script:Scripts 'Invoke-IntuneBackup.ps1') -ConfigPath $cfgPath -DryRun 6>&1 | Out-String
        $out | Should -Match 'Dry run'
        { & (Join-Path $script:Scripts 'Invoke-IntuneBackup.ps1') -ConfigPath $cfgPath -HistoryRoot (Join-Path $TestDrive 'hd') } | Should -Throw '*ProdToken*'
    }
}
