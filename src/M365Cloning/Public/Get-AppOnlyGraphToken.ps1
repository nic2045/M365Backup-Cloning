function Get-AppOnlyGraphToken {
    <#
    .SYNOPSIS
        App-only Microsoft Graph token of one tenant with the certificate of its app registration (issue #14).
        Returns the token as SecureString; it is never written to the screen, a log or a file.
    .DESCRIPTION
        OAuth 2.0 client credentials with a certificate assertion, as documented by Microsoft for the identity
        platform ("Microsoft identity platform application authentication certificate credentials"): a JWT signed
        with the private key of the certificate (RS256, header x5t#S256) is posted to
        https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token with the scope https://graph.microsoft.com/.default.
        Why own code (CLAUDE.md, reuse first): the scripts take ready tokens and leave getting them to the operator;
        the web jobs need them without a person at the console. MSAL.PS is archived, and the Microsoft Graph and Az
        modules do not hand out the raw token they hold. This function needs no extra module.
        The certificate is taken from -Certificate (tests) or found by thumbprint in the personal store of the
        current user, then of the machine. Only its private key signs; nothing of it leaves the machine.
        -Post replaces the HTTP call (tests): it gets the URI and the form fields and returns the answer object.
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [string]$CertThumbprint,
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [string]$Scope = 'https://graph.microsoft.com/.default',
        [scriptblock]$Post
    )
    foreach ($pair in @(@('TenantId', $TenantId), @('ClientId', $ClientId))) {
        if ([string]::IsNullOrWhiteSpace($pair[1]) -or $pair[1] -match '^<') { throw "Config has no $($pair[0]) for this tenant." }
    }
    if ($TenantId -notmatch '^[A-Za-z0-9.-]+$') { throw 'The tenant ID is not valid.' }

    $cert = $Certificate
    if (-not $cert) {
        if ([string]::IsNullOrWhiteSpace($CertThumbprint) -or $CertThumbprint -match '^<') { throw 'Config has no CertThumbprint for this tenant.' }
        $thumb = ($CertThumbprint -replace '\s', '').ToUpperInvariant()
        foreach ($location in 'CurrentUser', 'LocalMachine') {
            $store = [System.Security.Cryptography.X509Certificates.X509Store]::new('My', $location)
            try {
                $store.Open('ReadOnly')
                $found = $store.Certificates.Find('FindByThumbprint', $thumb, $false)
                if ($found.Count -gt 0) { $cert = $found[0]; break }
            }
            catch { Write-Verbose "Store $location/My cannot be read: $($_.Exception.Message)" }
            finally { $store.Close() }
        }
        if (-not $cert) { throw "The certificate with the thumbprint from the config is not in the personal store (CurrentUser\My or LocalMachine\My)." }
    }
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    if (-not $rsa) { throw 'The certificate has no RSA private key on this machine.' }

    $b64url = { param([byte[]]$Bytes) [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
    $utf8 = [System.Text.Encoding]::UTF8
    $tokenUri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header = [ordered]@{ alg = 'RS256'; typ = 'JWT'; 'x5t#S256' = (& $b64url ([System.Security.Cryptography.SHA256]::HashData($cert.RawData))) }
    $claims = [ordered]@{ aud = $tokenUri; iss = $ClientId; sub = $ClientId; jti = [guid]::NewGuid().ToString(); nbf = $now; iat = $now; exp = $now + 600 }
    $unsigned = (& $b64url $utf8.GetBytes((ConvertTo-Json $header -Compress))) + '.' + (& $b64url $utf8.GetBytes((ConvertTo-Json $claims -Compress)))
    $signature = $rsa.SignData($utf8.GetBytes($unsigned), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $form = [ordered]@{
        client_id             = $ClientId
        scope                 = $Scope
        grant_type            = 'client_credentials'
        client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        client_assertion      = $unsigned + '.' + (& $b64url $signature)
    }
    $sender = if ($Post) { $Post } else { { param($Uri, $Body) Invoke-RestMethod -Method Post -Uri $Uri -Body $Body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 60 } }
    try { $answer = & $sender $tokenUri $form }
    catch {
        # The error text of the token endpoint names the cause (AADSTS code) and holds no secret; the assertion is not shown.
        $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        if ($detail -match '"error_description"\s*:\s*"([^"]+)"') { $detail = $Matches[1] }
        throw "Sign-in of the app registration failed: $(($detail -split "`r?`n")[0])"
    }
    $value = if ($answer -is [System.Collections.IDictionary]) { $answer['access_token'] } else { $answer.access_token }
    if ([string]::IsNullOrWhiteSpace([string]$value)) { throw 'Sign-in of the app registration gave no access token.' }
    ConvertTo-SecureString -String ([string]$value) -AsPlainText -Force
}
