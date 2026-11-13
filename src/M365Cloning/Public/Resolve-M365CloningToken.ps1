function Resolve-M365CloningToken {
    <#
    .SYNOPSIS
        The Graph token of one tenant for a console script: the one that was passed, else the sign-in of the app
        registration with its certificate from the configuration (issue #87, ADR 0021).
    .DESCRIPTION
        The scripts (Get-DriftReport, Invoke-ApplyDev, Invoke-DevBaseline, Invoke-DevReset, Invoke-DevUsers,
        Export-DesiredState) take -ProdToken and -DevToken. When one is not passed, the token is fetched here with the
        certificate of the app registration (<Side>.TenantId, <Side>.ClientId, <Side>.CertThumbprint of config.psd1;
        the certificate is in the Windows certificate store, found by its thumbprint). The certificate is the only way
        to sign in: there is no client secret in this toolkit. The sign-in is the one of the web jobs
        (Get-WebJobGraphToken, Az.Accounts, ADR 0013: no own token code). A passed token wins, so a token from another
        source (a test, a pipeline) still works. The token is returned as SecureString; the private key, the token and
        the thumbprint are never written to the output. -TokenProvider replaces the sign-in (tests).
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][ValidateSet('Prod', 'Dev')][string]$Side,
        [securestring]$Token,
        [scriptblock]$TokenProvider
    )
    if ($Token) { return $Token }
    if (-not $Config.ContainsKey($Side) -or $Config[$Side] -isnot [hashtable]) { throw "The $Side tenant is missing in the configuration." }
    $tenant = $Config[$Side]
    $provider = if ($TokenProvider) { $TokenProvider } else {
        { param($TenantId, $ClientId, $Thumbprint) Get-WebJobGraphToken -TenantId $TenantId -ClientId $ClientId -CertThumbprint $Thumbprint }
    }
    try {
        $result = & $provider ([string]$tenant['TenantId']) ([string]$tenant['ClientId']) ([string]$tenant['CertThumbprint'])
    }
    catch {
        throw "No -$($Side)Token was passed and the sign-in of the $Side app registration with its certificate failed: $(($_.Exception.Message -split "`r?`n")[0]) (check $Side.TenantId, $Side.ClientId and $Side.CertThumbprint in config.psd1; Invoke-SetupCheck.ps1 -Scope Config shows the certificate)"
    }
    if ($result -isnot [securestring]) { throw "The sign-in of the $Side app registration gave no token." }
    $result
}
