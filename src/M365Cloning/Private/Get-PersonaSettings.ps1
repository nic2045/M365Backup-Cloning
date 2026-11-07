function Get-PersonaSettings {
    <#
    .SYNOPSIS
        Persona settings for Conditional Access from the config, with the defaults of ADR 0003.
    .DESCRIPTION
        Defaults: prefix 'CA-Persona-', personas Admins, Internals, Externals, Guests, Microsoft365ServiceAccounts,
        emergency group 'CA-BreakglassAccounts'. Config keys (all optional):
          PersonaPrefix : prefix of the persona groups (default 'CA-Persona-')
          Personas      : list of active personas (default: the five above); further personas from the paper
                          (GuestAdmins, AzureServiceAccounts, CorpServiceAccounts, WorkloadIdentities, Developers)
                          are switched on by listing them here
          PersonaMap    : persona -> exact Prod group name(s), for Prod names that do not follow the prefix
        The break-glass groups of the config (BreakGlassGroups) and the default emergency group belong to the
        persona 'BreakGlass'.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    $prefix = if ($Config.Contains('PersonaPrefix') -and -not [string]::IsNullOrWhiteSpace([string]$Config['PersonaPrefix'])) { [string]$Config['PersonaPrefix'] } else { 'CA-Persona-' }
    $personas = if ($Config.Contains('Personas') -and $null -ne $Config['Personas']) { [string[]]@($Config['Personas']) }
    else { [string[]]@('Admins', 'Internals', 'Externals', 'Guests', 'Microsoft365ServiceAccounts') }

    $map = @{}
    if ($Config.Contains('PersonaMap') -and $Config['PersonaMap'] -is [System.Collections.IDictionary]) {
        foreach ($persona in $Config['PersonaMap'].Keys) {
            $map[[string]$persona] = [string[]]@($Config['PersonaMap'][$persona] | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        }
    }

    $breakGroups = [System.Collections.Generic.List[string]]::new()
    $breakGroups.Add('CA-BreakglassAccounts')
    if ($Config.Contains('BreakGlassGroups') -and $null -ne $Config['BreakGlassGroups']) {
        foreach ($g in @($Config['BreakGlassGroups'])) { if (-not [string]::IsNullOrWhiteSpace([string]$g)) { $breakGroups.Add([string]$g) } }
    }

    [pscustomobject]@{
        Prefix      = $prefix
        Personas    = $personas
        Map         = $map
        BreakGroups = [string[]]@($breakGroups | Select-Object -Unique)
    }
}
