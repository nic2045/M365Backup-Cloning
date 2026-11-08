"""Job routes (issue #14, ADR 0012): roles, confirmation, one job at a time, cancel, files instead of memory."""

from __future__ import annotations

import json
from datetime import timedelta

import pytest
from fastapi.testclient import TestClient

from m365api import create_app
from m365api.contract import errors
from m365api.jobs import tenant_hash

from . import authkit
from .conftest import CLOCK, MOCK, FakeLauncher

RUNNING = "job-20261107-121500-k3m9qa"
DONE = "job-20261107-120900-p7x2zd"
APPLY_PLAN = "apply-plan-20261107-121000"
RESET_PLAN = "dev-reset-plan-full-20261107-120000"
DEV_TENANT = "tenant-dev-0001"  # the Dev tenant of the test fixtures (invented)


def plan_hash(plan_id: str) -> str:
    return MOCK[f"GET /api/plans/{plan_id}"]["body"]["planHash"]


def as_role(app, *roles: str, name: str = "Test Person") -> TestClient:
    return TestClient(app, headers=authkit.bearer(authkit.entra_token(list(roles), name=name)))


@pytest.fixture()
def idle(history):
    """No job is active: the running example job is removed."""
    (history / "jobs" / f"{RUNNING}.json").unlink()
    (history / "jobs" / f"{RUNNING}.log").unlink()
    return history


def job_file(history, job_id: str) -> dict:
    return json.loads((history / "jobs" / f"{job_id}.json").read_text(encoding="utf-8"))


def test_list_and_detail_follow_the_schema(client):
    listed = client.get("/api/jobs").json()
    assert errors("JobList", listed) == []
    assert [j["id"] for j in listed["items"]] == [RUNNING, DONE]
    assert all("log" not in j for j in listed["items"])
    detail = client.get(f"/api/jobs/{RUNNING}").json()
    assert errors("Job", detail) == [] and detail["progress"] == {"done": 2, "total": 4}
    assert detail["log"]


@pytest.mark.parametrize("url,status", [("/api/jobs/job-20261107-000000-zzzzzz", 404), ("/api/jobs/not-a-job", 400),
                                        ("/api/jobs/..%2Fsecret", 404)])
def test_unknown_or_bad_job_ids(client, url, status):
    response = client.get(url)
    assert response.status_code in (status, 404)
    assert errors("Error", response.json()) == []


def test_applier_starts_a_drift_report(app, idle, launcher):
    response = as_role(app, "Applier", name="Ada Admin").post("/api/jobs", json={"action": "drift"})
    assert response.status_code == 202, response.text
    body = response.json()
    assert errors("Job", body) == []
    assert body["status"] == "queued" and body["actor"] == "Ada Admin" and body["role"] == "Applier"
    assert body["progress"] == {"done": 0, "total": 4}
    assert len(launcher.started) == 1 and launcher.started[0].name == f"{body['id']}.json"
    stored = job_file(idle, body["id"])
    assert errors("JobFile", stored) == []
    assert stored["Confirm"] == {}


@pytest.mark.parametrize("roles,action,status", [
    (["Reader"], "drift", 403),
    (["Reader"], "plan-apply", 403),
    (["Resetter"], "drift", 403),
    (["Applier"], "plan-reset", 403),
    (["Resetter"], "plan-reset", 202),
    (["Applier"], "plan-baseline", 202),
    (["Applier"], "plan-users", 202),
    (["Applier"], "fitcheck", 202),
    (["Reader"], "intune-backup", 403),
    (["Resetter"], "intune-backup", 403),
    (["Applier"], "intune-backup", 202),
    (["Reader"], "export-desired", 403),
    (["Resetter"], "export-desired", 403),
    (["Applier"], "export-desired", 202),
])
def test_roles_by_action(app, idle, roles, action, status):
    response = as_role(app, *roles).post("/api/jobs", json={"action": action})
    assert response.status_code == status, response.text
    if status == 403:
        assert response.json()["code"] == "forbidden"


def test_plan_options_are_stored(app, idle):
    body = as_role(app, "Applier").post("/api/jobs", json={"action": "plan-apply", "area": "Intune"}).json()
    assert body["options"] == {"area": "Intune"}
    body2_client = as_role(app, "Resetter")
    (idle / "jobs" / f"{body['id']}.json").unlink()
    reset = body2_client.post("/api/jobs", json={"action": "plan-reset", "mode": "Full", "deviceAction": "Retire"}).json()
    assert reset["options"] == {"mode": "Full", "deviceAction": "Retire"} and reset["role"] == "Resetter"


@pytest.mark.parametrize("body", [
    {"action": "nothing"},
    {"action": "drift", "area": "Intune"},
    {"action": "plan-reset", "deviceAction": "Wipe"},
    {"action": "plan-apply", "area": "Exchange"},
    {"action": "apply", "planId": APPLY_PLAN},
    {"action": "apply", "planId": "../x", "confirmPlanHash": "0" * 64},
    {"action": "drift", "token": "abc"},
    [],
])
def test_bad_requests_are_refused(app, idle, body, launcher):
    response = as_role(app, "Applier", "Resetter").post("/api/jobs", json=body)
    assert response.status_code == 400, response.text
    assert errors("Error", response.json()) == []
    assert launcher.started == []


def test_non_json_and_large_bodies_are_refused(app, idle):
    c = as_role(app, "Applier")
    assert c.post("/api/jobs", content="action=drift", headers={"content-type": "application/x-www-form-urlencoded"}).status_code == 400
    assert c.post("/api/jobs", content="{nope", headers={"content-type": "application/json"}).status_code == 400
    big = json.dumps({"action": "drift", "x": "y" * 5000})
    assert c.post("/api/jobs", content=big, headers={"content-type": "application/json"}).status_code == 400


def test_one_job_at_a_time(app, launcher):
    response = as_role(app, "Applier").post("/api/jobs", json={"action": "drift"})
    assert response.status_code == 409 and response.json()["code"] == "job-running"
    assert launcher.started == []


def test_a_job_without_sign_of_life_no_longer_blocks(history, launcher):
    later = create_app(history, authkit.config(), launcher=launcher, clock=lambda: CLOCK + timedelta(hours=7))
    c = as_role(later, "Applier")
    stale = c.get(f"/api/jobs/{RUNNING}").json()
    assert stale["status"] == "failed" and "no sign of life" in stale["message"]
    assert c.post("/api/jobs", json={"action": "drift"}).status_code == 202
    # The file keeps what the runner wrote; only the view says it stopped.
    assert job_file(history, RUNNING)["Job"]["status"] == "running"


def test_apply_needs_the_hash_of_the_plan(app, idle, launcher):
    c = as_role(app, "Applier")
    wrong = c.post("/api/jobs", json={"action": "apply", "planId": APPLY_PLAN, "confirmPlanHash": "0" * 64})
    assert wrong.status_code == 409 and wrong.json()["code"] == "plan-changed"
    missing = c.post("/api/jobs", json={"action": "apply", "planId": "apply-plan-19990101-000000", "confirmPlanHash": "0" * 64})
    assert missing.status_code == 404
    ok = c.post("/api/jobs", json={"action": "apply", "planId": APPLY_PLAN, "confirmPlanHash": plan_hash(APPLY_PLAN)})
    assert ok.status_code == 202, ok.text
    job = ok.json()
    assert job["options"] == {"planId": APPLY_PLAN, "planKind": "apply", "planHash": plan_hash(APPLY_PLAN)}
    assert job_file(idle, job["id"])["Confirm"] == {"PlanHash": plan_hash(APPLY_PLAN)}
    assert len(launcher.started) == 1


def test_a_reset_needs_the_role_resetter_and_the_typed_dev_tenant(app, idle, launcher):
    body = {"action": "apply", "planId": RESET_PLAN, "confirmPlanHash": plan_hash(RESET_PLAN)}
    assert as_role(app, "Applier").post("/api/jobs", json={**body, "confirmTenant": DEV_TENANT}).status_code == 403
    r = as_role(app, "Resetter")
    no_tenant = r.post("/api/jobs", json=body)
    assert no_tenant.status_code == 400
    wrong = r.post("/api/jobs", json={**body, "confirmTenant": "tenant-prod-0001"})
    assert wrong.status_code == 409 and wrong.json()["code"] == "tenant-mismatch"
    assert launcher.started == []
    ok = r.post("/api/jobs", json={**body, "confirmTenant": "  TENANT-DEV-0001 "})
    assert ok.status_code == 202, ok.text
    text = (idle / "jobs" / f"{ok.json()['id']}.json").read_text(encoding="utf-8")
    assert json.loads(text)["Confirm"]["TenantHash"] == tenant_hash(DEV_TENANT)
    assert DEV_TENANT not in text.lower(), "the typed tenant ID is never stored"


def test_confirm_tenant_only_for_a_reset_plan(app, idle):
    c = as_role(app, "Applier")
    response = c.post("/api/jobs", json={"action": "apply", "planId": APPLY_PLAN, "confirmPlanHash": plan_hash(APPLY_PLAN), "confirmTenant": DEV_TENANT})
    assert response.status_code == 400


def test_a_runner_that_cannot_start_is_reported_and_does_not_block(history, idle):
    broken = create_app(history, authkit.config(), launcher=FakeLauncher(fail=True), clock=lambda: CLOCK)
    c = as_role(broken, "Applier")
    response = c.post("/api/jobs", json={"action": "drift"})
    assert response.status_code == 500 and response.json()["code"] == "job-start-failed"
    assert "pwsh" in response.json()["message"]
    failed = [j for j in c.get("/api/jobs").json()["items"] if j["status"] == "failed"]
    assert failed and failed[0]["finishedUtc"]
    assert c.post("/api/jobs", json={"action": "fitcheck"}).status_code == 500  # not 409: the failed job does not block


def test_cancel(app, history):
    assert as_role(app, "Reader").post(f"/api/jobs/{RUNNING}/cancel").status_code == 403
    assert as_role(app, "Resetter").post(f"/api/jobs/{RUNNING}/cancel").status_code == 403  # the job needs Applier
    c = as_role(app, "Applier")
    response = c.post(f"/api/jobs/{RUNNING}/cancel")
    assert response.status_code == 202 and response.json()["cancelRequested"] is True
    assert (history / "jobs" / f"{RUNNING}.cancel").is_file()
    finished = c.post(f"/api/jobs/{DONE}/cancel")
    assert finished.status_code == 409 and finished.json()["code"] == "job-finished"
    assert c.post("/api/jobs/bad/cancel").status_code == 400


def test_job_answers_are_masked(app, history):
    guid = "12345678-1234-4234-8234-123456789abc"
    (history / "jobs" / f"{RUNNING}.log").write_text(f"tenant {guid}\n", encoding="utf-8")
    text = as_role(app, "Reader").get(f"/api/jobs/{RUNNING}").text
    assert guid not in text and "12345678..." in text


def test_a_broken_job_file_is_left_out_of_the_list(app, history):
    (history / "jobs" / "job-20261107-130000-aaaaaa.json").write_text("{}", encoding="utf-8")
    c = as_role(app, "Reader")
    assert [j["id"] for j in c.get("/api/jobs").json()["items"]] == [RUNNING, DONE]
    assert c.get("/api/jobs/job-20261107-130000-aaaaaa").status_code == 409


def test_plan_list_names_the_area(client):
    items = {i["id"]: i for i in client.get("/api/plans").json()["items"]}
    assert items[APPLY_PLAN]["area"] == "Intune"
    assert "area" not in items["apply-plan-20261107-120000"]


# Break-glass account (issue #79, ADR 0016): a local sign-in only reads, whatever its token says.

def as_local(app, *roles: str) -> TestClient:
    return TestClient(app, client=("127.0.0.1", 50000), headers=authkit.bearer(authkit.local_token(list(roles))))


@pytest.mark.parametrize("roles", [("Applier",), ("Resetter",), ("Applier", "Resetter")])
@pytest.mark.parametrize("action", ["drift", "plan-apply", "plan-reset", "intune-backup", "export-desired"])
def test_the_local_account_starts_no_report_apply_or_reset(app, idle, launcher, roles, action):
    response = as_local(app, *roles).post("/api/jobs", json={"action": action})
    assert response.status_code == 403
    assert response.json()["code"] == "forbidden"
    assert launcher.started == []


def test_the_local_account_may_check_the_configuration(app, idle, launcher):
    response = as_local(app, "Reader").post("/api/jobs", json={"action": "setup-check", "scope": "Config"})
    assert response.status_code == 202
    full = as_local(app, "Applier").post("/api/jobs", json={"action": "setup-check"})
    assert full.status_code == 403
