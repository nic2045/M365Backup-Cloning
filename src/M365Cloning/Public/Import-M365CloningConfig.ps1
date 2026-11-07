function Import-M365CloningConfig {
    <#
    .SYNOPSIS
        Loads and validates config.psd1 (see config.example.psd1): exactly one Prod/Dev pair.
    .DESCRIPTION
        Optional: Dev.ApplyAllowed (bool, default false), BreakGlass (users) and BreakGlassGroups (group names),
        PersonaPrefix (string), Personas (list of persona names) and PersonaMap (persona -> exact group name(s)),
        see Get-PersonaSettings and ADR 0003. DevUsers (positive list for issue #22) and InviteRedirectUrl, see
        config.example.psd1. Baseline (Dev base state, issue #8), see Get-DevBaselineDefinition.
        Rejects a config without a Prod or Dev tenant, with placeholders such as '<prod-tenant-guid>'
        still in it, with identical Prod and Dev tenant IDs, or with the old 'Customers' list.
        -AllowPlaceholders is only for tests with the example file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowPlaceholders
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Config not found: $Path (copy config.example.psd1 to config.psd1)"
    }
    $config = Import-PowerShellDataFile -LiteralPath $Path

    if ($config.ContainsKey('Customers')) {
        throw "The 'Customers' list is not supported: one instance of this toolkit serves one Prod/Dev pair. Use Prod and Dev at the top level."
    }

    $isPlaceholder = { param($v) [string]::IsNullOrWhiteSpace([string]$v) -or [string]$v -match '^\s*<.*>\s*$' }

    foreach ($side in 'Prod', 'Dev') {
        if (-not $config.ContainsKey($side) -or $config[$side] -isnot [hashtable]) {
            throw "The $side tenant is missing (a Prod/Dev pair is required)."
        }
        foreach ($key in 'TenantId', 'ClientId', 'CertThumbprint') {
            if (-not $AllowPlaceholders -and (& $isPlaceholder $config[$side][$key])) {
                throw "$side.$key is empty or still a placeholder."
            }
        }
    }
    if (-not $AllowPlaceholders -and $config.Prod.TenantId -eq $config.Dev.TenantId) {
        throw 'Prod and Dev have the same TenantId.'
    }

    # Apply (ADR 0001): off unless Dev.ApplyAllowed is $true; the break-glass accounts are used for Conditional Access.
    if ($config.Dev.ContainsKey('ApplyAllowed') -and $config.Dev.ApplyAllowed -isnot [bool]) {
        throw 'Dev.ApplyAllowed must be $true or $false.'
    }
    # Factory reset (ADR 0005): off unless Dev.AllowReset is $true.
    if ($config.Dev.ContainsKey('AllowReset') -and $config.Dev.AllowReset -isnot [bool]) {
        throw 'Dev.AllowReset must be $true or $false.'
    }
    # Devices in the reset (issue #46): wipe is off unless Dev.AllowDeviceWipe is $true; protected device prefixes.
    if ($config.Dev.ContainsKey('AllowDeviceWipe') -and $config.Dev.AllowDeviceWipe -isnot [bool]) {
        throw 'Dev.AllowDeviceWipe must be $true or $false.'
    }
    if ($config.Dev.ContainsKey('ProtectedDevicePrefixes') -and $null -ne $config.Dev.ProtectedDevicePrefixes) {
        foreach ($entry in @($config.Dev.ProtectedDevicePrefixes)) {
            if ($entry -isnot [string] -or [string]::IsNullOrWhiteSpace($entry)) { throw 'Dev.ProtectedDevicePrefixes must be a list of non-empty strings.' }
            if (-not $AllowPlaceholders -and $entry -match '^\s*<.*>\s*$') { throw 'Dev.ProtectedDevicePrefixes still contains a placeholder.' }
        }
    }
    foreach ($listName in 'BreakGlass', 'BreakGlassGroups', 'ServiceAccounts', 'ProtectedAccounts') {
        if ($config.ContainsKey($listName) -and $null -ne $config[$listName]) {
            foreach ($entry in @($config[$listName])) {
                if ($entry -isnot [string]) { throw "$listName must be a list of strings." }
                if (-not $AllowPlaceholders -and $entry -match '^\s*<.*>\s*$') { throw "$listName still contains a placeholder." }
            }
        }
    }

    # Persona settings for Conditional Access (ADR 0003)
    if ($config.ContainsKey('PersonaPrefix') -and ($config.PersonaPrefix -isnot [string] -or [string]::IsNullOrWhiteSpace($config.PersonaPrefix))) {
        throw 'PersonaPrefix must be a non-empty string.'
    }
    if ($config.ContainsKey('Personas') -and $null -ne $config.Personas) {
        foreach ($p in @($config.Personas)) {
            if ($p -isnot [string] -or $p -notmatch '^[A-Za-z0-9]+$') { throw "Personas must be a list of names made of letters and digits (got '$p')." }
        }
    }
    if ($config.ContainsKey('PersonaMap') -and $null -ne $config.PersonaMap) {
        if ($config.PersonaMap -isnot [hashtable]) { throw 'PersonaMap must be a table: persona = group name or list of group names.' }
        foreach ($persona in $config.PersonaMap.Keys) {
            if ([string]$persona -notmatch '^[A-Za-z0-9]+$') { throw "PersonaMap: the persona name '$persona' may contain letters and digits only." }
            foreach ($name in @($config.PersonaMap[$persona])) {
                if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name)) { throw "PersonaMap '$persona' must contain group names (strings)." }
                if (-not $AllowPlaceholders -and $name -match '^\s*<.*>\s*$') { throw "PersonaMap '$persona' still contains a placeholder." }
            }
        }
    }
    # Dev users (issue #22): positive list of test users and admins invited as guests, each with exactly one persona.
    if ($config.ContainsKey('DevUsers') -and $null -ne $config.DevUsers) {
        $settings = Get-PersonaSettings -Config $config
        $known = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($p in $settings.Personas) { $null = $known.Add($p) }
        foreach ($p in $settings.Map.Keys) { $null = $known.Add([string]$p) }
        $breakGlass = @(if ($config.ContainsKey('BreakGlass') -and $null -ne $config.BreakGlass) { @($config.BreakGlass) })
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($u in @($config.DevUsers)) {
            if ($u -isnot [hashtable]) { throw 'DevUsers must be a list of tables: @{ Type = ...; Id = ...; Persona = ... }.' }
            if ([string]$u.Type -notin 'TestUser', 'AdminGuest') { throw "DevUsers: Type must be 'TestUser' or 'AdminGuest' (got '$($u.Type)')." }
            $id = [string]$u.Id
            if ([string]::IsNullOrWhiteSpace($id)) { throw 'DevUsers: every entry needs an Id (UPN for TestUser, mail address for AdminGuest).' }
            if (-not $AllowPlaceholders -and (& $isPlaceholder $id)) { throw "DevUsers: '$id' is still a placeholder." }
            if (-not ($id -match '^\s*<.*>\s*$') -and $id -notmatch '^[^@\s]+@[^@\s]+$') { throw "DevUsers: '$id' is not a UPN or mail address." }
            if (-not $seen.Add($id)) { throw "DevUsers: '$id' is listed more than once." }
            if ($breakGlass | Where-Object { [string]$_ -ieq $id }) { throw "DevUsers: '$id' is a break-glass account; break-glass accounts are never created or changed." }
            if (@($u.Persona).Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]@($u.Persona)[0])) { throw "DevUsers: '$id' needs exactly one Persona." }
            $persona = [string]@($u.Persona)[0]
            if ($persona -ieq 'BreakGlass') { throw "DevUsers: '$id' cannot get the persona BreakGlass." }
            if (-not $known.Contains($persona)) { throw "DevUsers: the persona '$persona' of '$id' is unknown (Personas or PersonaMap)." }
        }
    }
    if ($config.ContainsKey('InviteRedirectUrl') -and $null -ne $config.InviteRedirectUrl -and [string]$config.InviteRedirectUrl -notmatch '^https://') {
        throw 'InviteRedirectUrl must be an https URL.'
    }
    # Dev base state (issue #8, Get-DevBaselineDefinition): all keys optional.
    if ($config.ContainsKey('Baseline') -and $null -ne $config.Baseline) {
        if ($config.Baseline -isnot [hashtable]) { throw 'Baseline must be a table: @{ PersonaGroups = ...; ExclusionGroups = ...; CrossTenantPartner = ... }.' }
        foreach ($key in $config.Baseline.Keys) {
            if ([string]$key -notin 'PersonaGroups', 'ExclusionGroups', 'CrossTenantPartner') { throw "Baseline: unknown key '$key' (PersonaGroups, ExclusionGroups, CrossTenantPartner)." }
        }
        foreach ($key in 'PersonaGroups', 'CrossTenantPartner') {
            if ($config.Baseline.ContainsKey($key) -and $config.Baseline[$key] -isnot [bool]) { throw "Baseline.$key must be `$true or `$false." }
        }
        if ($config.Baseline.ContainsKey('ExclusionGroups') -and $null -ne $config.Baseline.ExclusionGroups) {
            foreach ($name in @($config.Baseline.ExclusionGroups)) {
                if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name)) { throw 'Baseline.ExclusionGroups must be a list of group names.' }
                if (-not $AllowPlaceholders -and $name -match '^\s*<.*>\s*$') { throw 'Baseline.ExclusionGroups still contains a placeholder.' }
            }
        }
    }
    # Copy all (ADR 0006, issue #40): workloads that are on, and types the operator excludes in addition.
    $workloads = @('Entra', 'Intune', 'Exchange', 'Teams', 'SecurityAndCompliance')
    if ($config.ContainsKey('Workloads') -and $null -ne $config.Workloads) {
        foreach ($w in @($config.Workloads)) {
            if ($w -isnot [string] -or $workloads -notcontains $w) { throw "Workloads: unknown workload '$w' ($($workloads -join ', '))." }
        }
    }
    if ($config.ContainsKey('ExcludeResourceTypes') -and $null -ne $config.ExcludeResourceTypes) {
        $names = if ($config.ExcludeResourceTypes -is [hashtable]) { @($config.ExcludeResourceTypes.Keys) } else { @($config.ExcludeResourceTypes) }
        foreach ($t in $names) {
            if ($t -isnot [string] -or $t -notmatch '^microsoft\.[a-z0-9]+\.[a-z0-9]+$') { throw "ExcludeResourceTypes: '$t' is not a resource type name like 'microsoft.intune.devicecategory'." }
        }
    }
    $config
}
