function Get-TenantLicences {
    <#
    .SYNOPSIS
        Reads the licences of one tenant, read only: GET https://graph.microsoft.com/v1.0/subscribedSkus through
        Invoke-UtcmGraphRequest (GET only), or offline from a saved JSON file of that answer (-Path).
    .DESCRIPTION
        Permission (Learn 'List subscribedSkus'): LicenseAssignment.Read.All (application, least privileged).
        Never assigns or changes a licence. When the list cannot be read, it does not throw: it returns Readable = $false
        with the reason, and Add-PlanLicenceCheck decides what that means for the plan.
        Reusable for Prod and Dev (issue #39).
    #>
    [CmdletBinding(DefaultParameterSetName = 'Online')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Online')][securestring]$Token,
        [Parameter(Mandatory, ParameterSetName = 'Offline')][string]$Path
    )
    $fail = { param($why) [ordered]@{ Readable = $false; Error = [string]$why; Available = [string[]]@(); Skus = [object[]]@() } }
    try {
        if ($PSCmdlet.ParameterSetName -eq 'Offline') {
            if (-not (Test-Path -LiteralPath $Path)) { return (& $fail "licence file not found: $Path") }
            return (ConvertTo-TenantLicences -SubscribedSkus (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable))
        }
        $all = [System.Collections.Generic.List[object]]::new()
        $uri = 'https://graph.microsoft.com/v1.0/subscribedSkus'
        $pages = 0
        while ($uri -and $pages -lt 20) {
            $pages++
            $answer = Invoke-UtcmGraphRequest -Method GET -Uri $uri -Token $Token
            foreach ($s in @($answer.value)) { if ($null -ne $s) { $all.Add($s) } }
            $next = $answer.PSObject.Properties['@odata.nextLink']
            $uri = if ($next) { [string]$next.Value } else { $null }
        }
        ConvertTo-TenantLicences -SubscribedSkus @{ value = $all.ToArray() }
    }
    catch { & $fail $_.Exception.Message }
}
