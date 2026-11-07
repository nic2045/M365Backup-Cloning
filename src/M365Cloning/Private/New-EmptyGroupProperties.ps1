function New-EmptyGroupProperties {
    <#
    .SYNOPSIS
        Properties of a static, empty security group for the Dev tenant (AADGroup, UTCM 'group' resource).
    .DESCRIPTION
        DisplayName and MailNickname are the keys of the resource; SecurityEnabled and MailEnabled are required.
        No Members, Owners, MemberOf, membership rule or licences: no Prod user comes along.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [string]$Description = '')

    $nick = ($Name -replace '[^A-Za-z0-9_-]', '')
    if ([string]::IsNullOrWhiteSpace($nick)) { $nick = 'group' }
    $props = [ordered]@{
        DisplayName     = $Name
        MailNickname    = $nick
        SecurityEnabled = $true
        MailEnabled     = $false
        Ensure          = 'Present'
    }
    if (-not [string]::IsNullOrWhiteSpace($Description)) { $props['Description'] = $Description }
    $props
}
