function ConvertTo-DesiredStateFile {
    <#
    .SYNOPSIS
        Pure function: turns a Prod snapshot into the files of the desired state (issue #27 part 1, ADR 0018).
        Writes nothing, calls nothing.
    .DESCRIPTION
        One entry per resource of the snapshot. Status 'written' with RelativePath (desired/<type>/<name>.json) and
        Content, or 'skipped' with a Reason. The rules follow the apply (ADR 0001, 0006), so the files hold exactly what
        an apply to Dev may take from Prod:
        - Skipped: a type the catalog does not know ('unknown type'), a type on the exclusion list or of a workload that
          is off ('excluded:'), a secret type, a profile with an encrypted OMA-URI value or a property listed as secret
          ('secret:'). Report-only types, tenant defaults and built-in objects are written: they are part of the desired
          state; the apply decides what it does with them.
        - Ids: Id and Identity are removed unless they are the key of the type. In assignments groupId and collectionId
          are removed (groups are matched by name, groupDisplayName stays) and the filter ID is replaced by the filter's
          display name (deviceAndAppManagementAssignmentFilterDisplayName), looked up in the same snapshot. An assignment
          filter that the snapshot does not hold skips the resource ('needs-filter'): without it the assignment would be
          wider than in Prod.
        - Tenant: properties that only describe the connection (TenantId, ApplicationId, CertificateThumbprint,
          ApplicationSecret, Credential, ManagedIdentity, AccessTokens) are removed. A resource that still contains the
          Prod tenant ID anywhere is skipped ('tenant id'): the repository never holds a tenant ID (ADR 0009).
        - Other values that look like an object ID (for example a role definition ID) are kept as they are and the
          entry is marked ObjectIds = true; the apply blocks them as before (ADR 0006).
        - Content: { resourceType, displayName, properties } with keys sorted (ordinal), lists in their original order.
        - File name: the display name with characters that Windows does not allow replaced by '_', trailing dots and
          spaces removed, Windows device names prefixed with '_', at most 120 characters. Names that end up equal
          (also when they differ only in case) get ' (2)', ' (3)' ... so a file never overwrites another.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )

    $prodTenant = if ($Config.Contains('Prod') -and $Config['Prod'] -is [System.Collections.IDictionary]) { [string]$Config['Prod']['TenantId'] } else { '' }
    $catalog = Get-ResourceTypeCatalog -Config $Config
    $index = Get-SnapshotResourceIndex -Snapshot $Snapshot
    $filterType = 'microsoft.intune.deviceandappmanagementassignmentfilter'
    $connection = @('TenantId', 'ApplicationId', 'CertificateThumbprint', 'ApplicationSecret', 'Credential', 'ManagedIdentity', 'AccessTokens')

    # Filter ID -> filter name, from the same snapshot.
    $filterNames = @{}
    foreach ($e in $index.Values) {
        if ($e.Type -ne $filterType -or $e.Resource['properties'] -isnot [System.Collections.IDictionary]) { continue }
        $p = $e.Resource['properties']
        foreach ($k in @($p.Keys | Where-Object { $_ -match '^(?i)(id|identity)$' })) {
            if (-not [string]::IsNullOrWhiteSpace([string]$p[$k])) { $filterNames[([string]$p[$k]).ToLowerInvariant()] = $e.Name }
        }
    }

    $usedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $results = foreach ($key in @($index.Keys | Sort-Object { $_ } -Culture ([cultureinfo]::InvariantCulture))) {
        $e = $index[$key]
        $type = $e.Type
        $entry = $catalog[$type]
        $out = [ordered]@{ ResourceType = $type; Name = $e.Name; Status = 'skipped'; Reason = ''; RelativePath = ''; ObjectIds = $false; Content = $null }
        if (-not $entry) { $out.Reason = "unknown type: '$type' is not in the catalog of the apply"; [pscustomobject]$out; continue }
        if ($entry.Excluded) { $out.Reason = "excluded: $($entry.ExcludeReason)"; [pscustomobject]$out; continue }
        if ($entry.Secret) { $out.Reason = "secret: $($entry.SecretReason) is never written"; [pscustomobject]$out; continue }
        if (Test-ResourceHasSecret -Resource $e.Resource) { $out.Reason = 'secret: the profile holds an encrypted value (OMA-URI)'; [pscustomobject]$out; continue }
        $secretProp = Get-ResourceSecretProperty -Resource $e.Resource
        if ($secretProp) { $out.Reason = "secret: the property '$secretProp' holds a secret"; [pscustomobject]$out; continue }

        $props = ConvertTo-CanonicalObject -Value $(if ($e.Resource['properties'] -is [System.Collections.IDictionary]) { $e.Resource['properties'] } else { @{} })
        $typeKey = [string]$entry.Key
        foreach ($k in @($props.Keys)) {
            if ($k -match '^(?i)(id|identity)$' -and -not ($typeKey -and $k -ieq $typeKey)) { $props.Remove($k); continue }
            if ($connection | Where-Object { $_ -ieq $k }) { $props.Remove($k) }
        }

        $reason = ''
        $assignmentsKey = @($props.Keys | Where-Object { $_ -ieq 'Assignments' }) | Select-Object -First 1
        if ($assignmentsKey) {
            $kept = [System.Collections.Generic.List[object]]::new()
            foreach ($a in @($props[$assignmentsKey])) {
                if ($a -isnot [System.Collections.IDictionary]) { $kept.Add($a); continue }
                $copy = [ordered]@{}
                foreach ($ak in $a.Keys) { if ($ak -notmatch '^(groupId|collectionId|deviceAndAppManagementAssignmentFilterId)$') { $copy[$ak] = $a[$ak] } }
                $filterId = [string]$a['deviceAndAppManagementAssignmentFilterId']
                $filterKind = [string]$a['deviceAndAppManagementAssignmentFilterType']
                if (-not [string]::IsNullOrWhiteSpace($filterId) -and $filterKind -ne 'none') {
                    $fn = $filterNames[$filterId.ToLowerInvariant()]
                    if ($fn) { $copy['deviceAndAppManagementAssignmentFilterDisplayName'] = $fn }
                    else { $reason = 'needs-filter: an assignment filter is not in the snapshot (add microsoft.intune.deviceandappmanagementassignmentfilter to the resources)' }
                }
                $kept.Add((ConvertTo-CanonicalObject -Value $copy))
            }
            $props[$assignmentsKey] = [object[]]@($kept.ToArray())
        }
        if ($reason) { $out.Reason = $reason; [pscustomobject]$out; continue }

        $content = [ordered]@{ resourceType = $type; displayName = $e.Name; properties = $props }
        $json = ConvertTo-Json -InputObject $content -Depth 50
        if ($prodTenant -and $json.IndexOf($prodTenant, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $out.Reason = 'tenant id: the resource contains the Prod tenant ID; it is never written to the repository'
            [pscustomobject]$out; continue
        }
        $out.ObjectIds = [bool]([regex]::IsMatch($json, '"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"'))

        $base = Get-DesiredStateFileName -Name $e.Name
        $candidate = $base; $n = 1
        while (-not $usedNames.Add("$type/$candidate")) { $n++; $candidate = "$base ($n)" }
        $out.Status = 'written'
        $out.RelativePath = "desired/$type/$candidate.json"
        $out.Content = $content
        [pscustomobject]$out
    }
    @($results)
}

function Get-DesiredStateFileName {
    <# A file name from a display name that works on Windows, macOS and Linux (see ConvertTo-DesiredStateFile). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    $safe = [regex]::Replace($Name, '[<>:"/\\|?*\x00-\x1F]', '_').TrimEnd('.', ' ').Trim()
    if (-not $safe) { $safe = '_' }
    if ($safe -match '^(?i)(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$') { $safe = "_$safe" }
    if ($safe.Length -gt 120) { $safe = $safe.Substring(0, 120).TrimEnd('.', ' ') }
    $safe
}

function Write-DesiredStateFile {
    <# Writes one desired-state file: JSON, two spaces, LF line ends, final newline, UTF-8 without BOM. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Content)
    $dir = Split-Path -Parent $Path
    $null = New-Item -ItemType Directory -Path $dir -Force
    $text = (ConvertTo-Json -InputObject $Content -Depth 50) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($Path, $text + "`n", [System.Text.UTF8Encoding]::new($false))
}

function Invoke-DesiredStateExport {
    <#
    .SYNOPSIS
        Read-only export of the Prod desired state into the configuration repository of the operator, one Git commit
        per run (issue #27 part 1, ADR 0018).
    .DESCRIPTION
        Reads a UTCM snapshot of Prod (the same resource types as the apply), turns it into one file per resource
        (ConvertTo-DesiredStateFile) in an empty folder below History\tmp and replaces <ConfigRepository>\desired with
        it only when every file was written; a failed run leaves the repository as it was. Git then shows what was
        added, changed or removed; the change is committed (only the desired folder), nothing is pushed.
        Writes History\reports\desired-export-<time>.json (counts, changed paths, skipped resources with the reason)
        and one audit line (mode 'export', counts only).
        Nothing is written to any tenant; Dev is not read.
        -SnapshotPath uses a saved Prod snapshot instead of reading Prod (offline, tests). -SnapshotProvider replaces the
        UTCM call (tests): param($Config, $Resources) returns the path of a snapshot.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$HistoryRoot,
        [securestring]$ProdToken,
        [string]$SnapshotPath,
        [scriptblock]$SnapshotProvider,
        [datetime]$Now = (Get-Date)
    )
    $repoSetting = if ($Config.ContainsKey('ConfigRepository')) { [string]$Config.ConfigRepository } else { '' }
    if ([string]::IsNullOrWhiteSpace($repoSetting) -or $repoSetting -match '^\s*<.*>\s*$') {
        throw 'ConfigRepository is not set in config.psd1: the path of your private configuration repository (ADR 0004).'
    }
    $repo = Assert-IntuneBackupRepository -Path $repoSetting

    $resources = if ($Config.ContainsKey('Resources') -and $Config.Resources) { @($Config.Resources) } else { @(Get-M365CloningDefaultResources -Config $Config) }
    if ($SnapshotPath) { $snapFile = $SnapshotPath }
    elseif ($SnapshotProvider) { $snapFile = & $SnapshotProvider $Config $resources }
    else {
        if (-not $ProdToken) { throw 'Pass -ProdToken (or -SnapshotPath for a saved Prod snapshot).' }
        Write-Host 'Reading the Prod tenant (UTCM snapshot, read only) ...'
        $snapFile = Get-UtcmTenantSnapshot -Token $ProdToken -Side Prod -TenantId $Config.Prod.TenantId -Resources $resources -HistoryRoot $HistoryRoot
    }
    $entries = ConvertTo-DesiredStateFile -Snapshot (Read-UtcmSnapshotFile -Path $snapFile) -Config $Config
    $written = @($entries | Where-Object { $_.Status -eq 'written' })
    $skipped = @($entries | Where-Object { $_.Status -eq 'skipped' })
    if ($written.Count -eq 0) { throw 'The Prod snapshot gave no file to write (no resource, or every resource was skipped). The configuration repository was not changed.' }

    $utcNow = $Now.ToUniversalTime()
    $stamp = $utcNow.ToString('yyyyMMdd-HHmmss')
    $tmpRoot = Join-Path $HistoryRoot 'tmp' "desired-export-$stamp"
    if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force }
    try {
        foreach ($w in $written) { Write-DesiredStateFile -Path (Join-Path $tmpRoot ($w.RelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)) -Content $w.Content }
        $target = Join-Path $repo 'desired'
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        $null = New-Item -ItemType Directory -Path $target -Force
        foreach ($item in Get-ChildItem -LiteralPath (Join-Path $tmpRoot 'desired') -Force) {
            Copy-Item -LiteralPath $item.FullName -Destination $target -Recurse -Force
        }
    }
    finally {
        if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Invoke-IntuneBackupGit -Repository $repo -Arguments @('add', '--all', '--', 'desired') | Out-Null
    $lines = @(Invoke-IntuneBackupGit -Repository $repo -Arguments @('-c', 'core.quotepath=off', 'diff', '--cached', '--name-status', '--no-renames', '--', 'desired'))
    $changes = @(foreach ($line in $lines) {
            if ($line -notmatch '^([AMD])\t(.+)$') { continue }
            $what = switch ($Matches[1]) { 'A' { 'added' } 'M' { 'changed' } 'D' { 'removed' } }
            [ordered]@{ Path = $Matches[2].Substring('desired/'.Length); Change = $what }
        })
    $added = @($changes | Where-Object { $_.Change -eq 'added' }).Count
    $changed = @($changes | Where-Object { $_.Change -eq 'changed' }).Count
    $removed = @($changes | Where-Object { $_.Change -eq 'removed' }).Count
    $commit = ''
    if ($changes.Count -gt 0) {
        $subject = 'Desired state export {0}' -f $utcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $body = @("Prod: $added added, $changed changed, $removed removed ($($written.Count) files, $($skipped.Count) skipped)")
        $actor = (([string]$env:M365CLONING_ACTOR) -replace '[\p{C}]', '').Trim()
        if ($actor) { $body += "Started by: $actor" }
        Invoke-IntuneBackupGit -Repository $repo -Arguments (@('-c', 'user.name=M365Cloning export', '-c', 'user.email=m365cloning-export@localhost',
                'commit', '--quiet', '-m', $subject, '-m', ($body -join "`n"), '--', 'desired')) | Out-Null
        $commit = [string](Invoke-IntuneBackupGit -Repository $repo -Arguments @('rev-parse', 'HEAD') | Select-Object -First 1)
        Write-Host "Committed $($commit.Substring(0, [Math]::Min(12, $commit.Length))) in the configuration repository (not pushed)."
    }
    else { Write-Host 'No change since the last export; nothing committed.' }

    $report = [ordered]@{
        SchemaVersion = '2'
        Kind          = 'desiredexport'
        CreatedUtc    = $utcNow.ToString('o')
        Commit        = $commit
        Unchanged     = ($changes.Count -eq 0)
        Folder        = 'desired'
        Files         = $written.Count
        Added         = $added
        Changed       = $changed
        Removed       = $removed
        WithObjectIds = @($written | Where-Object { $_.ObjectIds }).Count
        Changes       = @($changes | Sort-Object { $_.Path } -Culture ([cultureinfo]::InvariantCulture) | Select-Object -First 1000)
        Skipped       = @($skipped | Select-Object -First 1000 | ForEach-Object { [ordered]@{ ResourceType = $_.ResourceType; Name = $_.Name; Reason = $_.Reason } })
        Truncated     = ($changes.Count -gt 1000 -or $skipped.Count -gt 1000)
    }
    $reports = Join-Path $HistoryRoot 'reports'
    $null = New-Item -ItemType Directory -Path $reports -Force
    $path = Join-Path $reports "desired-export-$stamp.json"
    ConvertTo-Json -InputObject $report -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
    $reason = "desired state export: $added added, $changed changed, $removed removed, $($skipped.Count) skipped"
    if ($commit) { $reason += "; commit $($commit.Substring(0, [Math]::Min(12, $commit.Length)))" }
    Write-ApplyAudit -HistoryRoot $HistoryRoot -Mode export -Reason $reason
    [pscustomobject]@{ Path = $path; Report = $report }
}
