# Copy to config.psd1 (git-ignored) and fill in. One Prod/Dev pair: your own tenants.
# Placeholders only: never commit real IDs, names or certificate data.
@{
    Prod = @{
        TenantId       = '<prod-tenant-guid>'
        ClientId       = '<read-only-app-registration-guid>'
        CertThumbprint = '<certificate-thumbprint>'
    }
    Dev  = @{
        TenantId       = '<dev-tenant-guid>'
        ClientId       = '<dev-app-registration-guid>'
        CertThumbprint = '<certificate-thumbprint>'
        # Reset only runs against the Dev tenant ID above, and only when this is $true.
        AllowReset     = $false
        # Apply (scripts/Invoke-ApplyDev.ps1 -Apply) only runs against the Dev tenant ID above, and only when this is $true.
        ApplyAllowed   = $false
    }
    # Break-glass accounts: always excluded from every Conditional Access policy that is applied to Dev.
    # Users (UPN) and groups (display name). Without them no Conditional Access policy is applied.
    BreakGlass       = @('<break-glass-upn>')
    BreakGlassGroups = @()
    # Conditional Access personas (ADR 0003). Real Prod policies are copied to Dev; the groups they refer to are
    # created in Dev as static, EMPTY groups with the same name. A group is recognised as persona group by the
    # prefix + persona name (CA-Persona-Admins, CA-Persona-Admins-BaseProtection-Exclusions) or by PersonaMap.
    PersonaPrefix = 'CA-Persona-'
    Personas      = @('Admins', 'Internals', 'Externals', 'Guests', 'Microsoft365ServiceAccounts')
    # PersonaMap maps a persona to the exact names of your Prod groups when they do not follow the prefix:
    # PersonaMap = @{ Admins = @('<your-admin-group-name>') }
    PersonaMap    = @{}
    # Dev users (scripts/Invoke-DevUsers.ps1): positive list. TestUser = cloud account created in Dev (Id = UPN with a
    # verified domain of the Dev tenant); AdminGuest = admin from Prod invited as B2B guest (Id = mail address).
    # Persona = exactly one active persona (Personas or PersonaMap). Break-glass accounts must not be listed.
    # Each account is put into the empty Dev group of its persona. Nothing is ever removed.
    DevUsers = @(
        @{ Type = 'TestUser';   Id = '<test-user-upn>';       Persona = 'Internals'; DisplayName = 'Test Internals 01' }
        @{ Type = 'AdminGuest'; Id = '<prod-admin-mail>';     Persona = 'Admins' }
    )
    # Where an invited guest lands after redeeming (https). Default: https://myapps.microsoft.com
    # InviteRedirectUrl = 'https://myapps.microsoft.com'
    # Dev base state (scripts/Invoke-DevBaseline.ps1, issue #8). All keys optional; the defaults are shown.
    # Always included: the break-glass groups (BreakGlassGroups and CA-BreakglassAccounts), static and empty.
    Baseline = @{
        # One static, empty group per active persona (Personas / PersonaMap), e.g. CA-Persona-Admins.
        PersonaGroups      = $true
        # Extra exclusion groups (ADR 0003), each with a recognisable persona, e.g. 'CA-Persona-Admins-BaseProtection-Exclusions'.
        ExclusionGroups    = @()
        # The Prod tenant as partner in the cross-tenant access settings of Dev: B2B collaboration inbound allowed,
        # inbound invitations redeemed automatically (invited Prod admins get no consent prompt). No cross-tenant sync.
        CrossTenantPartner = $true
    }
    # Accounts that are never touched (admins, service accounts, break-glass). The factory reset
    # (scripts/Invoke-DevReset.ps1, ADR 0005) also keeps the Global Administrators of Prod (their guests in Dev),
    # all guests and the base state; it refuses to run when this list and BreakGlass are both empty.
    ProtectedAccounts = @('<upn-or-object-id>')
    # Service accounts in Dev that the reset never deletes (UPN or object ID).
    ServiceAccounts   = @()
    # Optional: override the resource types of the snapshot (see Get-M365CloningDefaultResources).
    # Resources = @('microsoft.entra.conditionalaccesspolicy')
}
