# Contract test fixture with invented values (no real tenant): config.valid.psd1 plus a DevUsers list,
# so every plan kind (apply, baseline, reset, users) can be produced offline.
@{
    Prod = @{ TenantId = 'tenant-prod-0001'; ClientId = 'client-prod-0001'; CertThumbprint = 'thumb-prod-0001' }
    Dev  = @{ TenantId = 'tenant-dev-0001'; ClientId = 'client-dev-0001'; CertThumbprint = 'thumb-dev-0001'; AllowReset = $false; ApplyAllowed = $false }
    BreakGlass = @('bg-user-0001')
    BreakGlassGroups = @('BG-Group')
    ProtectedAccounts = @('admin-0001')
    DevUsers = @(
        @{ Type = 'TestUser'; Id = 'test.internal@dev.example'; Persona = 'Internals'; DisplayName = 'Test Internals 01' }
        @{ Type = 'AdminGuest'; Id = 'admin.one@prod.example'; Persona = 'Admins' }
    )
}
