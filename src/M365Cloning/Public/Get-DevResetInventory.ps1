function Get-DevResetInventory {
    <#
    .SYNOPSIS
        Reads (GET only, through Invoke-UtcmGraphRequest) what the factory reset needs: the deletable objects of Dev,
        the objects that are only listed (devices, partners, the toolkit's app), and the Global Administrators of Prod.
    .DESCRIPTION
        Dev (Graph paths as on Microsoft Learn, checked 2026-11-07):
          v1.0 users, groups, identity/conditionalAccess/policies, deviceManagement/deviceConfigurations,
          deviceManagement/deviceCompliancePolicies, deviceManagement/managedDevices (kept unless an action is chosen, issue #46),
          policies/crossTenantAccessPolicy/partners (protected), servicePrincipals?$filter=appId eq Dev.ClientId (protected);
          beta deviceManagement/configurationPolicies, deviceManagement/intents, deviceManagement/assignmentFilters.
          Conditional Access dependencies (issue #33): v1.0 identity/conditionalAccess/namedLocations ("List
          namedLocations"), v1.0 policies/authenticationStrengthPolicies ("List authenticationStrengthPolicies";
          policyType tells built-in from custom). The Conditional Access policies are read with their conditions, so
          that the plan can protect the named locations of break-glass policies.
        Prod (read only): v1.0 directoryRoles(roleTemplateId='62e90394-69f5-4237-9190-012177145e10')/members
          ("List members of a directory role": the template ID of Global Administrator can be used).
        A failed Prod read is not swallowed into an empty list: ProdGlobalAdmins is $null and ProdReadError says
        why, and New-DevResetPlan refuses to plan. Returns a hashtable; it can be saved as JSON for an offline preview.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][securestring]$DevToken,
        [Parameter(Mandatory)][securestring]$ProdToken,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [string]$GraphHost = 'https://graph.microsoft.com'
    )
    $getAll = {
        param($uri, $token)
        $items = [System.Collections.Generic.List[object]]::new()
        while ($uri) {
            $r = Invoke-UtcmGraphRequest -Method GET -Uri $uri -Token $token
            foreach ($v in @($r.value)) { if ($null -ne $v) { $items.Add($v) } }
            $uri = $r.'@odata.nextLink'
        }
        [object[]]@($items)
    }
    $v1 = "$GraphHost/v1.0"; $beta = "$GraphHost/beta"
    $appFilter = [System.Uri]::EscapeDataString("appId eq '$(([string]$Config['Dev']['ClientId']).Replace("'", "''"))'")
    $dev = [ordered]@{
        Users                     = & $getAll "$v1/users?`$select=id,displayName,userPrincipalName,mail,userType,onPremisesSyncEnabled" $DevToken
        Groups                    = & $getAll "$v1/groups?`$select=id,displayName,groupTypes,membershipRule,isAssignableToRole,onPremisesSyncEnabled" $DevToken
        ConditionalAccessPolicies = & $getAll "$v1/identity/conditionalAccess/policies?`$select=id,displayName,state,conditions" $DevToken
        NamedLocations            = & $getAll "$v1/identity/conditionalAccess/namedLocations" $DevToken
        AuthenticationStrengths   = & $getAll "$v1/policies/authenticationStrengthPolicies?`$select=id,displayName,policyType" $DevToken
        DeviceConfigurations      = & $getAll "$v1/deviceManagement/deviceConfigurations?`$select=id,displayName" $DevToken
        DeviceCompliancePolicies  = & $getAll "$v1/deviceManagement/deviceCompliancePolicies?`$select=id,displayName" $DevToken
        ConfigurationPolicies     = & $getAll "$beta/deviceManagement/configurationPolicies?`$select=id,name" $DevToken
        Intents                   = & $getAll "$beta/deviceManagement/intents?`$select=id,displayName" $DevToken
        AssignmentFilters         = & $getAll "$beta/deviceManagement/assignmentFilters?`$select=id,displayName" $DevToken
        ManagedDevices            = & $getAll "$v1/deviceManagement/managedDevices?`$select=id,deviceName,operatingSystem,userPrincipalName,managementState" $DevToken
        CrossTenantPartners       = & $getAll "$v1/policies/crossTenantAccessPolicy/partners" $DevToken
        ToolkitServicePrincipals  = & $getAll "$v1/servicePrincipals?`$filter=$appFilter&`$select=id,appId,displayName" $DevToken
    }
    $admins = $null; $readError = ''
    try {
        $admins = & $getAll "$v1/directoryRoles(roleTemplateId='62e90394-69f5-4237-9190-012177145e10')/members?`$select=id,userPrincipalName,mail" $ProdToken
    }
    catch { $readError = ([string]$_.Exception.Message -split "`n")[0] }
    [ordered]@{ Dev = $dev; ProdGlobalAdmins = $admins; ProdReadError = $readError }
}
