"""Navigation, guidance and readable times (issues #61, #63, ADR 0011)."""

import re
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from m365ui import view
from m365ui.api_client import ApiResponse, BaseClient, MockClient
from m365ui.main import create_app

from test_pages import MOCK_FILE, PAGES, signed_in

NOW = datetime(2026, 11, 7, 14, 30, tzinfo=timezone.utc)
NAV = {"/": "overview", "/reports": "reports", "/plans": "plans", "/audit": "audit", "/jobs": "jobs",
       "/goals/align": "align", "/goals/fresh": "fresh", "/goals/fill": "fill", "/areas/intune": "intune",
       "/history/intune": "intune-changes"}
NAV_HREF = {"overview": "/", "reports": "/reports", "plans": "/plans", "audit": "/audit", "jobs": "/jobs",
            "align": "/goals/align", "fresh": "/goals/fresh", "fill": "/goals/fill", "intune": "/areas/intune",
            "intune-changes": "/history/intune"}


@pytest.fixture()
def web():
    return TestClient(create_app(MockClient(MOCK_FILE), clock=lambda: NOW))


def nav_page(path):
    first = path.split("?")[0]
    if first == "/":
        return "overview"
    if first in NAV:
        return NAV[first]
    return NAV[f"/{first.strip('/').split('/')[0]}"]


# ---------------------------------------------------------------- layout

@pytest.mark.parametrize("page", PAGES)
def test_active_item_is_marked_once(web, page):
    html = web.get(page).text
    current = re.findall(r'<a href="([^"]+)" class="nav-link" aria-current="page">', html)
    assert current == [NAV_HREF[nav_page(page)]]


@pytest.mark.parametrize("page", PAGES)
def test_layout_has_skip_link_menu_button_and_account(web, page):
    html = web.get(page).text
    assert '<a class="skip" href="#main">' in html and '<main id="main"' in html
    assert 'aria-expanded="false" aria-controls="side-menu"' in html and 'id="side-menu"' in html
    assert "Menu" in html  # the menu button has text, not only an icon
    assert "Example user" in html and "Roles: Applier, Reader, Resetter" in html


@pytest.mark.parametrize("page", [p for p in PAGES if p.count("/") > 1])
def test_detail_pages_have_breadcrumbs(web, page):
    html = web.get(page).text
    assert 'class="crumbs" aria-label="Breadcrumb"' in html
    assert '<a href="/">Overview</a>' in html and 'aria-current="page">' in html


def test_counter_badges_from_the_list_routes(web):
    html = web.get("/audit").text
    assert re.search(r'href="/reports"[^>]*>.*?<span class="count"[^>]*>2</span>', html, re.S)
    assert re.search(r'href="/plans"[^>]*>.*?<span class="count"[^>]*>6</span>', html, re.S)
    # Jobs: only the active ones are counted (one running job in the examples).
    assert re.search(r'href="/jobs"[^>]*>.*?<span class="count"[^>]*>1</span>', html, re.S)


def test_login_page_has_no_menu():
    html = TestClient(create_app(MockClient(MOCK_FILE))).get("/login").text
    assert 'class="nav-link"' not in html and "menu-toggle" not in html


def test_no_product_logos_and_own_logo(web):
    html = web.get("/").text
    assert 'class="logo"' in html and "/static/logo.svg" in html
    static = Path(__file__).resolve().parents[1] / "m365ui" / "static"
    assert (static / "logo.svg").is_file()


# ---------------------------------------------------------------- badges and icons

BADGE = re.compile(r'<span class="badge badge-[a-z]+">(.*?)</span></span>', re.S)


@pytest.mark.parametrize("page", PAGES)
def test_every_badge_has_icon_and_text(web, page):
    html = web.get(page).text
    for inner in BADGE.findall(html):
        assert '<svg class="icon"' in inner
        text = re.sub(r"<[^>]+>", "", inner).strip()
        assert text, inner


def test_badge_states_are_known():
    from jinja2 import Environment, FileSystemLoader
    env = Environment(loader=FileSystemLoader(str(Path(view.__file__).parent / "templates")))
    icons = view.load_icons()
    env.globals.update(_=lambda s: s, icon_svg=lambda n, label="": view.icon_markup(icons, n, label),
                       type_family=view.type_family, job_actions=view.JOB_ACTIONS)
    env.filters["when"] = lambda v: v
    macros = env.get_template("_macros.html").module
    for state, text in (("green", "Green"), ("yellow", "Yellow"), ("red", "Red"), ("grey", "Grey: not verified"),
                        ("identical", "Identical"), ("different", "Different"), ("blocked", "Blocked"),
                        ("outdated", "Outdated"), ("notverified", "Not verified"), ("ok", "OK"),
                        ("queued", "Queued"), ("running", "Running"), ("succeeded", "Succeeded"), ("cancelled", "Cancelled"),
                        ("failed", "Failed"), ("pending", "Waiting"), ("done", "Done")):
        out = str(macros.badge(state))
        assert text in out and "<svg" in out
    assert "Conditional Access" in str(macros.type_badge("microsoft.entra.conditionalaccesspolicy"))
    assert "Intune" in str(macros.type_badge("microsoft.intune.devicecompliancepolicywindows10"))
    assert "Entra ID" in str(macros.type_badge("microsoft.entra.group"))
    assert str(macros.type_badge("something.else")) == ""


def test_icons_are_plain_single_path_svgs():
    icons = view.load_icons()
    assert set(icons) == set(view.ICON_FILES)
    for path in icons.values():
        assert path.startswith('<path d="') and "<script" not in path
    assert 'aria-hidden="true"' in view.icon_markup(icons, "ok")
    assert 'role="img" aria-label="Done"' in view.icon_markup(icons, "ok", "Done")


@pytest.mark.parametrize("family,types", [
    ("ca", ["microsoft.entra.conditionalaccesspolicy", "ConditionalAccessPolicy"]),
    ("intune", ["microsoft.intune.deviceconfigurationpolicywindows10", "ConfigurationPolicy", "AssignmentFilter"]),
    ("entra", ["microsoft.entra.group", "microsoft.graph.user", "microsoft.graph.invitation"]),
    ("other", ["", None, "Device"]),
])
def test_type_family(family, types):
    for t in types:
        assert view.type_family(t) == family


# ---------------------------------------------------------------- time (#61)

@pytest.mark.parametrize("value,text,rel", [
    ("2026-11-07T12:00:00Z", "7 Nov 2026, 12:00 UTC", "2 hours ago"),
    ("2026-11-07T14:29:40Z", "7 Nov 2026, 14:29 UTC", "just now"),
    ("2026-11-06T14:00:00Z", "6 Nov 2026, 14:00 UTC", "1 day ago"),
    ("2026-10-01T08:05:00+02:00", "1 Oct 2026, 06:05 UTC", "1 month ago"),
    ("2024-01-01T00:00:00Z", "1 Jan 2024, 00:00 UTC", "2 years ago"),
    ("2026-11-07T15:31:00Z", "7 Nov 2026, 15:31 UTC", "in 1 hour"),
    ("2026-11-07T14:25:00Z", "7 Nov 2026, 14:25 UTC", "5 minutes ago"),
])
def test_time_is_readable(value, text, rel):
    w = view.when(value, NOW)
    assert (w.text, w.rel, w.ok) == (text, rel, True)


def test_unreadable_time_is_shown_as_is():
    assert view.when("not a time", NOW).text == "not a time"
    assert view.when(None, NOW).text == "unknown"
    assert "<time" not in view.time_markup("not a time", NOW)


def test_time_markup_keeps_the_exact_value():
    html = str(view.time_markup("2026-11-07T12:00:00Z", NOW))
    assert '<time datetime="2026-11-07T12:00:00Z" title="2026-11-07T12:00:00Z" data-local>7 Nov 2026, 12:00 UTC</time>' in html
    assert "(2 hours ago)" in html


@pytest.mark.parametrize("page", ["/", "/reports", "/plans", "/audit", "/plans/apply-plan-20261107-120000",
                                  "/reports/drift-20261107-120000", "/reports/tenantfit-20261107-120000"])
def test_pages_show_readable_times(web, page):
    html = web.get(page).text
    assert '<time datetime="2026-11-07T12:00:00Z"' in html and "7 Nov 2026, 12:00 UTC" in html
    assert "(2 hours ago)" in html
    assert "<time>2026-11-07T12:00:00Z</time>" not in html  # no raw value as visible text


# ---------------------------------------------------------------- order (#61)

def test_outdated_entries_go_last_and_newest_first():
    items = [
        {"id": "a", "createdUtc": "2026-01-01T00:00:00Z", "state": "outdated"},
        {"id": "b", "createdUtc": "2026-02-01T00:00:00Z"},
        {"id": "c", "createdUtc": "2026-03-01T00:00:00Z", "state": "current"},
        {"id": "d", "createdUtc": "2027-01-01T00:00:00Z", "state": "outdated"},
        {"id": "e", "createdUtc": "bad"},
    ]
    assert [i["id"] for i in view.newest_first(items, "createdUtc")] == ["c", "b", "e", "d", "a"]


class ListClient(BaseClient):
    """Status, plans and audit as given; everything else from the mock."""

    mock = False

    def __init__(self, status=None, fit=None, plans=None, reports=None, audit=None):
        self.inner = MockClient(MOCK_FILE)
        self.answers = {"/api/status": status, "/api/fitcheck/latest": fit, "/api/plans": plans,
                        "/api/reports": reports, "/api/audit": audit}

    def _get(self, path, params, token=None):
        if path in self.answers and self.answers[path] is not None:
            return self.answers[path]
        return self.inner._get(path, params, token)


def ok(body):
    return ApiResponse(200, {"schemaVersion": "2", **body})


def test_outdated_entries_are_last_in_the_lists():
    plans = [{"id": "apply-plan-20200101-000000", "kind": "apply", "createdUtc": "2027-01-01T00:00:00Z", "state": "outdated"},
             {"id": "apply-plan-20261107-120000", "kind": "apply", "createdUtc": "2026-11-07T12:00:00Z",
              "summary": {"Planned": 1, "Blocked": 0, "Skipped": 0}}]
    reports = [{"id": "drift-20200101-000000", "kind": "drift", "createdUtc": "2027-01-01T00:00:00Z", "state": "outdated"},
               {"id": "drift-20261107-120000", "kind": "drift", "createdUtc": "2026-11-07T12:00:00Z", "isIdentical": True}]
    web = signed_in(ListClient(plans=ok({"items": plans}), reports=ok({"items": reports})))
    html = web.get("/plans").text
    assert html.index("apply-plan-20261107-120000") < html.index("apply-plan-20200101-000000")
    html = web.get("/reports").text
    assert html.index("drift-20261107-120000") < html.index("drift-20200101-000000")


# ---------------------------------------------------------------- tiles (#61)

def test_tiles_show_three_plans_and_five_audit_entries(web):
    html = web.get("/").text
    plans = html.split('id="recent-plans"')[1].split("</article>")[0]
    audit = html.split('id="recent-audit"')[1].split("</article>")[0]
    assert plans.count('<a href="/plans/') == 3 and 'href="/plans">All plans' in plans
    assert audit.count('<span class="mode">') == 5 and 'href="/audit">Show the audit log' in audit


def test_tiles_use_only_existing_routes(web):
    class Recorder(MockClient):
        def __init__(self):
            super().__init__(MOCK_FILE)
            self.calls = []

        def _get(self, path, params, token=None):
            self.calls.append((path, params))
            return super()._get(path, params, token)

    rec = Recorder()
    TestClient(create_app(rec, clock=lambda: NOW)).get("/")
    assert {p for p, _ in rec.calls} == {"/api/status", "/api/fitcheck/latest", "/api/plans", "/api/audit", "/api/reports", "/api/jobs"}
    assert ("/api/audit", {"pageSize": "5"}) in rec.calls


def test_empty_states_explain_what_to_do():
    empty = ok({"items": []})
    web = signed_in(ListClient(
        status=ok({"lastComparisonUtc": None, "differences": 0, "fitStatus": "grey", "reportId": None}),
        fit=ApiResponse(404, {"code": "not-found", "message": "none"}),
        plans=empty, reports=empty, audit=ok({"items": [], "page": 1, "pageSize": 50, "total": 0})))
    html = web.get("/").text
    for text in ("Not compared yet", "No suitability check yet", "No plans yet", "No audit entries yet",
                 "scripts/Get-DriftReport.ps1", "scripts/Invoke-TenantFitCheck.ps1"):
        assert text in html
    assert html.count('class="empty"') == 4
    assert "No reports yet" in web.get("/reports").text
    assert "No plans yet" in web.get("/plans").text
    assert "No audit entries yet" in web.get("/audit").text
    assert "No plan of this kind" in web.get("/plans?kind=reset").text


# ---------------------------------------------------------------- next step (#63)

def facts(**kw):
    base = dict(has_report=True, report_age_days=1.0, differences=0, fit_status="green", fit_id="tenantfit-1",
                report_id="drift-1", has_apply_plan=False)
    base.update(kw)
    return view.Facts(**base)


@pytest.mark.parametrize("kw,first,command,link", [
    (dict(has_report=False, report_age_days=None, report_id=""), "no-report", "scripts/Get-DriftReport.ps1", ""),
    (dict(fit_status="red"), "fit-check", "scripts/Invoke-TenantFitCheck.ps1", "/reports/tenantfit-1"),
    (dict(fit_status="grey"), "fit-check", "scripts/Invoke-TenantFitCheck.ps1", "/reports/tenantfit-1"),
    (dict(fit_status="", fit_id=""), "fit-check", "scripts/Invoke-TenantFitCheck.ps1", ""),
    (dict(report_age_days=view.STALE_DAYS + 0.5), "stale-report", "scripts/Get-DriftReport.ps1", "/reports/drift-1"),
    (dict(differences=3), "differences", "scripts/Invoke-ApplyDev.ps1", "/reports/drift-1"),
    (dict(fit_status="yellow", differences=2), "differences", "scripts/Invoke-ApplyDev.ps1", "/reports/drift-1"),
    (dict(), "done", "", "/reports/drift-1"),
])
def test_next_step_rules(kw, first, command, link):
    steps = view.next_steps(facts(**kw))
    assert steps[0].id == first and steps[0].command == command and steps[0].link == link
    assert steps[0].title and steps[0].detail
    assert "done" not in [s.id for s in steps[1:]]


def test_all_matching_rules_follow_in_order():
    steps = view.next_steps(facts(fit_status="red", report_age_days=30, differences=4))
    assert [s.id for s in steps] == ["fit-check", "stale-report", "differences"]


def test_facts_come_from_the_api_answers():
    status = {"lastComparisonUtc": "2026-10-01T00:00:00Z", "differences": 3, "reportId": "drift-1"}
    fit = {"id": "tenantfit-1", "report": {"Status": "yellow", "Verified": False}}
    f = view.facts(status, fit, [{"kind": "apply"}], NOW)
    assert f.has_report and f.report_age_days > 30 and f.differences == 3
    assert f.fit_status == "grey"  # not verified counts as grey
    assert f.has_apply_plan
    assert not view.facts({}, None, [], NOW).has_report


def test_overview_shows_the_next_step(web):
    html = web.get("/").text
    assert "Next step" in html and "Create a plan" in html and "scripts/Invoke-ApplyDev.ps1" in html


def test_overview_asks_to_compare_again_when_old():
    later = TestClient(create_app(MockClient(MOCK_FILE), clock=lambda: NOW + timedelta(days=10)))
    html = later.get("/").text
    assert "Compare again" in html and "scripts/Get-DriftReport.ps1" in html
    assert "After that" in html and "Create a plan" in html


def test_overview_red_fit_points_to_the_suitability_report():
    fit = ok({"id": "tenantfit-20261107-120000", "createdUtc": "2026-11-07T12:00:00Z",
              "report": {"Status": "red", "Verified": True, "Verdict": "Dev is not enough."}})
    html = signed_in(ListClient(fit=fit)).get("/").text
    first = html.split('id="next-title">')[1].split("</h2>")[0]
    assert first == "Check the suitability report"
    assert 'href="/reports/tenantfit-20261107-120000"' in html
