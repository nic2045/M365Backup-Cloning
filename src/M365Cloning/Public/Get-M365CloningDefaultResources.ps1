function Get-M365CloningDefaultResources {
    <#
    .SYNOPSIS
        Resource type names for the snapshot request.
    .DESCRIPTION
        Source: Microsoft Learn, 'Supported Microsoft Entra / Intune resources for Tenant Configuration
        Management' (https://learn.microsoft.com/graph/utcm-intune-resources, .../utcm-entra-resources).
        The documented form is 'microsoft.<workload>.<resource, lower case>', for example
        'microsoft.entra.conditionalaccesspolicy' (named in 'Configuration management' on Learn).
        VERIFIED in the docs: conditionalaccesspolicy.
        INFERRED from that pattern and the documented resource types deviceConfigurationPolicyWindows10 and
        deviceCompliancePolicyWindows10: the Intune and group entries. The role entries are a best guess.
        validation/README.md asks the owner to check every name against a real tenant;
        you can override the list with 'Resources' in config.psd1.
    #>
    [CmdletBinding()]
    param()
    @(
        'microsoft.intune.deviceconfigurationpolicywindows10'   # inferred
        'microsoft.intune.devicecompliancepolicywindows10'      # inferred
        'microsoft.entra.group'                                 # inferred
        'microsoft.entra.conditionalaccesspolicy'               # documented
        'microsoft.intune.roledefinition'                       # guess
        'microsoft.entra.roledefinition'                        # guess
    )
}
