"""Setup check (issue #18): GET /api/setup-check/latest reads History/reports/setup-check-*.json only; the check
itself is a job (action setup-check, read only, option scope)."""

from __future__ import annotations

import json

import pytest

from m365api.contract import errors

from .conftest import MOCK
from .test_jobs import as_role, idle, job_file  # noqa: F401 - idle is a fixture

EXAMPLE = MOCK["GET /api/setup-check/latest"]["body"]
FILE = f"{EXAMPLE['id']}.json"


def test_latest_is_the_newest_current_check(client, history):
    older = dict(EXAMPLE["check"], CreatedUtc="2026-11-01T08:00:00Z", Status="red")
    (history / "reports" / "setup-check-20261101-080000.json").write_text(json.dumps(older), encoding="utf-8")
    body = client.get("/api/setup-check/latest").json()
    assert errors("SetupCheckResponse", body) == []
    assert body["id"] == EXAMPLE["id"] and body["check"]["Status"] == EXAMPLE["check"]["Status"]


def test_no_check_yet_is_404(client, history):
    (history / "reports" / FILE).unlink()
    response = client.get("/api/setup-check/latest")
    assert response.status_code == 404 and response.json()["code"] == "not-found"


def test_an_old_format_is_not_the_latest(client, history):
    (history / "reports" / "setup-check-20991231-000000.json").write_text(
        json.dumps({"SchemaVersion": "1", "Kind": "setupcheck"}), encoding="utf-8")
    assert client.get("/api/setup-check/latest").json()["id"] == EXAMPLE["id"]


def test_a_check_with_an_extra_field_is_not_sent(client, history):
    path = history / "reports" / FILE
    content = json.loads(path.read_text(encoding="utf-8"))
    content["Checks"][0]["Thumbprint"] = "abc"
    path.write_text(json.dumps(content), encoding="utf-8")
    assert client.get("/api/setup-check/latest").status_code == 404


def test_setup_checks_are_neither_reports_nor_plans(client):
    for url in ("/api/reports", "/api/plans"):
        assert not any(i["id"].startswith("setup-check-") for i in client.get(url).json()["items"])
    assert client.get(f"/api/reports/{EXAMPLE['id']}").status_code == 404


@pytest.mark.parametrize("roles,status", [(["Reader"], 403), (["Resetter"], 403), (["Applier"], 202)])
def test_the_check_is_a_job_for_the_applier(app, idle, roles, status):
    response = as_role(app, *roles).post("/api/jobs", json={"action": "setup-check"})
    assert response.status_code == status, response.text


@pytest.mark.parametrize("roles,scope,status,role", [
    (["Reader"], "Config", 202, "Reader"),
    (["Resetter"], "Config", 202, "Reader"),
    (["Applier"], "Config", 202, "Reader"),
    (["Reader"], "All", 403, None),
    (["Resetter"], "All", 403, None),
])
def test_a_reader_may_check_the_config_only(app, idle, roles, scope, status, role):
    """Issue #76: the config-only check signs in nowhere, so Reader is enough; the full check stays Applier."""
    response = as_role(app, *roles).post("/api/jobs", json={"action": "setup-check", "scope": scope})
    assert response.status_code == status, response.text
    if role:
        assert response.json()["role"] == role
    else:
        assert response.json()["code"] == "forbidden"


def test_role_by_scope_comes_from_the_job_table():
    from m365api.jobs import role_for
    assert role_for("setup-check", scope="Config") == "Reader"
    assert role_for("setup-check", scope="All") == "Applier"
    assert role_for("setup-check") == "Applier"
    assert role_for("drift", scope="Config") == "Applier"


@pytest.mark.parametrize("sent,stored", [({}, "All"), ({"scope": "Config"}, "Config"), ({"scope": "All"}, "All")])
def test_scope_is_stored(app, idle, sent, stored):
    body = as_role(app, "Applier").post("/api/jobs", json={"action": "setup-check", **sent}).json()
    assert body["options"] == {"scope": stored}
    assert job_file(idle, body["id"])["Job"]["options"] == {"scope": stored}


@pytest.mark.parametrize("body", [
    {"action": "setup-check", "scope": "Tenant"},
    {"action": "setup-check", "area": "Intune"},
    {"action": "drift", "scope": "Config"},
])
def test_bad_setup_requests_are_refused(app, idle, body, launcher):
    response = as_role(app, "Applier").post("/api/jobs", json=body)
    assert response.status_code == 400, response.text
    assert launcher.started == []
