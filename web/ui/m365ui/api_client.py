"""Clients for the API (web/openapi.json).

The interface may only call the routes of the API: ``GET`` the read routes and
the jobs, ``POST`` only to queue or cancel a job (issue #14). ``HttpClient`` talks
to the real server, ``MockClient`` answers from web/mock/responses.json for
development and tests. Both refuse any other path. The bearer token of the signed-in person is
passed per call and only ever sent in the Authorization header (ADR 0010).
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping
from urllib.parse import urlencode

import httpx

# The read routes of web/openapi.json. Anything else is refused before a request.
ALLOWED_PATHS = (
    re.compile(r"^/api/reports$"),
    re.compile(r"^/api/reports/[a-z0-9-]{1,100}$"),
    re.compile(r"^/api/plans$"),
    re.compile(r"^/api/plans/[a-z0-9-]{1,100}$"),
    re.compile(r"^/api/audit$"),
    re.compile(r"^/api/fitcheck/latest$"),
    re.compile(r"^/api/status$"),
    re.compile(r"^/api/jobs$"),
    re.compile(r"^/api/jobs/job-[0-9]{8}-[0-9]{6}-[a-z0-9]{6}$"),
)
# The only write routes: queue a job, cancel a job (issue #14, ADR 0012).
ALLOWED_POSTS = (
    re.compile(r"^/api/jobs$"),
    re.compile(r"^/api/jobs/job-[0-9]{8}-[0-9]{6}-[a-z0-9]{6}/cancel$"),
)

DEFAULT_MOCK_FILE = Path(__file__).resolve().parents[2] / "mock" / "responses.json"


class ForbiddenPath(ValueError):
    """The interface tried to call a path that is not a read route of the API."""


@dataclass(frozen=True)
class ApiResponse:
    status: int
    body: Any

    @property
    def ok(self) -> bool:
        return 200 <= self.status < 300


def check_path(path: str) -> str:
    if not any(p.match(path) for p in ALLOWED_PATHS):
        raise ForbiddenPath(f"not an API read route: {path!r}")
    return path


def check_post(path: str) -> str:
    if not any(p.match(path) for p in ALLOWED_POSTS):
        raise ForbiddenPath(f"not an API write route: {path!r}")
    return path


def _clean(params: Mapping[str, Any] | None) -> dict[str, str]:
    return {k: str(v) for k, v in (params or {}).items() if v not in (None, "")}


class BaseClient:
    mock = False

    def get(self, path: str, params: Mapping[str, Any] | None = None, token: str | None = None) -> ApiResponse:
        return self._get(check_path(path), _clean(params), token)

    def _get(self, path: str, params: dict[str, str], token: str | None = None) -> ApiResponse:  # pragma: no cover
        raise NotImplementedError

    def post(self, path: str, body: Mapping[str, Any] | None = None, token: str | None = None) -> ApiResponse:
        return self._post(check_post(path), dict(body or {}), token)

    def _post(self, path: str, body: dict[str, Any], token: str | None = None) -> ApiResponse:  # pragma: no cover
        raise NotImplementedError


class HttpClient(BaseClient):
    def __init__(self, base_url: str = "", timeout: float = 10.0, transport: httpx.BaseTransport | None = None,
                 http: httpx.Client | None = None):
        # ``http`` lets tests hand in a ready client (e.g. a TestClient of the API app).
        self._client = http or httpx.Client(base_url=base_url.rstrip("/"), timeout=timeout, transport=transport)

    def _get(self, path: str, params: dict[str, str], token: str | None = None) -> ApiResponse:
        headers = {"Authorization": f"Bearer {token}"} if token else {}
        try:
            r = self._client.get(path, params=params, headers=headers)
        except httpx.HTTPError as exc:
            return ApiResponse(503, {"code": "backend-unreachable", "message": f"The server did not answer ({type(exc).__name__})."})
        try:
            body = r.json()
        except ValueError:
            return ApiResponse(502, {"code": "bad-response", "message": "The server did not answer with JSON."})
        return ApiResponse(r.status_code, body)

    def _post(self, path: str, body: dict[str, Any], token: str | None = None) -> ApiResponse:
        headers = {"Authorization": f"Bearer {token}"} if token else {}
        try:
            r = self._client.post(path, json=body, headers=headers)
        except httpx.HTTPError as exc:
            return ApiResponse(503, {"code": "backend-unreachable", "message": f"The server did not answer ({type(exc).__name__})."})
        try:
            answer = r.json()
        except ValueError:
            return ApiResponse(502, {"code": "bad-response", "message": "The server did not answer with JSON."})
        return ApiResponse(r.status_code, answer)


class MockClient(BaseClient):
    mock = True

    def __init__(self, file: Path | str = DEFAULT_MOCK_FILE):
        data = json.loads(Path(file).read_text(encoding="utf-8"))
        self._responses: dict[str, dict[str, Any]] = data["responses"]
        self.posted: list[tuple[str, dict[str, Any]]] = []

    def _get(self, path: str, params: dict[str, str], token: str | None = None) -> ApiResponse:
        keys = []
        if params:
            keys.append(f"GET {path}?{urlencode(params)}")
        keys.append(f"GET {path}")
        for key in keys:
            if key in self._responses:
                hit = self._responses[key]
                return ApiResponse(int(hit["status"]), hit["body"])
        return ApiResponse(404, {"code": "not-found", "message": "No mock answer for this route."})

    def _post(self, path: str, body: dict[str, Any], token: str | None = None) -> ApiResponse:
        """The example answer of the route; nothing is started. A cancel of any job answers with the cancel example."""
        self.posted.append((path, body))
        key = f"POST {path}"
        if key not in self._responses and path.endswith("/cancel"):
            key = next((k for k in self._responses if k.startswith("POST /api/jobs/") and k.endswith("/cancel")), key)
        hit = self._responses.get(key)
        if hit is None:
            return ApiResponse(404, {"code": "not-found", "message": "No mock answer for this route."})
        return ApiResponse(int(hit["status"]), hit["body"])


def client_from_env() -> BaseClient:
    """``M365_UI_API_BASE`` set: real server; otherwise the mock answers."""
    base = os.environ.get("M365_UI_API_BASE", "").strip()
    if base:
        return HttpClient(base)
    return MockClient(os.environ.get("M365_UI_MOCK_FILE") or DEFAULT_MOCK_FILE)
