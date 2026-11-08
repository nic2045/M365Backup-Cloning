"""Pages of the interface against the mock (issues #12, #14, #66)."""

import json
import re
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from m365ui.api_client import (
    ApiResponse, BaseClient, ForbiddenPath, HttpClient, MockClient, check_path, check_post,
)
from m365ui.main import create_app

import uikit

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

    def _get(self, path, params, token=None):
        self.paths.append(path)
        return self.inner._get(path, params, token)

    def _post(self, path, body, token=None):
        self.paths.append("POST " + path)
        return self.inner._post(path, body, token)


def signed_in(client: BaseClient) -> TestClient:
    """A real (non-mock) client needs a session: sign in through the fake Entra ID."""
    auth = uikit.ui_auth()
    web = TestClient(create_app(client, auth))
    assert uikit.sign_in(web, auth).status_code == 303
    return web


def mock_ids():
    responses = json.loads(MOCK_FILE.read_text(encoding="utf-8"))["responses"]
    reports = [k.split("/")[-1] for k, v in responses.items() if k.startswith("GET /api/reports/") and v["status"] == 200]
    plans = [k.split("/")[-1] for k, v in responses.items() if k.startswith("GET /api/plans/") and v["status"] == 200]
    jobs = [k.split("/")[-1] for k, v in responses.items() if k.startswith("GET /api/jobs/") and v["status"] == 200]
    return reports, plans, jobs


REPORTS, PLANS, JOBS = mock_ids()
GOAL_PAGES = ["/goals/align", "/goals/fresh", "/goals/fill", "/areas/intune", "/jobs", "/history/intune",
              "/history/intune?id=intune-backup-20261106-120000", "/settings/setup"]
PAGES = ["/", "/reports", "/reports?kind=drift", "/plans", "/plans?kind=reset", "/audit", "/audit?mode=plan"] \
    + [f"/reports/{r}" for r in REPORTS] + [f"/plans/{p}" for p in PLANS] + GOAL_PAGES + [f"/jobs/{j}" for j in JOBS]


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
        sample = re.sub(r"\{[^}]+\}", "job-20261107-121500-k3m9qa" if path.startswith("/api/jobs") else "example-1", path)
        assert set(ops) <= {"get", "post"}, path
        if "get" in ops:
            check_path(sample)
        if "post" in ops:
            check_post(sample)


@pytest.mark.parametrize("bad", ["/api/plans", "/api/reports", "/api/jobs/x/cancel", "/api/jobs/job-20261107-121500-k3m9qa", "/api/status"])
def test_client_posts_only_to_the_job_routes(bad):
    with pytest.raises(ForbiddenPath):
        MockClient(MOCK_FILE).post(bad, {})


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

        def _get(self, path, params, token=None):
            if path == "/api/status":
                return ApiResponse(200, {"schemaVersion": "2", "lastComparisonUtc": guid, "differences": 1,
                                         "fitStatus": "red", "reportId": "drift-1"})
            return ApiResponse(404, {"code": "not-found", "message": guid})

    html = signed_in(GuidClient()).get("/").text
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


FORM = re.compile(r'<form method="post" action="([^"]+)"[^>]*>(.*?)</form>', re.S)


def test_write_controls_post_only_to_jobs_with_csrf(web):
    """The only forms that change something start or cancel a job (or sign out); each carries the CSRF token."""
    seen = 0
    for page in PAGES:
        html = web.get(page).text
        assert "hx-post" not in html.lower()
        for action, inner in FORM.findall(html):
            assert action == "/jobs" or re.fullmatch(r"/jobs/job-[0-9]{8}-[0-9]{6}-[a-z0-9]{6}/cancel", action) or action == "/logout", action
            assert re.search(r'name="csrf" value="[^"]{20,}"', inner), (page, action)
            seen += 1
    assert seen > 0


def test_unreachable_backend_shows_error():
    def boom(request):
        raise httpx.ConnectError("down")

    client = HttpClient("http://backend.invalid", transport=httpx.MockTransport(boom))
    r = signed_in(client).get("/")
    assert r.status_code == 502 and "backend-unreachable" in r.text and "Example data" not in r.text


def test_http_client_passes_status_and_params():
    seen = {}

    def handler(request):
        seen["url"] = str(request.url)
        return httpx.Response(200, json={"schemaVersion": "2", "items": [], "page": 2, "pageSize": 50, "total": 0})

    client = HttpClient("http://backend.test", transport=httpx.MockTransport(handler))
    res = client.get("/api/audit", {"mode": "plan", "page": 2, "since": None})
    assert res.ok and seen["url"] == "http://backend.test/api/audit?mode=plan&page=2"


class OutdatedClient(BaseClient):
    """Lists with one outdated entry each; details of outdated entries answer 409 (issue #59)."""

    mock = False

    def _get(self, path, params, token=None):
        if path == "/api/plans":
            return ApiResponse(200, {"schemaVersion": "2", "items": [
                {"id": "apply-plan-20200101-000000", "kind": "apply", "createdUtc": "2020-01-01T00:00:00Z", "state": "outdated"}]})
        if path == "/api/reports":
            return ApiResponse(200, {"schemaVersion": "2", "items": [
                {"id": "drift-20200101-000000", "kind": "drift", "createdUtc": "2020-01-01T00:00:00Z", "state": "outdated"}]})
        return ApiResponse(409, {"code": "unsupported-format", "message": "The file has an older or unknown format. Regenerate it with the scripts."})


def test_outdated_entries_and_409_page():
    web = signed_in(OutdatedClient())
    plans = web.get("/plans")
    assert plans.status_code == 200
    assert "badge-warn" in plans.text and "Outdated" in plans.text and '<svg class="icon" aria-hidden="true"' in plans.text
    reports = web.get("/reports")
    assert "Outdated" in reports.text and "regenerate the report with the script" in reports.text
    for page in ("/plans/apply-plan-20200101-000000", "/reports/drift-20200101-000000"):
        r = web.get(page)
        assert r.status_code == 409
        assert "older or unknown format" in r.text and "Regenerate the plan or report" in r.text
