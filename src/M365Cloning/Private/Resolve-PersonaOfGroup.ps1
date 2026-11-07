function Resolve-PersonaOfGroup {
    <#
    .SYNOPSIS
        The persona a group name belongs to, or $null when it has no recognisable persona (ADR 0003).
    .DESCRIPTION
        Order: the break-glass groups -> 'BreakGlass'; an exact name in PersonaMap -> that persona; a name that
        starts with the prefix followed by an active persona and then the end or a hyphen
        (CA-Persona-Admins, CA-Persona-Admins-BaseProtection-Exclusions) -> that persona. Anything else is $null.
        Names are compared case-insensitively.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GroupName,
        [Parameter(Mandatory)]$Settings
    )

    foreach ($b in $Settings.BreakGroups) { if ($GroupName -ieq $b) { return 'BreakGlass' } }
    foreach ($persona in $Settings.Map.Keys) {
        foreach ($name in $Settings.Map[$persona]) { if ($GroupName -ieq $name) { return [string]$persona } }
    }
    if ($GroupName.StartsWith($Settings.Prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rest = $GroupName.Substring($Settings.Prefix.Length)
        foreach ($persona in $Settings.Personas) {
            if ($rest -ieq $persona -or $rest.StartsWith("$persona-", [System.StringComparison]::OrdinalIgnoreCase)) { return [string]$persona }
        }
    }
    $null
}
