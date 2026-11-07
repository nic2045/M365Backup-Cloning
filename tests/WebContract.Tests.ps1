# Contract tests for the web API (issue #44, ADR 0008): the core's output files follow schema/m365cloning.schema.json,
# web/openapi.json is read-only and complete, and web/mock/responses.json follows the contract. Offline, mocks only.
BeforeAll {
    . (Join-Path $PSScriptRoot 'contract' 'ContractHelpers.ps1')
    $script:Work = Join-Path $TestDrive 'work'
    $null = New-Item -ItemType Directory -Path $script:Work -Force
    $script:Schema = Get-Content -LiteralPath $script:SchemaPath -Raw | ConvertFrom-Json -AsHashtable
    $script:OpenApi = Get-Content -LiteralPath $script:OpenApiPath -Raw | ConvertFrom-Json -AsHashtable
    $script:Mock = Get-Content -LiteralPath $script:MockPath -Raw | ConvertFrom-Json -AsHashtable
    $script:History = Invoke-ContractSampleRun -HistoryRoot (Join-Path $TestDrive 'History')
    $script:Files = @(Get-ChildItem -LiteralPath (Join-Path $script:History 'reports') -Filter '*.json')
}

Describe 'Core output files follow the schema' {
    It 'the offline run wrote every report and plan kind' {
        $names = $script:Files.Name
        foreach ($prefix in 'drift-', 'tenantfit-', 'apply-plan-', 'dev-baseline-plan-', 'dev-reset-plan-align-', 'dev-reset-plan-full-', 'dev-users-plan-') {
            @($names | Where-Object { $_ -like "$prefix*" }).Count | Should -BeGreaterThan 0 -Because "$prefix must be produced"
        }
    }
    It '<_> is valid' -ForEach @('drift-', 'tenantfit-', 'apply-plan-', 'dev-baseline-plan-', 'dev-reset-plan-align-', 'dev-reset-plan-full-', 'dev-users-plan-') {
        $prefix = $_   # inside Where-Object, $_ is the file, not the prefix
        $file = @($script:Files | Where-Object { $_.Name -like "$prefix*" })[0]
        $file | Should -Not -BeNullOrEmpty -Because "$prefix must be produced"
        $def = Get-ContractDefinitionForFile -Name $file.Name
        $def | Should -Not -BeNullOrEmpty
        Test-ContractJson -Json (Get-Content -LiteralPath $file.FullName -Raw) -Definition $def -Folder $script:Work | Should -BeNullOrEmpty
    }
    It 'every audit line is valid' {
        $lines = @(Get-Content -LiteralPath (Join-Path $script:History 'audit.jsonl'))
        $lines.Count | Should -BeGreaterThan 5
        foreach ($l in $lines) { Test-ContractJson -Json $l -Definition 'AuditEntry' -Folder $script:Work | Should -BeNullOrEmpty }
    }
    It 'an audit entry with an extra field is rejected (closed set of fields)' {
        $bad = '{"Timestamp":"2026-11-07T12:00:00Z","User":"x","Mode":"plan","PlanHash":"","TargetTenant":"t","Counts":{},"Reason":"","Token":"abc"}'
        Test-ContractJson -Json $bad -Definition 'AuditEntry' -Folder $script:Work | Should -Not -BeNullOrEmpty
    }
    It 'a plan file with a malformed hash is rejected' {
        $file = @($script:Files | Where-Object { $_.Name -like 'apply-plan-*' })[0]
        $plan = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
        $plan['PlanHash'] = 'not-a-hash'
        Test-ContractJson -Json ($plan | ConvertTo-Json -Depth 30) -Definition 'PlanFile' -Folder $script:Work | Should -Not -BeNullOrEmpty
    }
}

Describe 'No secrets in the contract or in what it describes' {
    It 'no output file has a secret-like key or a client ID or thumbprint of the configuration' {
        foreach ($f in $script:Files) {
            $text = Get-Content -LiteralPath $f.FullName -Raw
            Get-SecretLikeKey -Node ($text | ConvertFrom-Json -AsHashtable) | Should -BeNullOrEmpty -Because $f.Name
            Get-ContractConfigLeak -Text $text | Should -BeNullOrEmpty -Because $f.Name
        }
        $audit = Get-Content -LiteralPath (Join-Path $script:History 'audit.jsonl') -Raw
        Get-ContractConfigLeak -Text $audit | Should -BeNullOrEmpty
    }
    It 'schema, openapi.json and the mock have no secret-like key' {
        Get-SecretLikeKey -Node $script:Schema | Should -BeNullOrEmpty
        Get-SecretLikeKey -Node $script:OpenApi | Should -BeNullOrEmpty
        Get-SecretLikeKey -Node $script:Mock | Should -BeNullOrEmpty
    }
    It 'the users plan carries no initial password' {
        $file = @($script:Files | Where-Object { $_.Name -like 'dev-users-plan-*' })[0]
        (Get-Content -LiteralPath $file.FullName -Raw) | Should -Not -Match '(?i)"password'
    }
}

Describe 'web/openapi.json' {
    It 'is OpenAPI 3.1, read-only, with a 200 schema and the Error schema for 400 and 500 on every route' {
        Get-OpenApiProblem -OpenApi $script:OpenApi -Schema $script:Schema | Should -BeNullOrEmpty
    }
    It 'has the read routes of issue #44' {
        foreach ($p in '/api/reports', '/api/reports/{id}', '/api/plans', '/api/plans/{id}', '/api/audit', '/api/fitcheck/latest', '/api/status') {
            $script:OpenApi['paths'].ContainsKey($p) | Should -BeTrue -Because $p
        }
    }
    It 'reports a write route as a problem' {
        $copy = $script:OpenApi | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable
        $copy['paths']['/api/plans']['post'] = $copy['paths']['/api/plans']['get']
        (Get-OpenApiProblem -OpenApi $copy -Schema $script:Schema) -join ';' | Should -Match 'not a read route'
    }
    It 'reports a missing Error schema as a problem' {
        $copy = $script:OpenApi | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable
        $copy['paths']['/api/status']['get']['responses'].Remove('500')
        (Get-OpenApiProblem -OpenApi $copy -Schema $script:Schema) -join ';' | Should -Match 'no schema for 500'
    }
}

Describe 'web/mock/responses.json' {
    It 'has an example for every route' {
        $keys = @($script:Mock['responses'].Keys)
        foreach ($p in $script:OpenApi['paths'].Keys) {
            $rx = '^GET ' + ([regex]::Replace([regex]::Escape($p), '\\\{[^}]+\}', '[^/?]+')) + '(\?.*)?$'
            @($keys | Where-Object { $_ -match $rx }).Count | Should -BeGreaterThan 0 -Because $p
        }
    }
    It 'every example follows the schema of its route and status' {
        foreach ($k in $script:Mock['responses'].Keys) {
            $r = $script:Mock['responses'][$k]
            $method, $path = $k -split ' ', 2
            $name = Get-OpenApiResponseSchema -OpenApi $script:OpenApi -Method $method -Path (($path -split '\?')[0]) -Status ([string]$r['status'])
            $name | Should -Not -BeNullOrEmpty -Because $k
            Test-ContractJson -Json ($r['body'] | ConvertTo-Json -Depth 50) -Definition $name -Folder $script:Work | Should -BeNullOrEmpty -Because $k
        }
    }
}
