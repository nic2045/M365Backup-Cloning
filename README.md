# M365Backup-Cloning

Dev tenant toolkit for Microsoft 365 / Intune: read and report differences between a Prod and a Dev tenant (UTCM), apply a mirror to the Dev tenant only (Microsoft365DSC), reset and rebuild the Dev tenant.

Status: part 1 of #2 (read-only drift report) in progress. Origin: nic2045/SW-Depoyment#1585. Decisions: [`docs/adr/`](docs/adr/README.md).

## Rules
- Apply direction is Prod -> Dev only.
- No tenant data, certificates or secrets in this repository (`config.example.psd1` has placeholders only).
- Nothing runs against a real tenant without explicit approval.
- Destructive functions are guarded by a tenant ID allow list, a preview and a double confirmation.

## Third-party
See [`THIRD-PARTY.md`](THIRD-PARTY.md). License: MIT.

## Drift report (read only)

```powershell
Copy-Item config.example.psd1 config.psd1        # fill in; git-ignored
pwsh scripts/Get-DriftReport.ps1 -DryRun          # prints the plan, sends nothing
pwsh scripts/Get-DriftReport.ps1 -ProdToken $p -DevToken $d
pwsh scripts/Get-DriftReport.ps1 -SourceSnapshotPath prod.json -TargetSnapshotPath dev.json   # offline compare
```

- UTCM snapshot per tenant (Microsoft Graph `createSnapshot`, the only POST; it reads), kept under `History\Tenants\<Customer>\<Prod|Dev>\<timestamp>\`.
- Prod (desired) is compared with Dev (actual). Groups and assignments are matched by name, IDs and timestamps are ignored.
- Report: `History\Tenants\<Customer>\reports\drift-*.json` and `.md`. An empty report means identical.
- Module: `src/M365Cloning`. Tests: `Invoke-Pester tests`. What needs a real tenant: `validation/README.md`.
