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
        # Reset and apply only run against the Dev tenant ID above, and only when this is $true.
        AllowReset     = $false
    }
    # Accounts that are never touched (admins, service accounts, break-glass).
    ProtectedAccounts = @('<upn-or-object-id>')
    # Optional: override the resource types of the snapshot (see Get-M365CloningDefaultResources).
    # Resources = @('microsoft.entra.conditionalaccesspolicy')
}
