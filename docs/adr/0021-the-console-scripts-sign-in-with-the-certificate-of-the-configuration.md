# 0021 The console scripts sign in with the certificate of the configuration

Status: Accepted (2026-11-13, issue #87, owner in chat: certificate only, from the Windows certificate store by thumbprint). Builds on ADR 0013.

## Context
The web jobs sign in to the app registrations of Prod and Dev with their certificates (ADR 0013, Az.Accounts, `Get-WebJobGraphToken`), the apply signs in with the certificate itself (Microsoft365DSC), and the setup check looks at the certificates. The console scripts (`Get-DriftReport`, `Invoke-ApplyDev`, `Invoke-DevBaseline`, `Invoke-DevReset`, `Invoke-DevUsers`, `Export-DesiredState`, `Invoke-IntuneBackup`) still stopped unless the operator passed `-ProdToken` and `-DevToken` from somewhere else. `config.psd1` already requires `CertThumbprint` per side.

## Decision
1. **Certificate only.** There is no client secret in this toolkit and none is added: the app registrations of both tenants are reached with a certificate (`<Side>.CertThumbprint`, in the certificate store of the current user or the computer).
2. A new public function `Resolve-M365CloningToken -Config -Side [-Token]` returns the token that was passed, else signs in with the certificate of the configuration through the sign-in of the web jobs (`Get-WebJobGraphToken`, ADR 0013: no own token, JWT or signature code; a test checks for it).
3. Each script resolves its tokens right where it needed them before. A token that is passed still wins, so tests, pipelines and other sources keep working. Offline parameters (snapshot, inventory, directory) need no sign-in, as before.
4. The error names the side and the keys to check (`TenantId`, `ClientId`, `CertThumbprint`) and never the token, the private key or the thumbprint; `Invoke-SetupCheck -Scope Config` shows the certificate (present, private key, expiry).
5. Unchanged: no write path to Prod, `Invoke-UtcmGraphRequest` is the only Graph caller, Dev only for writes.

## Consequences
- `pwsh scripts/Get-DriftReport.ps1` works without a token on the computer that holds the certificates (needs the module Az.Accounts, like the web jobs).
- A real sign-in is checked on a real tenant and Windows (`validation/`), not in the unit tests.
