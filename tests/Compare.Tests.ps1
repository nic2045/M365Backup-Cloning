BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'M365Cloning' 'M365Cloning.psd1') -Force
    $script:Prod = Read-UtcmSnapshotFile -Path (Join-Path $PSScriptRoot 'fixtures' 'prod.snapshot.json')
    $script:Dev = Read-UtcmSnapshotFile -Path (Join-Path $PSScriptRoot 'fixtures' 'dev.snapshot.json')

    function script:New-Snapshot($Resources) { @{ resources = @($Resources) } }
    function script:New-Policy($Name, $Props) {
        @{ displayName = $Name; resourceType = 'microsoft.intune.deviceconfigurationpolicywindows10'; properties = ($Props + @{ DisplayName = $Name }) }
    }
}

Describe 'Compare-TenantSnapshot' {
    It 'reports an empty report for identical snapshots (IDs are ignored)' {
        $a = script:New-Snapshot @(script:New-Policy 'P' @{ Id = 'id-1'; Enabled = $true })
        $b = script:New-Snapshot @(script:New-Policy 'P' @{ Id = 'id-2'; Enabled = $true })
        $r = Compare-TenantSnapshot -Source $a -Target $b
        $r.IsIdentical | Should -BeTrue
        $r.Summary.Unchanged | Should -Be 1
    }
    It 'reports a resource only in Prod as Added' {
        $a = script:New-Snapshot @(script:New-Policy 'P' @{ X = 1 })
        $r = Compare-TenantSnapshot -Source $a -Target (script:New-Snapshot @())
        $r.Summary.Added | Should -Be 1
        $r.Types[0].Added | Should -Contain 'P'
        $r.IsIdentical | Should -BeFalse
    }
    It 'reports a resource only in Dev as Removed' {
        $b = script:New-Snapshot @(script:New-Policy 'P' @{ X = 1 })
        $r = Compare-TenantSnapshot -Source (script:New-Snapshot @()) -Target $b
        $r.Summary.Removed | Should -Be 1
        $r.Types[0].Removed | Should -Contain 'P'
    }
    It 'reports a changed property with both values' {
        $a = script:New-Snapshot @(script:New-Policy 'P' @{ Len = 8 })
        $b = script:New-Snapshot @(script:New-Policy 'P' @{ Len = 12 })
        $r = Compare-TenantSnapshot -Source $a -Target $b
        $r.Summary.Changed | Should -Be 1
        $d = $r.Types[0].Changed[0].Differences[0]
        $d.Property | Should -Be 'Len'
        $d.Source | Should -Be '8'
        $d.Target | Should -Be '12'
    }
    It 'compares groups by name, not by ID' {
        $a = script:New-Snapshot @(script:New-Policy 'P' @{ Assignments = @(@{ groupId = 'g-prod'; groupDisplayName = 'SW-Ring1' }) })
        $b = script:New-Snapshot @(script:New-Policy 'P' @{ Assignments = @(@{ groupId = 'g-dev'; groupDisplayName = 'SW-Ring1' }) })
        (Compare-TenantSnapshot -Source $a -Target $b).IsIdentical | Should -BeTrue
    }
    It 'reports a different group name as a change' {
        $a = script:New-Snapshot @(script:New-Policy 'P' @{ Assignments = @(@{ groupId = 'g-1'; groupDisplayName = 'SW-Ring1' }) })
        $b = script:New-Snapshot @(script:New-Policy 'P' @{ Assignments = @(@{ groupId = 'g-1'; groupDisplayName = 'SW-Ring2' }) })
        (Compare-TenantSnapshot -Source $a -Target $b).Summary.Changed | Should -Be 1
    }
    It 'does not care about the order of list entries' {
        $a = script:New-Snapshot @(script:New-Policy 'P' @{ Tags = @('b', 'a', 'c') })
        $b = script:New-Snapshot @(script:New-Policy 'P' @{ Tags = @('c', 'a', 'b') })
        (Compare-TenantSnapshot -Source $a -Target $b).IsIdentical | Should -BeTrue
    }
    It 'handles the fixture pair (Added none, Removed 1, Changed 1)' {
        $r = Compare-TenantSnapshot -Source $script:Prod -Target $script:Dev
        $r.Summary.Added | Should -Be 1       # CA policy only in Prod
        $r.Summary.Removed | Should -Be 1     # 'Old dev only policy'
        $r.Summary.Changed | Should -Be 1     # PasswordMinimumLength 8 vs 12 (assignments equal by group name)
        ($r.Types | Where-Object ResourceType -EQ 'microsoft.intune.deviceconfigurationpolicywindows10').Changed[0].Differences.Property |
            Should -Be 'PasswordMinimumLength'
    }
    It 'matches the same resource type case-insensitively' {
        $a = @{ resources = @(@{ displayName = 'P'; resourceType = 'Microsoft.Entra.Group'; properties = @{ A = 1 } }) }
        $b = @{ resources = @(@{ displayName = 'P'; resourceType = 'microsoft.entra.group'; properties = @{ A = 1 } }) }
        (Compare-TenantSnapshot -Source $a -Target $b).IsIdentical | Should -BeTrue
    }
}

Describe 'ConvertTo-DriftReportMarkdown' {
    It 'says so when there are no differences' {
        $r = Compare-TenantSnapshot -Source $script:Prod -Target $script:Prod
        ConvertTo-DriftReportMarkdown -Report $r | Should -Match 'No differences'
    }
    It 'lists added, removed and changed entries' {
        $r = Compare-TenantSnapshot -Source $script:Prod -Target $script:Dev
        $md = ConvertTo-DriftReportMarkdown -Report $r
        $md | Should -Match 'Added: CA require MFA'
        $md | Should -Match 'Removed: Old dev only policy'
        $md | Should -Match 'PasswordMinimumLength'
    }
}

Describe 'Export-DriftReport' {
    It 'writes JSON and Markdown under reports' {
        $r = Compare-TenantSnapshot -Source $script:Prod -Target $script:Dev
        $f = Export-DriftReport -Report $r -HistoryRoot (Join-Path $TestDrive 'History')
        Test-Path $f.Json | Should -BeTrue
        Test-Path $f.Markdown | Should -BeTrue
        $f.Json | Should -BeLike '*reports*'
        (Get-Content $f.Json -Raw | ConvertFrom-Json).Summary.Changed | Should -Be 1
    }
}
