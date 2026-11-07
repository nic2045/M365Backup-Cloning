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
    # Accounts that are never touched (admins, service accounts, break-glass).
    ProtectedAccounts = @('<upn-or-object-id>')
    # Optional: override the resource types of the snapshot (see Get-M365CloningDefaultResources).
    # Resources = @('microsoft.entra.conditionalaccesspolicy')
}
