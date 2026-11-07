function Get-IntuneBackupSettings {
    <#
    .SYNOPSIS
        Where and how the Intune backup runs (issue #68, ADR 0014): the configuration repository of the operator
        (ConfigRepository, ADR 0004), the Python command and the extra IntuneCD types to leave out.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)
    $repo = if ($Config.ContainsKey('ConfigRepository')) { [string]$Config.ConfigRepository } else { '' }
    if ([string]::IsNullOrWhiteSpace($repo) -or $repo -match '^\s*<.*>\s*$') {
        throw 'ConfigRepository is not set in config.psd1: the path of your private configuration repository (ADR 0004).'
    }
    $section = if ($Config.ContainsKey('IntuneBackup') -and $Config.IntuneBackup -is [hashtable]) { $Config.IntuneBackup } else { @{} }
    $python = if ($section.ContainsKey('Python') -and $section.Python) { [string]$section.Python } elseif ($IsWindows) { 'python' } else { 'python3' }
    [pscustomobject]@{
        Repository = $repo
        Python     = $python
        Exclude    = @(if ($section.ContainsKey('Exclude')) { @($section.Exclude) | ForEach-Object { [string]$_ } })
    }
}

function Invoke-IntuneBackup {
    <#
    .SYNOPSIS
        Read-only backup of the Intune configuration of Prod and Dev with IntuneCD into the configuration repository
        of the operator, one Git commit per run (issue #68, ADR 0014).
    .DESCRIPTION
        For each tenant IntuneCD writes its backup (JSON files, one per configuration, named by display name) into a
        new empty folder below History\tmp. Only when both tenants succeeded, the folders <ConfigRepository>\intune\prod
        and \dev are replaced by them; a failed run leaves the repository as it was. Git then shows what was added,
        changed or removed since the last run; the change is committed with a time stamp (only the intune folder,
        nothing else of the repository). Nothing is pushed.
        Writes History\reports\intune-backup-<time>.json (the files that changed per tenant) and one audit line
        (mode 'backup', counts in the reason, no names).
        Nothing is written to any tenant: IntuneCD's backup only reads (its update is never called), the token is
        handed to the Python process on stdin and never written to disk.
        -BackupRunner replaces the IntuneCD call (tests, no tenant): param($Side, $Folder, [securestring]$Token,
        [string[]]$Exclude, $Settings) returns the exit code.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$HistoryRoot,
        [Parameter(Mandatory)][securestring]$ProdToken,
        [Parameter(Mandatory)][securestring]$DevToken,
        [scriptblock]$BackupRunner,
        [datetime]$Now = (Get-Date)
    )
    $settings = Get-IntuneBackupSettings -Config $Config
    foreach ($type in $settings.Exclude) {
        if ($type -notmatch '^[A-Za-z]+$') { throw "IntuneBackup.Exclude: '$type' is not an IntuneCD type name." }
    }
    $repo = Assert-IntuneBackupRepository -Path $settings.Repository

    $utcNow = $Now.ToUniversalTime()
    $stamp = $utcNow.ToString('yyyyMMdd-HHmmss')
    $tmpRoot = Join-Path $HistoryRoot 'tmp' "intune-backup-$stamp"
    if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force }
    $runner = if ($BackupRunner) { $BackupRunner } else { ${function:Invoke-IntuneCdProcess} }
    $tokens = @{ Prod = $ProdToken; Dev = $DevToken }
    $sides = @('Prod', 'Dev')
    try {
        # 1. Back up each tenant into its own empty folder; nothing in the repository changes yet.
        foreach ($side in $sides) {
            $folder = Join-Path $tmpRoot $side.ToLowerInvariant()
            $null = New-Item -ItemType Directory -Path $folder -Force
            Write-Host "Backing up the Intune configuration of $side (read only) ..."
            $exit = & $runner $side $folder $tokens[$side] $settings.Exclude $settings
            if ([int]$exit -ne 0) { throw "The IntuneCD backup of $side ended with exit code $exit. The configuration repository was not changed." }
            $count = @(Get-ChildItem -LiteralPath $folder -Recurse -File).Count
            if ($count -eq 0) { throw "The IntuneCD backup of $side wrote no file (missing Graph permissions?). The configuration repository was not changed." }
            Write-Host "$side`: $count files."
        }
        # 2. Replace the folders in the repository (copy, then remove: History and the repository may be on other drives).
        foreach ($side in $sides) {
            $target = Join-Path $repo 'intune' $side.ToLowerInvariant()
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
            $null = New-Item -ItemType Directory -Path $target -Force
            # -LiteralPath per item: display names may contain [ ] (wildcards for -Path).
            foreach ($item in Get-ChildItem -LiteralPath (Join-Path $tmpRoot $side.ToLowerInvariant()) -Force) {
                Copy-Item -LiteralPath $item.FullName -Destination $target -Recurse -Force
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # 3. What changed since the last run, per tenant; then one commit of the intune folder only.
    Invoke-IntuneBackupGit -Repository $repo -Arguments @('add', '--all', '--', 'intune') | Out-Null
    $tenants = foreach ($side in $sides) {
        $rel = "intune/$($side.ToLowerInvariant())"
        $lines = @(Invoke-IntuneBackupGit -Repository $repo -Arguments @('-c', 'core.quotepath=off', 'diff', '--cached', '--name-status', '--no-renames', '--', $rel))
        $changes = foreach ($line in $lines) {
            if ($line -notmatch '^([AMD])\t(.+)$') { continue }
            $what = switch ($Matches[1]) { 'A' { 'added' } 'M' { 'changed' } 'D' { 'removed' } }
            [ordered]@{ Path = $Matches[2].Substring($rel.Length + 1); Change = $what }
        }
        $changes = @($changes)
        $files = @(Get-ChildItem -LiteralPath (Join-Path $repo 'intune' $side.ToLowerInvariant()) -Recurse -File).Count
        [ordered]@{
            Side      = $side
            Folder    = $rel
            Files     = $files
            Added     = @($changes | Where-Object { $_.Change -eq 'added' }).Count
            Changed   = @($changes | Where-Object { $_.Change -eq 'changed' }).Count
            Removed   = @($changes | Where-Object { $_.Change -eq 'removed' }).Count
            Changes   = @($changes | Sort-Object { $_.Path } | Select-Object -First 1000)
            Truncated = $changes.Count -gt 1000
        }
    }
    $tenants = @($tenants)
    $total = ($tenants | ForEach-Object { $_.Added + $_.Changed + $_.Removed } | Measure-Object -Sum).Sum
    $commit = ''
    if ($total -gt 0) {
        $subject = 'Intune backup {0}' -f $utcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $body = @(foreach ($t in $tenants) { '{0}: {1} added, {2} changed, {3} removed ({4} files)' -f $t.Side, $t.Added, $t.Changed, $t.Removed, $t.Files })
        $actor = (([string]$env:M365CLONING_ACTOR) -replace '[\p{C}]', '').Trim()
        if ($actor) { $body += "Started by: $actor" }
        Invoke-IntuneBackupGit -Repository $repo -Arguments (@('-c', 'user.name=M365Cloning backup', '-c', 'user.email=m365cloning-backup@localhost',
                'commit', '--quiet', '-m', $subject, '-m', ($body -join "`n"), '--', 'intune')) | Out-Null
        $commit = [string](Invoke-IntuneBackupGit -Repository $repo -Arguments @('rev-parse', 'HEAD') | Select-Object -First 1)
        Write-Host "Committed $($commit.Substring(0, [Math]::Min(12, $commit.Length))) in the configuration repository (not pushed)."
    }
    else { Write-Host 'No change since the last backup; nothing committed.' }

    $report = [ordered]@{
        SchemaVersion = '2'
        Kind          = 'intunebackup'
        CreatedUtc    = $utcNow.ToString('o')
        Commit        = $commit
        Unchanged     = ($total -eq 0)
        Tenants       = $tenants
    }
    $reports = Join-Path $HistoryRoot 'reports'
    $null = New-Item -ItemType Directory -Path $reports -Force
    $path = Join-Path $reports "intune-backup-$stamp.json"
    ConvertTo-Json -InputObject $report -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
    $reason = 'intune backup: ' + (@(foreach ($t in $tenants) { '{0} {1} added, {2} changed, {3} removed' -f $t.Side, $t.Added, $t.Changed, $t.Removed }) -join '; ')
    if ($commit) { $reason += "; commit $($commit.Substring(0, [Math]::Min(12, $commit.Length)))" }
    Write-ApplyAudit -HistoryRoot $HistoryRoot -Mode backup -Reason $reason
    [pscustomobject]@{ Path = $path; Report = $report }
}

function Assert-IntuneBackupRepository {
    <#
    .SYNOPSIS
        The configuration repository must exist, be a Git work tree and must not be this toolkit (its data would end
        up in a public tool set, ADR 0002). Returns the full path of its top folder.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "ConfigRepository '$Path' does not exist." }
    if (-not (Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue)) { throw 'Git is needed for the Intune backup (git was not found).' }
    $top = Invoke-IntuneBackupGit -Repository $Path -Arguments @('rev-parse', '--show-toplevel') -Quiet | Select-Object -First 1
    if (-not $top) { throw "ConfigRepository '$Path' is not a Git repository (run 'git init' there first)." }
    $top = (Resolve-Path -LiteralPath ([string]$top)).ProviderPath
    $toolkit = (Resolve-Path -LiteralPath (Join-Path $script:ModuleRoot '..' '..')).ProviderPath
    $norm = { param($p) ([string]$p).TrimEnd('\', '/').Replace('\', '/') }
    $t = & $norm $top
    $k = & $norm $toolkit
    $cmp = if ($IsWindows -or $IsMacOS) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if ([string]::Equals($t, $k, $cmp) -or $t.StartsWith("$k/", $cmp) -or $k.StartsWith("$t/", $cmp)) {
        throw 'ConfigRepository must be your own private repository, not this toolkit or a folder around it (ADR 0002, ADR 0004).'
    }
    $top
}

function Invoke-IntuneBackupGit {
    <# Runs git in the configuration repository; a failure stops the run with git's first line of error. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$Quiet
    )
    $output = & git -C $Repository @Arguments 2>&1
    $code = $LASTEXITCODE
    $text = @($output | ForEach-Object { [string]$_ })
    if ($code -ne 0) {
        if ($Quiet) { return }
        $first = ($text | Where-Object { $_ } | Select-Object -First 1)
        throw "git $($Arguments | Where-Object { $_ -notlike 'user.*' -and $_ -ne '-c' } | Select-Object -First 1) failed in the configuration repository: $first"
    }
    $text
}

function Invoke-IntuneCdProcess {
    <#
    .SYNOPSIS
        Runs tools/intunecd/intunecd_backup.py for one tenant. The token goes to the process on stdin, never on the
        command line, into an environment variable or a file. Returns the exit code; the output goes to the log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Side,
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][securestring]$Token,
        [string[]]$Exclude = @(),
        [Parameter(Mandatory)]$Settings
    )
    if (-not (Get-Command -Name $Settings.Python -ErrorAction SilentlyContinue)) {
        throw "Python was not found ('$($Settings.Python)'). Install Python 3.12 and IntuneCD (pip install --require-hashes -r tools/intunecd/requirements.txt) or set IntuneBackup.Python in config.psd1."
    }
    $wrapper = Join-Path $script:ModuleRoot '..' '..' 'tools' 'intunecd' 'intunecd_backup.py'
    $arguments = @($wrapper, '--path', $Folder)
    if ($Exclude.Count -gt 0) { $arguments += '--exclude'; $arguments += $Exclude }
    $plain = [System.Net.NetworkCredential]::new('', $Token).Password
    try {
        $plain | & $Settings.Python @arguments 2>&1 | ForEach-Object { Write-Host ("  [{0}] {1}" -f $Side, [string]$_) }
        $LASTEXITCODE
    }
    finally { $plain = $null }
}
