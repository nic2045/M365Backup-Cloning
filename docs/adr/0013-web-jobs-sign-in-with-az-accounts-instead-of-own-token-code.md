# 0013 Web jobs sign in with Az.Accounts instead of own token code

Status: Accepted (2026-11-07, issue #70). Supersedes point 7 ("Tokens and who", the sign-in part) of ADR 0012; the
`Actor` part of that point stays.

## Context

ADR 0012 let the job runner get its Graph tokens with own code (`Get-AppOnlyGraphToken`: client credentials with a
certificate assertion built and signed by the module). The working rules say reuse before building, and the reason
given for the own code was wrong: Az.Accounts does hand out a token (`Get-AzAccessToken`).

The preferred way is to hold no token at all: `Connect-MgGraph -ClientId -TenantId -CertificateThumbprint`
(Microsoft.Graph.Authentication) and `Invoke-MgGraphRequest` for every call. It does not fit the core as it is:

- The scripts and the core functions take one token per tenant (`-ProdToken`, `-DevToken`); the operator passes
  them on the console, and every Graph and UTCM call goes through one function (`Invoke-UtcmGraphRequest`, read
  only by construction) that puts the token into the header.
- One run reads Prod and Dev side by side (drift report and plan: a snapshot of each; reset: the Dev inventory and
  the Global Administrators of Prod). `Connect-MgGraph` keeps one connection per process, so every call would have
  to switch the connection between the tenants.

## Decision

1. The runner gets the token of each tenant it reads with **Az.Accounts**: `Connect-AzAccount -ServicePrincipal
   -ApplicationId -CertificateThumbprint -Tenant -Scope Process -SkipContextPopulation`, then
   `Get-AzAccessToken -ResourceUrl https://graph.microsoft.com`, then `Disconnect-AzAccount` (private function
   `Get-WebJobGraphToken`). `-Scope Process` keeps the Az context and its token cache off the disk.
2. A raw token is needed only there, for the reason above. It is kept as SecureString in memory and only put into the
   Authorization header by `Invoke-UtcmGraphRequest`. Microsoft365DSC (apply) signs in with the certificate itself.
3. No own token, JWT or signature code in the module. A test checks for it.
4. Moving every call to `Invoke-MgGraphRequest` (no token in our code at all) needs the core to switch from tokens to
   per-tenant connections; it is not done now and can be proposed as its own issue.

## Consequences

- The web host needs the module **Az.Accounts** (MIT) next to PowerShell 7, the module and the certificates.
- Tests mock the Az cmdlets; nothing signs in.
- Az.Accounts 5 returns the token as SecureString, older versions as a string; both are accepted.
