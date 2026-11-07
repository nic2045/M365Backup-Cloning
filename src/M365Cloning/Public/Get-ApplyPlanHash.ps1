function Get-ApplyPlanHash {
    <#
    .SYNOPSIS
        SHA-256 (hex, lower case) of the canonical JSON of a plan. Used as the confirmation token.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Plan)

    $json = ConvertTo-Json -InputObject (ConvertTo-CanonicalObject -Value $Plan) -Depth 30 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
}
