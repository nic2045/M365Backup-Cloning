function Invoke-UtcmGraphRequest {
    <#
    .SYNOPSIS
        The only place in the module that talks to Microsoft Graph. Read-only by construction.
    .DESCRIPTION
        Allowed: every GET, and exactly one POST: createSnapshot
        (POST /admin/configurationManagement/configurationSnapshots/createSnapshot), which starts an
        extraction job and changes no configuration in the tenant. Every other method or POST path
        throws before a request is sent (ADR 0001: no write path; Prod is never written).
        Tests mock this function; the token is passed in by the caller (app-only, certificate).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][securestring]$Token,
        [object]$Body
    )

    $uriObject = [System.Uri]$Uri
    if ($uriObject.Scheme -ne 'https') { throw "Only https is allowed: $Uri" }

    if ($Method -eq 'POST') {
        $isCreateSnapshot = $uriObject.AbsolutePath -match '/admin/configurationManagement/configurationSnapshots/createSnapshot/?$'
        if (-not $isCreateSnapshot) {
            throw "Blocked: POST is only allowed for createSnapshot (read-only tool). Uri: $Uri"
        }
    }

    $headers = @{
        Authorization = 'Bearer ' + (ConvertFrom-SecureString -SecureString $Token -AsPlainText)
        # Documented evolvable enum: needed to see the status value partiallySuccessful.
        Prefer        = 'include-unknown-enum-members'
    }
    $params = @{ Method = $Method; Uri = $Uri; Headers = $headers; ErrorAction = 'Stop' }
    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
        $params.ContentType = 'application/json'
    }
    Invoke-RestMethod @params
}
