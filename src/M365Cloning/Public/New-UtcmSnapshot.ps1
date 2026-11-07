function New-UtcmSnapshot {
    <#
    .SYNOPSIS
        Starts a UTCM snapshot job (reads the tenant, changes nothing).
    .NOTES
        API (Microsoft Learn, 'configurationBaseline: createSnapshot'):
        POST https://graph.microsoft.com/v1.0/admin/configurationManagement/configurationSnapshots/createSnapshot
        Body: displayName (required), description (optional), resources (required, string collection).
        Permission: ConfigurationMonitoring.ReadWrite.All (the only one listed for this action).
        Returns a configurationSnapshotJob (id, status, ...).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][securestring]$Token,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string[]]$Resources,
        [string]$Description = 'M365Backup-Cloning drift report (read only)',
        [string]$GraphBase = 'https://graph.microsoft.com/v1.0'
    )
    $body = [ordered]@{ displayName = $DisplayName; description = $Description; resources = @($Resources) }
    Invoke-UtcmGraphRequest -Method POST -Token $Token -Body $body `
        -Uri "$GraphBase/admin/configurationManagement/configurationSnapshots/createSnapshot"
}
