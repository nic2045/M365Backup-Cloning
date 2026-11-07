"""FastAPI application: the routes of web/openapi.json, nothing else (ADR 0002, issue #55, issue #14).

Routes are thin: check the parameters (params.py), read the files (store.py), then every body goes through
the same exit: mask tenant IDs and GUIDs (masking.py) and validate against the schema (contract.py). A body
that does not match the schema is never sent; the client gets the Error schema with status 500 instead.
No CORS, no generated docs (the contract is web/openapi.json).
Every route needs a signed-in person with the role Reader (auth.py, ADR 0010); 401 and 403 use the Error schema.
Write routes (issue #14, ADR 0012) only queue a job (jobs.py) and start the job runner in its own process; the role
an action needs (Applier, Resetter) is checked here, the confirmation in jobs.py, and both again by the runner.
"""

from __future__ import annotations

import json
import logging
import os
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

from fastapi import Depends, FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from . import contract, params
from .auth import AuthConfig, AuthError, Principal, Verifier, require
from .jobs import MAX_BODY_BYTES, JobStore, Launcher, check_apply, parse_request, role_for
from .masking import mask_response
from .store import Store, StoreError

log = logging.getLogger("m365api")

HISTORY_ENV = "M365CLONING_HISTORY"


def default_history_dir() -> Path:
    configured = os.environ.get(HISTORY_ENV)
    return Path(configured) if configured else contract.REPO_ROOT / "History"


def error_response(status: int, code: str, message: str) -> JSONResponse:
    return JSONResponse(status_code=status, content={"code": code, "message": message})


def respond(definition: str, produce: Callable[[], dict[str, Any]], status: int = 200) -> JSONResponse:
    """Runs one route: produce the body, mask it, validate it, send it - or send the Error schema."""
    try:
        body = mask_response(produce())
    except (StoreError, AuthError) as exc:
        return error_response(exc.status, exc.code, exc.message)
    except Exception:  # noqa: BLE001 - never leak details of an internal error
        log.exception("route failed")
        return error_response(500, "internal-error", "The server could not answer this request.")
    problems = contract.errors(definition, body)
    if problems:
        log.error("response does not match %s: %s", definition, problems[:5])
        return error_response(500, "invalid-response", "The answer did not match the contract and was not sent.")
    return JSONResponse(status_code=status, content=body)


def create_app(history_dir: Path | str | None = None, auth: AuthConfig | None = None,
               launcher: Launcher | None = None, clock: Callable[[], datetime] | None = None) -> FastAPI:
    """``auth`` None: read from the environment (auth.AuthConfig.from_env). Nothing configured: every route 401.
    ``launcher`` starts the job runner (tests pass a fake; default: pwsh scripts/Invoke-WebJob.ps1)."""
    history = Path(history_dir) if history_dir else default_history_dir()
    store = Store(history)
    jobs = JobStore(history, launcher, clock)
    verifier = Verifier(auth if auth is not None else AuthConfig.from_env())

    def reader(request: Request) -> Principal:
        headers = {k.lower(): v for k, v in request.headers.items()}
        who = require(verifier, "Reader", request.headers.get("authorization"),
                      request.client.host if request.client else None, headers)
        request.state.principal = who
        return who

    def needs(request: Request, role: str) -> Principal:
        who: Principal = request.state.principal
        if not who.has(role):
            raise AuthError(403, "forbidden", f"This needs the role {role}.")
        return who

    async def json_body(request: Request) -> Any:
        raw = await request.body()
        if len(raw) > MAX_BODY_BYTES:
            raise StoreError(400, "invalid-parameter", "The request is too large.")
        if "application/json" not in request.headers.get("content-type", ""):
            raise StoreError(400, "invalid-parameter", "Send the request as JSON.")
        try:
            return json.loads(raw.decode("utf-8"))
        except ValueError as exc:
            raise StoreError(400, "invalid-parameter", "The request is not valid JSON.") from exc

    app = FastAPI(
        title="M365Backup-Cloning API",
        version=contract.schema_version(),
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
        dependencies=[Depends(reader)],
    )

    @app.exception_handler(AuthError)
    async def auth_error(_: Request, exc: AuthError) -> JSONResponse:
        res = error_response(exc.status, exc.code, exc.message)
        if exc.status == 401:
            res.headers["WWW-Authenticate"] = 'Bearer realm="m365cloning"'
        return res

    @app.exception_handler(StarletteHTTPException)
    async def http_error(_: Request, exc: StarletteHTTPException) -> JSONResponse:
        codes = {404: "not-found", 405: "method-not-allowed"}
        return error_response(exc.status_code, codes.get(exc.status_code, "http-error"), str(exc.detail))

    @app.exception_handler(RequestValidationError)
    async def validation_error(_: Request, exc: RequestValidationError) -> JSONResponse:
        return error_response(400, "invalid-parameter", "A parameter is not valid.")

    @app.get("/api/reports")
    def list_reports(kind: str | None = None) -> JSONResponse:
        return respond("ReportList", lambda: store.list_reports(params.optional_enum("kind", kind, "ReportKind")))

    @app.get("/api/reports/{id}")
    def get_report(id: str) -> JSONResponse:  # noqa: A002 - name from web/openapi.json
        return respond("ReportResponse", lambda: store.get_report(id))

    @app.get("/api/plans")
    def list_plans(kind: str | None = None) -> JSONResponse:
        return respond("PlanList", lambda: store.list_plans(params.optional_enum("kind", kind, "PlanKind")))

    @app.get("/api/plans/{id}")
    def get_plan(id: str) -> JSONResponse:  # noqa: A002 - name from web/openapi.json
        return respond("PlanResponse", lambda: store.get_plan(id))

    @app.get("/api/audit")
    def audit(mode: str | None = None, since: str | None = None, planHash: str | None = None,  # noqa: N803
              page: str | None = None, pageSize: str | None = None) -> JSONResponse:  # noqa: N803
        return respond(
            "AuditPage",
            lambda: store.audit_page(
                params.audit_mode(mode),
                params.since(since),
                params.bounded_int("page", page, 1, 1, None),
                params.bounded_int("pageSize", pageSize, 50, 1, 500),
                params.plan_hash(planHash),
            ),
        )

    @app.get("/api/fitcheck/latest")
    def fitcheck_latest() -> JSONResponse:
        return respond("FitCheckResponse", store.latest_fitcheck)

    @app.get("/api/status")
    def status() -> JSONResponse:
        return respond("Status", store.status)

    # --- jobs (issue #14, ADR 0012) ----------------------------------------------------------------------------

    @app.get("/api/jobs")
    def list_jobs() -> JSONResponse:
        return respond("JobList", jobs.list_jobs)

    @app.get("/api/jobs/{id}")
    def get_job(id: str) -> JSONResponse:  # noqa: A002 - name from web/openapi.json
        return respond("Job", lambda: jobs.get_job(id))

    @app.post("/api/jobs")
    async def start_job(request: Request) -> JSONResponse:
        try:
            req = parse_request(await json_body(request))
        except StoreError as exc:
            return error_response(exc.status, exc.code, exc.message)

        def produce() -> dict[str, Any]:
            plan = None
            plan_kind = None
            if req.action == "apply":
                plan = store.get_plan(req.plan_id or "")
                plan_kind = str(plan["kind"])
            who = needs(request, role_for(req.action, plan_kind))
            if plan is not None:
                check_apply(req, plan)
            return jobs.create(req, role_for(req.action, plan_kind), who.name, plan)

        return respond("Job", produce, status=202)

    @app.post("/api/jobs/{id}/cancel")
    def cancel_job(id: str, request: Request) -> JSONResponse:  # noqa: A002 - name from web/openapi.json
        def produce() -> dict[str, Any]:
            needs(request, jobs.role_of(id))
            return jobs.cancel(id)

        return respond("Job", produce, status=202)

    return app
