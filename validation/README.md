# Validation (run by the owner, not by Claude)

Everything here needs a real tenant. The unit tests (`tests/`) use mocks only. Nothing in this folder is run automatically. Read-only drift report, issue #2 part 1 (ADR 0001).

## Before the first run

| # | Check | How | Expected |
|---|---|---|---|
| 1 | UTCM service principal exists in **both** tenants | Follow Learn: *Set up authentication for Tenant Configuration Management APIs* (`utcm-authentication-setup`) | Service principal with the UTCM app id present |
| 2 | UTCM has read permissions for the resource types | Grant per resource type as listed on Learn (`utcm-intune-resources`, `utcm-entra-resources`) | Snapshot does not end `failed` or `partiallySuccessful` because of permissions |
| 3 | App registration per tenant with certificate | Prod: read-only. Dev: its own registration. Permission for the snapshot call: `ConfigurationMonitoring.ReadWrite.All` (the only one Learn lists for `createSnapshot`) | App-only token (scope `https://graph.microsoft.com/.default`) works |
| 4 | Licence / availability of the API in the tenant | `GET /v1.0/admin/configurationManagement/configurationSnapshotJobs` with the token | `200`, not `403`/`404` |

Note: `ConfigurationMonitoring.ReadWrite.All` is a write-named permission. The tool only ever sends `POST .../configurationSnapshots/createSnapshot` (guard in `Invoke-UtcmGraphRequest`, covered by tests) and GET requests. If you want the Prod registration to have less, check on Learn whether `ConfigurationMonitoring.Read.All` is enough for `createSnapshot` (the page lists only `ReadWrite`).

## Resource names (open, must be verified)

`Get-M365CloningDefaultResources` uses the documented pattern `microsoft.<workload>.<resource>`. Only `microsoft.entra.conditionalaccesspolicy` is named literally in the docs. The Intune, group and role names are inferred. Check each name against the *Supported ... resources* pages. A name the API does not know shows up as a failed or partial snapshot. Fix with `Resources = @(...)` in `config.psd1`.

## Run

1. `Copy-Item config.example.psd1 config.psd1` and fill in your Prod/Dev pair (real data stays in the git-ignored file).
2. Dry run, nothing is sent: `pwsh scripts/Get-DriftReport.ps1 -DryRun`
3. Get a token per tenant (your own way, certificate flow) as `SecureString`.
4. `pwsh scripts/Get-DriftReport.ps1 -ProdToken $prod -DevToken $dev`
5. Look at `History\reports\drift-*.md`.

## What to look at

| Check | Expected |
|---|---|
| Both snapshots end `succeeded` | `History\Tenants\Prod\<stamp>\meta.json` and `History\Tenants\Dev\...` exist |
| Snapshot shape | `snapshot.json` has `resources[]` with `displayName`, `resourceType`, `properties` (Learn: same schema as a configurationBaseline). If not, `Compare-TenantSnapshot` needs an adjustment. |
| Group names | Assignments carry `groupDisplayName`. If a resource type only has `groupId`, the report shows it as a difference (cannot be matched by name). Tell me which types. |
| Volatile fields | Differences that are only IDs or timestamps: tell me the property names, they go into the ignore list in `ConvertTo-FlatProperty`. |
| Equal tenants | A Dev tenant that is a copy of Prod gives an empty report. |
| Quotas | Snapshot: 20,000 resources per tenant per month, snapshots kept 7 days (we copy them). |
| Tenant untouched | Entra audit log / Intune audit shows only the snapshot job, no change. |

Report anything unexpected as an issue; no apply step exists yet (part 2).
