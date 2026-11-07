function Get-DscResourceMap {
    <#
    .SYNOPSIS
        UTCM resource type -> Microsoft365DSC resource name and apply order.
    .DESCRIPTION
        Learn ('Supported Microsoft Entra / Intune resources for Tenant Configuration Management',
        https://learn.microsoft.com/graph/utcm-entra-resources and .../utcm-intune-resources) documents the
        resource types group, conditionalAccessPolicy, deviceConfigurationPolicyWindows10 and
        deviceCompliancePolicyWindows10 with the schema of the matching Microsoft365DSC resources (parameters
        DisplayName, Assignments with groupDisplayName, Ensure, State, ExcludeUsers, ExcludeGroups ...).
        The DSC resource NAMES (AADGroup, AADConditionalAccessPolicy, IntuneDeviceConfigurationPolicyWindows10,
        IntuneDeviceCompliancePolicyWindows10) follow the Microsoft365DSC naming; issue #1587/#1589 name
        AADGroup and AADConditionalAccessPolicy, the Intune ones and the role ones are inferred from the same
        naming. validation/README.md asks the owner to check each name with Get-DscResource in a real session.
        Order: groups first (others refer to them by name), Conditional Access last.
    #>
    [CmdletBinding()]
    param()
    @{
        'microsoft.entra.group'                                 = @{ Dsc = 'AADGroup'; Order = 1 }
        'microsoft.intune.devicecompliancepolicywindows10'      = @{ Dsc = 'IntuneDeviceCompliancePolicyWindows10'; Order = 2 }
        'microsoft.intune.deviceconfigurationpolicywindows10'   = @{ Dsc = 'IntuneDeviceConfigurationPolicyWindows10'; Order = 3 }
        'microsoft.intune.roledefinition'                       = @{ Dsc = 'IntuneRoleDefinition'; Order = 4 }
        'microsoft.entra.roledefinition'                        = @{ Dsc = 'AADRoleDefinition'; Order = 4 }
        'microsoft.entra.conditionalaccesspolicy'               = @{ Dsc = 'AADConditionalAccessPolicy'; Order = 5 }
    }
}
