function Invoke-DevUserPlan {
    <#
    .SYNOPSIS
        Applies a confirmed Dev users plan (New-DevUserPlan) to the Dev tenant with Microsoft Graph (issue #22).
    .DESCRIPTION
        Same gate as Invoke-ApplyPlan (Assert-DevApplyGate): plan hash, Dev.ApplyAllowed, Dev tenant only, every
        refusal in the audit log. Only actions with Status 'planned' run: first CreateUser / InviteGuest, then
        AddMember. Every write goes through Invoke-DevDirectoryWrite (allow list: users, invitations, group
        members; Dev tenant only). Graph is used and not Microsoft365DSC (AADUser), because DSC has no B2B
        invitation and the initial password must not pass through a plan file to a child process.
        Passwords: one random password per new test user (New-InitialPassword), forceChangePasswordNextSignIn,
        sent only in the request body; never stored, never in the result file, report or audit log. With
        -ShowInitialPasswords they are printed once to the console (Write-Host) after the run; without it they are
        discarded and an admin resets the password before the first sign-in.
        -GraphWriter replaces the real write (tests); it gets -Method, -Uri, -Body, -TenantId, -Config and returns
        the Graph response. -RetryDelaySeconds: wait before retrying an AddMember for a user created in this run
        (Graph replication delay, Learn: "Add members").
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ConfirmPlanHash,
        [securestring]$Token,
        [scriptblock]$GraphWriter,
        [switch]$ShowInitialPasswords,
        [ValidateRange(0, 60)][int]$RetryDelaySeconds = 5,
        [string]$HistoryRoot = (Join-Path (Get-Location) 'History'),
        [string]$GraphRoot = 'https://graph.microsoft.com/v1.0'
    )

    $hash = Assert-DevApplyGate -Plan $Plan -Config $Config -ConfirmPlanHash $ConfirmPlanHash -HistoryRoot $HistoryRoot
    $target = [string]$Plan['TargetTenant']
    $devId = [string]$Config['Dev']['TenantId']
    if (-not $GraphWriter -and -not $Token) { throw 'Pass -Token (Dev app registration, app-only).' }
    $writer = if ($GraphWriter) { $GraphWriter } else {
        { param($Method, $Uri, $Body, $TenantId, $Config) Invoke-DevDirectoryWrite -Method $Method -Uri $Uri -Body $Body -TenantId $TenantId -Config $Config -Token $Token }
    }
    $write = {
        param([string]$Uri, [System.Collections.IDictionary]$Body)
        # The allow list is checked here as well, so a test writer cannot be reached with another path either.
        Assert-DevDirectoryWriteAllowed -Uri $Uri -TenantId $devId -Config $Config
        & $writer -Method POST -Uri $Uri -Body $Body -TenantId $devId -Config $Config
    }

    $planned = @($Plan['Actions'] | Where-Object { $_['Status'] -eq 'planned' })
    $results = [System.Collections.Generic.List[object]]::new()
    $created = @{}       # UserRef -> object id of accounts created or invited in this run
    $passwords = [ordered]@{}
    foreach ($a in @($planned | Where-Object { $_['Operation'] -in 'CreateUser', 'InviteGuest' })) {
        $name = [string]$a['Name']
        try {
            if ($a['Operation'] -eq 'CreateUser') {
                $body = [ordered]@{}
                foreach ($k in $a['Properties'].Keys) { $body[$k] = $a['Properties'][$k] }
                $pw = New-InitialPassword
                $body['passwordProfile'] = [ordered]@{ forceChangePasswordNextSignIn = $true; password = $pw }
                $r = & $write "$GraphRoot/users" $body
                $created[$name] = [string]$r.id
                if ($ShowInitialPasswords) { $passwords[$name] = $pw }
                $pw = $null; $body = $null
            }
            else {
                $r = & $write "$GraphRoot/invitations" $a['Properties']
                $created[$name] = [string]$r.invitedUser.id
            }
            $results.Add([ordered]@{ Name = $name; Operation = [string]$a['Operation']; Status = 'applied'; Message = '' })
        }
        catch {
            $results.Add([ordered]@{ Name = $name; Operation = [string]$a['Operation']; Status = 'failed'; Message = (Get-SafeErrorMessage $_) })
        }
    }
    foreach ($a in @($planned | Where-Object { $_['Operation'] -eq 'AddMember' })) {
        $p = $a['Properties']; $name = [string]$a['Name']
        $memberId = if (-not [string]::IsNullOrWhiteSpace([string]$p['MemberId'])) { [string]$p['MemberId'] } else { [string]$created[[string]$p['UserRef']] }
        if ([string]::IsNullOrWhiteSpace($memberId)) {
            $results.Add([ordered]@{ Name = $name; Operation = 'AddMember'; Status = 'failed'; Message = 'the account was not created in this run' })
            continue
        }
        $uri = "$GraphRoot/groups/$([string]$p['GroupId'])/members/`$ref"
        $body = [ordered]@{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$memberId" }
        $tries = if ($created.ContainsKey([string]$p['UserRef'])) { 3 } else { 1 }
        for ($i = 1; $i -le $tries; $i++) {
            try {
                $null = & $write $uri $body
                $results.Add([ordered]@{ Name = $name; Operation = 'AddMember'; Status = 'applied'; Message = '' })
                break
            }
            catch {
                if ($i -lt $tries) { Start-Sleep -Seconds $RetryDelaySeconds; continue }
                $results.Add([ordered]@{ Name = $name; Operation = 'AddMember'; Status = 'failed'; Message = (Get-SafeErrorMessage $_) })
            }
        }
    }

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $dir = Join-Path (Join-Path $HistoryRoot 'apply') "dev-users-$stamp"
    $null = New-Item -ItemType Directory -Path $dir -Force
    ConvertTo-Json -InputObject ([object[]]@($results)) -Depth 5 | Set-Content -LiteralPath (Join-Path $dir 'result.json') -Encoding utf8

    $failed = @($results | Where-Object { $_['Status'] -eq 'failed' }).Count
    $applied = @($results | Where-Object { $_['Status'] -eq 'applied' }).Count
    $counts = @{ Planned = $planned.Count; Applied = $applied; Failed = $failed; Blocked = [int]$Plan['Summary']['Blocked'] }
    Write-ApplyAudit -HistoryRoot $HistoryRoot -Mode apply -PlanHash $hash -TargetTenantId $target -Counts $counts -Reason $(if ($failed -gt 0) { 'dev users: finished with failures' } else { 'dev users: finished' })

    if ($ShowInitialPasswords -and $passwords.Count -gt 0) {
        Write-Host 'Initial passwords (shown once, not stored; change at first sign-in):'
        foreach ($k in $passwords.Keys) { Write-Host "  $k  $($passwords[$k])" }
    }
    $passwords = $null
    [pscustomobject]@{ PlanHash = $hash; Applied = $applied; Failed = $failed; Results = [object[]]@($results) }
}

function Get-SafeErrorMessage {
    # Error text for the result file: first line, at most 300 characters. The request body (and with it a password)
    # is never part of an Invoke-RestMethod error message; the response text is.
    param($ErrorRecord)
    $m = ([string]$ErrorRecord.Exception.Message -split "`n")[0]
    if ($m.Length -gt 300) { $m.Substring(0, 300) } else { $m }
}
