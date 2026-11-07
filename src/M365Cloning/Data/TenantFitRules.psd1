# Rules of the suitability check (issue #39): is the Dev tenant enough to mirror Prod?
# Data only; Get-TenantFitAssessment reads it. Features are the 'Feature' names of Data\LicenceRequirements.psd1, so
# both checks use the same licence rules (Test-LicenceRuleApplies).
# Severity: 'red' = an equivalent tenant is needed, 'yellow' = Dev is enough with gaps, 'info' = shown, no effect.
# The overall result is the worst severity of all findings (red > yellow > green; info does not count).
# Thresholds are conservative: when something cannot be checked, the result is not green.
@{
    # A feature that Prod uses (or, without a Prod snapshot, that Prod is licensed for) and that Dev cannot provide.
    FeatureSeverity = @(
        @{
            Feature  = 'Microsoft Intune'
            Severity = 'red'
            Reason   = 'Intune is the core of the Dev mirror (configuration, compliance, apps from SW-Depoyment, enrolled test devices). Without it Dev cannot be a QA stage.'
        }
        @{
            Feature  = 'Conditional Access (Microsoft Entra ID P1)'
            Severity = 'red'
            Reason   = 'Without P1 no Conditional Access policy can be created or updated in Dev, so access behaviour cannot be tested like Prod.'
        }
    )
    # Every other used feature that Dev lacks: Dev is enough with gaps (these parts are blocked in the plan, #32).
    DefaultFeatureSeverity = 'yellow'
    DefaultFeatureReason   = 'This part of Prod cannot be mirrored to Dev; the apply plan blocks it (licence check, #32).'

    # A rule in LicenceRequirements without a confirmed service plan (warning only there).
    UnconfirmedRuleSeverity = 'info'

    # State of a Dev SKU (Learn: subscribedSku capabilityStatus). Plans of Suspended, Deleted or LockedOut SKUs do
    # not count as available (ConvertTo-TenantLicences); a missing core feature then gives red through FeatureSeverity.
    SkuStatus = @(
        @{ Status = 'Warning';   Severity = 'yellow'; Reason = 'Grace period: still usable, but the subscription expires soon.' }
        @{ Status = 'Suspended'; Severity = 'yellow'; Reason = 'Suspended: its service plans are not available any more.' }
        @{ Status = 'LockedOut'; Severity = 'yellow'; Reason = 'Locked out (subscription cancelled): its service plans are not available.' }
        @{ Status = 'Deleted';   Severity = 'yellow'; Reason = 'Deleted: its service plans are not available.' }
    )

    # Enough licences for the test users of DevUsers (Type TestUser). Admin guests are not counted: B2B guests are
    # billed by monthly active users (Learn: Microsoft Entra External ID pricing and billing; Entra licensing: External
    # ID core features free for the first 50,000 MAU).
    Capacity = @{
        ServicePlans = @('INTUNE_A', 'INTUNE_EDU', 'AAD_PREMIUM')
        Severity     = 'yellow'
        Reason       = 'Fewer free licence units in Dev than test users in DevUsers. Units already assigned to test users are not known, so this may be a false alarm; check before adding users.'
    }

    # A licence list that cannot be read: the result cannot be verified. Red is the careful choice: a scheduled run must
    # not report green or yellow when it did not see the licences.
    NotReadable = @{
        Severity = 'red'
        Reason   = 'The licence list could not be read, so the result is not verified (needs LicenseAssignment.Read.All).'
    }

    # No Prod snapshot: usage of Prod is unknown; every feature Prod is licensed for counts as used (careful choice).
    NoProdSnapshot = @{
        Severity = 'info'
        Reason   = 'No Prod snapshot given: every feature Prod is licensed for is treated as used.'
    }
}
