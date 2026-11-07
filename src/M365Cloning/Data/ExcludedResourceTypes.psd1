# Resource types that are never copied Prod -> Dev (ADR 0006, issue #40). Data only; Get-ResourceTypeCatalog reads it.
# Each entry: type = reason. The operator can add types in config.psd1 (ExcludeResourceTypes); entries here cannot be
# switched back on from the configuration (remove them here, with a reason in the pull request, to copy a type).
# Excluded types are not requested in the default snapshot. When a snapshot contains one anyway (Resources in the
# configuration), the plan shows each object as 'skipped' with a reason that starts with 'excluded:'.
# Types with their own path stay out of this list: the authentication method policies are report-only
# (Get-DscResourceMap), the secret-bearing profiles are 'skipped: secret' (ResourceRules.psd1).
@{
    Types = @{
        # Tenant-wide singletons: one object per tenant, they change sign-in, consent or lifecycle for everyone.
        'microsoft.entra.securitydefaults'                              = 'tenant-wide security defaults; switching them can lock users out or turn off Conditional Access'
        'microsoft.entra.authorizationpolicy'                           = 'tenant-wide authorization policy (default user permissions, consent); one per tenant'
        'microsoft.entra.tenantdetails'                                 = 'tenant details (name, contacts, notification addresses) belong to each tenant'
        'microsoft.entra.externalidentitypolicy'                        = 'tenant-wide external identity policy; one per tenant'
        'microsoft.entra.groupssettings'                                = 'tenant-wide group settings; one per tenant'
        'microsoft.entra.groupsnamingpolicy'                            = 'tenant-wide group naming policy; one per tenant'
        'microsoft.entra.grouplifecyclepolicy'                          = 'tenant-wide group expiry: it can delete groups in Dev'
        'microsoft.intune.devicecleanuprule'                            = 'tenant-wide device clean-up rule: it removes devices in Dev'
        # Own path in the base configuration (issue #8), never copied from Prod.
        'microsoft.entra.crosstenantaccesspolicy'                       = 'cross-tenant access is set by the base configuration (Invoke-DevBaseline), not copied'
        'microsoft.entra.crosstenantaccesspolicyconfigurationdefault'   = 'cross-tenant access is set by the base configuration (Invoke-DevBaseline), not copied'
        'microsoft.entra.crosstenantaccesspolicyconfigurationpartner'   = 'cross-tenant access is set by the base configuration (Invoke-DevBaseline), not copied'
        # Identities and their credentials: users are not mirrored (#22), applications carry secrets and tenant IDs.
        'microsoft.entra.user'                                          = 'users are not mirrored; test users and admin guests come from the positive list (Invoke-DevUsers)'
        'microsoft.entra.application'                                   = 'app registrations carry credentials and tenant-specific redirect and owner data'
        'microsoft.entra.serviceprincipal'                              = 'service principals belong to the app registrations and consents of each tenant'
        'microsoft.entra.socialidentityprovider'                        = 'identity providers carry client secrets'
        'microsoft.entra.administrativeunit'                            = 'administrative units hold members and scoped role members (identities)'
        # Roles and PIM: only role definitions are copied until issue #4 decides on assignments.
        'microsoft.entra.roleeligibilityschedulerequest'                = 'PIM eligibility names principals; roles and PIM wait for issue #4'
        'microsoft.entra.rolesetting'                                   = 'PIM role settings; roles and PIM wait for issue #4'
        'microsoft.intune.roleassignment'                               = 'Intune role assignments name members and scopes; roles wait for issue #4'
        # Entitlement management names identities (approvers, connected organisations, resources of the tenant).
        'microsoft.entra.entitlementmanagementaccesspackage'                    = 'entitlement management refers to identities and resources of the tenant'
        'microsoft.entra.entitlementmanagementaccesspackageassignmentpolicy'    = 'entitlement management refers to identities and resources of the tenant'
        'microsoft.entra.entitlementmanagementaccesspackagecatalog'             = 'entitlement management refers to identities and resources of the tenant'
        'microsoft.entra.entitlementmanagementaccesspackagecatalogresource'     = 'entitlement management refers to identities and resources of the tenant'
        'microsoft.entra.entitlementmanagementconnectedorganization'            = 'entitlement management refers to identities and resources of the tenant'
        # Tenant-wide token lifetimes: a default policy applies to every sign-in.
        'microsoft.entra.tokenlifetimepolicy'                           = 'token lifetime policies can apply tenant-wide to every sign-in'
        # Tenant-specific onboarding package.
        'microsoft.intune.deviceconfigurationdefenderforendpointonboardingpolicywindows10' = 'the Defender for Endpoint onboarding package belongs to the tenant of the Defender instance'
    }
}
