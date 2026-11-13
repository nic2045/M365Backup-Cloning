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
pwsh scripts/Get-DriftReport.ps1                      # without a token: signs in with the certificate of Prod.CertThumbprint and Dev.CertThumbprint (ADR 0021)
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
- Conditional Access dependencies (issue #33): named locations and custom authentication strengths are copied before the policies and matched by name; a policy that names a missing one is blocked (`needs-location`, `needs-auth-strength`). Built-in strengths are never touched. Authentication method policies are only reported (`skipped: report-only`), never applied, because they decide who can sign in. The reset deletes custom locations and strengths after the policies, keeps trusted locations and protects the locations of break-glass policies (validation part 8).
- Microsoft365DSC runs in its own Windows PowerShell 5.1 process. Drift reports, plans, refused attempts, applies (one line per object) and resets are logged in `History\audit.jsonl` (no secrets); the web interface shows and filters the log.

## Dev base state (writes to the Dev tenant only)

```powershell
# 1. Plan: reads a Dev snapshot (groups, cross-tenant access partners), nothing is changed.
#    Writes History\reports\dev-baseline-plan-*.md/.json; "Base state reached" = nothing planned or blocked.
pwsh scripts/Invoke-DevBaseline.ps1 -DevToken $d
# 2. Apply exactly that plan (needs Dev.ApplyAllowed = $true), then run step 1 again.
pwsh scripts/Invoke-DevBaseline.ps1 -DevToken $d -Apply -ConfirmPlanHash <hash>
```

- The base state is the section `Baseline` of `config.psd1` (all keys optional): the break-glass groups, one static, empty group per persona, extra exclusion groups, and the Prod tenant as partner in the cross-tenant access settings (B2B collaboration inbound allowed, invitations redeemed automatically). No app registrations, no cross-tenant sync.
- Only what is described is created or set; nothing is deleted, no member is added or removed. A dynamic group and a B2B rule that someone set differently are `blocked`, not changed.
- Order: this script first, then `Invoke-DevUsers.ps1` (needs the persona groups), then `Invoke-ApplyDev.ps1`. A later reset (#7) returns Dev to this base state.

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

## Copy all unless excluded (ADR 0006, issue #40)

The snapshot and the apply plan cover every resource type of the Tenant Configuration Management schema in the
workloads that are on (Entra and Intune by default, `Workloads` in `config.psd1`). The type list is data
(`src/M365Cloning/Data/ResourceTypes.psd1`, from the schema that Microsoft Learn links, with its date); the toolkit
never fetches it at run time. A type without a rule of its own goes through one generic path: IDs are removed, known
reference fields are matched by name or key (`Data/ResourceRules.psd1`, `References`), secret properties skip the
resource, and a remaining Prod object ID in a `...Id` / `...Ids` property blocks it. Types that make no sense in Dev are
on the exclusion list (`Data/ExcludedResourceTypes.psd1`, with a reason each; add more with `ExcludeResourceTypes` in
`config.psd1`). The plan shows per resource type how many entries are planned, blocked, skipped and excluded, and lists
the excluded types, so that the next type to exclude is easy to find. Conditional Access, groups, assignments, users,
the reset and the licence check keep their own rules.

## Licence check (read only, issue #32)

Every plan that writes to Dev (`Invoke-ApplyDev.ps1`, `Invoke-DevBaseline.ps1`, `Invoke-DevUsers.ps1`, and so the rebuild
after a reset) first reads the Dev licences (`GET /subscribedSkus`, permission `LicenseAssignment.Read.All`) and blocks
entries whose licence is missing, for example a risk-based Conditional Access policy without Entra ID P2
(`blocked: license: ...`). The rules are data in `src/M365Cloning/Data/LicenceRequirements.psd1`, each with its Learn
source. Offline: `-LicencePath <saved subscribedSkus JSON>`; without it an offline preview blocks every entry that needs
a licence (`license: not verified`). The preview shows a "Licences" section.

## Suitability check: is Dev enough? (read only, issue #39)

`scripts/Invoke-TenantFitCheck.ps1` compares the licences of Prod and Dev (`GET /subscribedSkus`) with what Prod uses
(features found in the newest Prod snapshot, matched with the same licence rules as the plan check) and answers with
a traffic light: **green** (Dev is enough), **yellow** (enough with gaps, the parts of Prod that cannot be mirrored are
listed), **red** (an equivalent tenant is needed) or **grey** (not verified: a licence list could not be read). It also
reports Dev SKUs in grace period, suspended or locked out, and fewer free licence units (enabled minus assigned) than
test users in `DevUsers` (yellow, never red).
Rules: `src/M365Cloning/Data/TenantFitRules.psd1`. Output: `History/reports/tenantfit-*.json` / `.md` and one audit
line; exit code 0 green, 1 yellow, 2 red, 3 grey. It only reads, so it may run on a schedule (ADR 0004): see `docs/automation.md`.

## Factory reset of Dev (deletes in the Dev tenant only, ADR 0005)

```powershell
# 1. Plan: nothing is changed. Mode Align (default) deletes only what exists in Dev but not in Prod;
#    -Mode Full deletes the whole reset scope except the protection list and the base state.
pwsh scripts/Invoke-DevReset.ps1 -ProdToken $p -DevToken $d
# 2. Run exactly that plan: needs Dev.AllowReset = $true, the plan hash and the Dev tenant ID as second confirmation.
#    -RebuildAfter then runs base state -> apply -> Dev users, each with its own plan and confirmation.
pwsh scripts/Invoke-DevReset.ps1 -Apply -ConfirmPlanHash <hash> -ConfirmTenant <Dev tenant ID> -ProdToken $p -DevToken $d
```

Never deleted: guests, synced objects, other member users, Microsoft 365 and role groups, app registrations,
cross-tenant settings. Devices (ADR 0007, issue #46) are kept unless chosen: `-DeviceAction Keep|Remove|Retire|Wipe`
for all, `-DeviceActionFile <.psd1/.json>` per device name (for example `@{ 'LAPTOP-01' = 'Retire' }`). Wipe needs
`Dev.AllowDeviceWipe = $true`; devices with a name from `Dev.ProtectedDevicePrefixes` and devices of protected users are
never touched; device actions run last. Pass the same device options with `-Apply` as with the preview. The Global Administrators of Prod (without break-glass) are always protected. Offline preview:
`-InventoryPath tests/fixtures/dev.reset-inventory.json` (Align also needs the two snapshot files).

## Intune backup and change history (read only, issue #68, ADR 0014)

```powershell
pwsh scripts/Invoke-IntuneBackup.ps1 -DryRun                      # names repository, Python and left-out types
pwsh scripts/Invoke-IntuneBackup.ps1 -ProdToken $p -DevToken $d
```

IntuneCD (backup only, never its update) reads the Intune configuration of both tenants into `intune/prod` and
`intune/dev` of your private configuration repository (`ConfigRepository` in `config.psd1`, ADR 0004), one commit per
run, nothing pushed. A failed run leaves the repository as it was. What changed is listed in
`History/reports/intune-backup-*.json` and on the page *History > Intune changes*. Needs Python 3.12 with
`pip install --require-hashes -r tools/intunecd/requirements.txt` and Git. Check on a real system: `validation/README.md`, part 15.

## Desired state export (read only, issue #27 part 1, ADR 0018)

```powershell
pwsh scripts/Export-DesiredState.ps1 -DryRun                 # names the repository; Dev is not read
pwsh scripts/Export-DesiredState.ps1 -ProdToken $p
pwsh scripts/Export-DesiredState.ps1 -SnapshotPath <prod snapshot.json>   # offline, from a saved Prod snapshot
```

Reads Prod (one UTCM snapshot, the resource types of the apply) and writes one normalised file per resource to
`desired/<type>/<name>.json` in your configuration repository: no IDs, no secrets, no tenant ID, groups and filters by
name. One commit per run, nothing pushed; a failed run leaves the repository as it was. Resources that are not written
(secrets, excluded types, missing filters) and what changed are listed in `History/reports/desired-export-*.json` and on
the page *History > Desired state*. `desired/` is the desired state the apply can build Dev from (below);
`intune/` (IntuneCD) stays the Intune history. Needs Git. Check on a real system: `validation/README.md`, part 18.

## Build Dev from the configuration repository (issue #27 part 2, ADR 0019)

```powershell
pwsh scripts/Invoke-ApplyDev.ps1 -Source Repository -DevToken $d            # plan from desired/, Prod is not read
pwsh scripts/Invoke-ApplyDev.ps1 -Source Repository -Apply -ConfirmPlanHash <hash> -DevToken $d
pwsh scripts/Invoke-DevReset.ps1 -Apply ... -RebuildAfter -RebuildSource Repository
```

The plan reads the committed `desired/` (an uncommitted change stops it) and compares it with Dev; it names the commit,
and the commit is part of the plan hash, so a changed desired state needs a new confirmation. All rules of the apply
stay. Default is `-Source Live` (Prod snapshot). In the web interface: *Bring Dev in line* or *Areas > Intune*, desired
state "Configuration repository". Check on a real system: `validation/README.md`, part 19.

## Sync report: configuration repository against Dev (issue #27 part 3, ADR 0020)

```powershell
pwsh scripts/Get-DriftReport.ps1 -Source Repository -DevToken $d                      # desired/ against Dev, Prod is not read
pwsh scripts/Get-DriftReport.ps1 -Source Repository -TargetSnapshotPath dev.json      # offline
pwsh scripts/Get-DriftReport.ps1 -Source Repository -DevToken $d -ReportExitCode      # schedule: 0 same, 1 differences, 3 not verified
```

The drift report with the repository as source shows what a plan from the same commit would change in Dev; it names
the commit. Read only; a schedule only reports (docs/automation.md). A rebuild with `-RebuildSource Repository` ends
with this report. What Prod changed since the last export is the commit diff of the next export (*History > Desired
state*). Default stays `-Source Live`. In the web interface: *Bring Dev in line*, step 1, desired state "Configuration
repository". Check on a real system: `validation/README.md`, part 20.

## Setup check (read only, issue #18)

```powershell
pwsh scripts/Invoke-SetupCheck.ps1 -Scope Config   # config, certificates, break-glass list, licences; no sign-in
pwsh scripts/Invoke-SetupCheck.ps1                 # also signs in to Prod and Dev and reads with GET only
```

Checks the config, the certificate of each app registration (store of this computer, end date), the sign-in and the
application permissions of both registrations (compared with `src/M365Cloning/Data/SetupRequirements.psd1`; Prod with a
write permission is red), the UTCM service principal in each tenant, the break-glass accounts in Dev and the licences
(the newest suitability check). Each check is green, yellow, red or grey (not checked) with what to do. It creates,
grants and changes nothing and writes only `History/reports/setup-check-*.json` (no IDs, thumbprints or account names).
In the web interface: *Settings* > *Setup check*. Exit code: 0 green, 1 yellow, 2 red, 3 grey. Check on a real system:
`validation/README.md`, part 16.

## Web contract (issue #44, ADR 0008)

The contract of the web server and interface (ADR 0002) is: `schema/m365cloning.schema.json` (formats the core writes and the API envelopes), `web/openapi.json` (read routes and the job routes) and `web/mock/responses.json` (example responses). `tests/WebContract.Tests.ps1` checks the core's files, the OpenAPI description and the mock against it. See [`docs/web-contract.md`](docs/web-contract.md).

## Start the web app (issue #79, ADR 0016)

```powershell
Copy-Item web.settings.example.psd1 web.settings.psd1   # fill in the Entra IDs (git-ignored)
pwsh scripts/Start-M365CloningWeb.ps1 -Check            # checks Python 3.12, settings and ports, starts nothing
pwsh scripts/Start-M365CloningWeb.ps1                   # sets up once, starts API and interface, opens the browser
```

Both apps listen on `127.0.0.1` only; Ctrl+C stops both. Normal sign-in is Entra ID with app roles. The local account is
a break-glass account for management only (role Reader). Step by step: [`docs/getting-started.md`](docs/getting-started.md).

## Web API (issues #55, #14)

`web/api` is the API server (FastAPI) for the routes of `web/openapi.json`: reports, plans, audit, suitability check, status and jobs from `History/`. Tenant IDs and GUIDs are masked in every answer. Its only write routes queue a job, which runs the scripts in its own process after the role and the confirmation are checked (ADR 0012). Start and test: see `docs/web-contract.md`, section "Start the backend".

## Web interface (issues #12, #14, #66)

`web/ui` is the interface (FastAPI, Jinja2, HTMX), organised by goals (Bring Dev in line, Start Dev fresh, Fill Dev), areas (Intune now, more later) and history (jobs, plans, reports, Intune changes, audit). Reports, plans, apply and reset start as jobs with steps and progress; nothing changes in Dev without a preview plan and your confirmation, a reset also needs the Dev tenant ID typed. It talks only to `/api/...` of `web/api`; without `M365_UI_API_BASE` it shows the example data of `web/mock/responses.json`. Start and test: see `docs/web-contract.md`, section "Start the frontend".

## Web sign-in (issue #60, ADR 0010)

API and interface need sign-in: Entra ID (OpenID Connect with PKCE) with the app roles `Reader`, `Applier`, `Resetter` assigned through groups; optionally a local account that works only on the same machine (`127.0.0.1`) and is off by default. Settings are environment variables (never in the repository): see `docs/web-contract.md`, section "Sign-in". App registration and check: `validation/README.md`, part "Web sign-in".
