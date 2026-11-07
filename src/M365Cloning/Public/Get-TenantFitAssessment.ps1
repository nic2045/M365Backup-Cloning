function Get-TenantFitAssessment {
    <#
    .SYNOPSIS
        Pure function (issue #39): is the Dev tenant enough to mirror Prod, or is an equivalent tenant needed?
        Reads nothing and writes nothing; the caller passes what it has read (Get-TenantLicences, Read-UtcmSnapshotFile).
    .DESCRIPTION
        - Usage of Prod: every resource of the Prod snapshot is matched against Data\LicenceRequirements.psd1 with the
          same rule test as the plan check (Test-LicenceRuleApplies). Without a snapshot, every feature Prod is
          licensed for counts as used (careful choice).
        - A used feature whose service plans Dev does not have gives a finding; the severity comes from
          Data\TenantFitRules.psd1 (Intune and Conditional Access P1 are red, everything else yellow).
        - Dev SKU states (Warning, Suspended, LockedOut, Deleted), free licence units for the test users of DevUsers,
          and licence lists that cannot be read give their own findings (rules in the same data file).
        Status = worst severity: 'green' (Dev is enough), 'yellow' (enough with gaps), 'grey' (not verified: a licence
        list could not be read), 'red' (equivalent tenant needed). Capacity is never red. Field names are stable for
        the web schema (#44).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$ProdLicences,
        [Parameter(Mandatory)][System.Collections.IDictionary]$DevLicences,
        [AllowNull()][System.Collections.IDictionary]$ProdSnapshot,
        [AllowNull()][System.Collections.IDictionary]$Config
    )

    $fit = Import-PowerShellDataFile -LiteralPath (Join-Path $script:ModuleRoot 'Data' 'TenantFitRules.psd1')
    $rules = @(Get-LicenceRequirementMap)
    $findings = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([string]$Id, [string]$Severity, [string]$Category, [string]$Feature, [string]$Message, [string[]]$Plans, [string[]]$Types, [int]$Count, [string]$Source)
        $findings.Add([ordered]@{
                Id            = $Id
                Severity      = $Severity
                Category      = $Category
                Feature       = $Feature
                Message       = $Message
                ServicePlans  = [string[]]@($Plans | Where-Object { $_ })
                AffectedTypes = [string[]]@($Types | Where-Object { $_ } | Sort-Object -Unique)
                AffectedCount = $Count
                Source        = $Source
            })
    }
    $devOk = [bool]$DevLicences['Readable']
    $prodOk = [bool]$ProdLicences['Readable']
    $hasSnapshot = $null -ne $ProdSnapshot -and $ProdSnapshot.Contains('resources')
    $devPlans = [System.Collections.Generic.HashSet[string]]::new([string[]]@($DevLicences['Available']), [System.StringComparer]::OrdinalIgnoreCase)
    $prodPlans = [System.Collections.Generic.HashSet[string]]::new([string[]]@($ProdLicences['Available']), [System.StringComparer]::OrdinalIgnoreCase)
    $get = { param($o, [string]$k) if ($o -is [System.Collections.IDictionary]) { $o[$k] } elseif ($null -ne $o -and $o.PSObject.Properties[$k]) { $o.PSObject.Properties[$k].Value } else { $null } }

    # Readability
    if (-not $devOk) { & $add 'readability:Dev' $fit.NotReadable.Severity 'readability' '' "Dev: $($fit.NotReadable.Reason) Error: $($DevLicences['Error'])" @() @() 0 '' }
    if (-not $hasSnapshot) {
        if ($prodOk) { & $add 'usage:no-snapshot' $fit.NoProdSnapshot.Severity 'usage' '' $fit.NoProdSnapshot.Reason @() @() 0 '' }
        else { & $add 'readability:Prod' $fit.NotReadable.Severity 'readability' '' "Prod (and no Prod snapshot): $($fit.NotReadable.Reason) Error: $($ProdLicences['Error'])" @() @() 0 '' }
    }

    # Usage of Prod: feature -> types and count
    $used = [ordered]@{}
    $mark = {
        param($rule, [string]$type)
        if (-not $used.Contains($rule.Feature)) { $used[$rule.Feature] = [ordered]@{ Rule = $rule; Types = [System.Collections.Generic.List[string]]::new(); Count = 0 } }
        $used[$rule.Feature].Types.Add($type); $used[$rule.Feature].Count++
    }
    if ($hasSnapshot) {
        foreach ($res in @($ProdSnapshot['resources'] | Where-Object { $null -ne $_ })) {
            $type = [string](& $get $res 'resourceType')
            $props = & $get $res 'properties'
            foreach ($r in $rules) { if (Test-LicenceRuleApplies -Rule $r -ResourceType $type -Properties $props) { & $mark $r $type.ToLowerInvariant() } }
        }
    }
    elseif ($prodOk) {
        foreach ($r in $rules) {
            if ($r.Known -and @($r.ServicePlans | Where-Object { $prodPlans.Contains($_) }).Count -gt 0) { & $mark $r $r.Match; $used[$r.Feature].Count = 0 }
        }
    }

    # Used features against Dev
    $missingCount = 0
    if ($devOk) {
        foreach ($feature in $used.Keys) {
            $u = $used[$feature]; $r = $u.Rule
            if (-not $r.Known) {
                & $add "unconfirmed:$feature" $fit.UnconfirmedRuleSeverity 'unconfirmed-rule' $feature "Prod uses $feature; Learn does not confirm which licence it needs, so Dev is not checked for it." @() @($u.Types) $u.Count $r.Source
                continue
            }
            if (@($r.ServicePlans | Where-Object { $devPlans.Contains($_) }).Count -gt 0) { continue }
            $missingCount++
            $sev = $fit.DefaultFeatureSeverity; $why = $fit.DefaultFeatureReason
            foreach ($fs in @($fit.FeatureSeverity)) { if ($fs.Feature -eq $feature) { $sev = $fs.Severity; $why = $fs.Reason } }
            & $add "feature:$feature" $sev 'feature' $feature "Prod uses $feature, Dev has none of $($r.ServicePlans -join ', '). $why" @($r.ServicePlans) @($u.Types) $u.Count $r.Source
        }

        # SKU states in Dev
        foreach ($sku in @($DevLicences['Skus'])) {
            foreach ($st in @($fit.SkuStatus)) {
                if ([string]$sku['CapabilityStatus'] -eq $st.Status) {
                    & $add "sku:$($sku['SkuPartNumber'])" $st.Severity 'sku-status' '' "Dev SKU $($sku['SkuPartNumber']) is $($st.Status). $($st.Reason)" @($sku['ServicePlans']) @() 0 'https://learn.microsoft.com/graph/api/resources/subscribedsku'
                }
            }
        }

        # Capacity for test users
        $testUsers = 0
        if ($null -ne $Config -and $Config.Contains('DevUsers')) { $testUsers = @($Config['DevUsers'] | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['Type'] -eq 'TestUser' }).Count }
        if ($testUsers -gt 0) {
            foreach ($plan in @($fit.Capacity.ServicePlans)) {
                $skus = @($DevLicences['Skus'] | Where-Object { @($_['ProvidedPlans']) -contains $plan })
                if ($skus.Count -eq 0) { continue }
                $free = 0
                foreach ($s in $skus) { $free += [int]$s['PrepaidEnabled'] - [int]$s['ConsumedUnits'] }
                if ($free -lt 0) { $free = 0 }
                if ($free -lt $testUsers) {
                    $sev = if ($fit.Capacity.Severity -eq 'red') { 'yellow' } else { $fit.Capacity.Severity }
                    & $add "capacity:$plan" $sev 'capacity' '' "Dev has $free free unit(s) with $plan (enabled minus assigned), DevUsers lists $testUsers test user(s). $($fit.Capacity.Reason)" @($plan) @() $testUsers 'https://learn.microsoft.com/graph/api/resources/subscribedsku#properties'
                }
            }
        }
    }

    $rank = @{ red = 3; grey = 2; yellow = 1; info = 0 }
    $worst = 0
    foreach ($f in $findings) { if ($rank[$f.Severity] -gt $worst) { $worst = $rank[$f.Severity] } }
    $status = @('green', 'yellow', 'grey', 'red')[$worst]
    $verified = $devOk -and ($hasSnapshot -or $prodOk)
    $verdict = switch ($status) {
        'green' { 'Dev is enough to mirror Prod.' }
        'yellow' { 'Dev is enough with gaps: the listed parts of Prod cannot be mirrored.' }
        'grey' { 'Not verified: a licence list could not be read.' }
        'red' { 'An equivalent tenant is needed: a core feature of Prod is missing in Dev.' }
    }
    $view = { param($l) [ordered]@{ Readable = [bool]$l['Readable']; Error = [string]$l['Error']; Available = [string[]]@($l['Available']); Skus = [object[]]@($l['Skus']) } }
    $sorted = @($findings | Sort-Object @{ Expression = { -$rank[$_.Severity] } }, @{ Expression = { $_.Id } })
    [ordered]@{
        Schema          = 'm365cloning.tenantfit/1'
        CreatedUtc      = (Get-Date).ToUniversalTime().ToString('o')
        Status          = $status
        Verified        = $verified
        Verdict         = $verdict
        ProdUsageSource = if ($hasSnapshot) { 'snapshot' } elseif ($prodOk) { 'licences' } else { 'none' }
        Summary         = [ordered]@{
            Red                  = @($findings | Where-Object { $_.Severity -eq 'red' }).Count
            Yellow               = @($findings | Where-Object { $_.Severity -eq 'yellow' }).Count
            Info                 = @($findings | Where-Object { $_.Severity -eq 'info' }).Count
            FeaturesUsedInProd   = $used.Count
            FeaturesMissingInDev = $missingCount
        }
        Findings        = [object[]]$sorted
        Licences        = [ordered]@{ Prod = (& $view $ProdLicences); Dev = (& $view $DevLicences) }
    }
}
