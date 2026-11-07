function ConvertTo-FlatProperty {
    <#
    .SYNOPSIS
        Flattens a resource's properties to path -> string (or sorted string[] for lists) for comparing.
    .DESCRIPTION
        Ignored because they differ between tenants without being a real difference (ADR 0001: compare by
        name, not by ID): id, Identity, timestamps, version, @odata.* and the assignment filter id.
        In an object that has groupDisplayName the group id (groupId) is dropped, so a group is compared
        by its name. Without groupDisplayName the id stays and shows up as a difference (cannot be mapped).
        Lists are compared as sets (order does not matter): each element becomes a canonical string.
    #>
    [CmdletBinding()]
    param(
        $Value,
        [string]$Path = '',
        [System.Collections.IDictionary]$Out = ([ordered]@{})
    )
    $ignore = '^(id|identity|createdDateTime|lastModifiedDateTime|version|deviceAndAppManagementAssignmentFilterId|@odata\..*)$'

    if ($null -eq $Value) {
        $Out[$Path] = '<null>'
    }
    elseif ($Value -is [System.Collections.IDictionary]) {
        $hasGroupName = @($Value.Keys | Where-Object { $_ -ieq 'groupDisplayName' }).Count -gt 0
        foreach ($key in ($Value.Keys | Sort-Object)) {
            if ($key -match $ignore) { continue }
            if ($hasGroupName -and $key -ieq 'groupId') { continue }
            $child = if ($Path) { "$Path.$key" } else { [string]$key }
            $null = ConvertTo-FlatProperty -Value $Value[$key] -Path $child -Out $Out
        }
    }
    elseif ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = foreach ($element in $Value) {
            if ($element -is [System.Collections.IDictionary]) {
                $sub = [ordered]@{}
                $null = ConvertTo-FlatProperty -Value $element -Path '' -Out $sub
                (($sub.Keys | ForEach-Object { "$_=$(@($sub[$_]) -join ',')" }) -join ';')
            }
            elseif ($element -is [System.Collections.IEnumerable] -and $element -isnot [string]) {
                $element | ConvertTo-Json -Depth 20 -Compress
            }
            else { ConvertTo-InvariantString $element }
        }
        # Ordinal sort: same result on every machine (lists are compared as sets).
        $sorted = [string[]]@($items)
        [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
        $Out[$Path] = $sorted
    }
    else {
        $Out[$Path] = ConvertTo-InvariantString $Value
    }
    $Out
}

function ConvertTo-InvariantString {
    param($Value)
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    [string]::Format([cultureinfo]::InvariantCulture, '{0}', $Value)
}
