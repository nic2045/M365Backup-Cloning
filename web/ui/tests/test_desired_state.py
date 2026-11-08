"""Desired state (issue #27, ADR 0018): the page shows what the read-only export of Prod changed in the configuration
repository and which resources were not written; the export runs only as a job through the API."""

import re
from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient

from m365ui.api_client import MockClient
from m365ui.main import create_app

import uikit
from test_pages import MOCK_FILE, RecordingClient

NOW = datetime(2026, 11, 7, 12, 40, tzinfo=timezone.utc)
CSRF = re.compile(r'name="csrf" value="([^"]+)"')
LATEST = "desired-export-20261107-123000"
OLDER = "desired-export-20261106-123000"


@pytest.fixture()
def recorder():
    return RecordingClient(MockClient(MOCK_FILE))


@pytest.fixture()
def web(recorder):
    return TestClient(create_app(recorder, clock=lambda: NOW))


def test_menu_has_desired_state_under_history(web):
    html = web.get("/").text
    assert 'href="/history/desired"' in html
    assert html.index(">Intune changes<") < html.index(">Desired state<") < html.index(">Audit log<")


def test_latest_export_shows_changes_and_skipped_resources(web, recorder):
    html = web.get("/history/desired").text
    assert f"/api/desired-exports/{LATEST}" in recorder.paths
    assert "7a6b5c4d3e2f" in html and "7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b" not in html
    for text in ("Windows - Example baseline", "microsoft.entra.group", "SW-Ring2", "Example Wi-Fi", "secret:"):
        assert text in html, text
    assert ".json" not in html.split("<main", 1)[1]
    for word in ("Added", "Changed", "Removed"):
        assert f'<span class="badge-text">{word}</span>' in html


def test_an_older_export_without_changes_says_so(web):
    html = web.get(f"/history/desired?id={OLDER}").text
    assert "Nothing changed since the export before" in html
    assert "The desired state is the same as at the export before." in html
    assert '<tr aria-current="true">' in html


def test_a_bad_id_calls_nothing(web, recorder):
    assert web.get("/history/desired?id=../../etc").status_code == 400
    assert web.get("/history/desired?id=intune-backup-20261107-120000").status_code == 400
    assert not [p for p in recorder.paths if "etc" in p or "intune-backup-2026" in p]


def test_a_missing_export_shows_the_error_page(web):
    r = web.get("/history/desired?id=desired-export-19990101-000000")
    assert r.status_code == 404 and "No desired state export with this id." in r.text


def test_export_now_posts_an_export_job_without_extra_fields(web, recorder):
    page = web.get("/history/desired").text
    assert 'value="export-desired"' in page
    token = CSRF.search(page).group(1)
    r = web.post("/jobs", data={"csrf": token, "action": "export-desired", "area": "Intune"}, follow_redirects=False)
    assert r.status_code == 303
    assert recorder.inner.posted[-1] == ("/api/jobs", {"action": "export-desired"})


def test_reader_sees_no_export_button():
    auth = uikit.ui_auth(uikit.FakeEntra(roles=("Reader",)))
    web = TestClient(create_app(MockClient(MOCK_FILE), auth, clock=lambda: NOW))
    assert uikit.sign_in(web, auth).status_code == 303
    html = web.get("/history/desired").text
    assert 'value="export-desired"' not in html and "needs the role Applier" in html
    assert "Windows - Example baseline" in html


def test_audit_can_filter_export_lines(web):
    html = web.get("/audit?mode=export").text
    assert 'value="export"' in html and "Desired state export" in html


def test_the_interface_may_read_only_the_export_routes():
    from m365ui.api_client import ForbiddenPath, check_path
    assert check_path("/api/desired-exports") and check_path(f"/api/desired-exports/{LATEST}")
    with pytest.raises(ForbiddenPath):
        check_path("/api/desired-exports/../reports")
