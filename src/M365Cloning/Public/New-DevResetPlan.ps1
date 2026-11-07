function New-DevResetPlan {
    <#
    .SYNOPSIS
        Pure function: plan of the factory reset of the Dev tenant (issue #7, ADR 0005). Writes nothing, calls nothing.
    .DESCRIPTION
        Two modes with the same protection rules and confirmations:
          Align (default, the careful one): deletes only objects in the reset scope that exist in Dev but not in Prod,
                according to the drift report (-Comparison, Compare-TenantSnapshot: 'Removed' = in Dev, missing in
                Prod). Everything else is kept; the apply (scripts/Invoke-ApplyDev.ps1) then aligns what differs.
                Objects whose type the drift report does not cover are kept.
          Full: deletes everything in the reset scope except the protection list and the base state, so that Dev can
                be rebuilt in a controlled way (baseline -> apply -> users).
        Reset scope: Conditional Access policies, Intune configuration profiles and update rings
        (deviceConfigurations), compliance policies, settings catalog / endpoint security (configurationPolicies,
        intents), assignment filters, custom named locations and custom authentication strengths (issue #33; deleted
        after the policies that use them), groups, and in Full mode the test users of the positive list (DevUsers,
        Type TestUser). Devices (issue #46): kept by default; -DeviceAction (all devices) or -DeviceActions (per device,
        keyed by Intune device ID, serial number or name; a name shared by several devices blocks Remove, Retire and Wipe, #49) choose Keep, Remove (delete the Intune object), Retire (remove company data) or Wipe (only when
        Dev.AllowDeviceWipe = $true). Protected and never touched: devices whose name starts with one of
        Dev.ProtectedDevicePrefixes (for example the Intune VM test devices) and devices whose primary user is on the
        protection list. Device actions run last, after every other step succeeded. Never deleted: guests, synced users and groups, other member users,
        Microsoft 365 groups and role-assignable groups (listed as skipped), licences, domains, role definitions,
        app registrations, the cross-tenant access settings and cross-tenant sync.
        Protection list (shown in the preview with its source): ProtectedAccounts, BreakGlass, ServiceAccounts and
        BreakGlassGroups of the config, the Global Administrators of Prod without the break-glass accounts (and their
        B2B guests in Dev), all guests in Dev, the toolkit's app in Dev, the cross-tenant partners, the groups of the
        base state (Get-DevBaselineDefinition), the named locations that a break-glass Conditional Access policy uses
        (a policy that includes a BreakGlass account or a BreakGlassGroups group). Trusted named locations are kept
        (Learn: a trusted location cannot be deleted before its trusted mark is removed; the reset does not change it);
        built-in authentication strengths are never touched. The plan refuses (throws) when Prod could not be read, when Prod has
        no Global Administrator, when the config protects no account, or when no protected account exists in Dev.
        A Prod Global Administrator without a guest in Dev is listed as 'Invite' (info): add it to DevUsers as
        AdminGuest and run scripts/Invoke-DevUsers.ps1 (the reset never invites).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)]$Inventory,
        [ValidateSet('Align', 'Full')][string]$Mode = 'Align',
        $Comparison,
        [ValidateSet('Keep', 'Remove', 'Retire', 'Wipe')][string]$DeviceAction = 'Keep',
        [System.Collections.IDictionary]$DeviceActions
    )

    foreach ($side in 'Prod', 'Dev') {
        if (-not $Config.Contains($side) -or $Config[$side] -isnot [System.Collections.IDictionary] -or
            [string]::IsNullOrWhiteSpace([string]$Config[$side]['TenantId'])) { throw "Config has no $side tenant ID." }
    }
    if ([string]$Config['Dev']['TenantId'] -eq [string]$Config['Prod']['TenantId']) {
        throw 'The target tenant ID equals the Prod tenant ID. Refused: the reset runs in the Dev tenant only.'
    }
    $allowedDeviceActions = 'Keep', 'Remove', 'Retire', 'Wipe'
    $perDevice = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($DeviceActions) {
        foreach ($k in $DeviceActions.Keys) {
            $v = [string]$DeviceActions[$k]
            $match = $allowedDeviceActions | Where-Object { $_ -ieq $v } | Select-Object -First 1
            if (-not $match) { throw "Device action '$v' for '$k' is not one of: $($allowedDeviceActions -join ', ')." }
            $perDevice[[string]$k] = $match
        }
    }
    if (($DeviceAction -eq 'Wipe' -or $perDevice.Values -contains 'Wipe') -and $Config['Dev']['AllowDeviceWipe'] -ne $true) {
        throw 'Wipe refused: set Dev.AllowDeviceWipe = $true in the config to allow wiping devices (off by default).'
    }
    if ($Mode -eq 'Align' -and $null -eq $Comparison) { throw 'Mode Align needs the drift report (-Comparison, Compare-TenantSnapshot of Prod and Dev).' }

    $get = {
        param($o, [string]$k)
        if ($null -eq $o) { return $null }
        if ($o -is [System.Collections.IDictionary]) { if ($o.Contains($k)) { return $o[$k] } else { return $null } }
        $p = $o.PSObject.Properties[$k]
        if ($p) { $p.Value } else { $null }
    }
    $list = { param($k) $cfg = & $get $Config $k; if ($null -eq $cfg) { @() } else { @($cfg | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ }) } }

    # --- Prod must be readable: its Global Administrators are protected in Dev ---
    # Read without a function return in between, so that an empty list stays an empty list and is not taken for $null.
    $prodAdmins = $null
    if ($Inventory -is [System.Collections.IDictionary]) { if ($Inventory.Contains('ProdGlobalAdmins')) { $prodAdmins = $Inventory['ProdGlobalAdmins'] } }
    elseif ($Inventory.PSObject.Properties['ProdGlobalAdmins']) { $prodAdmins = $Inventory.PSObject.Properties['ProdGlobalAdmins'].Value }
    if ($null -eq $prodAdmins) {
        $why = [string](& $get $Inventory 'ProdReadError')
        throw "Reset refused: the Global Administrators of Prod could not be read$(if ($why) { " ($why)" }). Nothing is deleted without them on the protection list."
    }
    $prodAdmins = @($prodAdmins)
    if ($prodAdmins.Count -eq 0) { throw 'Reset refused: Prod returned no Global Administrator; the protection list would be incomplete.' }

    $dev = & $get $Inventory 'Dev'
    $devList = { param($k) $v = & $get $dev $k; if ($null -eq $v) { @() } else { @($v) } }

    $protected = [System.Collections.Generic.List[object]]::new()
    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $addAccount = {
        param([string]$Name, [string]$Source, [string[]]$Keys)
        $protected.Add([ordered]@{ Kind = 'Account'; Name = $Name; Source = $Source })
        foreach ($k in $Keys) { if (-not [string]::IsNullOrWhiteSpace($k)) { $null = $ids.Add($k) } }
    }
    $breakGlass = & $list 'BreakGlass'
    $configAccounts = 0
    foreach ($a in (& $list 'ProtectedAccounts')) { & $addAccount $a 'config: ProtectedAccounts' @($a); $configAccounts++ }
    foreach ($a in $breakGlass) { & $addAccount $a 'config: BreakGlass' @($a); $configAccounts++ }
    foreach ($a in (& $list 'ServiceAccounts')) { & $addAccount $a 'config: ServiceAccounts' @($a) }
    if ($configAccounts -eq 0) { throw 'Reset refused: the config protects no account (ProtectedAccounts or BreakGlass).' }

    $users = & $devList 'Users'
    $guests = @($users | Where-Object { [string](& $get $_ 'userType') -ieq 'Guest' })
    $notes = [System.Collections.Generic.List[string]]::new()
    $invites = [System.Collections.Generic.List[object]]::new()
    foreach ($admin in $prodAdmins) {
        $upn = [string](& $get $admin 'userPrincipalName'); $mail = [string](& $get $admin 'mail')
        $name = if ($upn) { $upn } else { [string](& $get $admin 'id') }
        if ($breakGlass | Where-Object { $_ -ieq $upn -or ($mail -and $_ -ieq $mail) }) { continue }
        & $addAccount $name 'Prod: Global Administrator' @($upn, $mail)
        $guest = @($guests | Where-Object { $m = [string](& $get $_ 'mail'); $m -and ($m -ieq $mail -or $m -ieq $upn) }) | Select-Object -First 1
        if ($guest) { & $addAccount ([string](& $get $guest 'userPrincipalName')) 'Dev: B2B guest of a Prod Global Administrator' @([string](& $get $guest 'id'), [string](& $get $guest 'userPrincipalName')) }
        else { $invites.Add($name) }
    }
    $isProtectedUser = {
        param($u)
        foreach ($k in 'id', 'userPrincipalName', 'mail') { $v = [string](& $get $u $k); if ($v -and $ids.Contains($v)) { return $true } }
        $false
    }
    # Lockout check: at least one protected account must exist in Dev.
    if (-not @($users | Where-Object { [string](& $get $_ 'userType') -ine 'Guest' -and (& $isProtectedUser $_) }) -and
        -not @($guests | Where-Object { & $isProtectedUser $_ })) {
        throw 'Reset refused: none of the protected accounts exists in Dev; after the reset nobody could be sure to sign in.'
    }

    foreach ($g in $guests) {
        $null = $ids.Add([string](& $get $g 'id'))
        $protected.Add([ordered]@{ Kind = 'Account'; Name = [string](& $get $g 'userPrincipalName'); Source = 'Dev: guest (guests are never deleted)' })
    }
    foreach ($sp in (& $devList 'ToolkitServicePrincipals')) {
        $protected.Add([ordered]@{ Kind = 'App'; Name = [string](& $get $sp 'displayName'); Source = 'Dev: app registration of this toolkit' })
    }
    foreach ($p in (& $devList 'CrossTenantPartners')) {
        $protected.Add([ordered]@{ Kind = 'Partner'; Name = [string](& $get $p 'tenantId'); Source = 'Dev: cross-tenant access partner and cross-tenant sync (kept)' })
    }
    $groupNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($g in (Get-DevBaselineDefinition -Config $Config)['Groups']) {
        if ($groupNames.Add([string]$g['Name'])) { $protected.Add([ordered]@{ Kind = 'Group'; Name = [string]$g['Name']; Source = "base state ($($g['Kind']))" }) }
    }

    # Named locations of break-glass Conditional Access policies (issue #33): a policy that includes a break-glass
    # account or group keeps the locations it names, so the emergency path still works after the reset.
    $bgIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($b in $breakGlass) { $null = $bgIds.Add($b) }
    foreach ($u in $users) {
        foreach ($k in 'userPrincipalName', 'mail', 'id') {
            $v = [string](& $get $u $k)
            if ($v -and ($breakGlass | Where-Object { $_ -ieq $v })) { $null = $bgIds.Add([string](& $get $u 'id')); break }
        }
    }
    $bgGroupNames = & $list 'BreakGlassGroups'
    foreach ($g in (& $devList 'Groups')) {
        if ($bgGroupNames | Where-Object { $_ -ieq [string](& $get $g 'displayName') }) { $null = $bgIds.Add([string](& $get $g 'id')) }
    }
    $protectedLocationIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in (& $devList 'ConditionalAccessPolicies')) {
        $cond = & $get $p 'conditions'
        $usersCond = & $get $cond 'users'
        $targets = @(@(& $get $usersCond 'includeUsers') + @(& $get $usersCond 'includeGroups')) | Where-Object { $_ }
        if (-not ($targets | Where-Object { $bgIds.Contains([string]$_) })) { continue }
        $locCond = & $get $cond 'locations'
        foreach ($l in @(@(& $get $locCond 'includeLocations') + @(& $get $locCond 'excludeLocations'))) {
            if ($l -and [string]$l -notin 'All', 'AllTrusted') { $null = $protectedLocationIds.Add([string]$l) }
        }
    }
    foreach ($loc in (& $devList 'NamedLocations')) {
        if ($protectedLocationIds.Contains([string](& $get $loc 'id'))) {
            $protected.Add([ordered]@{ Kind = 'NamedLocation'; Name = [string](& $get $loc 'displayName'); Source = 'Dev: named location of a break-glass Conditional Access policy' })
        }
    }

    # --- Dev-only names from the drift report (mode Align) ---
    $category = @{
        ConditionalAccessPolicy = 'ca'; Group = 'group'; AssignmentFilter = 'filter'; DeviceCompliancePolicy = 'compliance'
        DeviceConfiguration = 'intune'; ConfigurationPolicy = 'intune'; Intent = 'intune'
        NamedLocation = 'location'; AuthenticationStrength = 'authstrength'
    }
    $devOnly = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($Mode -eq 'Align') {
        foreach ($t in @(& $get $Comparison 'Types')) {
            $type = ([string](& $get $t 'ResourceType')).ToLowerInvariant()
            $cat = switch -Wildcard ($type) {
                'microsoft.entra.conditionalaccesspolicy' { 'ca'; break }
                'microsoft.entra.group' { 'group'; break }
                'microsoft.entra.namedlocationpolicy' { 'location'; break }
                'microsoft.entra.authenticationstrengthpolicy' { 'authstrength'; break }
                '*assignmentfilter' { 'filter'; break }
                'microsoft.intune.devicecompliancepolicy*' { 'compliance'; break }
                'microsoft.intune.roledefinition' { ''; break }
                'microsoft.intune.*' { 'intune'; break }
                default { ''; break }
            }
            if (-not $cat) { continue }
            foreach ($n in @(& $get $t 'Removed')) { if ($n) { $null = $devOnly.Add("$cat|$n") } }
        }
    }

    $actions = [System.Collections.Generic.List[object]]::new()
    $rank = @{ ConditionalAccessPolicy = 0; NamedLocation = 1; AuthenticationStrength = 1; DeviceConfiguration = 1; DeviceCompliancePolicy = 1; ConfigurationPolicy = 1; Intent = 1; AssignmentFilter = 2; Group = 3; User = 4 }
    $add = {
        param([string]$Kind, [string]$Name, [string]$Operation, [string]$Status, [string]$Reason, [string]$Id)
        $actions.Add([ordered]@{
                ResourceType = $Kind; Name = $Name; Operation = $Operation; Status = $Status; Reason = $Reason
                DscResource = ''; Differences = [object[]]@(); Properties = $(if ($Id) { [ordered]@{ Id = $Id; Kind = $Kind } } else { $null })
            })
    }
    $consider = {
        param([string]$Kind, [string]$Name, [string]$Id, [string]$WhyDelete)
        if ($Mode -eq 'Align' -and -not $devOnly.Contains("$($category[$Kind])|$Name")) {
            & $add $Kind $Name 'Keep' 'skipped' 'not only in Dev (or not in the drift report): kept, the apply aligns it' $null
            return
        }
        & $add $Kind $Name 'Delete' 'planned' $WhyDelete $Id
    }
    $why = if ($Mode -eq 'Align') { 'only in Dev, not in Prod' } else { 'in the reset scope (Full)' }

    foreach ($p in (& $devList 'ConditionalAccessPolicies')) { & $consider 'ConditionalAccessPolicy' ([string](& $get $p 'displayName')) ([string](& $get $p 'id')) "$why; switched off first, then deleted" }
    foreach ($p in (& $devList 'DeviceConfigurations')) { & $consider 'DeviceConfiguration' ([string](& $get $p 'displayName')) ([string](& $get $p 'id')) $why }
    foreach ($p in (& $devList 'DeviceCompliancePolicies')) { & $consider 'DeviceCompliancePolicy' ([string](& $get $p 'displayName')) ([string](& $get $p 'id')) $why }
    foreach ($p in (& $devList 'ConfigurationPolicies')) { & $consider 'ConfigurationPolicy' ([string](& $get $p 'name')) ([string](& $get $p 'id')) $why }
    foreach ($p in (& $devList 'Intents')) { & $consider 'Intent' ([string](& $get $p 'displayName')) ([string](& $get $p 'id')) $why }
    foreach ($loc in (& $devList 'NamedLocations')) {
        $name = [string](& $get $loc 'displayName')
        if ($protectedLocationIds.Contains([string](& $get $loc 'id'))) { continue }   # protected: listed in Protected, never an action
        if ((& $get $loc 'isTrusted') -eq $true) { & $add 'NamedLocation' $name 'Keep' 'skipped' 'trusted named location: kept (remove the trusted mark by hand first if it should go; the reset does not change it)' $null; continue }
        & $consider 'NamedLocation' $name ([string](& $get $loc 'id')) "$why; after the Conditional Access policies that use it"
    }
    foreach ($st in (& $devList 'AuthenticationStrengths')) {
        if ([string](& $get $st 'policyType') -ieq 'builtIn') { continue }   # built-in: exists in every tenant, never touched
        & $consider 'AuthenticationStrength' ([string](& $get $st 'displayName')) ([string](& $get $st 'id')) "$why; after the Conditional Access policies that use it"
    }
    foreach ($p in (& $devList 'AssignmentFilters')) { & $consider 'AssignmentFilter' ([string](& $get $p 'displayName')) ([string](& $get $p 'id')) "$why; after the policies that use it" }

    foreach ($g in (& $devList 'Groups')) {
        $name = [string](& $get $g 'displayName')
        if ($groupNames.Contains($name)) { continue }   # protected: listed in Protected, never an action
        if ((& $get $g 'onPremisesSyncEnabled') -eq $true) { & $add 'Group' $name 'Keep' 'skipped' 'synced from on-premises: never deleted' $null; continue }
        if (@(& $get $g 'groupTypes') -contains 'Unified') { & $add 'Group' $name 'Keep' 'skipped' 'Microsoft 365 group (mailbox, site, team): not deleted by the reset, delete by hand if wanted' $null; continue }
        if ((& $get $g 'isAssignableToRole') -eq $true) { & $add 'Group' $name 'Keep' 'skipped' 'role-assignable group: not deleted by the reset' $null; continue }
        & $consider 'Group' $name ([string](& $get $g 'id')) "$why; goes to the deleted items (restorable for 30 days)"
    }

    $testUsers = @(@(& $get $Config 'DevUsers') | Where-Object { $_ -and [string](& $get $_ 'Type') -eq 'TestUser' } | ForEach-Object { [string](& $get $_ 'Id') })
    foreach ($u in $users) {
        if ([string](& $get $u 'userType') -ieq 'Guest') { continue }   # guests are protected
        if (& $isProtectedUser $u) { continue }                          # protected: never an action
        $upn = [string](& $get $u 'userPrincipalName')
        if ((& $get $u 'onPremisesSyncEnabled') -eq $true) { & $add 'User' $upn 'Keep' 'skipped' 'synced from on-premises: never deleted' $null; continue }
        if (-not ($testUsers | Where-Object { $_ -ieq $upn })) { & $add 'User' $upn 'Keep' 'skipped' 'not a test user of the positive list (DevUsers): never deleted by the reset' $null; continue }
        if ($Mode -eq 'Align') { & $add 'User' $upn 'Keep' 'skipped' 'test users are kept in Align mode (Full deletes them; Invoke-DevUsers creates them again)' $null; continue }
        & $add 'User' $upn 'Delete' 'planned' 'test user of the positive list (Full); goes to the deleted items (restorable for 30 days), created again by scripts/Invoke-DevUsers.ps1' ([string](& $get $u 'id'))
    }

    # Devices (issue #46): kept unless an action is chosen; protected devices are never touched.
    $prefixes = @(@(& $get $Config['Dev'] 'ProtectedDevicePrefixes') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    $deviceOp = @{ Keep = 'Keep'; Remove = 'Delete'; Retire = 'Retire'; Wipe = 'Wipe' }
    $deviceWhy = @{
        Remove = 'chosen: remove the device object from Intune (the device itself is not changed)'
        Retire = 'chosen: retire, company apps, profiles and data are removed at the next check-in, personal data stays'
        Wipe   = 'chosen: wipe, the device is reset to factory settings at the next check-in (Dev.AllowDeviceWipe)'
    }
    # A key in -DeviceActions names a device by Intune device ID, serial number (managedDevice.serialNumber, Learn:
    # graph/api/resources/intune-devices-manageddevice) or device name, matched in that order. A name that belongs to
    # more than one device cannot pick one device: Remove, Retire and Wipe chosen by such a name are blocked (#49);
    # Keep stays allowed. -DeviceAction for all devices still applies to every device; duplicate names are only noted.
    $devices = @(& $devList 'ManagedDevices')
    $nameCount = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $serialCount = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($d in $devices) {
        $n = [string](& $get $d 'deviceName'); if (-not $n) { $n = [string](& $get $d 'id') }
        $nameCount[$n] = 1 + $(if ($nameCount.ContainsKey($n)) { $nameCount[$n] } else { 0 })
        $sn = [string](& $get $d 'serialNumber')
        if ($sn) { $serialCount[$sn] = 1 + $(if ($serialCount.ContainsKey($sn)) { $serialCount[$sn] } else { 0 }) }
    }
    $usedKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $nameCount.Keys) {
        if ($nameCount[$n] -gt 1) { $notes.Add("Device name '$n' belongs to $($nameCount[$n]) devices. Name them by serial number or Intune device ID in -DeviceActionFile; a remove, retire or wipe chosen by this name is blocked.") }
    }
    foreach ($d in $devices) {
        $name = [string](& $get $d 'deviceName'); if (-not $name) { $name = [string](& $get $d 'id') }
        $devId = [string](& $get $d 'id')
        $serial = [string](& $get $d 'serialNumber')
        $owner = [string](& $get $d 'userPrincipalName')
        $prefix = $prefixes | Where-Object { $name.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        $why = $null
        if ($prefix) { $why = "config: ProtectedDevicePrefixes ('$prefix')" }
        elseif ($owner -and $ids.Contains($owner)) { $why = "primary user on the protection list ($owner)" }
        # Which key of the action file names this device (ID before serial before name).
        $key = $null; $keyKind = $null
        if ($devId -and $perDevice.ContainsKey($devId)) { $key = $devId; $keyKind = 'id' }
        elseif ($serial -and $perDevice.ContainsKey($serial)) { $key = $serial; $keyKind = 'serial' }
        elseif ($perDevice.ContainsKey($name)) { $key = $name; $keyKind = 'name' }
        if ($key) { $null = $usedKeys.Add($key) }
        if ($why) {
            $protected.Add([ordered]@{ Kind = 'Device'; Name = $name; Source = $why })
            & $add 'ManagedDevice' $name 'Keep' 'protected' "protected device, never touched: $why" $null
            continue
        }
        $choice = if ($key) { $perDevice[$key] } else { $DeviceAction }
        if ($choice -eq 'Keep') {
            & $add 'ManagedDevice' $name 'Keep' 'skipped' 'kept (default); choose -DeviceAction or -DeviceActionFile to remove, retire or wipe' $null
            continue
        }
        $ambiguous = ($keyKind -eq 'name' -and $nameCount[$name] -gt 1) -or ($keyKind -eq 'serial' -and $serialCount[$serial] -gt 1)
        if ($ambiguous) {
            $what = if ($keyKind -eq 'name') { "name '$name'" } else { "serial number '$serial'" }
            & $add 'ManagedDevice' $name $deviceOp[$choice] 'blocked' "ambiguous device name: the $what belongs to more than one device; name the device by serial number or Intune device ID in -DeviceActionFile" $null
            continue
        }
        & $add 'ManagedDevice' $name $deviceOp[$choice] 'planned' $deviceWhy[$choice] $devId
    }
    foreach ($k in $perDevice.Keys) {
        if (-not $usedKeys.Contains($k)) { $notes.Add("Device action for '$k' matches no device in Dev (by device ID, serial number or name); ignored.") }
    }
    foreach ($name in $invites) {
        & $add 'Invite' $name 'Invite' 'info' 'Global Administrator of Prod without a guest in Dev: add it to DevUsers as AdminGuest and run scripts/Invoke-DevUsers.ps1 (the reset never invites)' $null
    }

    # Delete order: CA, Intune policies, filters, groups, users; then the listed entries. Within that by name (ordinal).
    $keyed = [System.Collections.Generic.List[object]]::new()
    foreach ($a in $actions) {
        $r = if ($a['ResourceType'] -eq 'ManagedDevice' -and $a['Status'] -eq 'planned') { 5 }
        elseif ($a['Operation'] -eq 'Delete') { $rank[[string]$a['ResourceType']] } else { 9 }
        $keyed.Add([pscustomobject]@{ Key = ('{0}|{1}|{2}' -f $r, [string]$a['ResourceType'], [string]$a['Name']); Action = $a })
    }
    $keyed.Sort([System.Comparison[object]] { param($x, $y) [string]::CompareOrdinal($x.Key, $y.Key) })
    $sorted = [object[]]@($keyed | ForEach-Object { $_.Action })
    $prot = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $protected) { $prot.Add([pscustomobject]@{ Key = ('{0}|{1}|{2}' -f $p['Kind'], $p['Source'], $p['Name']); Item = $p }) }
    $prot.Sort([System.Comparison[object]] { param($x, $y) [string]::CompareOrdinal($x.Key, $y.Key) })

    $notes.Add('Deleted users, groups and Conditional Access policies stay in the deleted items for 30 days and can be restored; the reset never empties them.')
    $notes.Add('Conditional Access policies, then named locations and authentication strengths, then Intune policies, filters, groups and users are deleted in this order; a failure stops the later steps.')
    $notes.Add('Device actions (remove, retire, wipe) run last and only when every earlier step succeeded: retire and wipe cannot be undone. Retire and wipe take effect at the next check-in of the device.')
    if ($Mode -eq 'Align') { $notes.Add('Align: after the reset run scripts/Invoke-ApplyDev.ps1 to align what differs (or -RebuildAfter).') }
    else { $notes.Add('Full: rebuild with -RebuildAfter (baseline -> apply -> users, each with its own plan and confirmation).') }
    $count = { param($status) @($sorted | Where-Object { $_['Status'] -eq $status }).Count }
    [ordered]@{
        Direction      = "Factory reset of Dev ($Mode)"
        Title          = "Dev reset plan, mode $Mode (preview, nothing was changed)"
        ApplyHint      = "scripts/Invoke-DevReset.ps1 -Mode $Mode -Apply -ConfirmPlanHash <hash above> -ConfirmTenant <Dev tenant ID>"
        Mode           = $Mode
        TargetTenantId = [string]$Config['Dev']['TenantId']
        Actions        = $sorted
        Protected      = [object[]]@($prot | ForEach-Object { $_.Item })
        Notes          = [string[]]@($notes)
        Summary        = [ordered]@{
            Planned   = [int](& $count 'planned')
            Blocked   = [int](& $count 'blocked')
            Skipped   = [int](& $count 'skipped')
            Invite    = [int](& $count 'info')
            Protected = [int]$protected.Count
            Devices   = [ordered]@{
                Keep      = [int]@($sorted | Where-Object { $_['ResourceType'] -eq 'ManagedDevice' -and $_['Status'] -eq 'skipped' }).Count
                Protected = [int]@($sorted | Where-Object { $_['ResourceType'] -eq 'ManagedDevice' -and $_['Status'] -eq 'protected' }).Count
                Remove    = [int]@($sorted | Where-Object { $_['ResourceType'] -eq 'ManagedDevice' -and $_['Status'] -eq 'planned' -and $_['Operation'] -eq 'Delete' }).Count
                Retire    = [int]@($sorted | Where-Object { $_['ResourceType'] -eq 'ManagedDevice' -and $_['Status'] -eq 'planned' -and $_['Operation'] -eq 'Retire' }).Count
                Wipe      = [int]@($sorted | Where-Object { $_['ResourceType'] -eq 'ManagedDevice' -and $_['Status'] -eq 'planned' -and $_['Operation'] -eq 'Wipe' }).Count
            }
        }
    }
}
