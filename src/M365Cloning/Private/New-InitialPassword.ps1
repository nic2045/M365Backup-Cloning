function New-InitialPassword {
    <#
    .SYNOPSIS
        Random initial password for a Dev test user (cryptographic random numbers): 24 characters with upper and
        lower case letters, digits and symbols. Returned as a plain string ONLY to the caller that sends it to
        Graph; it is never written to a plan, report, result file or the audit log.
    #>
    [CmdletBinding()]
    param([ValidateRange(16, 128)][int]$Length = 24)

    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#%+-=?@^_~')
    $all = -join $sets
    $pick = { param([string]$from) $from[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($from.Length)] }
    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($set in $sets) { $chars.Add((& $pick $set)) }
    while ($chars.Count -lt $Length) { $chars.Add((& $pick $all)) }
    # Fisher-Yates shuffle so the first characters are not always one per class.
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($i + 1)
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }
    -join $chars
}
