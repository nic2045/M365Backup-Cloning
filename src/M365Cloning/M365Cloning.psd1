@{
    RootModule        = 'M365Cloning.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '5b0c8f4e-7a58-4f0e-9a52-2f1d1d9b6c01'
    Author            = 'nic2045'
    Description       = 'Read-only drift report between a Prod and a Dev Microsoft 365 tenant (UTCM snapshots). See docs/adr/0001.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Import-M365CloningConfig'
        'Get-M365CloningCustomer'
        'Get-M365CloningDefaultResources'
        'New-UtcmSnapshot'
        'Wait-UtcmSnapshot'
        'Save-UtcmSnapshot'
        'Get-UtcmTenantSnapshot'
        'Read-UtcmSnapshotFile'
        'Compare-TenantSnapshot'
        'ConvertTo-DriftReportMarkdown'
        'Export-DriftReport'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
