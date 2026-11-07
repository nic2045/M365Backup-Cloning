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
- `Operation`, `Status` and the audit counters are closed lists: a new value goes into the schema in the same pull request.
- Write routes (apply, reset with confirmation) come with #14 and use the same plan hash confirmation as the scripts.
- No field for passwords, tokens, client secrets, certificates or client IDs.

## Run the contract test

```powershell
Invoke-Pester tests/WebContract.Tests.ps1
```

## Versions and changes

| Version | Issue | Change |
|---|---|---|
| `1` | #44 | First contract: the core files as they were; the envelope adds `schemaVersion`, `id`, `kind`, `createdUtc`. |
| `2` | #51 (ADR 0009) | Every core file has `SchemaVersion`, `Kind` and `CreatedUtc`; plans also carry `SchemaVersion` and `Kind` inside. One plan shape for all kinds: same fields, same summary counters (0 when unused), `Licences` in every plan (reset: `Checked = false`), `Properties` always an object. Plans carry `TargetTenant` (shortened) and `TargetTenantHash` instead of the full `TargetTenantId`. Licence views share `Checked`, `Readable`, `Error`, `Available`. The suitability check uses `SchemaVersion`/`Kind` instead of `Schema`. `Operation`, `Status` and the audit counters are closed lists; every audit line has the same counters. Plan files of version 1 are refused with "make a new plan" (`Read-ApplyPlanFile`, apply gate). |
| `2` | #59 | Same version, only optional additions: list entries may carry `state` (`current`, `outdated`). A file in an older or unknown format is listed as `outdated` with its file time and without plan hash or summary, and its detail route answers **409** `unsupported-format` ("regenerate it with the scripts") instead of 500. A file the server cannot open stays 500 `unreadable-file`. |

## Start the backend (issue #55)

The read-only server in `web/api` (FastAPI) serves exactly the routes of `web/openapi.json`. It reads the files below `History/` (set another folder with `M365CLONING_HISTORY`), masks every tenant ID and every GUID in its answers (ADR 0009: the cross-tenant partner and the protected partner entry keep the full Prod ID in the files, never in the API), and validates every answer against the schema before it is sent; a body that does not match goes out as the `Error` schema with status 500. It has no write routes, no CORS and no generated docs, and binds to `127.0.0.1` unless `M365CLONING_API_HOST` says otherwise (port: `M365CLONING_API_PORT`, default 8000).

```bash
cd web/api
python -m venv .venv && . .venv/bin/activate
pip install --require-hashes -r requirements-dev.txt
pytest                 # contract test: routes, schema, masking, path checks
python -m m365api      # http://127.0.0.1:8000/api/status
```

The contract test builds a `History` folder from `web/mock/responses.json` and checks that every answer equals the example (masked) and matches the schema, that the app has no route outside `web/openapi.json`, that no answer contains a full GUID or the Prod tenant ID of the fixtures, and that ids outside `^[a-z0-9-]+$` or outside `History/reports` are refused.

## Start the frontend (issue #12)

The read-only interface in `web/ui` (FastAPI, Jinja2, HTMX 2.0.4 shipped as a file in `m365ui/static`, no CDN) renders the pages Overview, Reports (drift and suitability), Plans and Audit. It calls only the read routes of `web/openapi.json` (`/api/...`); any other path is refused before a request. It knows no file paths of the core and rebuilds none of its rules; filters on a report or plan only narrow what the API returned.

- With `M365_UI_API_BASE` (for example `http://127.0.0.1:8000`) it talks to the server in `web/api`.
- Without it, it answers from `web/mock/responses.json` and shows a yellow "Example data" banner (`M365_UI_MOCK_FILE` for another file).
- Every output is passed through a GUID mask as a second line of defence; the server masks already (ADR 0009).
- Status is shown as symbol, text and colour; tables become stacked rows below 40 rem, so the page never scrolls sideways (checked at 1280 and 390 px).

```bash
cd web/ui
python -m venv .venv && . .venv/bin/activate
pip install --require-hashes -r requirements-dev.txt     # includes web/api for the in-process test
pytest                                  # pages against the mock and against the real API in process
uvicorn m365ui.main:app --port 8080     # http://127.0.0.1:8080/  (mock unless M365_UI_API_BASE is set)
```

## Dependencies and lock files (issue #59)

`web/api` and `web/ui` keep their direct dependencies in `requirements.in` and `requirements-dev.in` (pinned, edited by hand). The `requirements.txt` and `requirements-dev.txt` next to them are lock files made by pip-tools: every package, also the indirect ones, with an exact version and its hashes. CI installs with `pip install --require-hashes`, so a package whose content changed on the index is refused. `web/ui/requirements-dev.in` includes `../api/requirements.in`, so a change of the API dependencies needs a new lock for both.

After changing an `.in` file, make the locks again with Python 3.12 (the CI version):

```bash
pip install pip-tools
cd web/api && pip-compile --generate-hashes --strip-extras --no-emit-index-url -o requirements.txt requirements.in \
  && pip-compile --generate-hashes --strip-extras --no-emit-index-url -o requirements-dev.txt requirements-dev.in
cd ../ui  && pip-compile --generate-hashes --strip-extras --no-emit-index-url -o requirements.txt requirements.in \
  && pip-compile --generate-hashes --strip-extras --no-emit-index-url -o requirements-dev.txt requirements-dev.in
```
