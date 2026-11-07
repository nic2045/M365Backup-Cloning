function Test-ResourceHasSecret {
    <#
    .SYNOPSIS
        True when a resource carries an encrypted value that must not be copied.
    .DESCRIPTION
        Schema (utcm-monitor.json, linked from Learn utcm-intune-resources): OMA settings of custom profiles
        (MSFT_MicrosoftGraphOmaSetting) have IsEncrypted and SecretReferenceValueId. A setting with IsEncrypted = true
        or a SecretReferenceValueId holds a secret (for example a key or a password); the Prod value cannot be read in
        clear and must not be carried to Dev. Whole resource types with secrets (Wi-Fi, VPN, certificates) are marked in
        Get-DscResourceMap instead.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Resource)

    $props = $Resource['properties']
    if ($props -isnot [System.Collections.IDictionary]) { return $false }
    $omaKey = @($props.Keys | Where-Object { $_ -ieq 'OmaSettings' }) | Select-Object -First 1
    if (-not $omaKey) { return $false }
    foreach ($setting in @($props[$omaKey])) {
        if ($setting -isnot [System.Collections.IDictionary]) { continue }
        foreach ($k in @($setting.Keys)) {
            if ($k -ieq 'IsEncrypted' -and ($setting[$k] -eq $true -or [string]$setting[$k] -ieq 'true')) { return $true }
            if ($k -ieq 'SecretReferenceValueId' -and -not [string]::IsNullOrWhiteSpace([string]$setting[$k])) { return $true }
        }
    }
    $false
}
