function Get-WebJobGraphToken {
    <#
    .SYNOPSIS
        Graph token of one tenant for a web job (issue #70, ADR 0013): sign-in with the certificate of the app
        registration through Az.Accounts, no own token code.
    .DESCRIPTION
        Connect-AzAccount -ServicePrincipal -CertificateThumbprint (scope Process: nothing is saved to the Az context
        file on disk), then Get-AzAccessToken for https://graph.microsoft.com, then Disconnect-AzAccount.
        Why a raw token at all (and not Connect-MgGraph + Invoke-MgGraphRequest): the scripts and the core functions
        take one token per tenant (-ProdToken, -DevToken) and one run reads Prod and Dev side by side (drift report,
        plan, reset inventory), while Connect-MgGraph keeps one connection per process. The token is returned as
        SecureString and only ever put into the Authorization header by Invoke-UtcmGraphRequest.
        Microsoft365DSC (apply) signs in with the certificate itself and needs no token.
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$CertThumbprint
    )
    foreach ($pair in @(@('TenantId', $TenantId), @('ClientId', $ClientId), @('CertThumbprint', $CertThumbprint))) {
        if ([string]::IsNullOrWhiteSpace($pair[1]) -or $pair[1] -match '^<') { throw "Config has no $($pair[0]) for this tenant." }
    }
    foreach ($command in 'Connect-AzAccount', 'Get-AzAccessToken', 'Disconnect-AzAccount') {
        if (-not (Get-Command -Name $command -ErrorAction SilentlyContinue)) {
            throw 'The module Az.Accounts is needed for the sign-in of web jobs: Install-Module Az.Accounts -Scope CurrentUser'
        }
    }
    try {
        $null = Connect-AzAccount -ServicePrincipal -Tenant $TenantId -ApplicationId $ClientId -CertificateThumbprint $CertThumbprint `
            -Scope Process -SkipContextPopulation -ErrorAction Stop -WarningAction SilentlyContinue
        $answer = Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com' -TenantId $TenantId -ErrorAction Stop -WarningAction SilentlyContinue
    }
    catch { throw "Sign-in of the app registration failed: $(($_.Exception.Message -split "`r?`n")[0])" }
    finally { $null = Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue -WarningAction SilentlyContinue }
    $token = if ($answer) { $answer.Token } else { $null }
    # Az.Accounts 5 and later return a SecureString; older versions a plain string.
    if ($token -is [securestring]) { return $token }
    if ([string]::IsNullOrWhiteSpace([string]$token)) { throw 'Sign-in of the app registration gave no access token.' }
    ConvertTo-SecureString -String ([string]$token) -AsPlainText -Force
}
