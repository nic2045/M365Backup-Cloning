function Get-DesiredStateConnectionProperty {
    <#
    .SYNOPSIS
        Properties that only describe the connection to a tenant, not its configuration (ADR 0018 point 4). The export
        removes them from the desired state; the plan from the repository (ADR 0019) removes them from the Dev snapshot
        before the comparison, so both sides are compared on the same properties.
    #>
    [CmdletBinding()]
    param()
    [string[]]@('TenantId', 'ApplicationId', 'CertificateThumbprint', 'ApplicationSecret', 'Credential', 'ManagedIdentity', 'AccessTokens')
}
