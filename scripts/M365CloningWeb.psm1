# Starts the web app of the toolkit (API + interface) on this machine with one command (issue #79).
# Used by scripts/Start-M365CloningWeb.ps1. Kept as a module so the steps can be tested with Pester (tests/StartWeb.Tests.ps1).
#
# - Settings come from web.settings.psd1 (git-ignored; template web.settings.example.psd1) and are given only to the two
#   child processes as environment variables, never to this session and never printed.
# - The shared token secret of interface and API is made once and kept in web.local/token.secret (git-ignored, readable
#   only by the current user).
# - Both apps listen on 127.0.0.1 only. The local account is a break-glass account: role Reader only (ADR 0016).

Set-StrictMode -Version Latest

$script:PythonVersion = '3.12'   # the lock files (requirements.txt) are compiled for this version
$script:GuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$script:LocalRoles = @('Reader')  # break-glass account: management only (issue #79, ADR 0016)

function Get-M365WebRoot {
    [CmdletBinding()] param ()
    Split-Path -Parent $PSScriptRoot
}

function Get-M365WebPaths {
    [CmdletBinding()] param ([Parameter(Mandatory)][string]$Root)
    $local = Join-Path $Root 'web.local'
    [pscustomobject]@{
        Root        = $Root
        Settings    = Join-Path $Root 'web.settings.psd1'
        Example     = Join-Path $Root 'web.settings.example.psd1'
        Local       = $local
        TokenSecret = Join-Path $local 'token.secret'
        ApiDir      = Join-Path $Root 'web/api'
        UiDir       = Join-Path $Root 'web/ui'
        ApiVenv     = Join-Path $local 'venv-api'
        UiVenv      = Join-Path $local 'venv-ui'
    }
}

function New-M365WebProblem {
    param ([string]$Field, [string]$Problem, [string]$Fix)
    [pscustomobject]@{ Field = $Field; Problem = $Problem; Fix = $Fix }
}

function Read-M365WebSettings {
    <# The settings as a hashtable; throws with a clear message when the file is missing or cannot be read. #>
    [CmdletBinding()] param ([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "No settings file: $Path. Copy web.settings.example.psd1 to web.settings.psd1 and fill it in (docs/getting-started.md)."
    }
    try { Import-PowerShellDataFile -LiteralPath $Path }
    catch { throw "The settings file cannot be read ($Path): $($_.Exception.Message.Split([Environment]::NewLine)[0])" }
}

function Get-M365WebSection {
    param ($Settings, [string]$Name)
    if ($Settings -is [hashtable] -and $Settings.ContainsKey($Name) -and $Settings[$Name] -is [hashtable]) { return $Settings[$Name] }
    @{}
}

function Get-M365WebValue {
    param ([hashtable]$Section, [string]$Name, $Default = '')
    if ($Section.ContainsKey($Name) -and $null -ne $Section[$Name]) { return $Section[$Name] }
    $Default
}

function Test-M365WebEntraConfigured {
    param ([hashtable]$Settings)
    $e = Get-M365WebSection $Settings 'Entra'
    [bool]((Get-M365WebValue $e 'TenantId') -and (Get-M365WebValue $e 'ApiClientId') -and (Get-M365WebValue $e 'UiClientId'))
}

function Test-M365WebSettings {
    <#
    .SYNOPSIS
    Checks the settings. Returns one object per problem (Field, Problem, Fix); no output means the settings are usable.
    Never puts a value of a secret into the text.
    #>
    [CmdletBinding()] param ([Parameter(Mandatory)][hashtable]$Settings)
    $out = [System.Collections.Generic.List[object]]::new()
    $entra = Get-M365WebSection $Settings 'Entra'
    $local = Get-M365WebSection $Settings 'LocalAccount'
    $ports = Get-M365WebSection $Settings 'Ports'

    $entraValues = 'TenantId', 'ApiClientId', 'UiClientId' | ForEach-Object { [string](Get-M365WebValue $entra $_) }
    $entraAny = [bool]($entraValues | Where-Object { $_ })
    $entraAll = -not ($entraValues | Where-Object { -not $_ })
    $localOn = [bool](Get-M365WebValue $local 'Enabled' $false)

    if (-not $entraAny -and -not $localOn) {
        $out.Add((New-M365WebProblem 'Entra' 'No sign-in is set up: the app would stay closed.' `
            'Fill in Entra.TenantId, Entra.ApiClientId and Entra.UiClientId (docs/getting-started.md, step 2). For management only you can switch on LocalAccount.'))
    }
    if ($entraAny -and -not $entraAll) {
        foreach ($k in 'TenantId', 'ApiClientId', 'UiClientId') {
            if (-not (Get-M365WebValue $entra $k)) {
                $out.Add((New-M365WebProblem "Entra.$k" 'is empty while other Entra values are set.' 'Fill it in from the app registration (docs/getting-started.md, step 2).'))
            }
        }
    }
    foreach ($k in 'TenantId', 'ApiClientId', 'UiClientId') {
        $v = [string](Get-M365WebValue $entra $k)
        if ($v -and $v -notmatch $script:GuidPattern) {
            $out.Add((New-M365WebProblem "Entra.$k" 'is not an ID in the form 00000000-0000-0000-0000-000000000000.' 'Copy the ID from the Overview page of the app registration.'))
        }
    }

    $backendPort = Get-M365WebValue $ports 'Api' 8000
    $frontendPort = Get-M365WebValue $ports 'Ui' 8080
    foreach ($p in @(@('Ports.Api', $backendPort), @('Ports.Ui', $frontendPort))) {
        if (-not ($p[1] -is [int]) -or $p[1] -lt 1024 -or $p[1] -gt 65535) {
            $out.Add((New-M365WebProblem $p[0] 'must be a whole number from 1024 to 65535.' 'Use the default (Api 8000, Ui 8080) or another free port.'))
        }
    }
    if ($backendPort -eq $frontendPort) {
        $out.Add((New-M365WebProblem 'Ports' 'Api and Ui use the same port.' 'Give each app its own port.'))
    }

    if ($entraAll) {
        $redirect = [string](Get-M365WebValue $entra 'RedirectUri' "http://localhost:$frontendPort/auth/callback")
        if ($redirect -notmatch '^(http://localhost(:\d+)?|https://[^/]+)/auth/callback$') {
            $out.Add((New-M365WebProblem 'Entra.RedirectUri' 'must be http://localhost:<port>/auth/callback (or https://<host>/auth/callback).' 'Use the same address as in the app registration of the interface.'))
        } elseif ($redirect -match '^http://localhost:(\d+)/' -and [int]$Matches[1] -ne $frontendPort) {
            $out.Add((New-M365WebProblem 'Entra.RedirectUri' "uses port $($Matches[1]), the interface runs on $frontendPort." 'Make the port in RedirectUri and Ports.Ui the same, here and in the app registration.'))
        }
    }

    if ($localOn) {
        $role = [string](Get-M365WebValue $local 'Role' 'Reader')
        if ($role -notin $script:LocalRoles) {
            $out.Add((New-M365WebProblem 'LocalAccount.Role' "'$role' is refused: the local account is a break-glass account for management only and gets at most the role Reader (ADR 0016)." `
                "Set Role = 'Reader'. Reports, apply and reset need a sign-in with Entra ID."))
        }
        if (-not (Get-M365WebValue $local 'User')) {
            $out.Add((New-M365WebProblem 'LocalAccount.User' 'is empty.' "Choose a user name, for example 'breakglass'."))
        }
        $hash = [string](Get-M365WebValue $local 'PasswordHash')
        if (-not $hash) {
            $out.Add((New-M365WebProblem 'LocalAccount.PasswordHash' 'is empty.' 'Run scripts/Start-M365CloningWeb.ps1 -SetLocalPassword; it asks for the password once and stores only the hash.'))
        } elseif ($hash -notmatch '^scrypt\$') {
            $out.Add((New-M365WebProblem 'LocalAccount.PasswordHash' 'is not a hash made by the toolkit.' 'Run scripts/Start-M365CloningWeb.ps1 -SetLocalPassword.'))
        }
    }

    $history = [string](Get-M365WebValue $Settings 'History')
    if ($history -and -not (Test-Path -LiteralPath $history -PathType Container)) {
        $out.Add((New-M365WebProblem 'History' 'is not a folder that exists.' 'Leave it empty for History\ next to the toolkit, or create the folder.'))
    }
    $config = [string](Get-M365WebValue $Settings 'ConfigPath')
    if ($config -and -not (Test-Path -LiteralPath $config -PathType Leaf)) {
        $out.Add((New-M365WebProblem 'ConfigPath' 'is not a file that exists.' 'Leave it empty for config.psd1 next to the toolkit, or give the full path.'))
    }
    $out
}

function ConvertTo-M365WebEnvironment {
    <#
    .SYNOPSIS
    The environment variables of the two child processes: @{ Api = @{...}; Ui = @{...} }. Both listen on 127.0.0.1 only.
    #>
    [CmdletBinding()] param ([Parameter(Mandatory)][hashtable]$Settings, [Parameter(Mandatory)][string]$TokenSecret)
    $entra = Get-M365WebSection $Settings 'Entra'
    $local = Get-M365WebSection $Settings 'LocalAccount'
    $ports = Get-M365WebSection $Settings 'Ports'
    $backendPort = [int](Get-M365WebValue $ports 'Api' 8000)
    $frontendPort = [int](Get-M365WebValue $ports 'Ui' 8080)

    $api = [ordered]@{
        M365CLONING_API_HOST           = '127.0.0.1'
        M365CLONING_API_PORT           = "$backendPort"
        M365CLONING_LOCAL_TOKEN_SECRET = $TokenSecret
    }
    $ui = [ordered]@{
        M365_UI_API_BASE               = "http://127.0.0.1:$backendPort"
        M365CLONING_LOCAL_TOKEN_SECRET = $TokenSecret
    }
    if (Test-M365WebEntraConfigured $Settings) {
        $apiId = [string]$entra.ApiClientId
        $api.M365CLONING_AUTH_TENANT_ID = [string]$entra.TenantId
        $api.M365CLONING_AUTH_AUDIENCE = "$apiId,api://$apiId"
        $ui.M365_UI_OIDC_TENANT_ID = [string]$entra.TenantId
        $ui.M365_UI_OIDC_CLIENT_ID = [string]$entra.UiClientId
        $ui.M365_UI_OIDC_API_SCOPE = [string](Get-M365WebValue $entra 'ApiScope' "api://$apiId/access_as_user")
        $ui.M365_UI_OIDC_REDIRECT_URI = [string](Get-M365WebValue $entra 'RedirectUri' "http://localhost:$frontendPort/auth/callback")
    }
    if ([bool](Get-M365WebValue $local 'Enabled' $false)) {
        $ui.M365_UI_LOCAL_LOGIN = '1'
        $ui.M365_UI_LOCAL_USER = [string]$local.User
        $ui.M365_UI_LOCAL_PASSWORD_HASH = [string]$local.PasswordHash
        $ui.M365_UI_LOCAL_ROLE = 'Reader'
    }
    $history = [string](Get-M365WebValue $Settings 'History')
    if ($history) { $api.M365CLONING_HISTORY = $history }
    $config = [string](Get-M365WebValue $Settings 'ConfigPath')
    if ($config) { $api.M365CLONING_CONFIG = $config }
    @{ Api = $api; Ui = $ui; ApiPort = $backendPort; UiPort = $frontendPort }
}

function Format-M365WebSummary {
    <# What will start, in a few lines, without any secret, hash or ID. #>
    [CmdletBinding()] param ([Parameter(Mandatory)][hashtable]$Settings)
    $local = Get-M365WebSection $Settings 'LocalAccount'
    $ports = Get-M365WebSection $Settings 'Ports'
    $backendPort = Get-M365WebValue $ports 'Api' 8000
    $frontendPort = Get-M365WebValue $ports 'Ui' 8080
    @(
        "Interface : http://localhost:$frontendPort/"
        "API       : http://127.0.0.1:$backendPort/ (only for the interface)"
        "Entra ID  : $(if (Test-M365WebEntraConfigured $Settings) { 'set up' } else { 'not set up (reports, apply and reset need it)' })"
        "Break-glass account : $(if ([bool](Get-M365WebValue $local 'Enabled' $false)) { "on, user '$($local.User)', role Reader, only on this machine" } else { 'off' })"
    )
}

function Find-M365WebPython {
    <# The Python 3.12 interpreter: path and version, or a clear error. #>
    [CmdletBinding()] param ()
    $candidates = @()
    if ($IsWindows) { $candidates += , @('py', "-$script:PythonVersion") }
    $candidates += , @("python$script:PythonVersion"); $candidates += , @('python3'); $candidates += , @('python')
    $seen = @()
    foreach ($c in $candidates) {
        if (-not (Get-Command $c[0] -CommandType Application -ErrorAction SilentlyContinue)) { continue }
        $exe = $c[0]; $pre = @($c | Select-Object -Skip 1)
        $info = & $exe @pre -c 'import sys; print(sys.executable); print("%d.%d" % sys.version_info[:2])' 2>$null
        if ($LASTEXITCODE -ne 0 -or @($info).Count -lt 2) { continue }
        $seen += "$($c -join ' ') = $($info[1])"
        if ($info[1] -eq $script:PythonVersion) { return [pscustomobject]@{ Path = $info[0]; Version = $info[1] } }
    }
    $found = if ($seen) { " Found: $($seen -join ', ')." } else { ' No Python found.' }
    throw "Python $script:PythonVersion is needed (the lock files are made for it).$found Install it from python.org (Windows: also the 'py' launcher) and start again."
}

function Get-M365WebVenvPython {
    param ([string]$Venv)
    if ($IsWindows) { Join-Path $Venv 'Scripts/python.exe' } else { Join-Path $Venv 'bin/python' }
}

function Initialize-M365WebVenv {
    <# Creates the venv when needed and installs the locked runtime packages (pip --require-hashes). Returns its python. #>
    [CmdletBinding()] param ([Parameter(Mandatory)][string]$Python, [Parameter(Mandatory)][string]$Venv, [Parameter(Mandatory)][string]$Requirements)
    $py = Get-M365WebVenvPython $Venv
    $marker = Join-Path $Venv '.m365-requirements.sha256'
    $want = (Get-FileHash -LiteralPath $Requirements -Algorithm SHA256).Hash
    if ((Test-Path -LiteralPath $py) -and (Test-Path -LiteralPath $marker) -and ((Get-Content -Raw -LiteralPath $marker).Trim() -eq $want)) {
        return $py
    }
    Write-Host "Setting up $(Split-Path -Leaf $Venv) (once, takes a minute) ..."
    if (-not (Test-Path -LiteralPath $py)) {
        & $Python -m venv $Venv
        if ($LASTEXITCODE -ne 0) { throw "Could not create the Python environment $Venv." }
    }
    & $py -m pip install --quiet --disable-pip-version-check --require-hashes -r $Requirements
    if ($LASTEXITCODE -ne 0) { throw "Installing the packages from $Requirements failed (see the pip output above). Check the network and start again." }
    Set-Content -LiteralPath $marker -Value $want -NoNewline
    $py
}

function Protect-M365WebFile {
    <# Only the current user may read and write the file. #>
    param ([string]$Path)
    if ($IsWindows) {
        $who = if ($env:USERDOMAIN) { "$env:USERDOMAIN\$env:USERNAME" } else { $env:USERNAME }
        & icacls $Path /inheritance:r /grant:r "${who}:(R,W)" *> $null
        if ($LASTEXITCODE -ne 0) { Write-Warning "Could not limit the access to $Path to your account; check its permissions." }
    } else {
        & chmod 600 $Path
    }
}

function Get-M365WebTokenSecret {
    <# The shared secret of interface and API (64 hex characters). Made once, kept in web.local/token.secret. #>
    [CmdletBinding()] param ([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $value = (Get-Content -Raw -LiteralPath $Path).Trim()
        if ($value.Length -ge 64) { return $value }
    }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $value = [Convert]::ToHexString($bytes).ToLowerInvariant()
    Set-Content -LiteralPath $Path -Value $value -NoNewline
    Protect-M365WebFile $Path
    $value
}

function Set-M365WebPasswordHash {
    <# Writes the hash into LocalAccount.PasswordHash of the settings file (only the hash, never the password). #>
    [CmdletBinding()] param ([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Hash)
    if ($Hash -notmatch '^scrypt\$[A-Za-z0-9$+/=._-]+$') { throw 'The password tool did not return a hash.' }
    $text = Get-Content -Raw -LiteralPath $Path
    $pattern = "(?m)^(\s*PasswordHash\s*=\s*)'[^']*'"
    if ($text -notmatch $pattern) { throw "LocalAccount.PasswordHash is missing in $Path. Take the block from web.settings.example.psd1." }
    $text = [regex]::Replace($text, $pattern, { param($m) $m.Groups[1].Value + "'" + $Hash + "'" }, 1)
    Set-Content -LiteralPath $Path -Value $text -NoNewline
}

function Start-M365WebProcess {
    <# Starts one app with its own environment variables; this session's environment is not changed. #>
    [CmdletBinding()] param (
        [Parameter(Mandatory)][string]$FilePath, [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory, [Parameter(Mandatory)][System.Collections.IDictionary]$Environment
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    foreach ($k in $Environment.Keys) { $psi.Environment[$k] = [string]$Environment[$k] }
    [System.Diagnostics.Process]::Start($psi)
}

function Stop-M365WebProcess {
    param ($Process)
    if ($Process -and -not $Process.HasExited) {
        try { $Process.Kill($true) } catch { Write-Verbose "stop: $($_.Exception.Message)" }
    }
}

function Test-M365WebPortFree {
    param ([int]$Port)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    try { $listener.Start(); $true } catch { $false } finally { $listener.Stop() }
}

function Wait-M365WebReady {
    <# Waits until the address answers (any HTTP status) or the process ends. #>
    [CmdletBinding()] param ([Parameter(Mandatory)][string]$Url, $Process, [int]$TimeoutSeconds = 60)
    # Any answer counts, also 303 to the sign-in page or 401: Invoke-WebRequest would treat a redirect it may not
    # follow as an error, so a plain HttpClient that does not follow redirects asks.
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $http = [System.Net.Http.HttpClient]::new($handler)
    $http.Timeout = [TimeSpan]::FromSeconds(2)
    try {
        $until = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ([DateTime]::UtcNow -lt $until) {
            if ($Process -and $Process.HasExited) { return $false }
            try {
                $http.GetAsync($Url).GetAwaiter().GetResult().Dispose()
                return $true
            } catch { Start-Sleep -Milliseconds 500 }
        }
        $false
    } finally { $http.Dispose() }
}

function Open-M365WebBrowser {
    param ([string]$Url)
    try {
        if ($IsWindows) { Start-Process $Url }
        elseif ($IsMacOS) { & open $Url }
        elseif (Get-Command xdg-open -ErrorAction SilentlyContinue) { & xdg-open $Url *> $null }
        else { Write-Host "Open $Url in your browser." }
    } catch { Write-Host "Open $Url in your browser." }
}

function Write-M365WebProblems {
    param ($Problems)
    Write-Host 'The web app cannot start yet:' -ForegroundColor Yellow
    foreach ($p in $Problems) {
        Write-Host "  x $($p.Field): $($p.Problem)" -ForegroundColor Yellow
        Write-Host "    -> $($p.Fix)"
    }
}

function Invoke-M365CloningWeb {
    <#
    .SYNOPSIS
    The steps of scripts/Start-M365CloningWeb.ps1. Returns the exit code: 0 ok, 2 something to fix first.
    #>
    [CmdletBinding()] param (
        [string]$Root = (Get-M365WebRoot), [string]$SettingsPath, [switch]$Check, [switch]$NoBrowser, [switch]$SetLocalPassword
    )
    $paths = Get-M365WebPaths -Root $Root
    if ($SettingsPath) { $paths.Settings = $SettingsPath }

    try { $settings = Read-M365WebSettings -Path $paths.Settings }
    catch { Write-Host $_.Exception.Message -ForegroundColor Yellow; return 2 }

    try { $python = Find-M365WebPython }
    catch { Write-Host $_.Exception.Message -ForegroundColor Yellow; return 2 }

    $localOn = [bool](Get-M365WebValue (Get-M365WebSection $settings 'LocalAccount') 'Enabled' $false)
    $hashEmpty = -not (Get-M365WebValue (Get-M365WebSection $settings 'LocalAccount') 'PasswordHash')
    if ($SetLocalPassword -or ($localOn -and $hashEmpty -and -not $Check)) {
        try {
            $frontendPython = Initialize-M365WebVenv -Python $python.Path -Venv $paths.UiVenv -Requirements (Join-Path $paths.UiDir 'requirements.txt')
            Write-Host 'Password of the break-glass account (at least 12 characters; only the hash is stored):'
            Push-Location $paths.UiDir
            try { $hash = & $frontendPython -m m365ui.passwords } finally { Pop-Location }
            if ($LASTEXITCODE -ne 0 -or -not $hash) { Write-Host 'No password set.' -ForegroundColor Yellow; return 2 }
            Set-M365WebPasswordHash -Path $paths.Settings -Hash ([string]@($hash)[-1]).Trim()
            Write-Host 'The hash is stored in web.settings.psd1.'
            $settings = Read-M365WebSettings -Path $paths.Settings
        } catch { Write-Host $_.Exception.Message -ForegroundColor Yellow; return 2 }
    }

    $problems = @(Test-M365WebSettings -Settings $settings)
    if ($problems.Count) { Write-M365WebProblems $problems; return 2 }

    Format-M365WebSummary -Settings $settings | ForEach-Object { Write-Host $_ }
    $env0 = ConvertTo-M365WebEnvironment -Settings $settings -TokenSecret 'x'
    foreach ($port in $env0.ApiPort, $env0.UiPort) {
        if (-not (Test-M365WebPortFree $port)) {
            Write-Host "Port $port is in use (is the app already running?). Stop the other program or set another port in Ports." -ForegroundColor Yellow
            return 2
        }
    }
    if ($Check) {
        Write-Host "Python $($python.Version): ok. Settings: ok. Ports: free."
        return 0
    }

    try {
        $sharedValue = Get-M365WebTokenSecret -Path $paths.TokenSecret
        $backendPython = Initialize-M365WebVenv -Python $python.Path -Venv $paths.ApiVenv -Requirements (Join-Path $paths.ApiDir 'requirements.txt')
        $frontendPython = Initialize-M365WebVenv -Python $python.Path -Venv $paths.UiVenv -Requirements (Join-Path $paths.UiDir 'requirements.txt')
    } catch { Write-Host $_.Exception.Message -ForegroundColor Yellow; return 2 }

    $envs = ConvertTo-M365WebEnvironment -Settings $settings -TokenSecret $sharedValue
    $backend = $null; $frontend = $null
    try {
        $backend = Start-M365WebProcess -FilePath $backendPython -Arguments @('-m', 'm365api') -WorkingDirectory $paths.ApiDir -Environment $envs.Api
        if (-not (Wait-M365WebReady -Url "http://127.0.0.1:$($envs.ApiPort)/api/status" -Process $backend)) {
            Write-Host 'The API did not start; see its output above.' -ForegroundColor Yellow; return 2
        }
        $frontend = Start-M365WebProcess -FilePath $frontendPython -Arguments @('-m', 'uvicorn', 'm365ui.main:app', '--host', '127.0.0.1', '--port', "$($envs.UiPort)") `
            -WorkingDirectory $paths.UiDir -Environment $envs.Ui
        $url = "http://localhost:$($envs.UiPort)/"
        if (-not (Wait-M365WebReady -Url $url -Process $frontend)) {
            Write-Host 'The interface did not start; see its output above.' -ForegroundColor Yellow; return 2
        }
        Write-Host "Ready: $url  (Ctrl+C stops both apps)" -ForegroundColor Green
        if (-not $NoBrowser) { Open-M365WebBrowser $url }
        while (-not $backend.HasExited -and -not $frontend.HasExited) { Start-Sleep -Milliseconds 500 }
        if ($backend.HasExited) { Write-Host 'The API has stopped.' -ForegroundColor Yellow; return 2 }
        Write-Host 'The interface has stopped.' -ForegroundColor Yellow
        return 2
    } finally {
        Stop-M365WebProcess $frontend
        Stop-M365WebProcess $backend
    }
}

Export-ModuleMember -Function Get-M365WebRoot, Get-M365WebPaths, Read-M365WebSettings, Test-M365WebSettings, ConvertTo-M365WebEnvironment,
    Format-M365WebSummary, Find-M365WebPython, Initialize-M365WebVenv, Get-M365WebTokenSecret, Set-M365WebPasswordHash,
    Start-M365WebProcess, Stop-M365WebProcess, Test-M365WebPortFree, Wait-M365WebReady, Open-M365WebBrowser, Invoke-M365CloningWeb
