# Copy to config.psd1 (git-ignored) and fill in. One Dev/Prod pair per customer.
# Placeholders only: never commit real IDs, names or certificate data.
@{
    Customers = @(
        @{
            Name = '<customer-name>'
            Prod = @{
                TenantId       = '<prod-tenant-guid>'
                ClientId       = '<read-only-app-registration-guid>'
                CertThumbprint = '<certificate-thumbprint>'
            }
            Dev  = @{
                TenantId       = '<dev-tenant-guid>'
                ClientId       = '<dev-app-registration-guid>'
                CertThumbprint = '<certificate-thumbprint>'
                # Reset and apply only run against tenant IDs listed here.
                AllowReset     = $false
            }
            # Accounts that are never touched (admins, service accounts, break-glass).
            ProtectedAccounts = @('<upn-or-object-id>')
        }
    )
}
