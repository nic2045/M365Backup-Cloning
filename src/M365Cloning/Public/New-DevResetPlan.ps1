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
        intents), assignment filters, groups, and in Full mode the test users of the positive list (DevUsers,
        Type TestUser). Never deleted: devices (listed only), guests, synced users and groups, other member users,
        Microsoft 365 groups and role-assignable groups (listed as skipped), licences, domains, role definitions,
        app registrations, the cross-tenant access settings and cross-tenant sync.
        Protection list (shown in the preview with its source): ProtectedAccounts, BreakGlass, ServiceAccounts and
        BreakGlassGroups of the config, the Global Administrators of Prod without the break-glass accounts (and their
        B2B guests in Dev), all guests in Dev, the toolkit's app in Dev, the cross-tenant partners, the groups of the
        base state (Get-DevBaselineDefinition). The plan refuses (throws) when Prod could not be read, when Prod has
        no Global Administrator, when the config protects no account, or when no protected account exists in Dev.
        A Prod Global Administrator without a guest in Dev is listed as 'Invite' (info): add it to DevUsers as
        AdminGuest and run scripts/Invoke-DevUsers.ps1 (the reset never invites).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)]$Inventory,
        [ValidateSet('Align', 'Full')][string]$Mode = 'Align',
        $Comparison
    )

    foreach ($side in 'Prod', 'Dev') {
        if (-not $Config.Contains($side) -or $Config[$side] -isnot [System.Collections.IDictionary] -or
            [string]::IsNullOrWhiteSpace([string]$Config[$side]['TenantId'])) { throw "Config has no $side tenant ID." }
    }
    if ([string]$Config['Dev']['TenantId'] -eq [string]$Config['Prod']['TenantId']) {
        throw 'The target tenant ID equals the Prod tenant ID. Refused: the reset runs in the Dev tenant only.'
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

    # --- Dev-only names from the drift report (mode Align) ---
    $category = @{
        ConditionalAccessPolicy = 'ca'; Group = 'group'; AssignmentFilter = 'filter'; DeviceCompliancePolicy = 'compliance'
        DeviceConfiguration = 'intune'; ConfigurationPolicy = 'intune'; Intent = 'intune'
    }
    $devOnly = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($Mode -eq 'Align') {
        foreach ($t in @(& $get $Comparison 'Types')) {
            $type = ([string](& $get $t 'ResourceType')).ToLowerInvariant()
            $cat = switch -Wildcard ($type) {
                'microsoft.entra.conditionalaccesspolicy' { 'ca'; break }
                'microsoft.entra.group' { 'group'; break }
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
    $rank = @{ ConditionalAccessPolicy = 0; DeviceConfiguration = 1; DeviceCompliancePolicy = 1; ConfigurationPolicy = 1; Intent = 1; AssignmentFilter = 2; Group = 3; User = 4 }
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

    foreach ($d in (& $devList 'ManagedDevices')) {
        & $add 'ManagedDevice' ([string](& $get $d 'deviceName')) 'None' 'skipped' 'devices are never deleted by the reset; retire or wipe by hand if needed' $null
    }
    foreach ($name in $invites) {
        & $add 'Invite' $name 'Invite' 'info' 'Global Administrator of Prod without a guest in Dev: add it to DevUsers as AdminGuest and run scripts/Invoke-DevUsers.ps1 (the reset never invites)' $null
    }

    # Delete order: CA, Intune policies, filters, groups, users; then the listed entries. Within that by name (ordinal).
    $keyed = [System.Collections.Generic.List[object]]::new()
    foreach ($a in $actions) {
        $r = if ($a['Operation'] -eq 'Delete') { $rank[[string]$a['ResourceType']] } else { 9 }
        $keyed.Add([pscustomobject]@{ Key = ('{0}|{1}|{2}' -f $r, [string]$a['ResourceType'], [string]$a['Name']); Action = $a })
    }
    $keyed.Sort([System.Comparison[object]] { param($x, $y) [string]::CompareOrdinal($x.Key, $y.Key) })
    $sorted = [object[]]@($keyed | ForEach-Object { $_.Action })
    $prot = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $protected) { $prot.Add([pscustomobject]@{ Key = ('{0}|{1}|{2}' -f $p['Kind'], $p['Source'], $p['Name']); Item = $p }) }
    $prot.Sort([System.Comparison[object]] { param($x, $y) [string]::CompareOrdinal($x.Key, $y.Key) })

    $notes.Add('Deleted users, groups and Conditional Access policies stay in the deleted items for 30 days and can be restored; the reset never empties them.')
    $notes.Add('Policies, filters, groups and users are deleted in this order; a failure stops the later steps.')
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
        }
    }
}
