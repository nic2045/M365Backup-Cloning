# Which Microsoft service plan a Dev write needs (issue #32). Data only; Get-LicenceRequirementMap reads it.
# A requirement is met when ANY of its ServicePlans is in the tenant with provisioningStatus 'Success' in a SKU whose
# capabilityStatus is 'Enabled' or 'Warning' (Get-TenantLicences).
# Service plan names and IDs: Learn 'Product names and service plan identifiers for licensing'
#   https://learn.microsoft.com/entra/identity/users/licensing-service-plan-reference
#   AAD_PREMIUM 41781fb2-bc02-4b7c-bd55-b576c07bb09d (Microsoft Entra ID P1)
#   AAD_PREMIUM_P2 eec0eb4f-6444-4f95-aba0-50c24d67f998 (Microsoft Entra ID P2)
#   INTUNE_A c1ec4a95-1f05-45b3-a911-aa3fa01094f5 (Microsoft Intune Plan 1)
#   INTUNE_EDU da24caf9-af8e-485c-b7c8-e73336da2693 (Intune for Education)
# Rules are checked in order; every matching rule applies. 'Match' is a -like pattern on the resource type.
# 'WhenAnyProperty' (optional): the rule only applies when one of these properties of the planned action is not empty.
# 'ServicePlans = @()' marks a requirement that Learn does not confirm: it gives a warning only, never a block.
@{
    Rules = @(
        @{
            Feature      = 'Microsoft Intune'
            Match        = 'microsoft.intune.*'
            ServicePlans = @('INTUNE_A', 'INTUNE_EDU')
            Source       = 'https://learn.microsoft.com/intune/fundamentals/planning-guide (Intune is needed to deploy policies and profiles); plan names from licensing-service-plan-reference'
        }
        @{
            Feature      = 'Conditional Access (Microsoft Entra ID P1)'
            Match        = 'microsoft.entra.conditionalaccesspolicy'
            ServicePlans = @('AAD_PREMIUM')
            Source       = 'https://learn.microsoft.com/entra/fundamentals/licensing#microsoft-entra-conditional-access (P1; with expired licences policies can no longer be updated)'
        }
        @{
            Feature         = 'Risk-based Conditional Access (Microsoft Entra ID P2)'
            Match           = 'microsoft.entra.conditionalaccesspolicy'
            WhenAnyProperty = @('SignInRiskLevels', 'UserRiskLevels')
            ServicePlans    = @('AAD_PREMIUM_P2')
            Source          = 'https://learn.microsoft.com/entra/identity/conditional-access/overview#license-requirements (sign-in and user risk need ID Protection, a P2 feature); property names from https://learn.microsoft.com/graph/utcm-entra-resources#conditionalaccesspolicy-resource-type'
        }
        @{
            Feature      = 'Named locations (part of Conditional Access, Microsoft Entra ID P1)'
            Match        = 'microsoft.entra.namedlocationpolicy'
            ServicePlans = @('AAD_PREMIUM')
            Source       = 'https://learn.microsoft.com/entra/fundamentals/licensing#microsoft-entra-conditional-access (named locations are a Conditional Access condition)'
        }
        @{
            Feature      = 'Authentication strengths (part of Conditional Access, Microsoft Entra ID P1)'
            Match        = 'microsoft.entra.authenticationstrengthpolicy'
            ServicePlans = @('AAD_PREMIUM')
            Source       = 'https://learn.microsoft.com/entra/fundamentals/licensing#microsoft-entra-conditional-access (authentication strength is a Conditional Access grant control)'
        }
        @{
            Feature      = 'Custom Microsoft Entra roles (Microsoft Entra ID P1)'
            Match        = 'microsoft.entra.roledefinition'
            ServicePlans = @('AAD_PREMIUM')
            Source       = 'https://learn.microsoft.com/entra/fundamentals/licensing#role-based-access-control (custom roles need P1)'
        }
        @{
            Feature      = 'Privileged Identity Management (Microsoft Entra ID P2)'
            Match        = 'microsoft.entra.roleeligibilityschedulerequest'
            ServicePlans = @('AAD_PREMIUM_P2')
            Source       = 'https://learn.microsoft.com/entra/fundamentals/licensing#microsoft-entra-privileged-identity-management (P2 or ID Governance; the Governance plan name is not checked, so only P2 is accepted)'
        }
        @{
            Feature      = 'Cross-tenant access, automatic redemption (Microsoft Entra ID P1 in the target tenant)'
            Match        = 'microsoft.entra.crosstenantaccesspolicyconfigurationpartner'
            ServicePlans = @('AAD_PREMIUM')
            Source       = 'https://learn.microsoft.com/entra/fundamentals/licensing#multitenant-organizations (at least one P1 licence in the target tenant to enable autoredemption)'
        }
        @{
            Feature      = 'Terms of use'
            Match        = 'microsoft.entra.termsofuse*'
            ServicePlans = @()
            Source       = 'not confirmed on Learn (checked 2026-11-07): warning only'
        }
    )
}
