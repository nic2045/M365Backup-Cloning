function Get-DevResetEndpoint {
    <#
    .SYNOPSIS
        The Graph path of each object kind the reset may delete (ADR 0005). Paths as documented on Microsoft Learn,
        checked 2026-11-07:
          ConditionalAccessPolicy  v1.0 DELETE /identity/conditionalAccess/policies/{id}   ("Delete conditionalAccessPolicy";
                                   the policy goes to the CA deleted items first) and PATCH {state} to switch it off first
          DeviceConfiguration      v1.0 DELETE /deviceManagement/deviceConfigurations/{id} (profiles and update rings)
          DeviceCompliancePolicy   v1.0 DELETE /deviceManagement/deviceCompliancePolicies/{id}
          ConfigurationPolicy      beta DELETE /deviceManagement/configurationPolicies/{id} (settings catalog, endpoint security)
          Intent                   beta DELETE /deviceManagement/intents/{id}               (older endpoint security profiles)
          AssignmentFilter         beta DELETE /deviceManagement/assignmentFilters/{id}
          NamedLocation            v1.0 DELETE /identity/conditionalAccess/namedLocations/{id} ("Delete namedLocation")
          AuthenticationStrength   v1.0 DELETE /policies/authenticationStrengthPolicies/{id}   ("Delete authenticationStrengthPolicy",
                                   custom policies only; built-in ones are never planned)
          Group                    v1.0 DELETE /groups/{id}  (deleted items, restorable for 30 days)
          User                     v1.0 DELETE /users/{id}   (deleted items, restorable for 30 days)
          ManagedDevice            v1.0 DELETE /deviceManagement/managedDevices/{id}          ("Delete managedDevice"),
                                   POST {id}/retire ("retire action", no body), POST {id}/wipe ("wipe action"); issue #46.
                                   Device writes are allowed only with -DeviceWrites, the wipe only with Dev.AllowDeviceWipe.
        The permanent delete (/directory/deletedItems) is not on the list.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Kind)
    $map = @{
        ConditionalAccessPolicy = 'v1.0/identity/conditionalAccess/policies'
        DeviceConfiguration     = 'v1.0/deviceManagement/deviceConfigurations'
        DeviceCompliancePolicy  = 'v1.0/deviceManagement/deviceCompliancePolicies'
        ConfigurationPolicy     = 'beta/deviceManagement/configurationPolicies'
        Intent                  = 'beta/deviceManagement/intents'
        AssignmentFilter        = 'beta/deviceManagement/assignmentFilters'
        NamedLocation           = 'v1.0/identity/conditionalAccess/namedLocations'
        AuthenticationStrength  = 'v1.0/policies/authenticationStrengthPolicies'
        Group                   = 'v1.0/groups'
        User                    = 'v1.0/users'
        ManagedDevice           = 'v1.0/deviceManagement/managedDevices'
    }
    if (-not $map.ContainsKey($Kind)) { throw "Blocked: the reset does not delete objects of kind '$Kind'." }
    $map[$Kind]
}

function Assert-DevResetWriteAllowed {
    <#
    .SYNOPSIS
        Throws unless the write is one of the reset writes: DELETE of one object of an allowed kind, or the PATCH that
        switches a Conditional Access policy off ({ state = 'disabled' } and nothing else). Dev tenant only.
        Device writes (issue #46) only with -DeviceWrites: DELETE of a managed device, POST {id}/retire, and POST
        {id}/wipe only when the config sets Dev.AllowDeviceWipe = $true. Device actions carry no body from the caller.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [System.Collections.IDictionary]$Body,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [switch]$DeviceWrites
    )
    $devId = [string]$Config['Dev']['TenantId']
    $prodId = [string]$Config['Prod']['TenantId']
    if ([string]::IsNullOrWhiteSpace($devId) -or $TenantId -ne $devId) { throw "Blocked: the reset writes to the Dev tenant of the config only (got '$TenantId')." }
    if ($TenantId -eq $prodId) { throw 'Blocked: the tenant equals the Prod tenant.' }
    $u = [System.Uri]$Uri
    if ($u.Scheme -ne 'https' -or $u.Host -ne 'graph.microsoft.com') { throw "Blocked: only https://graph.microsoft.com is allowed: $Uri" }
    if (-not [string]::IsNullOrEmpty($u.Query)) { throw "Blocked: no query string on a write: $Uri" }
    $path = [System.Uri]::UnescapeDataString($u.AbsolutePath)
    $id = '[A-Za-z0-9_-]+'
    $deletable = @(
        "^/v1\.0/identity/conditionalAccess/policies/$id$"
        "^/v1\.0/deviceManagement/deviceConfigurations/$id$"
        "^/v1\.0/deviceManagement/deviceCompliancePolicies/$id$"
        "^/beta/deviceManagement/configurationPolicies/$id$"
        "^/beta/deviceManagement/intents/$id$"
        "^/beta/deviceManagement/assignmentFilters/$id$"
        "^/v1\.0/identity/conditionalAccess/namedLocations/$id$"
        "^/v1\.0/policies/authenticationStrengthPolicies/$id$"
        "^/v1\.0/groups/$id$"
        "^/v1\.0/users/$id$"
    )
    $devicePath = "^/v1\.0/deviceManagement/managedDevices/$id$"
    $deviceAction = "^/v1\.0/deviceManagement/managedDevices/$id/(retire|wipe)$"
    if (($path -match $devicePath -or $path -match $deviceAction) -and -not $DeviceWrites) {
        throw "Blocked: device writes need a reset plan with chosen device actions: $Uri"
    }
    if ($DeviceWrites -and $path -match $devicePath) { $deletable += $devicePath }
    switch ($Method) {
        'POST' {
            if (-not $DeviceWrites -or $path -notmatch $deviceAction) { throw "Blocked: the reset only posts the device actions retire and wipe: $Uri" }
            if ($null -ne $Body -and $Body.Count -gt 0) { throw 'Blocked: a device action has no body from the caller.' }
            if ($path -match '/wipe$' -and $Config['Dev']['AllowDeviceWipe'] -ne $true) { throw 'Blocked: wipe needs Dev.AllowDeviceWipe = $true in the config.' }
        }
        'DELETE' {
            if (-not ($deletable | Where-Object { $path -match $_ })) { throw "Blocked: the reset may not delete this path: $Uri" }
            if ($null -ne $Body -and $Body.Count -gt 0) { throw 'Blocked: a delete has no body.' }
        }
        'PATCH' {
            if ($path -notmatch "^/v1\.0/identity/conditionalAccess/policies/$id$") { throw "Blocked: the reset patches Conditional Access policies only: $Uri" }
            if ($null -eq $Body -or $Body.Count -ne 1 -or [string]$Body['state'] -ne 'disabled') { throw "Blocked: the only patch is { state = 'disabled' }." }
        }
        default { throw "Blocked: the reset only uses DELETE, the PATCH that switches a policy off and the device actions, not $Method." }
    }
}

function Invoke-DevResetWrite {
    <#
    .SYNOPSIS
        The only write path of the factory reset (ADR 0005). Checks Assert-DevResetWriteAllowed before every
        request. Tests replace it with -GraphWriter in Invoke-DevResetPlan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('DELETE', 'PATCH', 'POST')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [System.Collections.IDictionary]$Body,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][securestring]$Token,
        [switch]$DeviceWrites
    )
    Assert-DevResetWriteAllowed -Method $Method -Uri $Uri -Body $Body -TenantId $TenantId -Config $Config -DeviceWrites:$DeviceWrites
    $headers = @{ Authorization = 'Bearer ' + (ConvertFrom-SecureString -SecureString $Token -AsPlainText) }
    if ($Method -eq 'POST') {
        # retire takes no body ("Do not supply a request body"); wipe takes optional parameters, none are set here.
        if ($Uri -match '/wipe$') { Invoke-RestMethod -Method POST -Uri $Uri -Headers $headers -ContentType 'application/json' -Body '{}' -ErrorAction Stop }
        else { Invoke-RestMethod -Method POST -Uri $Uri -Headers $headers -ErrorAction Stop }
    }
    elseif ($Method -eq 'PATCH') {
        Invoke-RestMethod -Method PATCH -Uri $Uri -Headers $headers -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Compress) -ErrorAction Stop
    }
    else {
        Invoke-RestMethod -Method DELETE -Uri $Uri -Headers $headers -ErrorAction Stop
    }
}
