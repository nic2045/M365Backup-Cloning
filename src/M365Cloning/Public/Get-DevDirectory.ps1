function Get-DevDirectory {
    <#
    .SYNOPSIS
        Reads (GET only, through Invoke-UtcmGraphRequest) what New-DevUserPlan needs from the Dev tenant: the
        users of the positive list (Config.DevUsers), their persona groups and the groups' members.
    .DESCRIPTION
        Returns @{ Users = @(@{ id; userPrincipalName; mail; userType }); Groups = @(@{ id; displayName });
        Members = @{ <group name> = @(<member ids>) } }. Test users are looked up by userPrincipalName, invited
        admins by mail (guests). Single quotes in filter values are doubled (OData).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][securestring]$Token,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [string]$GraphRoot = 'https://graph.microsoft.com/v1.0'
    )
    $entries = if ($Config.Contains('DevUsers') -and $null -ne $Config['DevUsers']) { @($Config['DevUsers']) } else { @() }
    $settings = Get-PersonaSettings -Config $Config
    $UserPrincipalNames = @($entries | Where-Object { $_['Type'] -eq 'TestUser' } | ForEach-Object { [string]$_['Id'] })
    $GuestMails = @($entries | Where-Object { $_['Type'] -eq 'AdminGuest' } | ForEach-Object { [string]$_['Id'] })
    $GroupNames = @($entries | ForEach-Object { Get-PersonaGroupName -Persona ([string]@($_['Persona'])[0]) -Settings $settings } | Where-Object { $_ })
    $q = { param($v) ([string]$v).Replace("'", "''") }
    $getAll = {
        param($uri)
        $items = [System.Collections.Generic.List[object]]::new()
        while ($uri) {
            $r = Invoke-UtcmGraphRequest -Method GET -Uri $uri -Token $Token
            foreach ($v in @($r.value)) { if ($null -ne $v) { $items.Add($v) } }
            $uri = $r.'@odata.nextLink'
        }
        $items
    }
    $users = [System.Collections.Generic.List[object]]::new()
    foreach ($upn in $UserPrincipalNames) {
        $filter = [System.Uri]::EscapeDataString("userPrincipalName eq '$(& $q $upn)'")
        foreach ($u in (& $getAll "$GraphRoot/users?`$filter=$filter&`$select=id,userPrincipalName,mail,userType")) { $users.Add($u) }
    }
    foreach ($mail in $GuestMails) {
        $filter = [System.Uri]::EscapeDataString("mail eq '$(& $q $mail)'")
        foreach ($u in (& $getAll "$GraphRoot/users?`$filter=$filter&`$select=id,userPrincipalName,mail,userType")) { $users.Add($u) }
    }
    $groups = [System.Collections.Generic.List[object]]::new()
    $members = @{}
    foreach ($name in ($GroupNames | Select-Object -Unique)) {
        $filter = [System.Uri]::EscapeDataString("displayName eq '$(& $q $name)'")
        foreach ($g in (& $getAll "$GraphRoot/groups?`$filter=$filter&`$select=id,displayName")) {
            $groups.Add($g)
            $members[[string]$g.displayName] = [string[]]@((& $getAll "$GraphRoot/groups/$($g.id)/members?`$select=id") | ForEach-Object { [string]$_.id })
        }
    }
    @{ Users = [object[]]@($users); Groups = [object[]]@($groups); Members = $members }
}
