# Content digest of the plans the offline sample run writes (issue #51): which actions, with which operation, status
# and reason, and which protected entries. The shape of the files may change; this content must not.
function Get-ContractActionDigest {
    param([Parameter(Mandatory)][string]$HistoryRoot)
    $prefixes = 'apply-plan-', 'dev-baseline-plan-', 'dev-reset-plan-align-', 'dev-reset-plan-full-', 'dev-users-plan-'
    $out = [ordered]@{}
    foreach ($prefix in $prefixes) {
        $file = @(Get-ChildItem -LiteralPath (Join-Path $HistoryRoot 'reports') -Filter "$prefix*.json" | Sort-Object Name)[0]
        $doc = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
        $plan = $doc['Plan']
        $out[$prefix.TrimEnd('-')] = [ordered]@{
            Actions   = @(foreach ($a in @($plan['Actions'])) { '{0} | {1} | {2} | {3} | {4}' -f $a['ResourceType'], $a['Name'], $a['Operation'], $a['Status'], $a['Reason'] })
            Protected = @(foreach ($p in @($plan['Protected'])) { if ($p) { '{0} | {1} | {2}' -f $p['Kind'], $p['Name'], $p['Source'] } })
            Counts    = '{0}/{1}/{2}' -f [int]$plan['Summary']['Planned'], [int]$plan['Summary']['Blocked'], [int]$plan['Summary']['Skipped']
        }
    }
    $out
}
