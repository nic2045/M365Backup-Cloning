#requires -Version 5.1
<#
.SYNOPSIS
    Runs in Windows PowerShell 5.1 (not PowerShell 7): applies the planned actions with Microsoft365DSC.
.DESCRIPTION
    Called by Start-DscApplyProcess. Reads plan.json (planned actions only), tests each resource and sets it when
    it is not in the desired state, writes result.json. Authentication: app-only with the Dev app registration
    and its certificate (ApplicationId, TenantId, CertificateThumbprint). It never uses Ensure = Absent.
    NOT run by Claude. What is unverified is listed in validation/README.md (how Invoke-DscResource passes
    CIM instances for Assignments, the exact resource names, the authentication parameters).
#>
param(
    [Parameter(Mandatory)][string]$PlanPath,
    [Parameter(Mandatory)][string]$ResultPath,
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory)][string]$CertThumbprint
)

$ErrorActionPreference = 'Stop'

function ConvertTo-PlainHash($Object) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $hash = @{}
        foreach ($p in $Object.PSObject.Properties) { $hash[$p.Name] = ConvertTo-PlainHash $p.Value }
        return $hash
    }
    if ($Object -is [System.Collections.IEnumerable] -and $Object -isnot [string]) {
        $list = @()
        foreach ($e in $Object) { $list += , (ConvertTo-PlainHash $e) }
        return , $list
    }
    $Object
}

# Nested settings whose plan entry names a CIM class in '__CimClass' (Dev baseline: cross-tenant access partner,
# classes MSFT_AADCrossTenantAccessPolicy...). Children first, then the instance itself. Arrays stay arrays.
function ConvertTo-CimTree($Value) {
    if ($Value -is [hashtable]) {
        $copy = @{}
        foreach ($k in $Value.Keys) { if ($k -ne '__CimClass') { $copy[$k] = ConvertTo-CimTree $Value[$k] } }
        if ($Value.ContainsKey('__CimClass')) {
            return New-CimInstance -ClassName ([string]$Value['__CimClass']) -Namespace root/microsoft/Windows/DesiredStateConfiguration -Property $copy -ClientOnly
        }
        return $copy
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $list = @()
        foreach ($e in $Value) { $list += , (ConvertTo-CimTree $e) }
        if ($list.Count -gt 0 -and $list[0] -is [Microsoft.Management.Infrastructure.CimInstance]) { return , ([Microsoft.Management.Infrastructure.CimInstance[]]$list) }
        return , $list
    }
    $Value
}

$results = @()
try {
    Import-Module Microsoft365DSC -ErrorAction Stop
    $actions = @(Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json)
}
catch {
    $results += [pscustomobject]@{ Name = '(setup)'; ResourceType = ''; Status = 'failed'; Message = [string]$_.Exception.Message }
    $results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultPath
    exit 1
}

# The Microsoft365DSC resource names are inferred (see Get-DscResourceMap and, for all other types, the rule
# '<prefix><resource name>' of Get-ResourceTypeCatalog, ADR 0006). Check each name against the installed module once
# and use the exact name it reports (names match without regard to case); an action whose resource is missing fails on
# its own instead of stopping the run.
$available = @{}
foreach ($name in @($actions | ForEach-Object { [string]$_.DscResource } | Sort-Object -Unique)) {
    $found = @(Get-DscResource -Module Microsoft365DSC -Name $name -ErrorAction SilentlyContinue) | Select-Object -First 1
    $available[$name] = if ($found) { [string]$found.Name } else { '' }
}

foreach ($action in $actions) {
    try {
        $dscName = [string]$available[[string]$action.DscResource]
        if (-not $dscName) { throw "Microsoft365DSC has no resource '$($action.DscResource)' in this version; nothing was changed for it." }
        $props = ConvertTo-PlainHash $action.Properties
        if ($props.ContainsKey('Ensure') -and $props['Ensure'] -ne 'Present') { throw 'Ensure must be Present; the toolkit never deletes.' }
        if ($props.ContainsKey('Assignments')) {
            # CIM class per resource type from the TCM schema (Assignments items 'title'), default for most types.
            $class = if ([string]::IsNullOrWhiteSpace([string]$action.AssignmentClass)) { 'MSFT_DeviceManagementConfigurationPolicyAssignments' } else { [string]$action.AssignmentClass }
            $cim = @()
            foreach ($assignment in @($props['Assignments'])) {
                $cim += New-CimInstance -ClassName $class `
                    -Namespace root/microsoft/Windows/DesiredStateConfiguration -Property $assignment -ClientOnly
            }
            $props['Assignments'] = $cim
        }
        foreach ($key in @($props.Keys)) {
            if ($props[$key] -is [hashtable] -and $props[$key].ContainsKey('__CimClass')) { $props[$key] = ConvertTo-CimTree $props[$key] }
        }
        $props['ApplicationId'] = $ClientId
        $props['TenantId'] = $TenantId
        $props['CertificateThumbprint'] = $CertThumbprint

        $test = Invoke-DscResource -Name $dscName -ModuleName Microsoft365DSC -Method Test -Property $props
        if ($test.InDesiredState) {
            $results += [pscustomobject]@{ Name = $action.Name; ResourceType = $action.ResourceType; Status = 'unchanged'; Message = '' }
            continue
        }
        $null = Invoke-DscResource -Name $dscName -ModuleName Microsoft365DSC -Method Set -Property $props
        $results += [pscustomobject]@{ Name = $action.Name; ResourceType = $action.ResourceType; Status = 'applied'; Message = '' }
    }
    catch {
        $text = [string]$_.Exception.Message
        if ($text.Length -gt 300) { $text = $text.Substring(0, 300) }
        $results += [pscustomobject]@{ Name = $action.Name; ResourceType = $action.ResourceType; Status = 'failed'; Message = $text }
    }
}

ConvertTo-Json -InputObject @($results) -Depth 5 | Set-Content -LiteralPath $ResultPath
if (@($results | Where-Object { $_.Status -eq 'failed' }).Count -gt 0) { exit 1 }
exit 0
