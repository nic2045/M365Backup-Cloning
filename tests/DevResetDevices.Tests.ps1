# Devices in the factory reset (issue #46): kept by default; Remove, Retire, Wipe only when chosen; Wipe only with
# Dev.AllowDeviceWipe; protected devices (prefix, protected primary user) are never touched. Invented data only.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'M365Cloning.psd1') -Force
    $script:Base = "Prod=@{TenantId='tenant-prod-0001';ClientId='c';CertThumbprint='x'}; Dev=@{TenantId='tenant-dev-0001';ClientId='client-dev-0001';CertThumbprint='x';AllowReset=`$true;ProtectedDevicePrefixes=@('VMTEST-')}; BreakGlass=@('bg-user@dev.example'); ProtectedAccounts=@('dev.admin@dev.example')"

    function script:New-Config([string]$Text = $script:Base) {
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.psd1')
        Set-Content -LiteralPath $path -Value "@{ $Text }"
        Import-M365CloningConfig -Path $path
    }
    function script:New-Inventory {
        @{
            ProdGlobalAdmins = @(@{ id = 'prod-admin-0001'; userPrincipalName = 'admin.one@prod.example'; mail = 'admin.one@prod.example' })
            ProdReadError    = ''
            Dev              = @{
                Users                     = @(
                    @{ id = 'user-admin-0001'; userPrincipalName = 'dev.admin@dev.example'; mail = ''; userType = 'Member' }
                    @{ id = 'user-bg-0001'; userPrincipalName = 'bg-user@dev.example'; mail = ''; userType = 'Member' }
                    @{ id = 'guest-admin-0001'; userPrincipalName = 'admin.one_prod.example#EXT#@dev.example'; mail = 'admin.one@prod.example'; userType = 'Guest' }
                )
                Groups                    = @(); ConditionalAccessPolicies = @(); NamedLocations = @(); AuthenticationStrengths = @()
                DeviceConfigurations      = @(); DeviceCompliancePolicies = @(); ConfigurationPolicies = @(); Intents = @(); AssignmentFilters = @()
                ManagedDevices            = @(
                    @{ id = 'md-0001'; deviceName = 'LAPTOP-01'; operatingSystem = 'Windows'; userPrincipalName = 'tester@dev.example' }
                    @{ id = 'md-0002'; deviceName = 'LAPTOP-02'; operatingSystem = 'Windows'; userPrincipalName = '' }
                    @{ id = 'md-0003'; deviceName = 'VMTEST-07'; operatingSystem = 'Windows'; userPrincipalName = 'tester@dev.example' }
                    @{ id = 'md-0004'; deviceName = 'ADMIN-PC'; operatingSystem = 'Windows'; userPrincipalName = 'dev.admin@dev.example' }
                    @{ id = 'md-0005'; deviceName = 'BG-PHONE'; operatingSystem = 'iOS'; userPrincipalName = 'bg-user@dev.example' }
                )
                CrossTenantPartners       = @(); ToolkitServicePrincipals = @()
            }
        }
    }
    function script:Device($Plan, [string]$Name) { @($Plan['Actions'] | Where-Object { $_['ResourceType'] -eq 'ManagedDevice' -and $_['Name'] -eq $Name })[0] }
    function script:New-Writer {
        $writes = [System.Collections.Generic.List[object]]::new()
        $script:Writes = $writes
        { param($Method, $Uri, $Body, $TenantId, $Config) $writes.Add(@{ Method = $Method; Uri = $Uri; TenantId = $TenantId }); $null }.GetNewClosure()
    }
    function script:Read-Audit([string]$Root) {
        $path = Join-Path $Root 'audit.jsonl'
        if (Test-Path $path) { @(Get-Content -LiteralPath $path | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
    }
}

Describe 'Device options in the reset plan' {
    BeforeEach { $script:Config = script:New-Config }
    It 'keeps every device by default (Full and Align)' {
        $plan = New-DevResetPlan -Config $script:Config -Inventory (script:New-Inventory) -Mode Full
        (script:Device $plan 'LAPTOP-01')['Operation'] | Should -Be 'Keep'
        (script:Device $plan 'LAPTOP-01')['Status'] | Should -Be 'skipped'
        $plan['Summary']['Devices']['Keep'] | Should -Be 2
        $plan['Summary']['Devices']['Remove'] + $plan['Summary']['Devices']['Retire'] + $plan['Summary']['Devices']['Wipe'] | Should -Be 0
        $cmp = [pscustomobject]@{ Types = @() }
        $align = New-DevResetPlan -Config $script:Config -Inventory (script:New-Inventory) -Mode Align -Comparison $cmp
        (script:Device $align 'LAPTOP-02')['Operation'] | Should -Be 'Keep'
    }
    It 'plans Remove for all devices and Retire for one by name' {
        $plan = New-DevResetPlan -Config $script:Config -Inventory (script:New-Inventory) -Mode Full -DeviceAction Remove -DeviceActions @{ 'laptop-02' = 'retire' }
        (script:Device $plan 'LAPTOP-01')['Operation'] | Should -Be 'Delete'
        (script:Device $plan 'LAPTOP-01')['Status'] | Should -Be 'planned'
        (script:Device $plan 'LAPTOP-01')['Properties']['Id'] | Should -Be 'md-0001'
        (script:Device $plan 'LAPTOP-02')['Operation'] | Should -Be 'Retire'
    }
    It 'refuses Wipe without Dev.AllowDeviceWipe, by parameter and by file' {
        { New-DevResetPlan -Config $script:Config -Inventory (script:New-Inventory) -Mode Full -DeviceAction Wipe } | Should -Throw '*AllowDeviceWipe*'
        { New-DevResetPlan -Config $script:Config -Inventory (script:New-Inventory) -Mode Full -DeviceActions @{ 'LAPTOP-01' = 'Wipe' } } | Should -Throw '*AllowDeviceWipe*'
    }
    It 'plans Wipe when Dev.AllowDeviceWipe is $true' {
        $c = script:New-Config ($script:Base -replace 'AllowReset=\$true', 'AllowReset=$true;AllowDeviceWipe=$true')
        $plan = New-DevResetPlan -Config $c -Inventory (script:New-Inventory) -Mode Full -DeviceActions @{ 'LAPTOP-01' = 'Wipe' }
        (script:Device $plan 'LAPTOP-01')['Operation'] | Should -Be 'Wipe'
        (script:Device $plan 'LAPTOP-02')['Operation'] | Should -Be 'Keep'
    }
    It 'rejects an unknown device action' {
        { New-DevResetPlan -Config $script:Config -Inventory (script:New-Inventory) -Mode Full -DeviceActions @{ 'LAPTOP-01' = 'Burn' } } | Should -Throw '*not one of*'
    }
    It 'never plans an action for a device with a protected prefix, even when chosen' {
        $plan = New-DevResetPlan -Config $script:Config -Inventory (script:New-Inventory) -Mode Full -DeviceAction Remove -DeviceActions @{ 'VMTEST-07' = 'Retire' }
        (script:Device $plan 'VMTEST-07')['Status'] | Should -Be 'protected'
        (script:Device $plan 'VMTEST-07')['Operation'] | Should -Be 'Keep'
        @($plan['Protected'] | Where-Object { $_['Kind'] -eq 'Device' -and $_['Name'] -eq 'VMTEST-07' }).Count | Should -Be 1
    }
    It 'never plans an action for a device of a protected user (admin, break-glass)' {
        $plan = New-DevResetPlan -Config $script:Config -Inventory (script:New-Inventory) -Mode Full -DeviceAction Remove
        foreach ($n in 'ADMIN-PC', 'BG-PHONE') {
            (script:Device $plan $n)['Status'] | Should -Be 'protected'
            (script:Device $plan $n)['Operation'] | Should -Be 'Keep'
        }
        $plan['Summary']['Devices']['Protected'] | Should -Be 3
    }
    It 'notes a device action for a name that does not exist' {
        $plan = New-DevResetPlan -Config $script:Config -Inventory (script:New-Inventory) -Mode Full -DeviceActions @{ 'GHOST-99' = 'Remove' }
        @($plan['Notes'] | Where-Object { $_ -like '*GHOST-99*' }).Count | Should -Be 1
    }
    It 'rejects AllowDeviceWipe that is not a boolean' {
        { script:New-Config ($script:Base -replace 'AllowReset=\$true', "AllowReset=`$true;AllowDeviceWipe='yes'") } | Should -Throw '*AllowDeviceWipe*'
    }
}

Describe 'Device actions in Invoke-DevResetPlan' {
    BeforeEach {
        $script:Config = script:New-Config
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }
    It 'removes and retires the chosen devices last, Dev only, with an audit line per device' {
        $plan = New-DevResetPlan -Config $script:Config -Inventory (script:New-Inventory) -Mode Full -DeviceAction Remove -DeviceActions @{ 'LAPTOP-02' = 'Retire' }
        $w = script:New-Writer
        $r = Invoke-DevResetPlan -Plan $plan -Config $script:Config -ConfirmPlanHash (Get-ApplyPlanHash -Plan $plan) -ConfirmTenant 'tenant-dev-0001' -GraphWriter $w -HistoryRoot $script:Root
        $r.Failed | Should -Be 0
        $r.Deleted | Should -Be 1
        $r.Retired | Should -Be 1
        @($script:Writes | ForEach-Object { "$($_.Method) $($_.Uri)" }) | Should -Be @(
            'DELETE https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/md-0001'
            'POST https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/md-0002/retire'
        )
        @($script:Writes | Where-Object { $_.TenantId -ne 'tenant-dev-0001' }).Count | Should -Be 0
        $audit = script:Read-Audit $script:Root
        @($audit | Where-Object { $_.Reason -eq 'deleted ManagedDevice: LAPTOP-01' }).Count | Should -Be 1
        @($audit | Where-Object { $_.Reason -eq 'retired ManagedDevice: LAPTOP-02' }).Count | Should -Be 1
        ($audit | ConvertTo-Json -Depth 5) | Should -Not -Match 'md-000'
    }
    It 'runs the device step after the other steps' {
        $inv = script:New-Inventory
        $inv.Dev.AssignmentFilters = @(@{ id = 'flt-0001'; displayName = 'Filter Dev Only' })
        $plan = New-DevResetPlan -Config $script:Config -Inventory $inv -Mode Full -DeviceActions @{ 'LAPTOP-01' = 'Remove' }
        $w = script:New-Writer
        $null = Invoke-DevResetPlan -Plan $plan -Config $script:Config -ConfirmPlanHash (Get-ApplyPlanHash -Plan $plan) -ConfirmTenant 'tenant-dev-0001' -GraphWriter $w -HistoryRoot $script:Root
        $script:Writes[-1].Uri | Should -BeLike '*/managedDevices/md-0001'
        $script:Writes[0].Uri | Should -BeLike '*/assignmentFilters/flt-0001'
    }
    It 'refuses a plan that wipes when the config does not allow it' {
        $c = script:New-Config ($script:Base -replace 'AllowReset=\$true', 'AllowReset=$true;AllowDeviceWipe=$true')
        $plan = New-DevResetPlan -Config $c -Inventory (script:New-Inventory) -Mode Full -DeviceActions @{ 'LAPTOP-01' = 'Wipe' }
        $w = script:New-Writer
        { Invoke-DevResetPlan -Plan $plan -Config $script:Config -ConfirmPlanHash (Get-ApplyPlanHash -Plan $plan) -ConfirmTenant 'tenant-dev-0001' -GraphWriter $w -HistoryRoot $script:Root } | Should -Throw '*AllowDeviceWipe*'
        $script:Writes.Count | Should -Be 0
    }
    It 'wipes with Dev.AllowDeviceWipe' {
        $c = script:New-Config ($script:Base -replace 'AllowReset=\$true', 'AllowReset=$true;AllowDeviceWipe=$true')
        $plan = New-DevResetPlan -Config $c -Inventory (script:New-Inventory) -Mode Full -DeviceActions @{ 'LAPTOP-01' = 'Wipe' }
        $w = script:New-Writer
        $r = Invoke-DevResetPlan -Plan $plan -Config $c -ConfirmPlanHash (Get-ApplyPlanHash -Plan $plan) -ConfirmTenant 'tenant-dev-0001' -GraphWriter $w -HistoryRoot $script:Root
        $r.Wiped | Should -Be 1
        $script:Writes[0].Uri | Should -Be 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/md-0001/wipe'
    }
    It 'refuses a tampered plan that acts on a protected device' {
        $plan = New-DevResetPlan -Config $script:Config -Inventory (script:New-Inventory) -Mode Full
        $plan['Actions'] = [object[]]@($plan['Actions']) + @([ordered]@{ ResourceType = 'ManagedDevice'; Name = 'VMTEST-07'; Operation = 'Delete'; Status = 'planned'; Reason = 'x'; DscResource = ''; Differences = @(); Properties = [ordered]@{ Id = 'md-0003'; Kind = 'ManagedDevice' } })
        $w = script:New-Writer
        { Invoke-DevResetPlan -Plan $plan -Config $script:Config -ConfirmPlanHash (Get-ApplyPlanHash -Plan $plan) -ConfirmTenant 'tenant-dev-0001' -GraphWriter $w -HistoryRoot $script:Root } | Should -Throw '*protected device*'
        $script:Writes.Count | Should -Be 0
    }
}

Describe 'Device writes in the reset allow list' {
    BeforeAll {
        $script:C = script:New-Config
        $script:CW = script:New-Config ($script:Base -replace 'AllowReset=\$true', 'AllowReset=$true;AllowDeviceWipe=$true')
    }
    It 'blocks device writes without -DeviceWrites' {
        InModuleScope M365Cloning -Parameters @{ C = $script:C } {
            param($C)
            { Assert-DevResetWriteAllowed -Method DELETE -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/d-1' -TenantId 'tenant-dev-0001' -Config $C } | Should -Throw '*Blocked*'
            { Assert-DevResetWriteAllowed -Method POST -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/d-1/retire' -TenantId 'tenant-dev-0001' -Config $C } | Should -Throw '*Blocked*'
        }
    }
    It 'allows remove and retire with -DeviceWrites, wipe only with Dev.AllowDeviceWipe' {
        InModuleScope M365Cloning -Parameters @{ C = $script:C; CW = $script:CW } {
            param($C, $CW)
            { Assert-DevResetWriteAllowed -Method DELETE -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/d-1' -TenantId 'tenant-dev-0001' -Config $C -DeviceWrites } | Should -Not -Throw
            { Assert-DevResetWriteAllowed -Method POST -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/d-1/retire' -TenantId 'tenant-dev-0001' -Config $C -DeviceWrites } | Should -Not -Throw
            { Assert-DevResetWriteAllowed -Method POST -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/d-1/wipe' -TenantId 'tenant-dev-0001' -Config $C -DeviceWrites } | Should -Throw '*AllowDeviceWipe*'
            { Assert-DevResetWriteAllowed -Method POST -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/d-1/wipe' -TenantId 'tenant-dev-0001' -Config $CW -DeviceWrites } | Should -Not -Throw
        }
    }
    It 'blocks other device posts, bodies and the Prod tenant' {
        InModuleScope M365Cloning -Parameters @{ C = $script:C } {
            param($C)
            { Assert-DevResetWriteAllowed -Method POST -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/d-1/syncDevice' -TenantId 'tenant-dev-0001' -Config $C -DeviceWrites } | Should -Throw '*Blocked*'
            { Assert-DevResetWriteAllowed -Method POST -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/d-1/retire' -Body @{ x = 1 } -TenantId 'tenant-dev-0001' -Config $C -DeviceWrites } | Should -Throw '*body*'
            { Assert-DevResetWriteAllowed -Method DELETE -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/d-1' -TenantId 'tenant-prod-0001' -Config $C -DeviceWrites } | Should -Throw '*Blocked*'
            { Assert-DevResetWriteAllowed -Method POST -Uri 'https://graph.microsoft.com/v1.0/groups' -TenantId 'tenant-dev-0001' -Config $C -DeviceWrites } | Should -Throw '*Blocked*'
        }
    }
}

Describe 'Duplicate device names in the action file (issue #49)' {
    BeforeEach {
        $script:Config = script:New-Config
        $script:Inv = script:New-Inventory
        $script:Inv.Dev.ManagedDevices = @(
            @{ id = 'md-0101'; deviceName = 'SHARED-PC'; serialNumber = 'SN-AAA-0001'; operatingSystem = 'Windows'; userPrincipalName = '' }
            @{ id = 'md-0102'; deviceName = 'SHARED-PC'; serialNumber = 'SN-BBB-0002'; operatingSystem = 'Windows'; userPrincipalName = '' }
            @{ id = 'md-0103'; deviceName = 'SINGLE-PC'; serialNumber = 'SN-CCC-0003'; operatingSystem = 'Windows'; userPrincipalName = '' }
        )
        function script:Devices($Plan, [string]$Name) { @($Plan['Actions'] | Where-Object { $_['ResourceType'] -eq 'ManagedDevice' -and $_['Name'] -eq $Name }) }
    }
    It 'blocks Remove chosen by a name that belongs to two devices' {
        $plan = New-DevResetPlan -Config $script:Config -Inventory $script:Inv -Mode Full -DeviceActions @{ 'shared-pc' = 'Remove' }
        $both = script:Devices $plan 'SHARED-PC'
        $both.Count | Should -Be 2
        foreach ($a in $both) {
            $a['Status'] | Should -Be 'blocked'
            $a['Reason'] | Should -BeLike 'ambiguous device name*'
            $a['Properties'] | Should -BeNullOrEmpty
        }
        @($plan['Notes'] | Where-Object { $_ -like "*'SHARED-PC' belongs to 2 devices*" }).Count | Should -Be 1
        $plan['Summary']['Blocked'] | Should -BeGreaterThan 1
    }
    It 'blocks Retire and (with the switch) Wipe by a shared name, too' {
        $plan = New-DevResetPlan -Config $script:Config -Inventory $script:Inv -Mode Full -DeviceActions @{ 'SHARED-PC' = 'Retire' }
        @(script:Devices $plan 'SHARED-PC' | Where-Object { $_['Status'] -ne 'blocked' }).Count | Should -Be 0
        $c = script:New-Config ($script:Base -replace 'AllowReset=\$true', 'AllowReset=$true;AllowDeviceWipe=$true')
        $plan = New-DevResetPlan -Config $c -Inventory $script:Inv -Mode Full -DeviceActions @{ 'SHARED-PC' = 'Wipe' }
        @(script:Devices $plan 'SHARED-PC' | Where-Object { $_['Status'] -ne 'blocked' }).Count | Should -Be 0
    }
    It 'allows Keep by a shared name' {
        $plan = New-DevResetPlan -Config $script:Config -Inventory $script:Inv -Mode Full -DeviceActions @{ 'SHARED-PC' = 'Keep' }
        foreach ($a in (script:Devices $plan 'SHARED-PC')) {
            $a['Status'] | Should -Be 'skipped'
            $a['Operation'] | Should -Be 'Keep'
        }
    }
    It 'picks exactly one device by serial number' {
        $plan = New-DevResetPlan -Config $script:Config -Inventory $script:Inv -Mode Full -DeviceActions @{ 'sn-bbb-0002' = 'Retire' }
        $planned = @(script:Devices $plan 'SHARED-PC' | Where-Object { $_['Status'] -eq 'planned' })
        $planned.Count | Should -Be 1
        $planned[0]['Operation'] | Should -Be 'Retire'
        $planned[0]['Properties']['Id'] | Should -Be 'md-0102'
        @(script:Devices $plan 'SHARED-PC' | Where-Object { $_['Status'] -eq 'skipped' }).Count | Should -Be 1
    }
    It 'picks exactly one device by Intune device ID, before serial number and name' {
        $plan = New-DevResetPlan -Config $script:Config -Inventory $script:Inv -Mode Full -DeviceActions @{ 'md-0101' = 'Remove'; 'SHARED-PC' = 'Retire' }
        $byId = @(script:Devices $plan 'SHARED-PC' | Where-Object { $_['Properties'] -and $_['Properties']['Id'] -eq 'md-0101' })
        $byId.Count | Should -Be 1
        $byId[0]['Operation'] | Should -Be 'Delete'
        $byId[0]['Status'] | Should -Be 'planned'
        # the other device is only named by the shared name -> blocked
        @(script:Devices $plan 'SHARED-PC' | Where-Object { $_['Status'] -eq 'blocked' }).Count | Should -Be 1
    }
    It 'notes an unknown serial number and changes nothing' {
        $plan = New-DevResetPlan -Config $script:Config -Inventory $script:Inv -Mode Full -DeviceActions @{ 'SN-NOT-THERE' = 'Remove' }
        @($plan['Notes'] | Where-Object { $_ -like "*'SN-NOT-THERE' matches no device*" }).Count | Should -Be 1
        @($plan['Actions'] | Where-Object { $_['ResourceType'] -eq 'ManagedDevice' -and $_['Status'] -eq 'planned' }).Count | Should -Be 0
    }
    It 'keeps -DeviceAction for all devices working with shared names (noted, not blocked)' {
        $plan = New-DevResetPlan -Config $script:Config -Inventory $script:Inv -Mode Full -DeviceAction Remove
        @(script:Devices $plan 'SHARED-PC' | Where-Object { $_['Status'] -eq 'planned' -and $_['Operation'] -eq 'Delete' }).Count | Should -Be 2
        @($plan['Notes'] | Where-Object { $_ -like "*'SHARED-PC' belongs to 2 devices*" }).Count | Should -Be 1
    }
    It 'never writes for a blocked device' {
        $plan = New-DevResetPlan -Config $script:Config -Inventory $script:Inv -Mode Full -DeviceActions @{ 'SHARED-PC' = 'Remove' }
        $w = script:New-Writer
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = Invoke-DevResetPlan -Plan $plan -Config $script:Config -ConfirmPlanHash (Get-ApplyPlanHash -Plan $plan) -ConfirmTenant 'tenant-dev-0001' -GraphWriter $w -HistoryRoot $root
        @($script:Writes | Where-Object { $_.Uri -like '*managedDevices*' }).Count | Should -Be 0
    }
}

Describe 'Run check uses the device ID, not the name (issue #49)' {
    BeforeEach {
        $script:Config = script:New-Config
        $script:Inv = script:New-Inventory
        # A is protected through its primary user, B has the same name and is not protected.
        $script:Inv.Dev.ManagedDevices = @(
            @{ id = 'md-0201'; deviceName = 'TWIN-PC'; serialNumber = 'SN-TWIN-A'; operatingSystem = 'Windows'; userPrincipalName = 'dev.admin@dev.example' }
            @{ id = 'md-0202'; deviceName = 'TWIN-PC'; serialNumber = 'SN-TWIN-B'; operatingSystem = 'Windows'; userPrincipalName = '' }
        )
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }
    It 'runs an action for B by serial number and leaves the protected A untouched' {
        $plan = New-DevResetPlan -Config $script:Config -Inventory $script:Inv -Mode Full -DeviceActions @{ 'SN-TWIN-B' = 'Retire' }
        @($plan['Protected'] | Where-Object { $_['Kind'] -eq 'Device' -and $_['Id'] -eq 'md-0201' }).Count | Should -Be 1
        $w = script:New-Writer
        $r = Invoke-DevResetPlan -Plan $plan -Config $script:Config -ConfirmPlanHash (Get-ApplyPlanHash -Plan $plan) -ConfirmTenant 'tenant-dev-0001' -GraphWriter $w -HistoryRoot $script:Root
        $r.Retired | Should -Be 1
        @($script:Writes | ForEach-Object { "$($_.Method) $($_.Uri)" }) | Should -Be @('POST https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/md-0202/retire')
        @($script:Writes | Where-Object { $_.Uri -like '*md-0201*' }).Count | Should -Be 0
    }
    It 'keeps an action by the shared name blocked' {
        $plan = New-DevResetPlan -Config $script:Config -Inventory $script:Inv -Mode Full -DeviceActions @{ 'TWIN-PC' = 'Remove' }
        $twins = @($plan['Actions'] | Where-Object { $_['ResourceType'] -eq 'ManagedDevice' -and $_['Name'] -eq 'TWIN-PC' })
        @($twins | Where-Object { $_['Status'] -eq 'protected' }).Count | Should -Be 1
        @($twins | Where-Object { $_['Status'] -eq 'blocked' -and $_['Reason'] -like 'ambiguous device name*' }).Count | Should -Be 1
        @($twins | Where-Object { $_['Status'] -eq 'planned' }).Count | Should -Be 0
    }
    It 'refuses the run when a planned device action has no device ID' {
        $plan = New-DevResetPlan -Config $script:Config -Inventory $script:Inv -Mode Full -DeviceActions @{ 'SN-TWIN-B' = 'Retire' }
        foreach ($a in $plan['Actions']) { if ($a['ResourceType'] -eq 'ManagedDevice' -and $a['Status'] -eq 'planned') { $a['Properties'] = $null } }
        $w = script:New-Writer
        { Invoke-DevResetPlan -Plan $plan -Config $script:Config -ConfirmPlanHash (Get-ApplyPlanHash -Plan $plan) -ConfirmTenant 'tenant-dev-0001' -GraphWriter $w -HistoryRoot $script:Root } | Should -Throw '*no device ID*'
        $script:Writes.Count | Should -Be 0
    }
    It 'refuses the run when a protected device entry has no device ID' {
        $plan = New-DevResetPlan -Config $script:Config -Inventory $script:Inv -Mode Full -DeviceActions @{ 'SN-TWIN-B' = 'Retire' }
        foreach ($p in $plan['Protected']) { if ($p['Kind'] -eq 'Device') { $p['Id'] = '' } }
        $w = script:New-Writer
        { Invoke-DevResetPlan -Plan $plan -Config $script:Config -ConfirmPlanHash (Get-ApplyPlanHash -Plan $plan) -ConfirmTenant 'tenant-dev-0001' -GraphWriter $w -HistoryRoot $script:Root } | Should -Throw '*protected device has no device ID*'
        $script:Writes.Count | Should -Be 0
    }
}
