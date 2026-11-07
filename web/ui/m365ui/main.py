"""Read-only pages: overview, reports, plans, audit (issue #12).

Run: ``uvicorn m365ui.main:app`` from web/ui. Without ``M365_UI_API_BASE`` the
pages show the mock answers of web/mock/responses.json and say so.

Filters on report and plan details work on the data the API returned (the API
has no filter for these); list filters are passed to the API as its parameters.

Sign-in (issue #60, ADR 0010): every page needs a session, see auth.py. Without a
session the browser goes to /login. Only in mock mode with no sign-in configured
the pages open for an example person, so the interface can be tried without a tenant.
"""

from __future__ import annotations

import hmac
import re
from pathlib import Path
from typing import Any

from urllib.parse import parse_qs

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from markupsafe import Markup

from . import auth as authmod
from .api_client import ApiResponse, BaseClient, client_from_env
from .auth import Session, SignInError, UiAuth
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


def secrets_equal(a: str, b: str) -> bool:
    return hmac.compare_digest(a.encode("utf-8"), b.encode("utf-8"))


def _pick(value: str | None, allowed: tuple[str, ...]) -> str:
    return value if value in allowed else ""


PUBLIC_PATHS = frozenset({"/login", "/login/local", "/auth/start", "/auth/callback"})
MAX_FORM_BYTES = 4096


def _headers(request: Request) -> dict[str, str]:
    return {k.lower(): v for k, v in request.headers.items()}


def _host(request: Request) -> str | None:
    return request.client.host if request.client else None


def create_app(client: BaseClient | None = None, auth: UiAuth | None = None) -> FastAPI:
    api = client or client_from_env()
    signin = auth if auth is not None else UiAuth.from_env()
    # No sign-in configured: only the mock may be shown, to an example person. A real server needs sign-in.
    open_example = api.mock and not signin.configured
    app = FastAPI(title="M365 Dev tenant toolkit", docs_url=None, redoc_url=None, openapi_url=None)
    app.mount("/static", StaticFiles(directory=HERE / "static"), name="static")
    templates = Jinja2Templates(directory=HERE / "templates")
    templates.env.finalize = mask_guids
    templates.env.globals.update(_=_, mock=api.mock)

    def secure(request: Request) -> bool:
        return signin.secure_cookies if signin.secure_cookies is not None else request.url.scheme == "https"

    def set_cookie(request: Request, response: Response, name: str, value: str, max_age: int) -> None:
        response.set_cookie(name, value, max_age=max_age, httponly=True, secure=secure(request), samesite="lax", path="/")

    def clear_cookie(request: Request, response: Response, name: str) -> None:
        response.delete_cookie(name, path="/", httponly=True, secure=secure(request), samesite="lax")

    @app.middleware("http")
    async def require_session(request: Request, call_next):
        path = request.url.path
        session = signin.session(request.cookies.get(authmod.SESSION_COOKIE))
        if session is None and open_example:
            session = signin.example_session()
        request.state.session = session
        if path.startswith("/static/") or path in PUBLIC_PATHS:
            return await call_next(request)
        if session is None:
            return RedirectResponse("/login", status_code=303)
        response = await call_next(request)
        response.headers.setdefault("Cache-Control", "no-store")
        return response

    def current(request: Request) -> Session | None:
        return getattr(request.state, "session", None)

    def call(request: Request, path: str, params: dict[str, Any] | None = None) -> ApiResponse:
        return api.get(path, params, token=signin.api_token(current(request)))

    def render(request: Request, name: str, http_status: int = 200, **ctx: Any) -> HTMLResponse:
        s = current(request)
        ctx.setdefault("user", s)
        ctx.setdefault("csrf_token", s.csrf if s else "")
        return templates.TemplateResponse(request, name, ctx, status_code=http_status)

    def failed(request: Request, res: ApiResponse) -> Response:
        if res.status == 401:
            # The API no longer accepts the sign-in (expired or revoked): sign in again.
            s = current(request)
            signin.end(s.sid if s else None)
            response = RedirectResponse("/login?expired=1", status_code=303)
            clear_cookie(request, response, authmod.SESSION_COOKIE)
            return response
        # 409: the stored file has an older format (issue #59); the page says how to regenerate it.
        status = res.status if res.status in (400, 403, 404, 409) else 502
        body = res.body if isinstance(res.body, dict) else {}
        return render(
            request, "error.html", http_status=status,
            code=body.get("code", "error"), message=body.get("message", _("The server answered with an error.")),
        )

    def bad_id(request: Request) -> HTMLResponse:
        return render(request, "error.html", http_status=400, code="invalid-id", message=_("This id is not valid."))

    def login_page(request: Request, message: str = "", http_status: int = 200) -> HTMLResponse:
        token = signin.new_login_csrf()
        response = render(
            request, "login.html", http_status=http_status, nav="login", user=None, message=message,
            oidc=signin.oidc is not None, local=signin.local_allowed(_host(request), _headers(request)),
            configured=signin.configured, login_csrf=token,
            expired=request.query_params.get("expired") == "1",
        )
        set_cookie(request, response, authmod.LOGIN_CSRF_COOKIE, token, 600)
        return response

    @app.get("/login", response_class=HTMLResponse)
    def login(request: Request):
        s = current(request)
        if s is not None and s.source != "example":
            return RedirectResponse("/", status_code=303)
        return login_page(request)

    @app.get("/auth/start")
    def auth_start(request: Request):
        if signin.oidc is None:
            return login_page(request, _("Sign-in with Microsoft is not configured."), 400)
        url, state = signin.start()
        response = RedirectResponse(url, status_code=303)
        set_cookie(request, response, authmod.STATE_COOKIE, state, authmod.PENDING_MAX_AGE)
        return response

    @app.get("/auth/callback")
    def auth_callback(request: Request, code: str | None = None, state: str | None = None, error: str | None = None):
        if error:
            return login_page(request, _("The sign-in with Microsoft was cancelled or refused."), 401)
        try:
            session = signin.finish(code, state, request.cookies.get(authmod.STATE_COOKIE))
        except SignInError as exc:
            response = login_page(request, _(str(exc)), 401)
            clear_cookie(request, response, authmod.STATE_COOKIE)
            return response
        response = RedirectResponse("/", status_code=303)
        clear_cookie(request, response, authmod.STATE_COOKIE)
        set_cookie(request, response, authmod.SESSION_COOKIE, session.sid, authmod.SESSION_MAX_AGE)
        return response

    @app.post("/login/local")
    async def login_local(request: Request):
        body = await request.body()
        if len(body) > MAX_FORM_BYTES:
            return login_page(request, _("The form is too large."), 400)
        form = {k: v[0] for k, v in parse_qs(body.decode("utf-8", "replace"), keep_blank_values=True).items()}
        cookie = request.cookies.get(authmod.LOGIN_CSRF_COOKIE, "")
        sent = form.get("csrf", "")
        if not cookie or not sent or not secrets_equal(cookie, sent):
            return login_page(request, _("The form has expired. Try again."), 400)
        try:
            session = signin.local_login(form.get("username", ""), form.get("password", ""), _host(request), _headers(request))
        except SignInError as exc:
            return login_page(request, _(str(exc)), 401)
        response = RedirectResponse("/", status_code=303)
        clear_cookie(request, response, authmod.LOGIN_CSRF_COOKIE)
        set_cookie(request, response, authmod.SESSION_COOKIE, session.sid, authmod.SESSION_MAX_AGE)
        return response

    @app.post("/logout")
    async def logout(request: Request):
        body = await request.body()
        form = {k: v[0] for k, v in parse_qs(body[:MAX_FORM_BYTES].decode("utf-8", "replace")).items()}
        s = current(request)
        if s is None or s.source == "example":
            return RedirectResponse("/login", status_code=303)
        if not signin.check_csrf(s, form.get("csrf") or request.headers.get("x-csrf-token")):
            return render(request, "error.html", http_status=403, code="csrf",
                          message=_("The form has expired. Reload the page and try again."))
        signin.end(s.sid)
        response = RedirectResponse("/login", status_code=303)
        clear_cookie(request, response, authmod.SESSION_COOKIE)
        return response

    @app.get("/", response_class=HTMLResponse)
    def overview(request: Request):
        status = call(request, "/api/status")
        if not status.ok:
            return failed(request, status)
        fit = call(request, "/api/fitcheck/latest")
        return render(request, "overview.html", nav="overview", status=status.body,
                      fit=fit.body if fit.ok else None)

    @app.get("/reports", response_class=HTMLResponse)
    def reports(request: Request, kind: str | None = None):
        kind = _pick(kind, REPORT_KINDS)
        res = call(request, "/api/reports", {"kind": kind})
        if not res.ok:
            return failed(request, res)
        return render(request, "reports.html", nav="reports", items=res.body.get("items", []),
                      kind=kind, kinds=REPORT_KINDS)

    @app.get("/reports/{report_id}", response_class=HTMLResponse)
    def report(request: Request, report_id: str, type: str | None = None, state: str | None = None):
        if not ID_RE.match(report_id):
            return bad_id(request)
        res = call(request, f"/api/reports/{report_id}")
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
        res = call(request, "/api/plans", {"kind": kind})
        if not res.ok:
            return failed(request, res)
        return render(request, "plans.html", nav="plans", items=res.body.get("items", []),
                      kind=kind, kinds=PLAN_KINDS)

    @app.get("/plans/{plan_id}", response_class=HTMLResponse)
    def plan(request: Request, plan_id: str, type: str | None = None, state: str | None = None):
        if not ID_RE.match(plan_id):
            return bad_id(request)
        res = call(request, f"/api/plans/{plan_id}")
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
        res = call(request, "/api/audit", {"mode": mode, "page": page if page > 1 else None})
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
