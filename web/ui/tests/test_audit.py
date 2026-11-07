"""Audit page (issue #13): every mode, filters by mode, period and plan, link from a line to its plan."""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from m365ui import view
from m365ui.api_client import MockClient
from m365ui.main import AUDIT_MODES, create_app

from test_pages import MOCK_FILE

NOW = datetime(2026, 11, 7, 14, 30, tzinfo=timezone.utc)
MOCK = json.loads(MOCK_FILE.read_text(encoding="utf-8"))["responses"]
APPLY_HASH = "0d6578ecf6d5388ccd2e041e1c6d060eca66633338193e8f2bdc17be0f3152ce"


class Recorder(MockClient):
    def __init__(self):
        super().__init__(MOCK_FILE)
        self.calls: list[tuple[str, dict[str, str]]] = []

    def _get(self, path, params, token=None):
        self.calls.append((path, params))
        return super()._get(path, params, token)


@pytest.fixture()
def rec():
    return Recorder()


@pytest.fixture()
def web(rec):
    return TestClient(create_app(rec, clock=lambda: NOW))


def audit_calls(rec):
    return [p for path, p in rec.calls if path == "/api/audit"]


def test_the_page_knows_every_mode_of_the_contract():
    schema = json.loads((MOCK_FILE.parents[2] / "schema" / "m365cloning.schema.json").read_text(encoding="utf-8"))
    assert set(AUDIT_MODES) == set(schema["$defs"]["AuditEntry"]["properties"]["Mode"]["enum"])


@pytest.mark.parametrize("period, days", [("1d", 1), ("7d", 7), ("30d", 30)])
def test_period_becomes_since(period, days):
    since = view.audit_since(period, NOW)
    assert since == (NOW - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")


def test_unknown_period_means_no_limit():
    assert view.audit_since("", NOW) is None and view.audit_since("1y", NOW) is None


def test_query_keeps_only_set_filters():
    assert view.audit_query() == ""
    assert view.audit_query("apply", "7d", APPLY_HASH, 2) == f"mode=apply&period=7d&plan={APPLY_HASH}&page=2"
    assert view.audit_query("", "", "", 1) == ""


def test_filters_go_to_the_api(web, rec):
    assert web.get("/audit", params={"mode": "apply", "period": "7d", "plan": APPLY_HASH, "page": 2}).status_code == 200
    assert audit_calls(rec)[-1] == {"mode": "apply", "since": "2026-10-31T14:30:00Z", "planHash": APPLY_HASH, "page": "2"}


@pytest.mark.parametrize("query", [{"mode": "nope"}, {"period": "1y"}, {"plan": "ABC"}, {"plan": "x" * 64}])
def test_unknown_filters_are_dropped_not_sent(web, rec, query):
    assert web.get("/audit", params=query).status_code == 200
    assert audit_calls(rec)[-1] == {}


def test_every_mode_is_shown_with_icon_and_text(web):
    html = web.get("/audit").text
    for text in ("Drift report", "Plan", "Apply", "Refused", "Reset", "Suitability check"):
        assert f"<span>{text}</span>" in html or f'<span class="badge-text">{text}</span>' in html, text
    # The refusal is a red badge, not only a colour.
    assert '<span class="badge badge-bad"><svg class="icon"' in html


def test_mode_and_period_are_choices_with_readable_names(web):
    html = web.get("/audit").text
    assert '<option value="report">Drift report</option>' in html
    assert '<option value="7d">Last 7 days</option>' in html


def test_a_line_links_to_its_plan_and_to_its_entries(web):
    html = web.get("/audit").text
    assert f'href="/audit?plan={APPLY_HASH}"' in html
    assert 'href="/plans/apply-plan-20261107-120000">Open the plan</a>' in html
    assert "failed to apply microsoft.entra.conditionalaccesspolicy: CA require MFA" in html


def test_plan_filter_is_shown_and_can_be_cleared(web):
    html = web.get("/audit", params={"plan": APPLY_HASH, "mode": "apply"}).text
    assert "Only the entries of plan" in html and "0d6578ec…" in html
    assert 'href="/audit?mode=apply">Show all plans</a>' in html
    assert f'<input type="hidden" name="plan" value="{APPLY_HASH}">' in html


def test_pager_keeps_the_filters():
    class Paged(MockClient):
        def _get(self, path, params, token=None):
            res = super()._get(path, params, token)
            if path == "/api/audit":
                res.body["pageSize"], res.body["total"], res.body["page"] = 2, 6, int(params.get("page", 1))
            return res

    web = TestClient(create_app(Paged(MOCK_FILE), clock=lambda: NOW))
    html = web.get("/audit", params={"mode": "apply", "period": "30d", "page": 2}).text
    assert 'href="/audit?mode=apply&amp;period=30d">' in html  # back to page 1
    assert 'href="/audit?mode=apply&amp;period=30d&amp;page=3">' in html


def test_plan_page_links_to_its_audit_entries(web):
    html = web.get("/plans/apply-plan-20261107-120000").text
    assert f'href="/audit?plan={APPLY_HASH}"' in html and "Audit entries of this plan" in html


def test_no_plan_lookup_when_no_line_has_a_plan():
    class NoHash(Recorder):
        def _get(self, path, params, token=None):
            res = super()._get(path, params, token)
            if path == "/api/audit":
                res.body["items"] = [dict(i, PlanHash="") for i in res.body["items"]]
            return res

    client = NoHash()
    TestClient(create_app(client, clock=lambda: NOW)).get("/audit")
    # Only the menu counters ask for the plans, not the audit page itself.
    assert sum(1 for path, _ in client.calls if path == "/api/plans") == 1
