# Web contract

How the core, the schema, the OpenAPI description and the later server and interface fit together (ADR 0002, ADR 0008, issue #44).

```
core (PowerShell)  --writes-->  History/reports/*.json, History/audit.jsonl, History/jobs/*
                                     |  format: schema/m365cloning.schema.json
server (FastAPI)  --reads, wraps in envelope-->  /api/...   (web/openapi.json)
                  --POST /api/jobs: writes History/jobs/<id>.json, starts scripts/Invoke-WebJob.ps1 (own process)
interface (Jinja2 + HTMX)  --calls only /api/...   (develops against web/mock/responses.json)
```

## Files

| File | Content |
|---|---|
| `schema/m365cloning.schema.json` | JSON Schema 2020-12 with one definition per format (`$defs`): `DriftReport`, `PlanFile`, `Plan`, `PlanAction`, `PlanSummary`, `PlanLicences`, `FitCheck`, `TenantLicences`, `AuditEntry`, `JobFile` (issue #14), and the API envelopes (`ReportList`, `ReportResponse`, `PlanList`, `PlanResponse`, `AuditPage`, `FitCheckResponse`, `Status`, `JobList`, `Job`, `JobRequest`, `Error`). |
| `web/openapi.json` | OpenAPI 3.1: read routes `GET /api/reports`, `/api/reports/{id}`, `/api/plans`, `/api/plans/{id}`, `/api/audit` (filters `mode`, `since`, `planHash`), `/api/fitcheck/latest`, `/api/status`, `/api/jobs`, `/api/jobs/{id}`; job routes `POST /api/jobs` and `POST /api/jobs/{id}/cancel` (issue #14, the only write routes). Its component schemas point into the schema file. |
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
- Write routes (issue #14, ADR 0012) only queue a job; they use the same plan hash confirmation as the scripts (and the typed Dev tenant ID for a reset), and the job runner and the script check it again.
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
| `2` | #60 (ADR 0010) | Same version, only additions: every route needs a bearer token (`security: bearerAuth`) and answers **401** (no or invalid token: `unauthorized`, `invalid-token`, `token-expired`, `sign-in-not-configured`) or **403** (`forbidden`, role missing) with the `Error` schema. `x-required-role` names the role (read routes: `Reader`). The audit line may carry `Actor` (the signed-in person in the web interface). |
| `2` | #59 | Same version, only optional additions: list entries may carry `state` (`current`, `outdated`). A file in an older or unknown format is listed as `outdated` with its file time and without plan hash or summary, and its detail route answers **409** `unsupported-format` ("regenerate it with the scripts") instead of 500. A file the server cannot open stays 500 `unreadable-file`. |
| `2` | #14, #66 (ADR 0012) | Same version, only additions: `Plan.Area` and `PlanListItem.area` (`Intune`; missing = all areas); job formats `JobFile` (History/jobs/<id>.json), `Job`, `JobList`, `JobRequest`; routes `GET /api/jobs`, `GET /api/jobs/{id}`, `POST /api/jobs` (202), `POST /api/jobs/{id}/cancel` (202); `x-required-role` of the write routes is `Applier|Resetter` (by action, see `src/M365Cloning/Data/WebJobs.json`); 409 codes `job-running`, `plan-changed`, `tenant-mismatch`, `job-finished`; 500 `job-start-failed`. Audit lines of a web job carry `Actor`. |
| `2` | #13 | Same version, only additions: audit mode `report` (one line per drift report, counts only); an apply writes one line per result (`applied`, `unchanged` or `failed to apply` with resource type and name; no properties, IDs or error text) before its summary line; `GET /api/audit` takes `planHash` (64 lowercase hex characters) to list the entries of one plan. Before/after values stay in the plan, found by its hash. |

## Start the backend (issue #55)

The read-only server in `web/api` (FastAPI) serves exactly the routes of `web/openapi.json`. It reads the files below `History/` (set another folder with `M365CLONING_HISTORY`), masks every tenant ID and every GUID in its answers (ADR 0009: the cross-tenant partner and the protected partner entry keep the full Prod ID in the files, never in the API), and validates every answer against the schema before it is sent; a body that does not match goes out as the `Error` schema with status 500. Its only write routes queue a job (see "Jobs" below). It has no CORS and no generated docs, and binds to `127.0.0.1` unless `M365CLONING_API_HOST` says otherwise (port: `M365CLONING_API_PORT`, default 8000).

```bash
cd web/api
python -m venv .venv && . .venv/bin/activate
pip install --require-hashes -r requirements-dev.txt
pytest                 # contract test: routes, schema, masking, path checks, sign-in
python -m m365api      # http://127.0.0.1:8000/api/status (needs a token, see "Sign-in")
```

The contract test builds a `History` folder from `web/mock/responses.json` and checks that every answer equals the example (masked) and matches the schema, that the app has no route outside `web/openapi.json`, that no answer contains a full GUID or the Prod tenant ID of the fixtures, and that ids outside `^[a-z0-9-]+$` or outside `History/reports` are refused.

## Start the frontend (issue #12)

The interface in `web/ui` (FastAPI, Jinja2, HTMX 2.0.4 shipped as a file in `m365ui/static`, no CDN) renders the pages Overview, the goals (Bring Dev in line, Start Dev fresh, Fill Dev), the area Intune, and the history (Jobs, Plans, Reports, Audit) (ADR 0012). It calls only the routes of `web/openapi.json` (`/api/...`): GET the read routes, POST only to queue or cancel a job; any other path is refused before a request. It knows no file paths of the core and rebuilds none of its rules; filters on a report or plan only narrow what the API returned.

- With `M365_UI_API_BASE` (for example `http://127.0.0.1:8000`) it talks to the server in `web/api`.
- Without it, it answers from `web/mock/responses.json` and shows a yellow "Example data" banner (`M365_UI_MOCK_FILE` for another file). Without sign-in the example person has every role; a button then shows the example answer and starts nothing.
- Every output is passed through a GUID mask as a second line of defence; the server masks already (ADR 0009).
- Status is shown as symbol, text and colour; tables become stacked rows below 40 rem, so the page never scrolls sideways (checked at 1280 and 390 px).

```bash
cd web/ui
python -m venv .venv && . .venv/bin/activate
pip install --require-hashes -r requirements-dev.txt     # includes web/api for the in-process test
pytest                                  # pages against the mock and against the real API in process
uvicorn m365ui.main:app --port 8080     # http://127.0.0.1:8080/  (mock unless M365_UI_API_BASE is set)
```

## Sign-in (issue #60, ADR 0010)

Both apps need sign-in. Nothing is configured: the API answers 401 to every request, and the interface opens only on the mock answers (for an "Example user"). Set the values as environment variables or from your secret store; never commit them. The app registration is described in `validation/README.md`, part "Web sign-in".

| Variable | App | Meaning |
|---|---|---|
| `M365CLONING_AUTH_TENANT_ID` | API | Your tenant ID (Entra ID tokens are accepted only from it) |
| `M365CLONING_AUTH_AUDIENCE` | API | Audience of the access token: the application (client) ID of the API registration; several values separated by commas |
| `M365_UI_OIDC_TENANT_ID` | UI | Your tenant ID |
| `M365_UI_OIDC_CLIENT_ID` | UI | Application (client) ID of the interface registration |
| `M365_UI_OIDC_API_SCOPE` | UI | Scope of the API, e.g. `api://<app id>/access_as_user` |
| `M365_UI_OIDC_REDIRECT_URI` | UI | e.g. `http://localhost:8080/auth/callback` (must match the registration) |
| `M365_UI_OIDC_CLIENT_SECRET` | UI | Only for a registration of the platform "Web" (hosted instance); from a secret store |
| `M365_UI_COOKIE_SECURE` | UI | `1`: always set `Secure` on cookies (behind TLS termination); default: only on https |
| `M365_UI_LOCAL_LOGIN` | UI | `1` switches the local account on (default off) |
| `M365_UI_LOCAL_USER` | UI | User name of the local account |
| `M365_UI_LOCAL_PASSWORD_HASH` | UI | scrypt hash from `python -m m365ui.passwords` (asks for the password, prints the hash) |
| `M365_UI_LOCAL_ROLE` | UI | `Reader` (default), `Applier` or `Resetter` |
| `M365CLONING_LOCAL_TOKEN_SECRET` | both | Shared secret (at least 32 bytes) for the short local tokens UI -> API, e.g. `openssl rand -hex 32` |

- Roles: `Reader` reads; `Applier` and `Resetter` include `Reader`. Starting a job needs the role of its action (`src/M365Cloning/Data/WebJobs.json`): reports and the plans of apply, base state and users `Applier`, reset preview and reset apply `Resetter`.
- The local account is offered and accepted only from `127.0.0.1`/`::1` without proxy headers. Do not put it behind a reverse proxy.
- The browser holds only an `HttpOnly`, `SameSite=Lax` session cookie (`Secure` on https); tokens stay on the server. Pages carry a CSRF token for every form (sign-out, start and cancel a job).
- Tests make their own keys and tokens (`web/api/tests/authkit.py`, `web/ui/tests/uikit.py`); nothing calls Entra ID.

## Jobs (issue #14, ADR 0012)

`POST /api/jobs` with a `JobRequest` (`{"action": "drift"}`, `{"action": "plan-apply", "area": "Intune"}`, `{"action": "plan-reset", "mode": "Full", "deviceAction": "Retire"}`, `{"action": "apply", "planId": "...", "confirmPlanHash": "...", "confirmTenant": "<Dev tenant ID, reset only>"}`) writes `History/jobs/<id>.json` and starts the job runner; the answer is 202 with the job. The runner keeps state, steps and result in the same file and writes the script output to `<id>.log` (the process output goes to `<id>.out`). Only one job runs at a time.

| Variable | Meaning |
|---|---|
| `M365CLONING_PWSH` | Path of PowerShell 7 (default `pwsh`) |
| `M365CLONING_CONFIG` | Path of `config.psd1` if it is not the one next to `scripts/` |

The account that runs the API needs the module Az.Accounts and the certificate of each app registration (thumbprints in the config) in its personal certificate store; the runner signs in with it through `Connect-AzAccount` and `Get-AzAccessToken` (ADR 0013). An apply runs Microsoft365DSC, so it needs Windows. Check on a real system: `validation/README.md`, part 14.

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
