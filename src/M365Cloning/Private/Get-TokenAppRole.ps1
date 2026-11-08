function Get-TokenAppRole {
    <#
    .SYNOPSIS
        The application permissions of an app-only Graph token (the 'roles' claim), for the setup check (issue #18).
    .DESCRIPTION
        Reads the payload of the token that the sign-in already returned; no request, no extra permission. The token
        is decoded in memory only and never written anywhere. Not a token check: Microsoft Graph checks the token,
        this only lists what was granted with admin consent.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][securestring]$Token)
    $parts = (ConvertFrom-SecureString -SecureString $Token -AsPlainText) -split '\.'
    if ($parts.Count -lt 2) { throw 'The token is not a JSON Web Token.' }
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
    $claims = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload)) | ConvertFrom-Json -AsHashtable
    $roles = if ($claims.ContainsKey('roles') -and $claims['roles']) { @($claims['roles'] | ForEach-Object { [string]$_ }) } else { @() }
    [string[]]@($roles | Sort-Object -Unique)
}
