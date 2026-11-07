# Test fixture with invented values (no real tenant).
@{
    Prod = @{ TenantId = 'tenant-prod-0001'; ClientId = 'client-prod-0001'; CertThumbprint = 'thumb-prod-0001' }
    Dev  = @{ TenantId = 'tenant-dev-0001'; ClientId = 'client-dev-0001'; CertThumbprint = 'thumb-dev-0001'; AllowReset = $false; ApplyAllowed = $false }
    BreakGlass = @('bg-user-0001')
    BreakGlassGroups = @('BG-Group')
    ProtectedAccounts = @('admin-0001')
}
