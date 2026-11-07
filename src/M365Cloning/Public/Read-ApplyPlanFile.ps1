function Read-ApplyPlanFile {
    <#
    .SYNOPSIS
        Reads a plan file written by Export-ApplyPlan (History/reports/*-plan-*.json) and returns
        @{ SchemaVersion; Kind; CreatedUtc; PlanHash; Plan }.
    .DESCRIPTION
        A plan file of an older format (no Kind or another SchemaVersion, issue #51) is refused with 'make a new plan'
        instead of being read in a guessed way: its content cannot be checked against the current rules and its hash
        does not match a plan that is built today. The scripts never apply a file; they build the plan again and
        compare its hash. This reader is for consumers such as the web server (ADR 0008).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Plan file not found: $Path" }
    $doc = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    $version = if ($doc -is [System.Collections.IDictionary] -and $doc.Contains('SchemaVersion')) { [string]$doc['SchemaVersion'] } else { '' }
    $kind = if ($doc -is [System.Collections.IDictionary] -and $doc.Contains('Kind')) { [string]$doc['Kind'] } else { '' }
    if ($version -ne $script:M365CloningSchemaVersion -or -not $kind -or -not $doc.Contains('Plan')) {
        throw "The plan file '$([System.IO.Path]::GetFileName($Path))' has an older format (schema version '$version', expected '$($script:M365CloningSchemaVersion)'): make a new plan (run the script again without -Apply)."
    }
    $doc
}
