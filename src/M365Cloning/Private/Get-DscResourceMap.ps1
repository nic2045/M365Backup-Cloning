function Get-DscResourceMap {
    <#
    .SYNOPSIS
        UTCM resource type -> Microsoft365DSC resource, apply order and assignment CIM class.
    .DESCRIPTION
        Sources (checked 2026-11-07):
        - UTCM type names: the schema that Microsoft Learn links as the complete TCM schema
          ('Supported Microsoft Intune resources for Tenant Configuration Management',
          https://learn.microsoft.com/graph/utcm-intune-resources -> https://www.schemastore.org/utcm-monitor.json).
          Every type below occurs there in the form 'microsoft.<workload>.<resource>'.
        - Assignment CIM class: the 'title' of the Assignments items in that schema
          (MSFT_DeviceManagementConfigurationPolicyAssignments for most types; account protection has its own).
          settingCatalogCustomPolicyWindows10 is listed in the schema's type list but has no definition there; its
          parameters (key 'Name', Assignments) come from the Learn page section of the same name.
        - Microsoft365DSC resource names: not listed on Learn. They follow the rule 'Intune' / 'AAD' + the resource
          name in PascalCase; the schema's CIM class names carry the same stem (MSFT_IntuneAccountProtectionPolicy...,
          MSFT_IntuneWindowsInformationProtectionPolicyWindows10MdmEnrolled..., MSFT_AADGroupLicense). This is an
          inference: the DSC runner checks each name with Get-DscResource before use and fails only that action when
          the installed module lacks it (validation/README.md, part 5).
        Entries with Secret = $true are never copied (they hold keys, certificates or pre-shared keys): the plan
        marks them 'skipped: secret'. Scope tags (role scope tags) are not a TCM resource and do not appear in the
        policy schemas: they are not handled (see README).
        Order: groups first, then filters (assignments refer to both), policies, roles, Conditional Access last.
    #>
    [CmdletBinding()]
    param()

    $schema = 'utcm-monitor.json (linked from Learn utcm-intune-resources / utcm-entra-resources)'
    $default = 'MSFT_DeviceManagementConfigurationPolicyAssignments'
    $e = { param($Dsc, $Order, $Source = $schema, $Class = $default) @{ Dsc = $Dsc; Order = $Order; AssignmentClass = $Class; Source = $Source; Secret = $false } }
    $secret = { param($Why) @{ Dsc = ''; Order = 9; AssignmentClass = ''; Source = $schema; Secret = $true; SecretReason = $Why } }

    @{
        # Entra
        'microsoft.entra.group'                                                     = & $e 'AADGroup' 1
        'microsoft.entra.roledefinition'                                            = & $e 'AADRoleDefinition' 7
        'microsoft.entra.conditionalaccesspolicy'                                   = & $e 'AADConditionalAccessPolicy' 8

        # Intune: filters before everything that is assigned
        'microsoft.intune.deviceandappmanagementassignmentfilter'                   = & $e 'IntuneDeviceAndAppManagementAssignmentFilter' 2

        # Compliance
        'microsoft.intune.devicecompliancepolicywindows10'                          = & $e 'IntuneDeviceCompliancePolicyWindows10' 3

        # Configuration profiles (classic deviceConfigurations and Settings Catalog)
        'microsoft.intune.deviceconfigurationpolicywindows10'                       = & $e 'IntuneDeviceConfigurationPolicyWindows10' 4
        'microsoft.intune.deviceconfigurationendpointprotectionpolicywindows10'     = & $e 'IntuneDeviceConfigurationEndpointProtectionPolicyWindows10' 4
        'microsoft.intune.deviceconfigurationadministrativetemplatepolicywindows10' = & $e 'IntuneDeviceConfigurationAdministrativeTemplatePolicyWindows10' 4
        'microsoft.intune.deviceconfigurationcustompolicywindows10'                 = & $e 'IntuneDeviceConfigurationCustomPolicyWindows10' 4
        'microsoft.intune.settingcatalogcustompolicywindows10'                      = & $e 'IntuneSettingCatalogCustomPolicyWindows10' 4 'Learn utcm-intune-resources, section settingCatalogCustomPolicyWindows10 (no definition in the schema)'

        # Endpoint security
        'microsoft.intune.antiviruspolicywindows10settingcatalog'                   = & $e 'IntuneAntivirusPolicyWindows10SettingCatalog' 5
        'microsoft.intune.endpointdetectionandresponsepolicywindows10'              = & $e 'IntuneEndpointDetectionAndResponsePolicyWindows10' 5
        'microsoft.intune.settingcatalogasrrulespolicywindows10'                    = & $e 'IntuneSettingCatalogASRRulesPolicyWindows10' 5
        'microsoft.intune.exploitprotectionpolicywindows10settingcatalog'           = & $e 'IntuneExploitProtectionPolicyWindows10SettingCatalog' 5
        'microsoft.intune.applicationcontrolpolicywindows10'                        = & $e 'IntuneApplicationControlPolicyWindows10' 5
        'microsoft.intune.accountprotectionpolicy'                                  = & $e 'IntuneAccountProtectionPolicy' 5 $schema 'MSFT_IntuneAccountProtectionPolicyAssignments'

        # Update rings
        'microsoft.intune.windowsupdateforbusinessringupdateprofilewindows10'       = & $e 'IntuneWindowsUpdateForBusinessRingUpdateProfileWindows10' 6
        'microsoft.intune.windowsupdateforbusinessfeatureupdateprofilewindows10'    = & $e 'IntuneWindowsUpdateForBusinessFeatureUpdateProfileWindows10' 6

        # Roles
        'microsoft.intune.roledefinition'                                           = & $e 'IntuneRoleDefinition' 7

        # Never copied: they carry secrets (keys, certificates, pre-shared keys)
        'microsoft.intune.wificonfigurationpolicywindows10'                         = & $secret 'Wi-Fi profile (pre-shared key)'
        'microsoft.intune.deviceconfigurationvpnpolicywindows10'                    = & $secret 'VPN profile (certificates, shared secrets)'
        'microsoft.intune.deviceconfigurationwirednetworkpolicywindows10'           = & $secret 'wired network profile (802.1X certificates)'
        'microsoft.intune.deviceconfigurationpkcscertificatepolicywindows10'        = & $secret 'PKCS certificate profile'
        'microsoft.intune.deviceconfigurationscepcertificatepolicywindows10'        = & $secret 'SCEP certificate profile'
        'microsoft.intune.deviceconfigurationimportedpfxcertificatepolicywindows10' = & $secret 'imported PFX certificate profile'
        'microsoft.intune.deviceconfigurationtrustedcertificatepolicywindows10'     = & $secret 'trusted certificate profile'
    }
}
