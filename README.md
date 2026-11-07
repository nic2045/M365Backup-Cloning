# M365Backup-Cloning

Dev tenant toolkit for Microsoft 365 / Intune: read and report differences between a Prod and a Dev tenant (UTCM), apply a mirror to the Dev tenant only (Microsoft365DSC), reset and rebuild the Dev tenant.

Status: drift report, apply to Dev (Intune configuration, compliance, endpoint security, update rings, filters, groups, Conditional Access) and Dev users are in the repository; nothing has been run against a real tenant yet (see `validation/README.md`). Origin: nic2045/SW-Depoyment#1585. Decisions: [`docs/adr/`](docs/adr/README.md).

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
- Groups and assignments by name. Anything that cannot be resolved (unknown exclusion group, unknown assignment filter, specific users) is **blocked**, never widened.
- Conditional Access is always planned as Report-only, the break-glass accounts from `config.psd1` are always excluded; without them no policy is applied.
- Conditional Access copy (ADR 0003): your real Prod policies are copied to Dev with their names. The groups they refer to are created in Dev as **static, empty** groups with the same name (no members, no dynamic rule); the policy then points to them by name. A group is a persona group by prefix and persona name (`CA-Persona-Admins`, `CA-Persona-Admins-...-Exclusions`) or through `PersonaMap` in `config.psd1` for other Prod names. A group without a recognisable persona that does not exist in Dev blocks the policy (`needs-group`); copied groups without a persona are listed under Notes in the plan.
- Intune (issue #2): configuration profiles (classic and Settings Catalog), compliance, endpoint security, update rings and assignment filters (list: `Get-M365CloningDefaultResources`). A missing **inclusion** group of an assignment is created empty and static; a missing exclusion group blocks the policy. Filters are matched by name; a filter that Dev lacks is created first and the policy follows in the next run (`needs-filter`). Profiles with secrets (Wi-Fi, VPN, wired network, certificates, encrypted OMA-URI values) are **skipped** (`secret:`), create them in Dev by hand. Role scope tags are not handled (no TCM resource). Apps are uploaded by SW-Depoyment.
- Microsoft365DSC runs in its own Windows PowerShell 5.1 process. Refused attempts and applies are logged in `History\audit.jsonl` (no secrets).

## Dev users: test users and invited admins (writes to the Dev tenant only)

```powershell
# 1. Plan: reads the Dev state (GET only), nothing is changed. Writes History\reports\dev-users-plan-*.md/.json.
pwsh scripts/Invoke-DevUsers.ps1 -DevToken $d
# 2. Apply exactly that plan (needs Dev.ApplyAllowed = $true).
pwsh scripts/Invoke-DevUsers.ps1 -DevToken $d -Apply -ConfirmPlanHash <hash> [-ShowInitialPasswords]
```

- Positive list `DevUsers` in `config.psd1`: `TestUser` (cloud account in Dev, Id = UPN) or `AdminGuest` (admin from Prod invited as B2B guest, Id = mail address), each with exactly one persona. Break-glass accounts are refused.
- Each account goes into the empty Dev group of its persona (prefix + persona or `PersonaMap`). A missing persona group blocks the entry (`needs-group`): run `Invoke-ApplyDev.ps1` first.
- Only add: nothing is removed, disabled or changed on existing accounts; existing accounts and memberships are shown as `exists`.
- Microsoft Graph with an allow list of three write endpoints (users, invitations, group members), Dev tenant only. No invitation mail is sent.
- Initial passwords: random, must be changed at first sign-in, never stored or logged. `-ShowInitialPasswords` prints them once to the console; without it an admin resets the password before the first sign-in.
- Cross-tenant sync as the automatic way is a later step (#21).
