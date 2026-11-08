"""Setup check (issue #18) and the progress of Start Dev fresh: the page only reads /api/setup-check/latest and starts
the read-only check as a job; nothing is written to the config or a tenant from here."""

import re
from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient

from m365ui import view
from m365ui.api_client import ApiResponse, MockClient
from m365ui.main import create_app

from test_pages import MOCK_FILE, RecordingClient

NOW = datetime(2026, 11, 7, 12, 20, tzinfo=timezone.utc)
CSRF = re.compile(r'name="csrf" value="([^"]+)"')


class NoSetupCheck(MockClient):
    """The mock without a setup check yet (the API answers 404)."""

    def _get(self, path, params, token=None):
        if path == "/api/setup-check/latest":
            return ApiResponse(404, {"code": "not-found", "message": "No setup check yet."})
        return super()._get(path, params, token)


@pytest.fixture()
def recorder():
    return RecordingClient(MockClient(MOCK_FILE))


@pytest.fixture()
def web(recorder):
    return TestClient(create_app(recorder, clock=lambda: NOW))


def test_settings_group_comes_after_history_and_marks_the_page(web):
    html = web.get("/settings/setup").text
    assert html.index(">History<") < html.index(">Settings<") < html.index(">Setup check<")
    assert re.search(r'<a href="/settings/setup" class="nav-link" aria-current="page">', html)


def test_groups_in_the_order_of_the_work_with_status_and_what_to_do(web):
    html = web.get("/settings/setup").text
    headings = re.findall(r'<h2 id="group-([a-z]+)">', html)
    assert headings == ["config", "certificates", "permissions", "utcm", "breakglass", "licences"]
    assert "Certificate expires soon" in html and "Renew it before 2026-11-28" in html
    assert 'href="/reports/tenantfit-20261107-120000"' in html
    assert "full check, both tenants" in html


def test_page_only_reads_and_shows_no_secret(web, recorder):
    html = web.get("/settings/setup").text
    assert [p for p in recorder.paths if p.startswith("POST ")] == []
    # Config key names (Dev.CertThumbprint) may be named in a hint; values never are (none are in the file).
    assert not re.search(r"thumb-[a-z]+-\d|client-[a-z]+-\d|tenant-[a-z]+-\d", html)


def test_without_a_check_the_page_explains_and_offers_both_runs():
    web = TestClient(create_app(NoSetupCheck(MOCK_FILE), clock=lambda: NOW))
    response = web.get("/settings/setup")
    assert response.status_code == 200
    html = response.text
    assert "Not checked yet" in html and "scripts/Invoke-SetupCheck.ps1" in html
    assert 'name="scope" value="All"' in html and 'name="scope" value="Config"' in html


@pytest.mark.parametrize("scope", ["All", "Config"])
def test_runs_post_the_scope_to_the_api(web, recorder, scope):
    page = web.get("/settings/setup").text
    r = web.post("/jobs", data={"csrf": CSRF.search(page).group(1), "action": "setup-check", "scope": scope},
                 follow_redirects=False)
    assert r.status_code == 303
    assert recorder.inner.posted[-1] == ("/api/jobs", {"action": "setup-check", "scope": scope})


def test_an_unknown_scope_is_refused_before_the_api(web, recorder):
    page = web.get("/settings/setup").text
    r = web.post("/jobs", data={"csrf": CSRF.search(page).group(1), "action": "setup-check", "scope": "Tenant"})
    assert r.status_code == 400
    assert [p for p in recorder.paths if p.startswith("POST ")] == []


# ---------------------------------------------------------------- next step on the overview

def setup_answer(status: str) -> dict:
    return {"check": {"Status": status}}


@pytest.mark.parametrize("setup,first", [
    (None, "setup"),                 # no setup check yet
    (setup_answer("red"), "setup"),  # something blocks the work
    (setup_answer("yellow"), "no-report"),
    (setup_answer("green"), "no-report"),
    (False, "no-report"),            # not readable: no claim either way
])
def test_setup_rule_comes_first_only_when_missing_or_red(setup, first):
    steps = view.next_steps(view.facts({}, None, [], NOW, setup=setup))
    assert steps[0].id == first


def test_facts_without_setup_keep_the_old_order():
    assert view.next_steps(view.facts({}, None, [], NOW))[0].id == "no-report"


def test_overview_without_a_check_points_to_the_setup_check():
    html = TestClient(create_app(NoSetupCheck(MOCK_FILE), clock=lambda: NOW)).get("/").text
    assert "Check the setup" in html and 'href="/settings/setup"' in html


# ---------------------------------------------------------------- view helpers

def test_setup_groups_take_the_worst_status_and_skip_empty_groups():
    check = {"Checks": [
        {"Group": "Permissions", "Status": "green", "Tenant": "Prod"},
        {"Group": "Permissions", "Status": "grey", "Tenant": "Dev"},
        {"Group": "Config", "Status": "green", "Tenant": ""},
        {"Group": "Licences", "Status": "red", "Tenant": ""},
    ]}
    groups = view.setup_groups(check)
    assert [(g["key"], g["status"]) for g in groups] == [("Config", "green"), ("Permissions", "grey"), ("Licences", "red")]
    assert [r["Tenant"] for r in groups[1]["rows"]] == ["Prod", "Dev"]
    assert view.setup_groups(None) == []


RESET = {"id": "dev-reset-plan-align-20261107-120000", "kind": "reset", "mode": "Align", "planHash": "a" * 64,
         "createdUtc": "2026-11-07T12:00:00Z"}


def states(progress):
    return [s["state"] for s in progress["steps"]]


def test_fresh_progress_follows_plan_and_audit():
    assert states(view.fresh_progress([], [])) == ["current", "todo", "todo"]
    assert states(view.fresh_progress([RESET], [])) == ["done", "current", "todo"]
    reset_line = {"Mode": "reset", "PlanHash": "a" * 64, "Timestamp": "2026-11-07T12:10:00Z"}
    assert states(view.fresh_progress([RESET], [reset_line])) == ["done", "done", "current"]
    older_apply = {"Mode": "apply", "PlanHash": "b" * 64, "Timestamp": "2026-11-07T12:05:00Z"}
    assert states(view.fresh_progress([RESET], [reset_line, older_apply])) == ["done", "done", "current"]
    newer_apply = dict(older_apply, Timestamp="2026-11-07T12:30:00Z")
    done = view.fresh_progress([RESET], [reset_line, newer_apply])
    assert states(done) == ["done", "done", "done"] and done["percent"] == 100


def test_fresh_progress_ignores_a_reset_of_another_plan_and_outdated_plans():
    other = {"Mode": "reset", "PlanHash": "c" * 64, "Timestamp": "2026-11-07T12:10:00Z"}
    assert states(view.fresh_progress([RESET], [other])) == ["done", "current", "todo"]
    assert states(view.fresh_progress([dict(RESET, state="outdated")], [])) == ["current", "todo", "todo"]


def test_fresh_progress_without_the_audit_log_says_unknown():
    p = view.fresh_progress([RESET], None)
    assert states(p) == ["done", "unknown", "unknown"] and p["done"] == 1


def test_fresh_page_shows_progress_and_the_setup_status(web, recorder):
    html = web.get("/goals/fresh").text
    assert '<progress max="100" value="33"' in html
    assert "job-step-done" in html and "job-step-current" in html
    assert 'href="/settings/setup"' in html and "Setup check" in html
    assert "/api/setup-check/latest" in recorder.paths
