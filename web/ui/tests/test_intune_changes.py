"""Intune changes (issue #68, ADR 0014): the page shows what the read-only IntuneCD backup found changed, and starts
the backup only as a job through the API."""

import re
from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient

from m365ui import view
from m365ui.api_client import MockClient
from m365ui.main import create_app

import uikit
from test_pages import MOCK_FILE, RecordingClient

NOW = datetime(2026, 11, 7, 12, 20, tzinfo=timezone.utc)
CSRF = re.compile(r'name="csrf" value="([^"]+)"')
LATEST = "intune-backup-20261107-120000"
OLDER = "intune-backup-20261106-120000"


@pytest.fixture()
def recorder():
    return RecordingClient(MockClient(MOCK_FILE))


@pytest.fixture()
def web(recorder):
    return TestClient(create_app(recorder, clock=lambda: NOW))


def test_menu_has_intune_changes_under_history(web):
    html = web.get("/").text
    assert 'href="/history/intune"' in html
    assert html.index(">Reports<") < html.index(">Intune changes<") < html.index(">Audit log<")


def test_latest_run_is_shown_with_changes_per_tenant(web, recorder):
    html = web.get("/history/intune").text
    assert f"/api/intune-backups/{LATEST}" in recorder.paths
    assert "3f1c2a9e8b7d" in html and "3f1c2a9e8b7d6c5b4a39281706f5e4d3c2b1a090" not in html  # short commit only
    for text in ("Windows - Example security baseline", "Windows - Example Wi-Fi", "Settings Catalog", "Prod", "Dev"):
        assert text in html, text
    assert ".json" not in html.split("<main", 1)[1]  # names without the file ending
    for word in ("Added", "Changed", "Removed"):
        assert f'<span class="badge-text">{word}</span>' in html


def test_changes_are_sorted_added_changed_removed_within_a_type(web):
    groups = view.change_groups({"Changes": [
        {"Path": "B/x.json", "Change": "removed"}, {"Path": "B/a.json", "Change": "changed"},
        {"Path": "A/z.json", "Change": "added"}, {"Path": "B/c.json", "Change": "added"}]})
    assert [g["folder"] for g in groups] == ["A", "B"]
    assert [(r["name"], r["change"]) for r in groups[1]["rows"]] == [("c", "added"), ("a", "changed"), ("x", "removed")]


def test_an_older_run_without_changes_says_so(web):
    html = web.get(f"/history/intune?id={OLDER}").text
    assert "Nothing changed since the run before" in html
    assert html.count("The backup of this tenant is the same as the run before.") == 2
    assert f'<tr aria-current="true">' in html


def test_runs_list_links_each_run(web):
    html = web.get("/history/intune").text
    assert f'href="/history/intune?id={OLDER}"' in html and f'href="/history/intune?id={LATEST}"' in html


def test_a_bad_id_calls_nothing(web, recorder):
    assert web.get("/history/intune?id=../../etc").status_code == 400
    assert web.get("/history/intune?id=drift-20261107-120000").status_code == 400
    assert not [p for p in recorder.paths if "etc" in p or "drift" in p]


def test_a_missing_run_shows_the_error_page(web):
    r = web.get("/history/intune?id=intune-backup-19990101-000000")
    assert r.status_code == 404 and "No Intune backup with this id." in r.text


def test_back_up_now_posts_an_intune_backup_job(web, recorder):
    # The example data has a running job: the button is disabled, but the form is there and the API decides.
    page = web.get("/history/intune").text
    assert 'value="intune-backup"' in page and 'disabled aria-describedby="busy-note"' in page
    token = CSRF.search(page).group(1)
    r = web.post("/jobs", data={"csrf": token, "action": "intune-backup"}, follow_redirects=False)
    assert r.status_code == 303
    assert recorder.inner.posted[-1] == ("/api/jobs", {"action": "intune-backup"})


def test_extra_fields_are_not_sent_with_a_backup(web, recorder):
    page = web.get("/history/intune").text
    web.post("/jobs", data={"csrf": CSRF.search(page).group(1), "action": "intune-backup", "area": "Intune"})
    assert recorder.inner.posted[-1] == ("/api/jobs", {"action": "intune-backup"})


def test_the_intune_area_shows_the_last_backup(web):
    html = web.get("/areas/intune").text
    assert html.count("<h2>Intune backup</h2>") == 1 and f'href="/history/intune?id={LATEST}"' in html
    assert html.count("<h1>") == 1
    assert 'value="intune-backup"' in html


def test_audit_can_filter_backup_lines(web, recorder):
    html = web.get("/audit?mode=backup").text
    assert "Intune backup" in html


def test_reader_sees_no_backup_button():
    auth = uikit.ui_auth(uikit.FakeEntra(roles=("Reader",)))
    web = TestClient(create_app(MockClient(MOCK_FILE), auth, clock=lambda: NOW))
    assert uikit.sign_in(web, auth).status_code == 303
    html = web.get("/history/intune").text
    assert 'value="intune-backup"' not in html and "needs the role Applier" in html
    assert "Windows - Example security baseline" in html  # reading needs Reader only


def test_the_interface_may_read_only_the_backup_routes():
    from m365ui.api_client import ForbiddenPath, check_path
    assert check_path("/api/intune-backups") and check_path(f"/api/intune-backups/{LATEST}")
    with pytest.raises(ForbiddenPath):
        check_path("/api/intune-backups/../reports")
