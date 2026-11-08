# What the setup check (issue #18, scripts/Invoke-SetupCheck.ps1) expects of an instance. Read only: the check
# compares, it never grants, creates or changes anything.
# Sources (Microsoft Learn, checked 2026-11-08): "Set up authentication for Tenant Configuration Management APIs"
# (utcm-authentication-setup: app IDs of the TCM and M365 Admin Services principals, ConfigurationMonitoring.ReadWrite.All
# for snapshots), "List subscribedSkus" (LicenseAssignment.Read.All), "Get servicePrincipal" (Application.Read.All),
# "Get user" (User.Read.All), "List groups" (Group.Read.All). The permissions of the features are the ones named in
# validation/README.md.
@{
    # Microsoft's public application IDs (the same in every tenant; not tenant data).
    UtcmAppId          = '03b07b79-c5bc-4b5e-9bfa-13acf4a99998'
    AdminServicesAppId = '6b91db1b-f05b-405a-a0b2-e3f60b28d645'
    GraphAppId         = '00000003-0000-0000-c000-000000000000'

    # A certificate that ends within this many days is yellow.
    CertificateWarnDays = 30
    # A suitability check older than this many days is yellow (same limit as the drift report, issue #63).
    LicenceStaleDays    = 7

    # Application permissions of the app registration of each tenant (the 'roles' of its token).
    # Required: missing = red. Features: missing = yellow, with the feature that needs it.
    Prod = @{
        Required = @(
            @{ Permission = 'ConfigurationMonitoring.ReadWrite.All'; For = 'UTCM snapshot of Prod (drift report)' }
            @{ Permission = 'LicenseAssignment.Read.All'; For = 'suitability check (licences of Prod)' }
        )
        Features = @(
            @{ Permission = 'RoleManagement.Read.Directory'; For = 'reset and Dev users: the Global Administrators of Prod' }
            @{ Permission = 'DeviceManagementConfiguration.Read.All'; For = 'Intune backup with IntuneCD' }
            @{ Permission = 'Application.Read.All'; For = 'setup check: the UTCM service principal' }
        )
        # Prod is read only (ADR 0001). Any permission with a write part is red, except these (the snapshot call
        # needs the write-named permission, the tool only sends createSnapshot; guard in Invoke-UtcmGraphRequest).
        AllowedWrite = @('ConfigurationMonitoring.ReadWrite.All')
    }
    Dev = @{
        Required = @(
            @{ Permission = 'ConfigurationMonitoring.ReadWrite.All'; For = 'UTCM snapshot of Dev (drift report)' }
            @{ Permission = 'LicenseAssignment.Read.All'; For = 'suitability check and licence check of a plan' }
        )
        Features = @(
            @{ Permission = 'Group.ReadWrite.All'; For = 'base state: persona and break-glass groups' }
            @{ Permission = 'Policy.ReadWrite.ConditionalAccess'; For = 'apply Conditional Access (Report-only)' }
            @{ Permission = 'Policy.ReadWrite.CrossTenantAccess'; For = 'base state: Prod as cross-tenant partner' }
            @{ Permission = 'DeviceManagementConfiguration.ReadWrite.All'; For = 'apply the Intune configuration' }
            @{ Permission = 'DeviceManagementManagedDevices.ReadWrite.All'; For = 'reset: remove devices' }
            @{ Permission = 'User.ReadWrite.All'; For = 'Dev users: test users' }
            @{ Permission = 'User.Invite.All'; For = 'Dev users: invite the Prod admins as guests' }
            @{ Permission = 'GroupMember.ReadWrite.All'; For = 'Dev users: put them into their persona group' }
            @{ Permission = 'Application.Read.All'; For = 'setup check: the UTCM service principal' }
        )
    }
}
