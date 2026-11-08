function Invoke-DevRebuildChain {
    <#
    .SYNOPSIS
        Controlled rebuild after a reset (issue #7, ADR 0005): base state -> apply (Intune, Conditional Access) ->
        Dev users -> drift report. Every step makes its own plan and needs its own confirmation; nothing runs on
        without it.
    .DESCRIPTION
        For each step the step script runs in plan mode first (it writes History\reports\<prefix>-*.json with the plan
        hash). A plan with nothing planned is passed over. Otherwise -Prompt is asked; only when it returns exactly the
        plan hash does the step script run again with -Apply -ConfirmPlanHash <hash> (the script makes the plan again
        and refuses if the tenant changed since). Any other answer stops the chain. At the end the drift report runs;
        the goal is an empty report except for what is excluded on purpose.
        -Runner runs a script (tests replace it): param($ScriptPath, [hashtable]$Arguments). -Prompt asks the person:
        param($StepName, $PlanHash, $PlanPath), returns the typed text. The users step is passed over without DevUsers.
        -Source (issue #27 part 2, ADR 0019): where the apply step reads the desired state, Live (Prod snapshot) or
        Repository (desired/ of the configuration repository); the same value is passed with -Apply. With Repository the
        drift report at the end compares desired/ with Dev as well (sync report, issue #27 part 3, ADR 0020).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][string]$HistoryRoot,
        [securestring]$ProdToken,
        [securestring]$DevToken,
        [ValidateSet('Live', 'Repository')][string]$Source = 'Live',
        [scriptblock]$Runner = { param($ScriptPath, [hashtable]$Arguments) & $ScriptPath @Arguments },
        [scriptblock]$Prompt = { param($StepName, $PlanHash, $PlanPath) Read-Host "[$StepName] Plan: $PlanPath`nType the plan hash to apply it (anything else stops)" }
    )
    $common = @{ ConfigPath = $ConfigPath; HistoryRoot = $HistoryRoot }
    $steps = [System.Collections.Generic.List[object]]::new()
    $steps.Add(@{ Name = 'Base state'; Script = 'Invoke-DevBaseline.ps1'; Prefix = 'dev-baseline-plan'; Args = @{ DevToken = $DevToken } })
    $steps.Add(@{ Name = 'Apply Intune and Conditional Access'; Script = 'Invoke-ApplyDev.ps1'; Prefix = 'apply-plan'; Args = $(if ($Source -eq 'Repository') { @{ DevToken = $DevToken; Source = 'Repository' } } else { @{ ProdToken = $ProdToken; DevToken = $DevToken } }) })
    $hasUsers = $Config.Contains('DevUsers') -and @($Config['DevUsers'] | Where-Object { $_ }).Count -gt 0
    if ($hasUsers) { $steps.Add(@{ Name = 'Dev users'; Script = 'Invoke-DevUsers.ps1'; Prefix = 'dev-users-plan'; Args = @{ DevToken = $DevToken } }) }

    $reports = Join-Path $HistoryRoot 'reports'
    $newest = {
        param([string]$Pattern, [datetime]$Since)
        if (-not (Test-Path -LiteralPath $reports)) { return $null }
        Get-ChildItem -LiteralPath $reports -Filter $Pattern -File | Where-Object { $_.LastWriteTimeUtc -ge $Since } |
            Sort-Object LastWriteTimeUtc, Name | Select-Object -Last 1
    }
    $log = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $steps) {
        $path = Join-Path $ScriptRoot $s.Script
        $since = (Get-Date).ToUniversalTime().AddSeconds(-1)
        $null = & $Runner $path ($common + $s.Args)
        $file = & $newest "$($s.Prefix)-*.json" $since
        if (-not $file) { $log.Add([ordered]@{ Step = $s.Name; Status = 'failed'; Message = 'no plan file was written' }); return [pscustomobject]@{ Completed = $false; Steps = [object[]]@($log); Report = $null } }
        $doc = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
        $hash = [string]$doc['PlanHash']
        if ([int]$doc['Plan']['Summary']['Planned'] -eq 0) { $log.Add([ordered]@{ Step = $s.Name; Status = 'nothing-to-do'; Message = '' }); continue }
        $answer = [string](& $Prompt $s.Name $hash ([System.IO.Path]::ChangeExtension($file.FullName, '.md')))
        if (-not [string]::Equals($answer.Trim(), $hash, [System.StringComparison]::OrdinalIgnoreCase)) {
            $log.Add([ordered]@{ Step = $s.Name; Status = 'stopped'; Message = 'not confirmed: the chain stops here' })
            return [pscustomobject]@{ Completed = $false; Steps = [object[]]@($log); Report = $null }
        }
        $null = & $Runner $path ($common + $s.Args + @{ Apply = $true; ConfirmPlanHash = $hash })
        $log.Add([ordered]@{ Step = $s.Name; Status = 'applied'; Message = '' })
    }
    $since = (Get-Date).ToUniversalTime().AddSeconds(-1)
    $driftArgs = if ($Source -eq 'Repository') { @{ DevToken = $DevToken; Source = 'Repository' } } else { @{ ProdToken = $ProdToken; DevToken = $DevToken } }
    $null = & $Runner (Join-Path $ScriptRoot 'Get-DriftReport.ps1') ($common + $driftArgs)
    $report = & $newest 'drift-*.json' $since
    [pscustomobject]@{ Completed = $true; Steps = [object[]]@($log); Report = $(if ($report) { $report.FullName } else { $null }) }
}
