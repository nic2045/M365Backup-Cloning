function Test-LicenceRuleApplies {
    <#
    .SYNOPSIS
        Pure: does one licence rule (Get-LicenceRequirementMap) apply to a resource of this type with these properties?
        Shared by the plan check (Add-PlanLicenceCheck, issue #32) and the suitability check (Get-TenantFitAssessment,
        issue #39), so both read Data\LicenceRequirements.psd1 the same way.
    .DESCRIPTION
        'Match' is a -like pattern on the lower-case resource type. With 'WhenAnyProperty' the rule applies only when
        one of these properties is not empty (a non-blank string or a list with at least one non-empty item).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][object]$Rule,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ResourceType,
        [AllowNull()][object]$Properties
    )
    if ($ResourceType.ToLowerInvariant() -notlike $Rule.Match) { return $false }
    if (@($Rule.WhenAnyProperty).Count -eq 0) { return $true }
    if ($Properties -isnot [System.Collections.IDictionary]) { return $false }
    foreach ($name in @($Rule.WhenAnyProperty)) {
        if (-not $Properties.Contains($name)) { continue }
        $v = $Properties[$name]
        if ($null -eq $v) { continue }
        if ($v -is [string]) { if (-not [string]::IsNullOrWhiteSpace($v)) { return $true }; continue }
        if (@($v | Where-Object { $null -ne $_ -and [string]$_ -ne '' }).Count -gt 0) { return $true }
    }
    return $false
}
