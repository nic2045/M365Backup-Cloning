"""Goals, areas and jobs (issues #14, #66, ADR 0012): forms start jobs through the API, never anything else."""

import re
from datetime import datetime, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from m365api import create_app as create_api
from m365ui import view
from m365ui.api_client import HttpClient, MockClient
from m365ui.main import create_app

import uikit
from test_pages import MOCK_FILE, RecordingClient
from test_with_backend import MOCK, write_history

NOW = datetime(2026, 11, 7, 12, 20, tzinfo=timezone.utc)
CSRF = re.compile(r'name="csrf" value="([^"]+)"')
RUNNING = "job-20261107-121500-k3m9qa"
APPLY_PLAN = "apply-plan-20261107-121000"
RESET_PLAN = "dev-reset-plan-full-20261107-120000"


def csrf_of(html: str) -> str:
    m = CSRF.search(html)
    assert m, "no CSRF token on the page"
    return m.group(1)


@pytest.fixture()
def recorder():
    return RecordingClient(MockClient(MOCK_FILE))


@pytest.fixture()
def web(recorder):
    return TestClient(create_app(recorder, clock=lambda: NOW))


def posts(recorder):
    return [p for p in recorder.paths if p.startswith("POST ")]


# ---------------------------------------------------------------- menu (#66)

def test_menu_has_goals_areas_and_history(web):
    html = web.get("/").text
    for label in ("Goals", "Bring Dev in line", "Start Dev fresh", "Fill Dev", "Areas", "Intune", "History", "Jobs",
                  "Plans", "Reports", "Audit log"):
        assert f">{label}<" in html or f"{label}</span>" in html, label
    assert html.index("Bring Dev in line") < html.index("Start Dev fresh") < html.index("Fill Dev")


@pytest.mark.parametrize("label", ["Entra ID", "Conditional Access", "Licences"])
def test_later_areas_are_greyed_out_and_not_links(web, label):
    html = web.get("/").text
    item = re.search(r'<span class="nav-link nav-later" role="link" aria-disabled="true">(.*?)</span></li>', html, re.S)
    assert item
    later = re.findall(r'<span class="nav-link nav-later" role="link" aria-disabled="true">.*?<span class="nav-text">([^<]+)</span><span class="later-tag">later</span>', html, re.S)
    assert label in later
    assert not re.search(rf'<a [^>]*class="nav-link"[^>]*>(?:(?!</a>).)*<span class="nav-text">{label}</span>', html, re.S)


def test_no_settings_item_without_a_settings_page(web):
    assert "/settings" not in web.get("/").text


# ---------------------------------------------------------------- forms -> API

def test_starting_a_job_posts_to_the_api_and_opens_the_job(web, recorder):
    page = web.get("/goals/align")
    r = web.post("/jobs", data={"csrf": csrf_of(page.text), "action": "drift"}, follow_redirects=False)
    assert r.status_code == 303 and r.headers["location"] == f"/jobs/{RUNNING}"
    assert recorder.inner.posted == [("/api/jobs", {"action": "drift"})]


def test_the_intune_area_plans_only_intune(web, recorder):
    page = web.get("/areas/intune")
    assert 'name="area" value="Intune"' in page.text
    web.post("/jobs", data={"csrf": csrf_of(page.text), "action": "plan-apply", "area": "Intune"}, follow_redirects=False)
    assert recorder.inner.posted[-1] == ("/api/jobs", {"action": "plan-apply", "area": "Intune"})


def test_reset_preview_sends_mode_and_device_action(web, recorder):
    page = web.get("/goals/fresh")
    assert 'value="Wipe"' not in page.text  # a wipe runs with the script only
    web.post("/jobs", data={"csrf": csrf_of(page.text), "action": "plan-reset", "mode": "Full", "deviceAction": "Retire"},
             follow_redirects=False)
    assert recorder.inner.posted[-1] == ("/api/jobs", {"action": "plan-reset", "mode": "Full", "deviceAction": "Retire"})


def test_without_csrf_nothing_is_posted(web, recorder):
    r = web.post("/jobs", data={"action": "drift"})
    assert r.status_code == 403 and posts(recorder) == []
    r = web.post("/jobs", data={"action": "drift", "csrf": "wrong"})
    assert r.status_code == 403 and posts(recorder) == []


@pytest.mark.parametrize("form,message", [
    ({"action": "apply", "planId": APPLY_PLAN, "confirmPlanHash": "a" * 64}, "Tick the box"),
    ({"action": "apply", "planId": RESET_PLAN, "confirmPlanHash": "a" * 64, "kind": "reset", "confirmed": "yes"}, "Type the ID"),
    ({"action": "plan-reset", "deviceAction": "Wipe"}, "not offered"),
    ({"action": "rm -rf"}, "Unknown action"),
])
def test_incomplete_forms_are_refused_before_the_api(web, recorder, form, message):
    page = web.get("/goals/align")
    r = web.post("/jobs", data={"csrf": csrf_of(page.text), **form})
    assert r.status_code == 400 and message in r.text
    assert posts(recorder) == []


def test_apply_form_on_the_plan_page(web, recorder):
    page = web.get(f"/plans/{APPLY_PLAN}")
    html = page.text
    assert 'id="apply"' in html and 'name="confirmed" value="yes" required' in html
    plan_hash = MOCK[f"GET /api/plans/{APPLY_PLAN}"]["body"]["planHash"]
    assert f'name="confirmPlanHash" value="{plan_hash}"' in html
    assert "confirmTenant" not in html
    web.post("/jobs", data={"csrf": csrf_of(html), "action": "apply", "kind": "apply", "planId": APPLY_PLAN,
                            "confirmPlanHash": plan_hash, "confirmed": "yes"}, follow_redirects=False)
    assert recorder.inner.posted[-1] == ("/api/jobs", {"action": "apply", "planId": APPLY_PLAN, "confirmPlanHash": plan_hash})


def test_reset_plan_page_asks_for_the_second_confirmation(web):
    html = web.get(f"/plans/{RESET_PLAN}").text
    assert 'name="confirmTenant" required' in html and "button-danger" in html and "Reset Dev" in html


def test_a_plan_with_nothing_planned_offers_no_apply(web):
    html = web.get("/plans/dev-users-plan-20261107-120000").text
    users = MOCK["GET /api/plans/dev-users-plan-20261107-120000"]["body"]["plan"]["Summary"]["Planned"]
    if users == 0:
        assert "Nothing is planned" in html and 'value="apply"' not in html
    else:
        assert 'value="apply"' in html


def test_running_job_disables_the_start_buttons(web):
    html = web.get("/goals/align").text
    assert "A job is running" in html and f'href="/jobs/{RUNNING}"' in html
    assert html.count('disabled aria-describedby="busy-note"') >= 3


def test_job_page_shows_steps_progress_and_polls_while_running(web):
    html = web.get(f"/jobs/{RUNNING}").text
    assert "Read both tenants and compare" in html and "Running" in html
    assert '<progress max="100" value="50"' in html
    assert f'hx-get="/jobs/{RUNNING}" hx-trigger="every 3s"' in html
    assert f'action="/jobs/{RUNNING}/cancel"' in html


def test_finished_job_links_its_result_and_does_not_poll(web):
    html = web.get("/jobs/job-20261107-120900-p7x2zd").text
    assert "hx-trigger" not in html and "Cancel the job" not in html
    assert f'href="/plans/{APPLY_PLAN}#apply"' in html and "Succeeded" in html


def test_cancel_posts_to_the_api(web, recorder):
    page = web.get(f"/jobs/{RUNNING}")
    r = web.post(f"/jobs/{RUNNING}/cancel", data={"csrf": csrf_of(page.text)}, follow_redirects=False)
    assert r.status_code == 303 and r.headers["location"] == f"/jobs/{RUNNING}"
    assert recorder.inner.posted[-1] == (f"/api/jobs/{RUNNING}/cancel", {})


def test_bad_job_ids_call_nothing(web, recorder):
    assert web.get("/jobs/../../etc").status_code in (400, 404)
    assert web.get("/jobs/job-1").status_code == 400
    assert web.post("/jobs/job-1/cancel", data={"csrf": "x"}).status_code == 400
    assert [p for p in recorder.paths if "job-1" in p] == []


def test_jobs_list(web):
    html = web.get("/jobs").text
    assert "Drift report" in html and "Plan Prod → Dev" in html and "Example Admin" in html


# ---------------------------------------------------------------- roles

def test_reader_sees_no_start_buttons():
    auth = uikit.ui_auth(uikit.FakeEntra(roles=("Reader",)))
    web = TestClient(create_app(MockClient(MOCK_FILE), auth, clock=lambda: NOW))
    assert uikit.sign_in(web, auth).status_code == 303
    for page, role in (("/goals/align", "Applier"), ("/goals/fresh", "Resetter"), ("/goals/fill", "Applier"), ("/areas/intune", "Applier")):
        html = web.get(page).text
        assert 'action="/jobs"' not in html, page
        assert f"needs the role {role}" in html, page
    assert "Applying this plan needs the role Applier" in web.get(f"/plans/{APPLY_PLAN}").text
    assert "Cancel the job" not in web.get(f"/jobs/{RUNNING}").text


def test_applier_does_not_see_the_reset_button():
    auth = uikit.ui_auth(uikit.FakeEntra(roles=("Applier",)))
    web = TestClient(create_app(MockClient(MOCK_FILE), auth, clock=lambda: NOW))
    assert uikit.sign_in(web, auth).status_code == 303
    assert "needs the role Resetter" in web.get(f"/plans/{RESET_PLAN}").text
    assert 'value="plan-reset"' not in web.get("/goals/fresh").text


# ---------------------------------------------------------------- against the real API in process

class Launcher:
    def __init__(self):
        self.started = []

    def __call__(self, job_path: Path, out_path: Path) -> None:
        self.started.append(job_path)


def test_a_job_through_the_real_api(tmp_path):
    history = write_history(tmp_path / "History")
    launcher = Launcher()
    api = TestClient(create_api(history, uikit.api_auth(), launcher=launcher))
    auth = uikit.ui_auth(uikit.FakeEntra(roles=("Applier",), name="Ada Admin"))
    web = TestClient(create_app(HttpClient(http=api), auth))
    assert uikit.sign_in(web, auth).status_code == 303
    page = web.get("/goals/align")
    r = web.post("/jobs", data={"csrf": csrf_of(page.text), "action": "drift"}, follow_redirects=False)
    assert r.status_code == 303, r.text[:300]
    job_id = r.headers["location"].rsplit("/", 1)[-1]
    assert view.JOB_ID_RE.fullmatch(job_id) and launcher.started[0].name == f"{job_id}.json"
    html = web.get(f"/jobs/{job_id}").text
    assert "Queued" in html and "Ada Admin" in html and "has not picked the job up yet" in html
    # A second job is refused while the first is queued; the page links to the running one.
    second = web.post("/jobs", data={"csrf": csrf_of(html), "action": "fitcheck"})
    assert second.status_code == 409 and "job-running" in second.text and f'href="/jobs/{job_id}"' in second.text
    # A reset needs the role Resetter: the API refuses it even if a form is sent by hand.
    plan_hash = MOCK[f"GET /api/plans/{RESET_PLAN}"]["body"]["planHash"]
    (history / "jobs" / f"{job_id}.json").unlink()
    refused = web.post("/jobs", data={"csrf": csrf_of(html), "action": "apply", "kind": "reset", "planId": RESET_PLAN,
                                      "confirmPlanHash": plan_hash, "confirmed": "yes", "confirmTenant": "tenant-dev-0001"})
    assert refused.status_code == 403 and "Resetter" in refused.text
    assert len(launcher.started) == 1


# ---------------------------------------------------------------- pure helpers

def test_job_request_keeps_only_the_fields_of_the_action():
    assert view.job_request({"action": "drift", "area": "Intune", "planId": "x"}) == {"action": "drift"}
    assert view.job_request({"action": "plan-apply", "area": "Intune"}) == {"action": "plan-apply", "area": "Intune"}
    with pytest.raises(view.FormError):
        view.job_request({"action": "plan-apply", "area": "Teams"})


def test_latest_plan_by_kind_and_area():
    items = [
        {"id": "a1", "kind": "apply", "createdUtc": "2026-11-07T10:00:00Z"},
        {"id": "a2", "kind": "apply", "createdUtc": "2026-11-07T11:00:00Z", "area": "Intune"},
        {"id": "a3", "kind": "apply", "createdUtc": "2026-11-07T12:00:00Z", "state": "outdated"},
    ]
    assert view.latest_plan(items, "apply")["id"] == "a1"
    assert view.latest_plan(items, "apply", area="Intune")["id"] == "a2"
    assert view.latest_plan(items, "reset") is None


def test_job_progress():
    assert view.job_progress({"progress": {"done": 1, "total": 4}}) == 25
    assert view.job_progress({"progress": {"done": 0, "total": 0}}) == 0
