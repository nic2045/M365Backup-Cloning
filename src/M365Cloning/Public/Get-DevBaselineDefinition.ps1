function Get-DevBaselineDefinition {
    <#
    .SYNOPSIS
        The documented base state of the Dev tenant (issue #8), built from the config. Pure, calls nothing.
    .DESCRIPTION
        The base state is described in the config (section 'Baseline', all keys optional) and not in a second file,
        because everything it names already lives there (persona settings, break-glass groups, the Prod tenant ID)
        and config.psd1 is git-ignored and checked by Import-M365CloningConfig.
          PersonaGroups      : $true (default) = one static, empty group per active persona (Get-PersonaGroupName)
          ExclusionGroups    : extra group names, e.g. 'CA-Persona-Admins-BaseProtection-Exclusions' (ADR 0003);
                               each must have a recognisable persona (Resolve-PersonaOfGroup), otherwise the plan
                               blocks it
          CrossTenantPartner : $true (default) = the Prod tenant is a partner in the cross-tenant access settings of
                               Dev: B2B collaboration inbound allowed, inbound invitations redeemed automatically
                               (no consent prompt for the admins invited as guests, issue #22)
        Always part of the base state: the break-glass groups (BreakGlassGroups and the default emergency group).
        Not part of it: app registrations and certificates (setup wizard, #18), cross-tenant synchronisation (#21),
        the Dev users of the positive list (scripts/Invoke-DevUsers.ps1, #22; only referenced, never created twice).
        Returns @{ Groups = @(@{ Name; Persona; Kind }); Partner = $null or @{ PartnerTenantId }; Notes = @() }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    $baseline = if ($Config.Contains('Baseline') -and $Config['Baseline'] -is [System.Collections.IDictionary]) { $Config['Baseline'] } else { @{} }
    $flag = { param($key) if ($baseline.Contains($key) -and $null -ne $baseline[$key]) { [bool]$baseline[$key] } else { $true } }
    $settings = Get-PersonaSettings -Config $Config

    $groups = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $addGroup = {
        param([string]$Name, [string]$Persona, [string]$Kind)
        if ([string]::IsNullOrWhiteSpace($Name) -or -not $seen.Add($Name)) { return }
        $groups.Add([ordered]@{ Name = $Name; Persona = $Persona; Kind = $Kind })
    }

    foreach ($g in $settings.BreakGroups) { & $addGroup $g 'BreakGlass' 'break-glass' }
    if (& $flag 'PersonaGroups') {
        foreach ($p in $settings.Personas) { & $addGroup (Get-PersonaGroupName -Persona $p -Settings $settings) $p 'persona' }
        foreach ($p in $settings.Map.Keys) { & $addGroup (Get-PersonaGroupName -Persona ([string]$p) -Settings $settings) ([string]$p) 'persona' }
    }
    if ($baseline.Contains('ExclusionGroups') -and $null -ne $baseline['ExclusionGroups']) {
        foreach ($name in @($baseline['ExclusionGroups'])) {
            $n = [string]$name
            & $addGroup $n ([string](Resolve-PersonaOfGroup -GroupName $n -Settings $settings)) 'exclusion'
        }
    }

    $partner = $null
    if (& $flag 'CrossTenantPartner') {
        $partner = [ordered]@{ PartnerTenantId = [string]$Config['Prod']['TenantId'] }
    }

    $notes = [System.Collections.Generic.List[string]]::new()
    $users = if ($Config.Contains('DevUsers') -and $null -ne $Config['DevUsers']) { @($Config['DevUsers']).Count } else { 0 }
    if ($users -gt 0) {
        $notes.Add("The $users Dev users of the positive list are not part of this plan: run scripts/Invoke-DevUsers.ps1 after it (it needs the persona groups created here).")
    }
    $notes.Add('Members of the groups are never added or removed by the baseline.')

    [ordered]@{ Groups = [object[]]@($groups); Partner = $partner; Notes = [string[]]@($notes) }
}

function Get-M365CloningBaselineResources {
    <#
    .SYNOPSIS
        Resource types the baseline reads from the Dev snapshot (UTCM type names, TCM schema linked from Learn
        'Supported Microsoft Entra resources for Tenant Configuration Management', checked 2026-11-07).
    #>
    [CmdletBinding()]
    param()
    @(
        'microsoft.entra.group'
        'microsoft.entra.crosstenantaccesspolicyconfigurationpartner'
    )
}
