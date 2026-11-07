function Invoke-DevDirectoryWrite {
    <#
    .SYNOPSIS
        The only write path to the Dev directory for test users and invited admins (issue #22). Blocks everything
        else before a request is sent.
    .DESCRIPTION
        Allowed, and only with POST against Microsoft Graph v1.0 (documented on Microsoft Learn):
          POST /v1.0/users                       Create user (test user, cloud account)
          POST /v1.0/invitations                 Create invitation (B2B guest, sendInvitationMessage = false)
          POST /v1.0/groups/{id}/members/$ref    Add members (one member per request)
        -TenantId must be the Dev tenant of the config and differ from the Prod tenant; the token is the Dev
        app registration's (app-only). No delete, no PATCH, no other path. Tests replace this function with
        -GraphWriter in Invoke-DevUserPlan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('POST')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Body,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][securestring]$Token
    )
    Assert-DevDirectoryWriteAllowed -Uri $Uri -TenantId $TenantId -Config $Config
    $headers = @{ Authorization = 'Bearer ' + (ConvertFrom-SecureString -SecureString $Token -AsPlainText) }
    Invoke-RestMethod -Method POST -Uri $Uri -Headers $headers -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 10 -Compress) -ErrorAction Stop
}

function Assert-DevDirectoryWriteAllowed {
    <#
    .SYNOPSIS
        Throws unless the URI is one of the three allowed write endpoints and the tenant is Dev (not Prod).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )
    $devId = [string]$Config['Dev']['TenantId']
    $prodId = [string]$Config['Prod']['TenantId']
    if ([string]::IsNullOrWhiteSpace($devId) -or $TenantId -ne $devId) { throw "Blocked: writes go to the Dev tenant of the config only (got '$TenantId')." }
    if ($TenantId -eq $prodId) { throw 'Blocked: the tenant equals the Prod tenant.' }
    $u = [System.Uri]$Uri
    if ($u.Scheme -ne 'https' -or $u.Host -ne 'graph.microsoft.com') { throw "Blocked: only https://graph.microsoft.com is allowed: $Uri" }
    if (-not [string]::IsNullOrEmpty($u.Query)) { throw "Blocked: no query string on a write: $Uri" }
    $path = [System.Uri]::UnescapeDataString($u.AbsolutePath)
    $allowed = @('^/v1\.0/users$', '^/v1\.0/invitations$', '^/v1\.0/groups/[A-Za-z0-9-]+/members/\$ref$')
    if (-not ($allowed | Where-Object { $path -match $_ })) { throw "Blocked: write not allowed for this path (users, invitations, group members only): $Uri" }
}
