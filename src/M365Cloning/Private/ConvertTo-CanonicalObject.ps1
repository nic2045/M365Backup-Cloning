function ConvertTo-CanonicalObject {
    <#
    .SYNOPSIS
        Deep copy with sorted dictionary keys (ordinal), so the same content always gives the same JSON and hash.
    #>
    [CmdletBinding()]
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        $keys = [string[]]@($Value.Keys | ForEach-Object { [string]$_ })
        [Array]::Sort($keys, [System.StringComparer]::Ordinal)
        foreach ($key in $keys) { $out[$key] = ConvertTo-CanonicalObject -Value $Value[$key] }
        return $out
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($element in $Value) { $list.Add((ConvertTo-CanonicalObject -Value $element)) }
        return , $list.ToArray()
    }
    $Value
}
