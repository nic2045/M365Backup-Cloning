Describe 'config.example.psd1' {
    BeforeAll { $script:Path = Join-Path $PSScriptRoot '..\config.example.psd1' }

    It 'parses' {
        { Import-PowerShellDataFile -Path $script:Path } | Should -Not -Throw
    }
    It 'contains placeholders only, no GUIDs' {
        (Get-Content -Raw $script:Path) | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    }
    It 'does not allow reset by default' {
        $c = Import-PowerShellDataFile -Path $script:Path
        $c.Customers[0].Dev.AllowReset | Should -BeFalse
    }
}
