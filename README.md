# M365Backup-Cloning

Dev tenant toolkit for Microsoft 365 / Intune: read and report differences between a Prod and a Dev tenant (UTCM), apply a mirror to the Dev tenant only (Microsoft365DSC), reset and rebuild the Dev tenant.

Status: #2 part 1 (read-only drift report) and part 2 (apply to Dev with preview and confirmation) are in the repository; nothing has been run against a real tenant yet (see `validation/README.md`). Origin: nic2045/SW-Depoyment#1585. Decisions: [`docs/adr/`](docs/adr/README.md).

## Rules
- Apply direction is Prod -> Dev only.
- No tenant data, certificates or secrets in this repository (`config.example.psd1` has placeholders only).
- Nothing runs against a real tenant without explicit approval.
- Destructive functions are guarded by a tenant ID allow list, a preview and a double confirmation.

## Third-party
See [`THIRD-PARTY.md`](THIRD-PARTY.md). License: MIT.

## Drift report (read only)

```powershell
Copy-Item config.example.psd1 config.psd1        # fill in your Prod/Dev pair; git-ignored
pwsh scripts/Get-DriftReport.ps1 -DryRun          # prints the plan, sends nothing
pwsh scripts/Get-DriftReport.ps1 -ProdToken $p -DevToken $d
pwsh scripts/Get-DriftReport.ps1 -SourceSnapshotPath prod.json -TargetSnapshotPath dev.json   # offline compare
```

- UTCM snapshot per tenant (Microsoft Graph `createSnapshot`, the only POST; it reads), kept under `History\Tenants\<Prod|Dev>\<timestamp>\`.
- Prod (desired) is compared with Dev (actual). Groups and assignments are matched by name, IDs and timestamps are ignored.
- Report: `History\reports\drift-*.json` and `.md`. An empty report means identical.
- Module: `src/M365Cloning`. Tests: `Invoke-Pester tests`. What needs a real tenant: `validation/README.md`.

## Apply Prod -> Dev (writes to the Dev tenant only)

```powershell
# 1. Plan: nothing is changed. Writes History\reports\apply-plan-*.md/.json and prints the plan hash.
pwsh scripts/Invoke-ApplyDev.ps1 -SourceSnapshotPath prod.json -TargetSnapshotPath dev.json
# 2. Read the plan, then apply exactly that plan (needs Dev.ApplyAllowed = $true in config.psd1).
pwsh scripts/Invoke-ApplyDev.ps1 -SourceSnapshotPath prod.json -TargetSnapshotPath dev.json -Apply -ConfirmPlanHash <hash>
```

- Never automatic: the hash of the plan you looked at is the confirmation (`-Confirm:$false` does not replace it). A changed tenant gives another hash and is refused.
- Create and update only. A resource that exists only in Dev is shown as skipped, never deleted (no `Ensure = Absent`).
- Groups and assignments by name. Anything that cannot be resolved (unknown group, assignment filter, specific users) is **blocked**, never widened.
- Conditional Access is always planned as Report-only, the break-glass accounts from `config.psd1` are always excluded; without them no policy is applied.
- Microsoft365DSC runs in its own Windows PowerShell 5.1 process. Refused attempts and applies are logged in `History\audit.jsonl` (no secrets).
