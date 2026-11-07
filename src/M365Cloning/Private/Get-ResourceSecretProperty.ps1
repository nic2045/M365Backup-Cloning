function Get-ResourceSecretProperty {
    <#
    .SYNOPSIS
        Name of the first property that holds a secret value, or '' (ADR 0006, generic handling).
    .DESCRIPTION
        The property names come from Data/ResourceRules.psd1 (SecretProperties, taken from the TCM schema
        utcm-monitor.json). A property counts only when its value is not empty; Prod usually does not export the
        value at all, but a resource that carries one is never copied to Dev. Nested objects and lists are searched
        too. The OMA-URI rule (IsEncrypted, SecretReferenceValueId) stays in Test-ResourceHasSecret.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Resource)

    $names = @((Import-PowerShellDataFile -Path (Join-Path $script:ModuleRoot 'Data' 'ResourceRules.psd1')).SecretProperties)
    $props = $Resource['properties']
    if ($props -isnot [System.Collections.IDictionary]) { return '' }
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push($props)
    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        if ($node -is [System.Collections.IDictionary]) {
            foreach ($k in @($node.Keys)) {
                $v = $node[$k]
                if (($names | Where-Object { $_ -ieq [string]$k }) -and $null -ne $v -and -not [string]::IsNullOrWhiteSpace((@($v) -join ''))) { return [string]$k }
                if ($v -is [System.Collections.IDictionary] -or ($v -is [System.Collections.IEnumerable] -and $v -isnot [string])) { $stack.Push($v) }
            }
        }
        elseif ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
            foreach ($item in $node) { if ($item -is [System.Collections.IDictionary] -or ($item -is [System.Collections.IEnumerable] -and $item -isnot [string])) { $stack.Push($item) } }
        }
    }
    ''
}
