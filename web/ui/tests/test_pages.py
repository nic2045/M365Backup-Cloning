"""Pages of the read-only interface against the mock (issue #12)."""

import json
import re
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from m365ui.api_client import (
    ApiResponse, BaseClient, ForbiddenPath, HttpClient, MockClient, check_path,
)
from m365ui.main import create_app

MOCK_FILE = Path(__file__).resolve().parents[2] / "mock" / "responses.json"
OPENAPI_FILE = Path(__file__).resolve().parents[2] / "openapi.json"
GUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")


class RecordingClient(BaseClient):
    """Answers from the mock and records every path. Any path that is not a
    read route of the API fails in check_path (BaseClient.get)."""

    def __init__(self, inner: BaseClient):
        self.inner = inner
        self.paths: list[str] = []
        self.mock = True

    def _get(self, path, params):
        self.paths.append(path)
        return self.inner._get(path, params)


def mock_ids():
    responses = json.loads(MOCK_FILE.read_text(encoding="utf-8"))["responses"]
    reports = [k.split("/")[-1] for k, v in responses.items() if k.startswith("GET /api/reports/") and v["status"] == 200]
    plans = [k.split("/")[-1] for k, v in responses.items() if k.startswith("GET /api/plans/") and v["status"] == 200]
    return reports, plans


REPORTS, PLANS = mock_ids()
PAGES = ["/", "/reports", "/reports?kind=drift", "/plans", "/plans?kind=reset", "/audit", "/audit?mode=plan"] \
    + [f"/reports/{r}" for r in REPORTS] + [f"/plans/{p}" for p in PLANS]


@pytest.fixture()
def recorder():
    return RecordingClient(MockClient(MOCK_FILE))


@pytest.fixture()
def web(recorder):
    return TestClient(create_app(recorder))


@pytest.mark.parametrize("page", PAGES)
def test_every_page_renders_from_the_mock(web, page):
    r = web.get(page)
    assert r.status_code == 200, r.text[:500]
    assert "text/html" in r.headers["content-type"]
    assert "Example data" in r.text  # the mock banner


def test_mock_has_report_and_plan_pages():
    assert {"drift", "tenantfit"} <= {r.split("-")[0] for r in REPORTS}
    assert len(PLANS) >= 4


@pytest.mark.parametrize("page", PAGES)
def test_pages_call_only_api_read_routes(web, recorder, page):
    web.get(page)
    assert recorder.paths, "page made no API call"
    for p in recorder.paths:
        check_path(p)  # raises when not a read route


def test_allowed_paths_match_openapi():
    spec = json.loads(OPENAPI_FILE.read_text(encoding="utf-8"))
    for path, ops in spec["paths"].items():
        assert set(ops) == {"get"}, path
        sample = re.sub(r"\{[^}]+\}", "example-1", path)
        check_path(sample)


@pytest.mark.parametrize("bad", ["/", "/api", "/api/apply", "/api/plans/../x", "/admin", "/api/reports/ABC", "http://x/api/status"])
def test_client_refuses_other_paths(bad):
    with pytest.raises(ForbiddenPath):
        MockClient(MOCK_FILE).get(bad)


@pytest.mark.parametrize("page", PAGES)
def test_no_full_guid_in_pages(web, page):
    assert not GUID.search(web.get(page).text)


def test_guid_from_the_server_is_masked():
    guid = "1a2b3c4d-1111-2222-3333-444455556666"

    class GuidClient(BaseClient):
        mock = False

        def _get(self, path, params):
            if path == "/api/status":
                return ApiResponse(200, {"schemaVersion": "2", "lastComparisonUtc": guid, "differences": 1,
                                         "fitStatus": "red", "reportId": "drift-1"})
            return ApiResponse(404, {"code": "not-found", "message": guid})

    html = TestClient(create_app(GuidClient())).get("/").text
    assert guid not in html and "1a2b3c4d" in html


@pytest.mark.parametrize("page", PAGES)
def test_markup_is_not_escaped_twice(web, page):
    html = web.get(page).text
    assert "&amp;lt;" not in html and "&lt;select" not in html and "&lt;span" not in html


def test_filter_forms_have_selects(web):
    html = web.get("/plans/apply-plan-20261107-120000").text
    assert '<select name="type">' in html and '<select name="state">' in html


def test_drift_filter_by_type_and_state(web):
    rid = next(r for r in REPORTS if r.startswith("drift"))
    html = web.get(f"/reports/{rid}?state=changed").text
    assert "Windows baseline" in html and "CA require MFA" not in html
    html = web.get(f"/reports/{rid}?type=microsoft.entra.conditionalaccesspolicy").text
    assert "CA require MFA" in html and "Windows baseline" not in html


def test_plan_shows_summary_and_licences(web):
    html = web.get("/plans/apply-plan-20261107-120000").text
    for text in ("planned (copied)", "excluded", "blocked", "skipped", "Licences", "Available service plans"):
        assert text in html


def test_unknown_plan_is_404(web):
    r = web.get("/plans/apply-plan-19990101-000000")
    assert r.status_code == 404 and "No plan with this id." in r.text


def test_invalid_id_is_400_and_calls_nothing(web, recorder):
    r = web.get("/plans/BAD_ID")
    assert r.status_code == 400 and recorder.paths == []


def test_no_write_controls(web):
    for page in PAGES:
        html = web.get(page).text.lower()
        assert 'method="post"' not in html and "hx-post" not in html


def test_unreachable_backend_shows_error():
    def boom(request):
        raise httpx.ConnectError("down")

    client = HttpClient("http://backend.invalid", transport=httpx.MockTransport(boom))
    r = TestClient(create_app(client)).get("/")
    assert r.status_code == 502 and "backend-unreachable" in r.text and "Example data" not in r.text


def test_http_client_passes_status_and_params():
    seen = {}

    def handler(request):
        seen["url"] = str(request.url)
        return httpx.Response(200, json={"schemaVersion": "2", "items": [], "page": 2, "pageSize": 50, "total": 0})

    client = HttpClient("http://backend.test", transport=httpx.MockTransport(handler))
    res = client.get("/api/audit", {"mode": "plan", "page": 2, "since": None})
    assert res.ok and seen["url"] == "http://backend.test/api/audit?mode=plan&page=2"
