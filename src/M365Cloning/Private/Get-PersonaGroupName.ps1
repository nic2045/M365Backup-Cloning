function Get-PersonaGroupName {
    <#
    .SYNOPSIS
        The Dev group name a persona's users go into (ADR 0003): the first name in PersonaMap for that persona,
        otherwise prefix + persona (CA-Persona-Admins). $null for an unknown persona or for 'BreakGlass'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Persona,
        [Parameter(Mandatory)]$Settings
    )
    if ($Persona -ieq 'BreakGlass') { return $null }
    foreach ($key in $Settings.Map.Keys) {
        if ([string]$key -ieq $Persona -and @($Settings.Map[$key]).Count -gt 0) { return [string]@($Settings.Map[$key])[0] }
    }
    foreach ($p in $Settings.Personas) { if ($p -ieq $Persona) { return $Settings.Prefix + $p } }
    $null
}
