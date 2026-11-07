# Web contract

How the core, the schema, the OpenAPI description and the later server and interface fit together (ADR 0002, ADR 0008, issue #44).

```
core (PowerShell)  --writes-->  History/reports/*.json, History/audit.jsonl
                                     |  format: schema/m365cloning.schema.json
server (FastAPI, later)  --reads, wraps in envelope-->  /api/...   (web/openapi.json)
interface (Jinja2 + HTMX, later)  --calls only /api/...   (develops against web/mock/responses.json)
```

## Files

| File | Content |
|---|---|
| `schema/m365cloning.schema.json` | JSON Schema 2020-12 with one definition per format (`$defs`): `DriftReport`, `PlanFile`, `Plan`, `PlanAction`, `PlanSummary`, `PlanLicences`, `FitCheck`, `TenantLicences`, `AuditEntry`, and the API envelopes (`ReportList`, `ReportResponse`, `PlanList`, `PlanResponse`, `AuditPage`, `FitCheckResponse`, `Status`, `Error`). |
| `web/openapi.json` | OpenAPI 3.1, read routes only: `GET /api/reports`, `/api/reports/{id}`, `/api/plans`, `/api/plans/{id}`, `/api/audit`, `/api/fitcheck/latest`, `/api/status`. Its component schemas point into the schema file. |
| `web/mock/responses.json` | One example per route (and an example of 400 and 404), made offline from the test fixtures with invented values. Key: `<METHOD> <path>`. |
| `tests/WebContract.Tests.ps1` | Runs the scripts offline against the fixtures and validates every file they write; checks the OpenAPI description and the mock; checks that nothing carries a secret. |

## Ids and kinds

The `id` is the file base name below `History/reports` (for example `apply-plan-20261107-120000`). The `kind` comes from the prefix:

| Prefix | Kind | Route |
|---|---|---|
| `drift-` | `drift` | `/api/reports` |
| `tenantfit-` | `tenantfit` | `/api/reports`, `/api/fitcheck/latest` |
| `apply-plan-` | `apply` | `/api/plans` |
| `dev-baseline-plan-` | `baseline` | `/api/plans` |
| `dev-reset-plan-align-`, `dev-reset-plan-full-` | `reset` (with `mode`) | `/api/plans` |
| `dev-users-plan-` | `users` | `/api/plans` |

`/api/status` is the optional read-only status for consumers (ADR 0002 point 8): time of the latest drift report, number of differences, suitability status.

## Rules

- New or changed route, or a changed core file format: schema, OpenAPI entry, mock example and contract test in the same pull request.
- Adding an optional field keeps `schemaVersion`; removing, renaming or changing the meaning of a field raises it.
- Write routes (apply, reset with confirmation) come with #14 and use the same plan hash confirmation as the scripts.
- No field for passwords, tokens, client secrets, certificates or client IDs.

## Run the contract test

```powershell
Invoke-Pester tests/WebContract.Tests.ps1
```
