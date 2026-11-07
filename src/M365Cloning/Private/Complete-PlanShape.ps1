# Version of the file formats the core writes (plans, drift report, suitability check). ADR 0008 / issue #51:
# a removed, renamed or changed field raises it; the web envelope carries the same value.
$script:M365CloningSchemaVersion = '2'

function Get-TenantIdShort {
    <# First 8 characters plus '...' (as in the audit log); shorter IDs stay as they are. #>
    param([AllowEmptyString()][string]$TenantId)
    if ($TenantId.Length -gt 8) { $TenantId.Substring(0, 8) + '...' } else { $TenantId }
}

function Complete-PlanShape {
    <#
    .SYNOPSIS
        Brings a plan of any kind into the one shape of schema version 2 (issue #51). Pure function, no tenant access.
    .DESCRIPTION
        - Header: SchemaVersion, Kind (apply, baseline, reset, users).
        - Tenant: the full TargetTenantId is replaced by TargetTenant (shortened, for people) and TargetTenantHash
          (SHA-256 of the lower-case ID, for the gate). The gate compares the hash with the Dev tenant of the local
          config, so a plan never needs to carry the full ID.
        - Every field is present: Title, ApplyHint, Mode, Protected, Notes, TypeSummary, ExcludedTypes, Licences
          (not checked until Add-PlanLicenceCheck runs) and one Summary with the same counters for every kind.
        - Actions: AssignmentClass is a string, Differences a list and Properties always an object (never null).
        The time of the plan is NOT part of the plan: the plan hash must be the same when the script builds the plan
        again for -Apply. CreatedUtc is written into the plan file by Export-ApplyPlan.
        What the plan does (actions, operations, statuses, reasons, protection list) is not changed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan,
        [Parameter(Mandatory)][ValidateSet('apply', 'baseline', 'reset', 'users')][string]$Kind
    )
    $get = { param([string]$k, $default) if ($Plan.Contains($k) -and $null -ne $Plan[$k]) { $Plan[$k] } else { $default } }

    $tenant = if ($Plan.Contains('TargetTenantId')) { [string]$Plan['TargetTenantId'] } else { '' }
    $short = if ($Plan.Contains('TargetTenant')) { [string]$Plan['TargetTenant'] } else { Get-TenantIdShort -TenantId $tenant }
    $hash = if ($Plan.Contains('TargetTenantHash')) { [string]$Plan['TargetTenantHash'] } elseif ($tenant) { Get-TenantIdHash -TenantId $tenant } else { '' }

    $actions = [object[]]@(foreach ($a in @(& $get 'Actions' @())) {
            if ($null -eq $a) { continue }
            if ($a -is [System.Collections.IDictionary]) {
                if (-not $a.Contains('AssignmentClass') -or $null -eq $a['AssignmentClass']) { $a['AssignmentClass'] = '' }
                if (-not $a.Contains('DscResource') -or $null -eq $a['DscResource']) { $a['DscResource'] = '' }
                if (-not $a.Contains('Differences') -or $null -eq $a['Differences']) { $a['Differences'] = [object[]]@() }
                if (-not $a.Contains('Properties') -or $null -eq $a['Properties']) { $a['Properties'] = [ordered]@{} }
                if (-not $a.Contains('Reason') -or $null -eq $a['Reason']) { $a['Reason'] = '' }
            }
            $a
        })

    $s = & $get 'Summary' @{}
    $n = { param([string]$k) if ($s.Contains($k) -and $s[$k] -is [ValueType] -and $s[$k] -isnot [bool]) { [int]$s[$k] } else { 0 } }
    $d = if ($s.Contains('Devices') -and $s['Devices'] -is [System.Collections.IDictionary]) { $s['Devices'] } else { @{} }
    $dn = { param([string]$k) if ($d.Contains($k)) { [int]$d[$k] } else { 0 } }
    $summary = [ordered]@{
        Planned    = & $n 'Planned'
        Blocked    = & $n 'Blocked'
        Skipped    = & $n 'Skipped'
        Excluded   = & $n 'Excluded'
        Exists     = & $n 'Exists'
        Invite     = & $n 'Invite'
        Protected  = & $n 'Protected'
        InBaseline = $false
        Devices    = [ordered]@{ Keep = & $dn 'Keep'; Protected = & $dn 'Protected'; Remove = & $dn 'Remove'; Retire = & $dn 'Retire'; Wipe = & $dn 'Wipe' }
    }
    $summary['InBaseline'] = ($summary['Planned'] -eq 0 -and $summary['Blocked'] -eq 0)

    $licences = & $get 'Licences' $null
    if ($null -eq $licences) {
        $licences = [ordered]@{
            Checked   = $false
            Readable  = $false
            Error     = 'not checked for this plan'
            Available = [string[]]@()
            Missing   = [object[]]@()
            Warnings  = [string[]]@()
        }
    }

    $shaped = [ordered]@{
        SchemaVersion    = $script:M365CloningSchemaVersion
        Kind             = $Kind
        Direction        = [string](& $get 'Direction' '')
        Title            = [string](& $get 'Title' '')
        ApplyHint        = [string](& $get 'ApplyHint' '')
        Mode             = [string](& $get 'Mode' '')
        TargetTenant     = $short
        TargetTenantHash = $hash
        Actions          = $actions
        Protected        = [object[]]@(& $get 'Protected' @())
        Notes            = [string[]]@(& $get 'Notes' @())
        Summary          = $summary
        TypeSummary      = [object[]]@(& $get 'TypeSummary' @())
        ExcludedTypes    = [object[]]@(& $get 'ExcludedTypes' @())
        Licences         = $licences
    }
    # Area (issue #66): only when the plan covers one area; a plan of all areas keeps its shape and its hash.
    $area = [string](& $get 'Area' '')
    if ($area) { $shaped['Area'] = $area }
    $shaped
}
