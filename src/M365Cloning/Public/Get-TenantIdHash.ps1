function Get-TenantIdHash {
    <#
    .SYNOPSIS
        SHA-256 (hex, lower case) of a tenant ID in lower case. Plans carry this instead of the full ID (issue #51);
        the gate compares it with the Dev tenant ID of the local config.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$TenantId)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($TenantId.Trim().ToLowerInvariant())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
}
