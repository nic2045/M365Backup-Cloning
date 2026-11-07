"""Read-only pages: overview, reports, plans, audit (issue #12).

Run: ``uvicorn m365ui.main:app`` from web/ui. Without ``M365_UI_API_BASE`` the
pages show the mock answers of web/mock/responses.json and say so.

Filters on report and plan details work on the data the API returned (the API
has no filter for these); list filters are passed to the API as its parameters.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from markupsafe import Markup

from .api_client import ApiResponse, BaseClient, client_from_env
from .i18n import _

HERE = Path(__file__).resolve().parent
ID_RE = re.compile(r"^[a-z0-9-]{1,100}$")
GUID_RE = re.compile(r"\b([0-9a-fA-F]{8})-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")

REPORT_KINDS = ("drift", "tenantfit")
PLAN_KINDS = ("apply", "baseline", "reset", "users")
AUDIT_MODES = ("plan", "apply", "reset", "fitcheck")
DRIFT_STATES = ("added", "removed", "changed", "unchanged")


def mask_guids(value: Any) -> Any:
    """Defence in depth (ADR 0009): no full GUID ever reaches a page, even if
    the server sent one. Applied to every ``{{ ... }}`` output."""
    if isinstance(value, str):
        masked = GUID_RE.sub(lambda m: m.group(1) + "…", str(value))
        # Markup (macro output) must stay Markup, or it would be escaped twice.
        return Markup(masked) if isinstance(value, Markup) else masked
    return value


def _pick(value: str | None, allowed: tuple[str, ...]) -> str:
    return value if value in allowed else ""


def create_app(client: BaseClient | None = None) -> FastAPI:
    api = client or client_from_env()
    app = FastAPI(title="M365 Dev tenant toolkit", docs_url=None, redoc_url=None, openapi_url=None)
    app.mount("/static", StaticFiles(directory=HERE / "static"), name="static")
    templates = Jinja2Templates(directory=HERE / "templates")
    templates.env.finalize = mask_guids
    templates.env.globals.update(_=_, mock=api.mock)

    def render(request: Request, name: str, http_status: int = 200, **ctx: Any) -> HTMLResponse:
        return templates.TemplateResponse(request, name, ctx, status_code=http_status)

    def failed(request: Request, res: ApiResponse) -> HTMLResponse:
        # 409: the stored file has an older format (issue #59); the page says how to regenerate it.
        status = res.status if res.status in (400, 404, 409) else 502
        body = res.body if isinstance(res.body, dict) else {}
        return render(
            request, "error.html", http_status=status,
            code=body.get("code", "error"), message=body.get("message", _("The server answered with an error.")),
        )

    def bad_id(request: Request) -> HTMLResponse:
        return render(request, "error.html", http_status=400, code="invalid-id", message=_("This id is not valid."))

    @app.get("/", response_class=HTMLResponse)
    def overview(request: Request):
        status = api.get("/api/status")
        if not status.ok:
            return failed(request, status)
        fit = api.get("/api/fitcheck/latest")
        return render(request, "overview.html", nav="overview", status=status.body,
                      fit=fit.body if fit.ok else None)

    @app.get("/reports", response_class=HTMLResponse)
    def reports(request: Request, kind: str | None = None):
        kind = _pick(kind, REPORT_KINDS)
        res = api.get("/api/reports", {"kind": kind})
        if not res.ok:
            return failed(request, res)
        return render(request, "reports.html", nav="reports", items=res.body.get("items", []),
                      kind=kind, kinds=REPORT_KINDS)

    @app.get("/reports/{report_id}", response_class=HTMLResponse)
    def report(request: Request, report_id: str, type: str | None = None, state: str | None = None):
        if not ID_RE.match(report_id):
            return bad_id(request)
        res = api.get(f"/api/reports/{report_id}")
        if not res.ok:
            return failed(request, res)
        body = res.body
        data = body.get("report", {})
        if body.get("kind") == "tenantfit":
            return render(request, "report_fit.html", nav="reports", env=body, fit=data)
        all_types = data.get("Types", [])
        state = _pick(state, DRIFT_STATES)
        rows = [t for t in all_types if not type or t.get("ResourceType") == type]
        if state:
            rows = [t for t in rows if (t.get("Unchanged", 0) if state == "unchanged" else len(t.get(state.capitalize(), [])))]
        return render(request, "report_drift.html", nav="reports", env=body, report=data, rows=rows,
                      type_names=sorted({t.get("ResourceType", "") for t in all_types}),
                      type=type or "", state=state, states=DRIFT_STATES)

    @app.get("/plans", response_class=HTMLResponse)
    def plans(request: Request, kind: str | None = None):
        kind = _pick(kind, PLAN_KINDS)
        res = api.get("/api/plans", {"kind": kind})
        if not res.ok:
            return failed(request, res)
        return render(request, "plans.html", nav="plans", items=res.body.get("items", []),
                      kind=kind, kinds=PLAN_KINDS)

    @app.get("/plans/{plan_id}", response_class=HTMLResponse)
    def plan(request: Request, plan_id: str, type: str | None = None, state: str | None = None):
        if not ID_RE.match(plan_id):
            return bad_id(request)
        res = api.get(f"/api/plans/{plan_id}")
        if not res.ok:
            return failed(request, res)
        body = res.body
        data = body.get("plan", {})
        actions = data.get("Actions", [])
        states = sorted({a.get("Status", "") for a in actions if a.get("Status")})
        state = state if state in states else ""
        rows = [a for a in actions if (not type or a.get("ResourceType") == type) and (not state or a.get("Status") == state)]
        return render(request, "plan.html", nav="plans", env=body, plan=data, rows=rows,
                      type_names=sorted({a.get("ResourceType", "") for a in actions}),
                      type=type or "", state=state, states=states)

    @app.get("/audit", response_class=HTMLResponse)
    def audit(request: Request, mode: str | None = None, page: int = 1):
        mode = _pick(mode, AUDIT_MODES)
        page = max(1, min(page, 100000))
        res = api.get("/api/audit", {"mode": mode, "page": page if page > 1 else None})
        if not res.ok:
            return failed(request, res)
        body = res.body
        size = max(1, int(body.get("pageSize", 50)))
        total = int(body.get("total", 0))
        pages = max(1, -(-total // size))
        return render(request, "audit.html", nav="audit", items=body.get("items", []), mode=mode,
                      modes=AUDIT_MODES, page=int(body.get("page", page)), pages=pages, total=total)

    return app


app = create_app()
