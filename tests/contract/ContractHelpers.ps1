# Helpers for tests/WebContract.Tests.ps1 (issue #44). Plain functions, no Pester, so they can also be called
# from a console. Validation uses Test-Json (PowerShell 7.4: JSON Schema draft 2020-12), no network.

$script:ContractRoot = Join-Path $PSScriptRoot '..' '..'
$script:SchemaPath = Join-Path $script:ContractRoot 'schema' 'm365cloning.schema.json'
$script:OpenApiPath = Join-Path $script:ContractRoot 'web' 'openapi.json'
$script:MockPath = Join-Path $script:ContractRoot 'web' 'mock' 'responses.json'

function Get-ContractSchemaFile {
    <# Writes a schema whose root is one definition of schema/m365cloning.schema.json and returns its path. #>
    param([Parameter(Mandatory)][string]$Definition, [Parameter(Mandatory)][string]$Folder)
    $schema = Get-Content -LiteralPath $script:SchemaPath -Raw | ConvertFrom-Json -AsHashtable
    if (-not $schema['$defs'].ContainsKey($Definition)) { throw "Unknown schema definition '$Definition'." }
    $root = [ordered]@{ '$schema' = $schema['$schema']; '$ref' = "#/`$defs/$Definition"; '$defs' = $schema['$defs'] }
    $path = Join-Path $Folder "contract-$Definition.schema.json"
    $root | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $path -Encoding utf8
    $path
}

function Test-ContractJson {
    <# Returns the validation errors (empty = valid) of a JSON text against one schema definition. #>
    param([Parameter(Mandatory)][string]$Json, [Parameter(Mandatory)][string]$Definition, [Parameter(Mandatory)][string]$Folder)
    $file = Get-ContractSchemaFile -Definition $Definition -Folder $Folder
    $errs = $null
    $ok = Test-Json -Json $Json -SchemaFile $file -ErrorAction SilentlyContinue -ErrorVariable errs
    if ($ok) { @() } else { @($errs | ForEach-Object { $_.ToString() }) + @(if (-not $errs) { 'invalid' }) }
}

function Get-OpenApiResponseSchema {
    <# Name of the component schema for a route, method and status code; $null if the route or status is missing. #>
    param([Parameter(Mandatory)]$OpenApi, [Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Status)
    $route = $null
    foreach ($p in $OpenApi['paths'].Keys) {
        $rx = '^' + ([regex]::Replace([regex]::Escape($p), '\\\{[^}]+\}', '[^/]+')) + '$'
        if ($Path -match $rx -and ($null -eq $route -or $p -notmatch '\{')) { $route = $p }
    }
    if (-not $route) { return $null }
    $op = $OpenApi['paths'][$route][$Method.ToLowerInvariant()]
    if (-not $op -or -not $op['responses'].ContainsKey($Status)) { return $null }
    $resp = $op['responses'][$Status]
    if ($resp.ContainsKey('$ref')) { $resp = $OpenApi['components']['responses'][($resp['$ref'] -split '/')[-1]] }
    ($resp['content']['application/json']['schema']['$ref'] -split '/')[-1]
}

function Get-OpenApiProblem {
    <# Structural checks of web/openapi.json: version, read-only, sign-in required (ADR 0010),
       schemas for 200/400/401/403/500, all references resolve. #>
    param([Parameter(Mandatory)]$OpenApi, [Parameter(Mandatory)]$Schema)
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($OpenApi['openapi'] -notmatch '^3\.1\.\d+$') { $problems.Add("openapi version '$($OpenApi['openapi'])' is not 3.1.x") }
    $schemes = if ($OpenApi['components'].ContainsKey('securitySchemes')) { $OpenApi['components']['securitySchemes'] } else { @{} }
    if (-not $schemes.ContainsKey('bearerAuth') -or $schemes['bearerAuth']['scheme'] -ne 'bearer') { $problems.Add('components.securitySchemes has no bearerAuth') }
    if (-not (@($OpenApi['security']) | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.ContainsKey('bearerAuth') })) { $problems.Add('the API does not require bearerAuth (security)') }
    foreach ($p in $OpenApi['paths'].Keys) {
        if ($p -notlike '/api/*') { $problems.Add("$p is not below /api/") }
        foreach ($m in $OpenApi['paths'][$p].Keys) {
            if ($m -ne 'get') { $problems.Add("$m $p is not a read route (write routes come with #14)") ; continue }
            foreach ($code in '200', '400', '401', '403', '500') {
                $name = Get-OpenApiResponseSchema -OpenApi $OpenApi -Method $m -Path $p -Status $code
                if (-not $name) { $problems.Add("$m $p has no schema for $code") }
                elseif ($code -ne '200' -and $name -ne 'Error') { $problems.Add("$m $p uses '$name' for $code instead of Error") }
            }
        }
    }
    foreach ($n in $OpenApi['components']['schemas'].Keys) {
        $ref = [string]$OpenApi['components']['schemas'][$n]['$ref']
        if ($ref -notmatch '^\.\./schema/m365cloning\.schema\.json#/\$defs/(.+)$' -or -not $Schema['$defs'].ContainsKey($Matches[1])) {
            $problems.Add("components.schemas.$n does not point to a definition of schema/m365cloning.schema.json")
        }
    }
    $text = $OpenApi | ConvertTo-Json -Depth 50
    foreach ($m in [regex]::Matches($text, '"\$ref":\s*"#/components/(schemas|responses)/([^"]+)"')) {
        if (-not $OpenApi['components'][$m.Groups[1].Value].ContainsKey($m.Groups[2].Value)) { $problems.Add("unresolved reference $($m.Value)") }
    }
    $problems.ToArray()
}

function Get-SecretLikeKey {
    <# Every object key in a JSON document that names a secret value (a password, client secret, token, certificate
       thumbprint, client id or private key). Policy settings such as PasswordRequired are not secrets and pass.
       The contract and everything it describes must never carry such fields. #>
    param([Parameter(Mandatory)][AllowNull()]$Node, [string]$Path = '$')
    $found = [System.Collections.Generic.List[string]]::new()
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($k in $Node.Keys) {
            if ([string]$k -match '(?i)^(password|passwordprofile|initialpassword|secret|clientsecret|secretvalue|token|accesstoken|refreshtoken|idtoken|thumbprint|certthumbprint|certificate|certificatedata|clientid|privatekey)$') { $found.Add("$Path.$k") }
            foreach ($f in (Get-SecretLikeKey -Node $Node[$k] -Path "$Path.$k")) { $found.Add($f) }
        }
    }
    elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        $i = 0
        foreach ($item in $Node) { foreach ($f in (Get-SecretLikeKey -Node $item -Path "$Path[$i]")) { $found.Add($f) }; $i++ }
    }
    $found.ToArray()
}

function Invoke-ContractSampleRun {
    <# Runs the scripts offline against the test fixtures (no tenant, no network) and returns the History folder
       with the files they wrote: drift report, apply/baseline/reset(Align, Full)/users plans, suitability check,
       audit.jsonl. #>
    param([Parameter(Mandatory)][string]$HistoryRoot)
    $f = Join-Path $script:ContractRoot 'tests' 'fixtures'
    $s = Join-Path $script:ContractRoot 'scripts'
    $cfg = Join-Path $f 'config.valid.psd1'
    $prod = Join-Path $f 'prod.snapshot.json'; $dev = Join-Path $f 'dev.snapshot.json'
    $lic = Join-Path $f 'dev.subscribedskus.json'; $inv = Join-Path $f 'dev.reset-inventory.json'
    $null = & (Join-Path $s 'Get-DriftReport.ps1') -ConfigPath $cfg -SourceSnapshotPath $prod -TargetSnapshotPath $dev -HistoryRoot $HistoryRoot 6>$null
    $null = & (Join-Path $s 'Invoke-ApplyDev.ps1') -ConfigPath $cfg -SourceSnapshotPath $prod -TargetSnapshotPath $dev -LicencePath $lic -HistoryRoot $HistoryRoot 6>$null
    $null = & (Join-Path $s 'Invoke-DevBaseline.ps1') -ConfigPath $cfg -TargetSnapshotPath $dev -LicencePath $lic -HistoryRoot $HistoryRoot 6>$null
    $null = & (Join-Path $s 'Invoke-DevReset.ps1') -ConfigPath $cfg -Mode Full -InventoryPath $inv -HistoryRoot $HistoryRoot 6>$null
    $null = & (Join-Path $s 'Invoke-DevReset.ps1') -ConfigPath $cfg -Mode Align -InventoryPath $inv -SourceSnapshotPath $prod -TargetSnapshotPath $dev -HistoryRoot $HistoryRoot 6>$null
    $null = & (Join-Path $s 'Invoke-DevUsers.ps1') -ConfigPath (Join-Path $f 'contract' 'config.contract.psd1') -DirectoryPath (Join-Path $f 'contract' 'dev.directory.json') -LicencePath $lic -HistoryRoot $HistoryRoot 6>$null
    $null = & (Join-Path $s 'Invoke-TenantFitCheck.ps1') -ConfigPath $cfg -ProdLicencePath $lic -DevLicencePath $lic -ProdSnapshotPath $prod -HistoryRoot $HistoryRoot 6>$null
    $HistoryRoot
}

function Get-ContractDefinitionForFile {
    <# Which schema definition a file in History/reports follows, by its name prefix. #>
    param([Parameter(Mandatory)][string]$Name)
    switch -Regex ($Name) {
        '^drift-' { 'DriftReport'; break }
        '^tenantfit-' { 'FitCheck'; break }
        '^(apply-plan|dev-baseline-plan|dev-reset-plan-(align|full)|dev-users-plan)-' { 'PlanFile'; break }
        default { $null }
    }
}

function Get-ContractConfigLeak {
    <# Values of the fixture configuration that must never appear in a file the core writes (client IDs and
       certificate thumbprints of both tenants). Returns the values found in the text. #>
    param([Parameter(Mandatory)][string]$Text)
    $cfg = Import-PowerShellDataFile -LiteralPath (Join-Path $script:ContractRoot 'tests' 'fixtures' 'config.valid.psd1')
    @(foreach ($v in @($cfg.Prod.ClientId, $cfg.Prod.CertThumbprint, $cfg.Dev.ClientId, $cfg.Dev.CertThumbprint)) { if ($v -and $Text.Contains($v)) { $v } })
}
