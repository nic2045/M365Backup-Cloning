function Get-M365CloningDefaultResources {
    <#
    .SYNOPSIS
        Resource type names for the snapshot request.
    .DESCRIPTION
        Source: the TCM schema that Microsoft Learn links from 'Supported Microsoft Intune / Entra resources for
        Tenant Configuration Management' (https://learn.microsoft.com/graph/utcm-intune-resources,
        .../utcm-entra-resources -> https://www.schemastore.org/utcm-monitor.json). Every name below occurs in that
        schema (checked 2026-11-07). The list covers what the toolkit can apply to Dev (Get-DscResourceMap) plus the
        secret-bearing Windows profiles and the authentication method policies, so that the drift report shows them and
        the plan marks them 'skipped: secret' / 'skipped: report-only'. Override with 'Resources' in config.psd1.
        Not covered: role scope tags (no TCM resource), apps (uploaded by SW-Depoyment).
    #>
    [CmdletBinding()]
    param()
    @(
        # Entra
        'microsoft.entra.group'
        'microsoft.entra.conditionalaccesspolicy'
        'microsoft.entra.roledefinition'
        # Conditional Access dependencies (issue #33)
        'microsoft.entra.namedlocationpolicy'
        'microsoft.entra.authenticationstrengthpolicy'
        # Authentication methods: read for the report, never applied
        'microsoft.entra.authenticationmethodpolicy'
        'microsoft.entra.authenticationmethodpolicyauthenticator'
        'microsoft.entra.authenticationmethodpolicyemail'
        'microsoft.entra.authenticationmethodpolicyfido2'
        'microsoft.entra.authenticationmethodpolicysms'
        'microsoft.entra.authenticationmethodpolicysoftware'
        'microsoft.entra.authenticationmethodpolicytemporary'
        'microsoft.entra.authenticationmethodpolicyvoice'
        'microsoft.entra.authenticationmethodpolicyx509'
        # Intune: filters, compliance, configuration profiles
        'microsoft.intune.deviceandappmanagementassignmentfilter'
        'microsoft.intune.devicecompliancepolicywindows10'
        'microsoft.intune.deviceconfigurationpolicywindows10'
        'microsoft.intune.deviceconfigurationendpointprotectionpolicywindows10'
        'microsoft.intune.deviceconfigurationadministrativetemplatepolicywindows10'
        'microsoft.intune.deviceconfigurationcustompolicywindows10'
        'microsoft.intune.settingcatalogcustompolicywindows10'
        # Endpoint security
        'microsoft.intune.antiviruspolicywindows10settingcatalog'
        'microsoft.intune.endpointdetectionandresponsepolicywindows10'
        'microsoft.intune.settingcatalogasrrulespolicywindows10'
        'microsoft.intune.exploitprotectionpolicywindows10settingcatalog'
        'microsoft.intune.applicationcontrolpolicywindows10'
        'microsoft.intune.accountprotectionpolicy'
        # Update rings
        'microsoft.intune.windowsupdateforbusinessringupdateprofilewindows10'
        'microsoft.intune.windowsupdateforbusinessfeatureupdateprofilewindows10'
        # Roles
        'microsoft.intune.roledefinition'
        # Secret-bearing profiles: read for the report, never applied
        'microsoft.intune.wificonfigurationpolicywindows10'
        'microsoft.intune.deviceconfigurationvpnpolicywindows10'
        'microsoft.intune.deviceconfigurationwirednetworkpolicywindows10'
        'microsoft.intune.deviceconfigurationpkcscertificatepolicywindows10'
        'microsoft.intune.deviceconfigurationscepcertificatepolicywindows10'
        'microsoft.intune.deviceconfigurationimportedpfxcertificatepolicywindows10'
        'microsoft.intune.deviceconfigurationtrustedcertificatepolicywindows10'
    )
}
