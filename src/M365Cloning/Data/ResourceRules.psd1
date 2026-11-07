# Rules of the generic handling (ADR 0006, issue #40). Data only; Get-ResourceTypeCatalog and ConvertTo-ApplyProperties
# read it. Changing a rule here changes the plan without code changes.
@{
    # Workloads of the TCM schema (ResourceTypes.psd1). Only the default ones are snapshotted and planned unless the
    # configuration sets Workloads. DscPrefix: Microsoft365DSC resource names are '<prefix><resource name>' (the rule
    # of Get-DscResourceMap; not listed on Learn, so the DSC runner resolves each name with Get-DscResource and fails
    # only that action when the installed module lacks it).
    Workloads        = @{
        Entra                 = @{ Default = $true; DscPrefix = 'AAD' }
        Intune                = @{ Default = $true; DscPrefix = 'Intune' }
        Exchange              = @{ Default = $false; DscPrefix = 'EXO' }
        Teams                 = @{ Default = $false; DscPrefix = 'Teams' }
        SecurityAndCompliance = @{ Default = $false; DscPrefix = 'SC' }
    }

    # Apply order of types without an entry in Get-DscResourceMap (lower first). Groups 1, filters, locations,
    # strengths and contexts 2, compliance 3, profiles 4-6, roles 7, Conditional Access 8, policy sets last.
    DefaultOrder     = @{ Entra = 4; Intune = 4; Exchange = 4; Teams = 4; SecurityAndCompliance = 4 }
    OrderOverrides   = @{
        'microsoft.entra.authenticationcontextclassreference' = 2
        'microsoft.intune.devicecategory'                     = 2
        'microsoft.entra.attributeset'                        = 2
        'microsoft.intune.policysets'                         = 9
    }

    # Whole types that carry keys, certificates or pre-shared keys: never copied ('skipped: secret'). The Windows
    # profiles of the same kind are marked in Get-DscResourceMap.
    SecretTypes      = @{
        'microsoft.intune.wificonfigurationpolicyandroiddeviceadministrator'    = 'Wi-Fi profile (pre-shared key)'
        'microsoft.intune.wificonfigurationpolicyandroidenterprisedeviceowner'  = 'Wi-Fi profile (pre-shared key)'
        'microsoft.intune.wificonfigurationpolicyandroidenterpriseworkprofile'  = 'Wi-Fi profile (pre-shared key)'
        'microsoft.intune.wificonfigurationpolicyandroidforwork'                = 'Wi-Fi profile (pre-shared key)'
        'microsoft.intune.wificonfigurationpolicyandroidopensourceproject'      = 'Wi-Fi profile (pre-shared key)'
        'microsoft.intune.wificonfigurationpolicyios'                           = 'Wi-Fi profile (pre-shared key)'
        'microsoft.intune.wificonfigurationpolicymacos'                         = 'Wi-Fi profile (pre-shared key)'
    }
    # Properties whose non-empty value is a secret (schema property names, utcm-monitor.json). A resource with one of
    # them set is 'skipped: secret'. The OMA-URI rule (IsEncrypted, SecretReferenceValueId) stays in Test-ResourceHasSecret.
    SecretProperties = @('PreSharedKey', 'ClientSecret', 'Password', 'Secret', 'SharedSecret', 'PrivateKey', 'DataRecoveryCertificate')

    # Objects that every tenant has and that cannot be created ('skipped: tenant default'). Priority 0 marks the
    # default enrollment status page and the default platform restriction (schema: 'Priority ... lowest value').
    TenantDefaults   = @{
        'microsoft.intune.deviceenrollmentstatuspagewindows10'  = @{ Property = 'Priority'; Value = 0 }
        'microsoft.intune.deviceenrollmentplatformrestriction'  = @{ Property = 'Priority'; Value = 0 }
    }

    # Reference fields (Verweisfeld -> Zieltyp). Handler 'generic': resolved by ConvertTo-ApplyProperties from this
    # table: every value must exist in Dev (matched by MatchBy on the target type) or be created earlier in the same
    # plan, otherwise the resource is blocked with the reason prefix. Handler 'special': resolved by the existing
    # rules for that field (groups and filters in assignments, Conditional Access lists); listed here for the record.
    References       = @(
        @{ Field = 'AuthenticationContexts'; TargetType = 'microsoft.entra.authenticationcontextclassreference'; MatchBy = 'Id'; Reason = 'needs-auth-context'; Handler = 'generic'
           Source = 'Learn utcm-entra-resources: conditionalAccessPolicy AuthenticationContexts; authenticationContextClassReference key Id' }
        @{ Field = 'IncludeLocations / ExcludeLocations'; TargetType = 'microsoft.entra.namedlocationpolicy'; MatchBy = 'DisplayName'; Reason = 'needs-location'; Handler = 'special' }
        @{ Field = 'AuthenticationStrength'; TargetType = 'microsoft.entra.authenticationstrengthpolicy'; MatchBy = 'DisplayName'; Reason = 'needs-auth-strength'; Handler = 'special' }
        @{ Field = 'IncludeGroups / ExcludeGroups, Assignments.groupDisplayName'; TargetType = 'microsoft.entra.group'; MatchBy = 'DisplayName'; Reason = 'needs-group'; Handler = 'special' }
        @{ Field = 'Assignments.deviceAndAppManagementAssignmentFilterId'; TargetType = 'microsoft.intune.deviceandappmanagementassignmentfilter'; MatchBy = 'DisplayName (via the Prod ID)'; Reason = 'needs-filter'; Handler = 'special' }
    )
}
