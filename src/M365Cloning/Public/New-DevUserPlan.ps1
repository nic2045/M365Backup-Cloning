function New-DevUserPlan {
    <#
    .SYNOPSIS
        Pure function: plan for the Dev users of the positive list (issue #22). Writes nothing, calls nothing.
    .DESCRIPTION
        For each entry of Config.DevUsers (validated by Import-M365CloningConfig):
          TestUser   -> CreateUser (cloud account in Dev) unless a user with that UPN exists ('exists');
          AdminGuest -> InviteGuest (B2B invitation, no mail sent) unless a guest with that mail exists ('exists');
          both       -> AddMember to the Dev group of the persona (Get-PersonaGroupName), unless already a member.
        A persona group that does not exist in Dev blocks the entry ('needs-group'): run scripts/Invoke-ApplyDev.ps1
        first, it creates the persona groups as empty copies (ADR 0003). Only add, never remove or disable.
        Only accounts of the positive list are in the plan; break-glass accounts are refused by the config check.
        -Directory is the Dev state (Get-DevDirectory or a saved JSON file). No password is part of the plan.
        The plan has the shape of New-ApplyPlan (TargetTenantId, Actions, Summary) so Get-ApplyPlanHash and
        Export-ApplyPlan work on it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)]$Directory
    )

    foreach ($side in 'Prod', 'Dev') {
        if (-not $Config.Contains($side) -or $Config[$side] -isnot [System.Collections.IDictionary] -or
            [string]::IsNullOrWhiteSpace([string]$Config[$side]['TenantId'])) { throw "Config has no $side tenant ID." }
    }
    if ([string]$Config['Dev']['TenantId'] -eq [string]$Config['Prod']['TenantId']) {
        throw 'The target tenant ID equals the Prod tenant ID. Refused: Dev users are written to the Dev tenant only.'
    }

    $get = {
        param($o, [string]$k)
        if ($null -eq $o) { return $null }
        if ($o -is [System.Collections.IDictionary]) { return $o[$k] }
        $p = $o.PSObject.Properties[$k]
        if ($p) { $p.Value } else { $null }
    }
    $users = @(& $get $Directory 'Users')
    $groups = @(& $get $Directory 'Groups')
    $membersByGroup = & $get $Directory 'Members'
    $settings = Get-PersonaSettings -Config $Config
    $entries = if ($Config.Contains('DevUsers') -and $null -ne $Config['DevUsers']) { @($Config['DevUsers']) } else { @() }

    $actions = [System.Collections.Generic.List[object]]::new()
    $new = {
        param($Type, $Name, $Operation, $Status, $Reason, $Props)
        [ordered]@{
            ResourceType = $Type; Name = $Name; Operation = $Operation; Status = $Status; Reason = $Reason
            DscResource = ''; Differences = [object[]]@(); Properties = $Props
        }
    }

    foreach ($e in $entries) {
        $id = [string]$e['Id']; $kind = [string]$e['Type']; $persona = [string]$e['Persona']
        $groupName = Get-PersonaGroupName -Persona $persona -Settings $settings
        $group = @($groups | Where-Object { [string](& $get $_ 'displayName') -ieq $groupName }) | Select-Object -First 1

        if ($kind -eq 'TestUser') {
            $existing = @($users | Where-Object { [string](& $get $_ 'userPrincipalName') -ieq $id }) | Select-Object -First 1
            $type = 'microsoft.graph.user'; $op = 'CreateUser'
        }
        else {
            $existing = @($users | Where-Object { [string](& $get $_ 'mail') -ieq $id -and [string](& $get $_ 'userType') -ieq 'Guest' }) | Select-Object -First 1
            $type = 'microsoft.graph.invitation'; $op = 'InviteGuest'
        }

        if (-not $groupName -or -not $group) {
            $actions.Add((& $new $type $id $op 'blocked' "needs-group: the persona group '$groupName' (persona $persona) does not exist in Dev; run scripts/Invoke-ApplyDev.ps1 first" $null))
            continue
        }

        $existingId = if ($existing) { [string](& $get $existing 'id') } else { '' }
        if ($existing) {
            $actions.Add((& $new $type $id $op 'exists' 'the account already exists in Dev; only the group membership is checked' $null))
        }
        elseif ($kind -eq 'TestUser') {
            $display = if ([string]::IsNullOrWhiteSpace([string]$e['DisplayName'])) { ($id -split '@')[0] } else { [string]$e['DisplayName'] }
            $nick = (($id -split '@')[0] -replace '[^A-Za-z0-9._-]', '')
            $actions.Add((& $new $type $id $op 'planned' "test user (persona $persona); random initial password, change at first sign-in" ([ordered]@{
                            accountEnabled = $true; displayName = $display; mailNickname = $nick; userPrincipalName = $id })))
        }
        else {
            $props = [ordered]@{ invitedUserEmailAddress = $id; sendInvitationMessage = $false; inviteRedirectUrl = $(if ($Config.Contains('InviteRedirectUrl') -and $Config['InviteRedirectUrl']) { [string]$Config['InviteRedirectUrl'] } else { 'https://myapps.microsoft.com' }) }
            if (-not [string]::IsNullOrWhiteSpace([string]$e['DisplayName'])) { $props['invitedUserDisplayName'] = [string]$e['DisplayName'] }
            $actions.Add((& $new $type $id $op 'planned' "admin from Prod as B2B guest (persona $persona); no invitation mail" $props))
        }

        $groupId = [string](& $get $group 'id')
        $current = if ($membersByGroup) { @(& $get $membersByGroup ([string](& $get $group 'displayName'))) } else { @() }
        $memberName = "$id -> $groupName"
        if ($existingId -and ($current -contains $existingId)) {
            $actions.Add((& $new 'microsoft.graph.groupMember' $memberName 'AddMember' 'exists' 'already a member' $null))
        }
        else {
            $actions.Add((& $new 'microsoft.graph.groupMember' $memberName 'AddMember' 'planned' "add to the persona group (persona $persona); never removed" ([ordered]@{
                            GroupId = $groupId; GroupName = $groupName; UserRef = $id; MemberId = $existingId })))
        }
    }

    # Accounts first, then memberships; within that by name (ordinal, the same on every machine).
    $rank = @{ CreateUser = '0'; InviteGuest = '0'; AddMember = '1' }
    $keyed = [System.Collections.Generic.List[object]]::new()
    foreach ($a in $actions) { $keyed.Add([pscustomobject]@{ Key = ('{0}|{1}' -f $rank[$a['Operation']], [string]$a['Name']); Action = $a }) }
    $keyed.Sort([System.Comparison[object]] { param($x, $y) [string]::CompareOrdinal($x.Key, $y.Key) })
    $sorted = [object[]]@($keyed | ForEach-Object { $_.Action })
    $count = { param($status) @($sorted | Where-Object { $_['Status'] -eq $status }).Count }
    [ordered]@{
        Direction      = 'Dev users (positive list)'
        Title          = 'Dev users plan (preview, nothing was changed)'
        ApplyHint      = 'scripts/Invoke-DevUsers.ps1 -Apply -ConfirmPlanHash <hash above>'
        TargetTenantId = [string]$Config['Dev']['TenantId']
        Actions        = $sorted
        Notes          = [string[]]@()
        Summary        = [ordered]@{
            Planned = [int](& $count 'planned')
            Blocked = [int](& $count 'blocked')
            Skipped = [int](& $count 'skipped')
            Exists  = [int](& $count 'exists')
        }
    }
}
