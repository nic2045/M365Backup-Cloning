function Invoke-SetupCheck {
    <#
    .SYNOPSIS
        Setup check of this instance (issue #18): is everything in place that the toolkit needs? Read only.
    .DESCRIPTION
        Checks, each green, yellow, red or grey (not checked) with what to do:
        - Config: config.psd1 readable, Prod/Dev pair set and different, apply and reset gates.
        - Certificates: the certificate of each app registration is in the store of this computer (current user or
          local machine), has its private key and is valid (yellow within CertificateWarnDays). Windows only; grey
          elsewhere.
        - Sign-in and permissions (Scope All): sign-in of each app registration with its certificate, then the
          application permissions of its token compared with Data/SetupRequirements.psd1 (required = red, features =
          yellow). Prod with a write permission is red (ADR 0001).
        - UTCM: the Tenant Configuration Management and the M365 Admin Services service principal in each tenant
          and the number of application permissions granted to the TCM principal (needs Application.Read.All, grey
          without).
        - Break-glass: the list in the config (offline); with Scope All each account and group is looked up in Dev.
        - Licences: the newest suitability check (tenantfit-*.json) is reused, not run again.
        Nothing is created, granted, changed or written to a tenant: only GET requests (Invoke-UtcmGraphRequest) and
        the result file History/reports/setup-check-<yyyyMMdd-HHmmss>.json. The file has no tenant ID, client ID,
        thumbprint or account name: break-glass entries are named by their position in the list.
        -Scope Config: no sign-in, no request (config, certificates, break-glass list, licences only).
        -TokenProvider, -CertificateProvider and -Now replace the sign-in, the certificate store and the clock (tests).
    .OUTPUTS
        The result (ordered hashtable) and the path of the file in .Path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$HistoryRoot,
        [ValidateSet('All', 'Config')][string]$Scope = 'All',
        [scriptblock]$TokenProvider,
        [scriptblock]$CertificateProvider,
        [datetime]$Now = (Get-Date).ToUniversalTime()
    )
    $req = Import-PowerShellDataFile -LiteralPath (Join-Path $script:ModuleRoot 'Data' 'SetupRequirements.psd1')
    $checks = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([string]$Id, [string]$Group, [string]$Tenant, [string]$Status, [string]$Title, [string]$Detail, [string]$Hint, [string]$ReportId = '')
        $c = [ordered]@{ Id = $Id; Group = $Group; Tenant = $Tenant; Status = $Status; Title = $Title; Detail = $Detail; Hint = $Hint }
        if ($ReportId) { $c['ReportId'] = $ReportId }
        $checks.Add($c)
    }
    $firstLine = { param($Err) (([string]$Err.Exception.Message) -split "`r?`n")[0] }
    $httpStatus = {
        param($Err)
        $code = 0
        try { if ($Err.Exception.Response) { $code = [int]$Err.Exception.Response.StatusCode } } catch { $code = 0 }
        if ($code) { return $code }
        $m = [string]$Err.Exception.Message
        if ($m -match '\b403\b|Forbidden|Authorization_RequestDenied') { return 403 }
        if ($m -match '\b404\b|NotFound|Request_ResourceNotFound') { return 404 }
        0
    }
    $sides = 'Prod', 'Dev'

    # --- config
    $config = $null
    try {
        $config = Import-M365CloningConfig -Path $ConfigPath
        & $add 'config-readable' 'Config' '' 'green' 'The config is readable' 'config.psd1 was read and has a valid Prod/Dev pair.' ''
    }
    catch {
        & $add 'config-readable' 'Config' '' 'red' 'The config cannot be used' (& $firstLine $_) 'Copy config.example.psd1 to config.psd1 next to the toolkit and fill in your Prod and Dev tenant. The config stays on this computer.'
    }
    if ($null -eq $config) {
        foreach ($g in 'Certificates', 'Permissions', 'UTCM', 'BreakGlass') {
            & $add "$($g.ToLowerInvariant())-skipped" $g '' 'grey' 'Not checked' 'The config is not readable.' 'Fix the config first, then run the check again.'
        }
    }
    else {
        $gate = { param([string]$Key) if ($config.Dev.ContainsKey($Key) -and $config.Dev[$Key] -eq $true) { 'yes' } else { 'no' } }
        & $add 'config-tenants' 'Config' '' 'green' 'Prod and Dev are set' ("Prod is only read; every write goes to the Dev tenant of the config. Apply allowed: {0}. Reset allowed: {1}." -f (& $gate 'ApplyAllowed'), (& $gate 'AllowReset')) $(if ((& $gate 'ApplyAllowed') -eq 'no' -or (& $gate 'AllowReset') -eq 'no') { 'To apply or reset from the web interface, set Dev.ApplyAllowed and Dev.AllowReset to $true in config.psd1.' } else { '' })

        # --- certificates
        $certProvider = if ($CertificateProvider) { $CertificateProvider } else {
            {
                param([string]$Thumbprint)
                if (-not $IsWindows) { return @{ Supported = $false } }
                foreach ($store in 'Cert:\CurrentUser\My', 'Cert:\LocalMachine\My') {
                    $c = Get-Item -LiteralPath (Join-Path $store $Thumbprint) -ErrorAction SilentlyContinue
                    if ($c) { return @{ Supported = $true; Found = $true; HasPrivateKey = [bool]$c.HasPrivateKey; NotAfter = $c.NotAfter.ToUniversalTime(); Store = $store } }
                }
                @{ Supported = $true; Found = $false }
            }
        }
        foreach ($side in $sides) {
            $cert = & $certProvider ([string]$config[$side].CertThumbprint)
            if (-not $cert -or -not $cert.Supported) {
                & $add "certificate-$($side.ToLowerInvariant())" 'Certificates' $side 'grey' 'Certificate not checked' 'The certificate store can only be read on Windows.' 'Run the setup check on the Windows computer that runs the jobs.'
                continue
            }
            if (-not $cert.Found) {
                & $add "certificate-$($side.ToLowerInvariant())" 'Certificates' $side 'red' 'Certificate not found' "No certificate with the thumbprint of $side.CertThumbprint is in the store of the current user or of the computer." "Import the certificate of the $side app registration with its private key, or correct $side.CertThumbprint."
                continue
            }
            $days = [int][math]::Floor(([datetime]$cert.NotAfter - $Now).TotalDays)
            $until = ([datetime]$cert.NotAfter).ToString('yyyy-MM-dd')
            if (-not $cert.HasPrivateKey) {
                & $add "certificate-$($side.ToLowerInvariant())" 'Certificates' $side 'red' 'Certificate without private key' "The certificate is in the store but without its private key, so it cannot sign in." 'Import the certificate again as .pfx with its private key.'
            }
            elseif ($days -lt 0) {
                & $add "certificate-$($side.ToLowerInvariant())" 'Certificates' $side 'red' 'Certificate expired' "The certificate expired on $until." "Create a new certificate, upload it to the $side app registration and put its thumbprint into $side.CertThumbprint."
            }
            elseif ($days -lt [int]$req.CertificateWarnDays) {
                & $add "certificate-$($side.ToLowerInvariant())" 'Certificates' $side 'yellow' 'Certificate expires soon' "The certificate is valid until $until ($days days)." "Renew it before $until and put the new thumbprint into $side.CertThumbprint."
            }
            else {
                & $add "certificate-$($side.ToLowerInvariant())" 'Certificates' $side 'green' 'Certificate valid' "Valid until $until, with private key." ''
            }
        }

        # --- sign-in, permissions, UTCM, break-glass in Dev
        $bg = @(@($config['BreakGlass']) | Where-Object { $_ })
        $bgGroups = @(@($config['BreakGlassGroups']) | Where-Object { $_ })
        $protected = @(@($config['ProtectedAccounts']) | Where-Object { $_ })
        if ($bg.Count -eq 0 -and $protected.Count -eq 0) {
            & $add 'breakglass-list' 'BreakGlass' '' 'red' 'No break-glass or protected accounts' 'BreakGlass and ProtectedAccounts are both empty: the reset refuses to run and no Conditional Access policy is applied.' 'List your break-glass accounts in BreakGlass (and BreakGlassGroups) in config.psd1.'
        }
        elseif ($bg.Count -eq 0) {
            & $add 'breakglass-list' 'BreakGlass' '' 'yellow' 'No break-glass accounts' 'BreakGlass is empty: no Conditional Access policy is applied to Dev.' 'List your break-glass accounts in BreakGlass in config.psd1.'
        }
        else {
            & $add 'breakglass-list' 'BreakGlass' '' 'green' 'Break-glass accounts listed' ("{0} account(s), {1} group(s) and {2} protected account(s) in the config." -f $bg.Count, $bgGroups.Count, $protected.Count) ''
        }

        if ($Scope -eq 'Config') {
            foreach ($g in 'Permissions', 'UTCM') {
                & $add "$($g.ToLowerInvariant())-skipped" $g '' 'grey' 'Not checked' 'The check ran for the config only (no sign-in).' 'Run the full check to sign in to both tenants.'
            }
        }
        else {
            $provider = if ($TokenProvider) { $TokenProvider } else {
                { param($Config, [string]$Side) $t = $Config[$Side]; Get-WebJobGraphToken -TenantId ([string]$t.TenantId) -ClientId ([string]$t.ClientId) -CertThumbprint ([string]$t.CertThumbprint) }
            }
            $tokens = @{}
            foreach ($side in $sides) {
                $id = $side.ToLowerInvariant()
                try { $tokens[$side] = & $provider $config $side }
                catch {
                    & $add "signin-$id" 'Permissions' $side 'red' 'Sign-in failed' (& $firstLine $_) "Check $side.ClientId, the certificate and that the certificate is uploaded to the $side app registration. Install Az.Accounts if it is missing."
                    & $add "permissions-$id" 'Permissions' $side 'grey' 'Permissions not checked' 'The sign-in failed.' 'Fix the sign-in first.'
                    & $add "utcm-$id" 'UTCM' $side 'grey' 'UTCM not checked' 'The sign-in failed.' 'Fix the sign-in first.'
                    continue
                }
                & $add "signin-$id" 'Permissions' $side 'green' 'Sign-in works' 'The app registration signed in with its certificate.' ''

                # permissions from the token
                $roles = @()
                try { $roles = @(Get-TokenAppRole -Token $tokens[$side]) }
                catch { $roles = $null }
                if ($null -eq $roles) {
                    & $add "permissions-$id" 'Permissions' $side 'grey' 'Permissions not read' 'The token could not be read.' 'Check the permissions in the Entra admin center: App registrations > API permissions.'
                }
                else {
                    $missing = @(foreach ($r in $req[$side].Required) { if ($roles -notcontains $r.Permission) { "$($r.Permission) ($($r.For))" } })
                    $features = @(foreach ($r in $req[$side].Features) { if ($roles -notcontains $r.Permission) { "$($r.Permission) ($($r.For))" } })
                    $writes = @()
                    if ($side -eq 'Prod') {
                        $writes = @($roles | Where-Object { $_ -match 'ReadWrite|\.Write|Invite|\.Create|PrivilegedOperations|\.Send' -and $req.Prod.AllowedWrite -notcontains $_ })
                    }
                    $status = if ($writes.Count -or $missing.Count) { 'red' } elseif ($features.Count) { 'yellow' } else { 'green' }
                    $parts = @("$($roles.Count) application permission(s) granted.")
                    if ($writes.Count) { $parts += "Write permissions on Prod: $($writes -join ', ')." }
                    if ($missing.Count) { $parts += "Missing (needed): $($missing -join '; ')." }
                    if ($features.Count) { $parts += "Missing for features: $($features -join '; ')." }
                    $hint = if ($writes.Count) { 'Remove the write permissions from the Prod app registration: Prod is only read.' }
                        elseif ($missing.Count -or $features.Count) { "Add the missing application permissions to the $side app registration and grant admin consent. Features you do not use can stay without." }
                        else { '' }
                    $title = switch ($status) { 'red' { 'Permissions need a change' } 'yellow' { 'Permissions for some features missing' } default { 'Permissions complete' } }
                    & $add "permissions-$id" 'Permissions' $side $status $title ($parts -join ' ') $hint
                }

                # UTCM service principal
                $spOf = {
                    param([string]$AppId)
                    $u = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$AppId'&`$select=id,accountEnabled"
                    @((Invoke-UtcmGraphRequest -Method GET -Uri $u -Token $tokens[$side]).value)
                }
                try {
                    $utcm = @(& $spOf $req.UtcmAppId)
                    $admin = @(& $spOf $req.AdminServicesAppId)
                    if ($utcm.Count -eq 0) {
                        & $add "utcm-$id" 'UTCM' $side 'red' 'UTCM service principal missing' 'The Tenant Configuration Management service principal is not in this tenant, so no snapshot can run.' 'Add it as described on Microsoft Learn: Set up authentication for Tenant Configuration Management APIs.'
                    }
                    elseif ($utcm[0].accountEnabled -eq $false) {
                        & $add "utcm-$id" 'UTCM' $side 'red' 'UTCM service principal disabled' 'The Tenant Configuration Management service principal is disabled.' 'Enable it in the Entra admin center: Enterprise applications.'
                    }
                    else {
                        $granted = @((Invoke-UtcmGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($utcm[0].id)/appRoleAssignments?`$select=appRoleId" -Token $tokens[$side]).value).Count
                        $status = if ($granted -eq 0 -or $admin.Count -eq 0) { 'yellow' } else { 'green' }
                        $detail = "Present and enabled; $granted application permission(s) granted to it."
                        if ($admin.Count -eq 0) { $detail += ' The M365 Admin Services service principal is missing.' }
                        $hint = if ($granted -eq 0) { 'Grant the UTCM service principal the read permissions of the resource types you copy (Microsoft Learn: Supported Entra / Intune resources).' }
                            elseif ($admin.Count -eq 0) { 'Provision the M365 Admin Services service principal as Microsoft Learn describes.' } else { '' }
                        & $add "utcm-$id" 'UTCM' $side $status $(if ($status -eq 'green') { 'UTCM ready' } else { 'UTCM partly ready' }) $detail $hint
                    }
                }
                catch {
                    if ((& $httpStatus $_) -eq 403) {
                        & $add "utcm-$id" 'UTCM' $side 'grey' 'UTCM not checked' 'The app registration may not read service principals.' "Grant Application.Read.All to the $side app registration, or check the service principal in the Entra admin center: Enterprise applications."
                    }
                    else {
                        & $add "utcm-$id" 'UTCM' $side 'grey' 'UTCM not checked' (& $firstLine $_) 'Run the check again later.'
                    }
                }
            }

            # break-glass accounts and groups in Dev
            if ($tokens.ContainsKey('Dev') -and ($bg.Count -or $bgGroups.Count)) {
                $notFound = [System.Collections.Generic.List[string]]::new()
                $disabled = [System.Collections.Generic.List[string]]::new()
                $groupsMissing = [System.Collections.Generic.List[string]]::new()
                $denied = $false
                try {
                    for ($i = 0; $i -lt $bg.Count; $i++) {
                        try {
                            $u = Invoke-UtcmGraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/users/{0}?`$select=id,accountEnabled" -f [uri]::EscapeDataString([string]$bg[$i])) -Token $tokens['Dev']
                            if ($u.accountEnabled -eq $false) { $disabled.Add("BreakGlass entry $($i + 1)") }
                        }
                        catch {
                            if ((& $httpStatus $_) -eq 404) { $notFound.Add("BreakGlass entry $($i + 1)") } else { throw }
                        }
                    }
                    for ($i = 0; $i -lt $bgGroups.Count; $i++) {
                        $name = ([string]$bgGroups[$i]).Replace("'", "''")
                        $g = Invoke-UtcmGraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/groups?`$filter={0}&`$select=id" -f [uri]::EscapeDataString("displayName eq '$name'")) -Token $tokens['Dev']
                        if (@($g.value).Count -eq 0) { $groupsMissing.Add("BreakGlassGroups entry $($i + 1)") }
                    }
                }
                catch {
                    $denied = $true
                    $why = if ((& $httpStatus $_) -eq 403) { 'The Dev app registration may not read users or groups (User.Read.All, Group.Read.All).' } else { & $firstLine $_ }
                    & $add 'breakglass-dev' 'BreakGlass' 'Dev' 'grey' 'Break-glass accounts not looked up' $why 'Grant User.Read.All and Group.Read.All to the Dev app registration, or check the accounts in the Entra admin center.'
                }
                if (-not $denied) {
                    if ($notFound.Count -or $disabled.Count) {
                        $detail = @()
                        if ($notFound.Count) { $detail += "Not found in Dev: $($notFound -join ', ')." }
                        if ($disabled.Count) { $detail += "Disabled in Dev: $($disabled -join ', ')." }
                        & $add 'breakglass-dev' 'BreakGlass' 'Dev' 'red' 'Break-glass accounts not usable in Dev' ($detail -join ' ') 'Create or enable the break-glass accounts in Dev, or correct the list in config.psd1. Without them you can lock yourself out of Dev.'
                    }
                    elseif ($groupsMissing.Count) {
                        & $add 'breakglass-dev' 'BreakGlass' 'Dev' 'yellow' 'Break-glass groups missing in Dev' "Not found in Dev: $($groupsMissing -join ', ')." 'Apply the base state (Fill Dev): it creates the break-glass groups static and empty.'
                    }
                    else {
                        & $add 'breakglass-dev' 'BreakGlass' 'Dev' 'green' 'Break-glass accounts found in Dev' ("{0} account(s) found and enabled, {1} group(s) found." -f $bg.Count, $bgGroups.Count) ''
                    }
                }
            }
        }
    }

    # --- licences: the newest suitability check, reused
    $reports = Join-Path $HistoryRoot 'reports'
    $fit = Get-ChildItem -LiteralPath $reports -Filter 'tenantfit-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if (-not $fit) {
        & $add 'licences' 'Licences' '' 'grey' 'No suitability check yet' 'The licences of Prod and Dev have not been compared.' 'Run the suitability check (Bring Dev in line).'
    }
    else {
        try {
            $content = Get-Content -LiteralPath $fit.FullName -Raw | ConvertFrom-Json -AsHashtable
            $created = ([datetime]$content['CreatedUtc']).ToUniversalTime()
            $age = [int][math]::Floor(($Now - $created).TotalDays)
            $fitStatus = [string]$content['Status']
            $verdict = [string]$content['Verdict']
            if ($age -gt [int]$req.LicenceStaleDays) {
                & $add 'licences' 'Licences' '' 'yellow' 'Suitability check is old' "The last check is $age days old ($fitStatus): $verdict" 'Run the suitability check again (Bring Dev in line).' $fit.BaseName
            }
            else {
                $hint = switch ($fitStatus) { 'green' { '' } 'yellow' { 'Open the report: some features of Prod cannot be mirrored fully.' } 'red' { 'Open the report: Dev cannot mirror Prod; an equivalent tenant may be needed.' } default { 'Open the report: a licence list could not be read.' } }
                & $add 'licences' 'Licences' '' $fitStatus "Suitability: $fitStatus" $verdict $hint $fit.BaseName
            }
        }
        catch {
            & $add 'licences' 'Licences' '' 'grey' 'Suitability check not readable' (& $firstLine $_) 'Run the suitability check again.' $fit.BaseName
        }
    }

    $count = { param([string]$S) @($checks | Where-Object { $_.Status -eq $S }).Count }
    $summary = [ordered]@{ Green = & $count 'green'; Yellow = & $count 'yellow'; Red = & $count 'red'; Grey = & $count 'grey' }
    $overall = if ($summary.Red) { 'red' } elseif ($summary.Yellow) { 'yellow' } elseif ($summary.Grey) { 'grey' } else { 'green' }
    $result = [ordered]@{
        SchemaVersion = $script:M365CloningSchemaVersion
        Kind          = 'setupcheck'
        CreatedUtc    = $Now.ToString('yyyy-MM-ddTHH:mm:ssZ')
        Scope         = $Scope
        Status        = $overall
        Summary       = $summary
        Checks        = [object[]]$checks.ToArray()
    }
    $null = New-Item -ItemType Directory -Path $reports -Force
    $path = Join-Path $reports ("setup-check-{0}.json" -f $Now.ToString('yyyyMMdd-HHmmss'))
    ConvertTo-Json -InputObject $result -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
    # One audit line (issue #76): the colour and the count per colour only - no tenant, no IDs, no names.
    Write-ApplyAudit -HistoryRoot $HistoryRoot -Mode setupcheck -Reason "setup check ($Scope): $overall" -Counts ([ordered]@{
            Red = [int]$summary.Red; Yellow = [int]$summary.Yellow; Green = [int]$summary.Green; Grey = [int]$summary.Grey
        })
    $result['Path'] = $path
    $result
}
