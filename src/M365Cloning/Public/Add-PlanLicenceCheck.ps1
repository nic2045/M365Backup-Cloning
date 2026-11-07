function Add-PlanLicenceCheck {
    <#
    .SYNOPSIS
        Pure function, the one place of the licence check (issue #32): blocks every planned Dev write whose licence
        is missing in the Dev tenant, before anything is applied. Writes nothing, calls nothing.
    .DESCRIPTION
        Rules: Data\LicenceRequirements.psd1 (Get-LicenceRequirementMap). Only entries with Status 'planned' and an
        operation that writes (not a delete, not SkipDelete) are checked. For every matching rule:
        - known rule, none of its service plans available -> Status 'blocked', Reason 'license: <feature> (needs <plans>)';
        - rule without confirmed service plan (Learn does not say) -> warning in Plan.Licences.Warnings, entry unchanged.
        Licence list not readable (Licences.Readable = $false): every entry that has a KNOWN requirement is blocked
        ('license: not verified, ...'); entries without a requirement stay as they are. This is the more careful choice:
        a write without the licence fails halfway (DSC) or leaves a Conditional Access policy that can no longer be
        updated (Learn: expired licences), and reading needs only LicenseAssignment.Read.All.
        The plan gets Plan.Licences (Readable, Error, Available, Missing, Warnings) and new Summary counts; the plan
        hash covers this, so preview and apply must see the same licences.
        Used by every script that writes to Dev: Invoke-ApplyDev (Intune, Conditional Access and its dependencies),
        Invoke-DevBaseline, Invoke-DevUsers; the rebuild chain after a reset runs these scripts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Licences
    )

    $rules = @(Get-LicenceRequirementMap)
    $readable = [bool]$Licences['Readable']
    $available = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Licences['Available']), [System.StringComparer]::OrdinalIgnoreCase)
    $missing = [ordered]@{}
    $warnings = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)

    foreach ($a in @($Plan['Actions'])) {
        if ([string]$a['Status'] -ne 'planned') { continue }
        $op = [string]$a['Operation']
        if ($op -like 'Delete*' -or $op -eq 'SkipDelete') { continue }
        $type = ([string]$a['ResourceType']).ToLowerInvariant()
        $reasons = [System.Collections.Generic.List[string]]::new()
        foreach ($r in $rules) {
            if (-not (Test-LicenceRuleApplies -Rule $r -ResourceType $type -Properties $a['Properties'])) { continue }
            if (-not $r.Known) { $null = $warnings.Add("$($r.Feature): no confirmed licence rule; '$($a['Name'])' ($type) is applied without a licence check"); continue }
            $ok = $readable -and @($r.ServicePlans | Where-Object { $available.Contains($_) }).Count -gt 0
            if ($ok) { continue }
            $need = $r.ServicePlans -join ' or '
            if ($readable) { $reasons.Add("license: $($r.Feature) (needs $need)") }
            else { $reasons.Add("license: not verified, the licence list of Dev could not be read ($($r.Feature) needs $need)") }
            if (-not $missing.Contains($r.Feature)) { $missing[$r.Feature] = [ordered]@{ Feature = $r.Feature; ServicePlans = [string[]]$r.ServicePlans; Source = $r.Source; Entries = [System.Collections.Generic.List[string]]::new() } }
            $missing[$r.Feature].Entries.Add("$type | $($a['Name'])")
        }
        if ($reasons.Count -gt 0) {
            $a['Status'] = 'blocked'
            $a['Reason'] = (@($reasons) + @([string]$a['Reason'] | Where-Object { $_ })) -join '; '
        }
    }

    $count = { param($status) @($Plan['Actions'] | Where-Object { $_['Status'] -eq $status }).Count }
    $s = $Plan['Summary']
    $s['Planned'] = [int](& $count 'planned')
    $s['Blocked'] = [int](& $count 'blocked')
    if ($s.Contains('InBaseline')) { $s['InBaseline'] = ($s['Planned'] -eq 0 -and $s['Blocked'] -eq 0) }

    $Plan['Licences'] = [ordered]@{
        Readable  = $readable
        Error     = [string]$Licences['Error']
        Available = [string[]]@($available | Sort-Object)
        Missing   = [object[]]@($missing.Values | ForEach-Object { [ordered]@{ Feature = $_.Feature; ServicePlans = $_.ServicePlans; Source = $_.Source; Entries = [string[]]@($_.Entries | Sort-Object) } })
        Warnings  = [string[]]@($warnings)
    }
    $Plan
}
