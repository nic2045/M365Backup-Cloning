#requires -Version 7.0
Set-StrictMode -Version Latest

$script:ModuleRoot = $PSScriptRoot

foreach ($folder in 'Private', 'Public') {
    Get-ChildItem -Path (Join-Path $PSScriptRoot $folder) -Filter '*.ps1' -File |
        ForEach-Object { . $_.FullName }
}
