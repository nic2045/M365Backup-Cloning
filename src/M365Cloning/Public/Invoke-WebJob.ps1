function Get-WebJobDefinition {
    <# The job table of the web interface (Data/WebJobs.json): role, tenants, script, steps per action. #>
    [CmdletBinding()]
    param()
    Get-Content -LiteralPath (Join-Path $script:ModuleRoot 'Data' 'WebJobs.json') -Raw | ConvertFrom-Json -AsHashtable
}

function Invoke-WebJob {
    <#
    .SYNOPSIS
        Runs one job of the web interface in its own process (issue #14, ADR 0012): reads History\jobs\<id>.json,
        runs the matching script and keeps the state, the steps and the result in that file.
    .DESCRIPTION
        The web API only writes the queued job and starts this runner (scripts/Invoke-WebJob.ps1); it never runs a
        script itself. Steps: check the request, sign in to the tenants, run the script, record the result.
        - plan-* and the reports run the script without -Apply: nothing is changed in any tenant. intune-backup reads
          both tenants with IntuneCD and commits the files in the configuration repository (issue #68, ADR 0014).
        - apply: the plan file must exist, its hash must equal the hash the person confirmed in the browser, and for a
          reset plan the hash of the Dev tenant ID the person typed must equal the Dev tenant of the plan and of the
          config (second confirmation). The script then builds the plan again and applies it only if the hash is still
          the same (as on the console). Area, reset mode and device action come from the plan itself. A refused
          request writes an audit line 'refused'.
        - Tokens: Graph tokens from the certificate of each app registration through Az.Accounts (Get-WebJobGraphToken,
          ADR 0013), only for the tenants the action reads; they stay in memory.
        - Actor: the person who started the job is written into every audit line of the run (M365CLONING_ACTOR).
        - Cancel: the API creates History\jobs\<id>.cancel; the runner checks it before each step. A running script
          is not interrupted (an apply half done is worse than one done).
        -TokenProvider and -ScriptRunner replace the sign-in and the script call (tests, no tenant).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JobPath,
        [Parameter(Mandatory)][string]$HistoryRoot,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [scriptblock]$TokenProvider,
        [scriptblock]$ScriptRunner
    )
    $utc = { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $file = Get-Content -LiteralPath $JobPath -Raw | ConvertFrom-Json -AsHashtable
    $job = $file['Job']
    $confirm = if ($file['Confirm']) { $file['Confirm'] } else { @{} }
    $jobDir = Split-Path -Parent $JobPath
    $logPath = Join-Path $jobDir "$($job['id']).log"
    $cancelPath = Join-Path $jobDir "$($job['id']).cancel"
    $defs = Get-WebJobDefinition
    $def = $defs['actions'][[string]$job['action']]

    $log = { param([string]$Text) Add-Content -LiteralPath $logPath -Value ("{0} {1}" -f (& $utc), $Text) -Encoding utf8 }
    $save = {
        $job['updatedUtc'] = & $utc
        $tmp = "$JobPath.tmp"
        ConvertTo-Json -InputObject $file -Depth 10 | Set-Content -LiteralPath $tmp -Encoding utf8
        Move-Item -LiteralPath $tmp -Destination $JobPath -Force
    }
    $setStep = { param([string]$Key, [string]$Status) foreach ($s in $job['steps']) { if ($s['key'] -eq $Key) { $s['status'] = $Status } } }
    $finish = {
        param([string]$Status, [string]$Message)
        foreach ($s in $job['steps']) { if ($s['status'] -in 'pending', 'running') { $s['status'] = if ($Status -eq 'succeeded') { 'done' } elseif ($s['status'] -eq 'running') { 'failed' } else { 'skipped' } } }
        $job['status'] = $Status
        $job['message'] = if ($Message.Length -gt 500) { $Message.Substring(0, 500) } else { $Message }
        $job['finishedUtc'] = & $utc
        & $save
        & $log "job $Status. $Message"
    }

    if ($job['status'] -ne 'queued') { throw "Job $($job['id']) is not queued (status $($job['status']))." }
    if (-not $def) { $job['steps'] = @(); & $finish 'failed' "Unknown action '$($job['action'])'."; return }

    $planFile = $null
    $kindDef = $def
    $options = $job['options']
    if ($job['action'] -eq 'apply') {
        $kindDef = $def['byPlanKind'][[string]$options['planKind']]
    }
    $runTitle = if ($kindDef) { [string]$kindDef['run'] } else { 'Run the script' }
    $job['steps'] = @(foreach ($s in $defs['steps']) { [ordered]@{ key = $s['key']; title = $(if ($s['key'] -eq 'run') { $runTitle } else { $s['title'] }); status = 'pending' } })
    $job['status'] = 'running'
    $job['message'] = ''
    $job['startedUtc'] = & $utc
    & $save
    & $log "job $($job['id']) started: $($job['action'])"
    $started = (Get-Date).ToUniversalTime().AddSeconds(-2)

    $previousActor = $env:M365CLONING_ACTOR
    $env:M365CLONING_ACTOR = [string]$job['actor']
    try {
        $cancelled = { if (Test-Path -LiteralPath $cancelPath) { & $finish 'cancelled' 'Cancelled before this step; nothing more was run.'; $true } else { $false } }

        # --- 1 check
        if (& $cancelled) { return }
        & $setStep 'check' 'running'; & $save
        $config = Import-M365CloningConfig -Path $ConfigPath
        $params = [ordered]@{ ConfigPath = $ConfigPath; HistoryRoot = $HistoryRoot }
        $refuse = {
            param([string]$Why, [string]$Hash = '')
            Write-ApplyAudit -HistoryRoot $HistoryRoot -Mode refused -PlanHash $Hash -TargetTenantId ([string]$config.Dev.TenantId) -Reason "web: $Why"
            & $finish 'failed' "Refused: $Why"
        }
        switch ([string]$job['action']) {
            'drift' { }
            'fitcheck' { $params['TakeProdSnapshot'] = $true }
            'intune-backup' { }
            'plan-apply' { $params['Plan'] = $true; $params['Area'] = if ($options['area']) { [string]$options['area'] } else { 'All' } }
            'plan-baseline' { $params['Plan'] = $true }
            'plan-users' { $params['Plan'] = $true }
            'plan-reset' {
                $params['Plan'] = $true
                $params['Mode'] = if ($options['mode']) { [string]$options['mode'] } else { 'Align' }
                $params['DeviceAction'] = if ($options['deviceAction']) { [string]$options['deviceAction'] } else { 'Keep' }
                if ($params['DeviceAction'] -notin 'Keep', 'Remove', 'Retire') { & $refuse 'the web interface offers only Keep, Remove and Retire for devices'; return }
            }
            'apply' {
                if (-not $kindDef) { & $refuse "unknown plan kind '$($options['planKind'])'"; return }
                $planId = [string]$options['planId']
                if ($planId -notmatch '^[a-z0-9-]{1,100}$') { & $refuse 'the plan id is not valid'; return }
                $planPath = Join-Path $HistoryRoot 'reports' "$planId.json"
                if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) { & $refuse "plan $planId was not found"; return }
                $planFile = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json -AsHashtable
                $hash = [string]$planFile['PlanHash']
                if ([string]$planFile['Kind'] -ne [string]$options['planKind']) { & $refuse "plan $planId is not of kind $($options['planKind'])" $hash; return }
                if (-not $confirm['PlanHash'] -or $confirm['PlanHash'] -ne $hash) { & $refuse 'the confirmed plan hash is not the hash of this plan' $hash; return }
                $plan = $planFile['Plan']
                $params['Apply'] = $true
                $params['ConfirmPlanHash'] = $hash
                switch ([string]$options['planKind']) {
                    'apply' { $params['Area'] = if ($plan.Contains('Area') -and $plan['Area']) { [string]$plan['Area'] } else { 'All' } }
                    'reset' {
                        $devHash = Get-TenantIdHash -TenantId ([string]$config.Dev.TenantId)
                        if (-not $confirm['TenantHash'] -or $confirm['TenantHash'] -ne $devHash -or [string]$plan['TargetTenantHash'] -ne $devHash) {
                            & $refuse 'the typed tenant ID is not the Dev tenant of this plan and of the config' $hash; return
                        }
                        $d = $plan['Summary']['Devices']
                        $chosen = @(foreach ($k in 'Remove', 'Retire', 'Wipe') { if ([int]$d[$k] -gt 0) { $k } })
                        if ($chosen -contains 'Wipe') { & $refuse 'the plan wipes devices; a wipe runs with the script only' $hash; return }
                        if ($chosen.Count -gt 1) { & $refuse 'the plan has different device actions; apply it with the script and the same -DeviceActionFile' $hash; return }
                        $params['Mode'] = [string]$plan['Mode']
                        $params['DeviceAction'] = if ($chosen.Count -eq 1) { $chosen[0] } else { 'Keep' }
                        $params['ConfirmTenant'] = [string]$config.Dev.TenantId
                    }
                }
            }
        }
        & $setStep 'check' 'done'; & $save

        # --- 2 sign in
        if (& $cancelled) { return }
        & $setStep 'signin' 'running'; & $save
        $provider = if ($TokenProvider) { $TokenProvider } else {
            { param($Config, [string]$Side) $t = $Config[$Side]; Get-WebJobGraphToken -TenantId ([string]$t.TenantId) -ClientId ([string]$t.ClientId) -CertThumbprint ([string]$t.CertThumbprint) }
        }
        try {
            foreach ($side in @($kindDef['tenants'])) { $params["${side}Token"] = & $provider $config $side; & $log "signed in to $side" }
        }
        catch { & $finish 'failed' "Sign-in failed: $($_.Exception.Message)"; return }
        & $setStep 'signin' 'done'; & $save

        # --- 3 run
        if (& $cancelled) { return }
        & $setStep 'run' 'running'; & $save
        $script = Join-Path $ScriptRoot ([string]$kindDef['script'])
        & $log "running $([string]$kindDef['script']) $((@($params.Keys | Where-Object { $_ -notlike '*Token' -and $_ -ne 'ConfirmTenant' }) | ForEach-Object { "-$_" }) -join ' ')"
        $runner = if ($ScriptRunner) { $ScriptRunner } else {
            {
                param([string]$Path, [System.Collections.IDictionary]$Parameters, [string]$Log)
                $global:LASTEXITCODE = 0
                $splat = @{} + $Parameters
                & $Path @splat *>&1 | ForEach-Object { Add-Content -LiteralPath $Log -Value ([string]$_) -Encoding utf8 }
                $global:LASTEXITCODE
            }
        }
        try { $exit = [int](& $runner $script $params $logPath | Select-Object -Last 1) }
        catch { & $finish 'failed' "The script stopped: $(($_.Exception.Message -split "`r?`n")[0])"; return }
        $job['result']['exitCode'] = $exit
        $okExit = if ($job['action'] -eq 'fitcheck') { $exit -in 0, 1, 2, 3 } else { $exit -eq 0 }
        & $setStep 'run' $(if ($okExit) { 'done' } else { 'failed' }); & $save

        # --- 4 result
        & $setStep 'result' 'running'; & $save
        if ($job['action'] -ne 'apply') {
            $prefix = [string]$def['resultPrefix']
            if ($job['action'] -eq 'plan-reset') { $prefix += ([string]$params['Mode']).ToLowerInvariant() + '-' }
            $newest = Get-ChildItem -LiteralPath (Join-Path $HistoryRoot 'reports') -Filter "$prefix*.json" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTimeUtc -ge $started } | Sort-Object LastWriteTimeUtc, Name | Select-Object -Last 1
            if ($newest) {
                if ($job['action'] -like 'plan-*') {
                    $job['result']['planId'] = $newest.BaseName
                    $written = Get-Content -LiteralPath $newest.FullName -Raw | ConvertFrom-Json -AsHashtable
                    $job['result']['planHash'] = [string]$written['PlanHash']
                }
                else { $job['result']['reportId'] = $newest.BaseName }
            }
        }
        if (-not $okExit) { & $finish 'failed' "The script ended with exit code $exit. See the log."; return }
        $message = switch -Wildcard ([string]$job['action']) {
            'plan-*' { 'The plan is ready. Nothing was changed; open the plan to check and apply it.' }
            'apply' { 'The plan was applied. Compare again to see the new state.' }
            'intune-backup' { 'The Intune backup is saved in the configuration repository. Open Intune changes to see what changed.' }
            default { 'The report is ready.' }
        }
        & $finish 'succeeded' $message
    }
    catch {
        & $finish 'failed' "The job stopped: $(($_.Exception.Message -split "`r?`n")[0])"
    }
    finally {
        $env:M365CLONING_ACTOR = $previousActor
    }
}
