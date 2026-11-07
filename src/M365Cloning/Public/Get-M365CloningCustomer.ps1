function Get-M365CloningCustomer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [string]$Name
    )
    $customers = @($Config.Customers)
    if ($Name) {
        $match = $customers | Where-Object { $_.Name -eq $Name }
        if (-not $match) { throw "Customer '$Name' is not in the config." }
        return $match
    }
    if ($customers.Count -ne 1) { throw 'More than one customer in the config: pass -Name.' }
    $customers[0]
}
