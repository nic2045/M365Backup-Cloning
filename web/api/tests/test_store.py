"""Reading rules: other formats are listed as outdated and refused with 409 in detail (issue #59); audit paging
and filters; status."""

from __future__ import annotations

import json

from fastapi.testclient import TestClient

from m365api import create_app
from m365api.contract import errors


def test_older_format_is_listed_as_outdated_and_refused_with_409(client, history):
    old = {"Kind": "apply", "PlanHash": "0" * 64, "Plan": {}}  # schema version 1 had no SchemaVersion
    (history / "reports" / "apply-plan-20200101-000000.json").write_text(json.dumps(old), encoding="utf-8")
    listing = client.get("/api/plans").json()
    assert errors("PlanList", listing) == []
    outdated = [item for item in listing["items"] if item["id"] == "apply-plan-20200101-000000"]
    assert len(outdated) == 1
    assert outdated[0]["state"] == "outdated" and outdated[0]["kind"] == "apply"
    assert "planHash" not in outdated[0] and "summary" not in outdated[0]
    current = [item for item in listing["items"] if item["id"] != "apply-plan-20200101-000000"]
    assert current and all("state" not in item for item in current)
    response = client.get("/api/plans/apply-plan-20200101-000000")
    assert response.status_code == 409
    body = response.json()
    assert body["code"] == "unsupported-format" and "Regenerate" in body["message"]
    assert errors("Error", body) == []


def test_reset_plan_outdated_keeps_its_mode(client, history):
    (history / "reports" / "dev-reset-plan-full-20200101-000000.json").write_text(json.dumps({"Plan": {}}), encoding="utf-8")
    items = client.get("/api/plans", params={"kind": "reset"}).json()["items"]
    outdated = [item for item in items if item["id"] == "dev-reset-plan-full-20200101-000000"]
    assert outdated == [{"id": "dev-reset-plan-full-20200101-000000", "kind": "reset", "createdUtc": outdated[0]["createdUtc"], "state": "outdated", "mode": "Full"}]


def test_broken_json_is_listed_as_outdated_and_refused_with_409(client, history):
    (history / "reports" / "drift-20200101-000000.json").write_text("{not json", encoding="utf-8")
    listing = client.get("/api/reports").json()
    assert errors("ReportList", listing) == []
    states = {item["id"]: item.get("state") for item in listing["items"]}
    assert states["drift-20200101-000000"] == "outdated"
    response = client.get("/api/reports/drift-20200101-000000")
    assert response.status_code == 409 and response.json()["code"] == "unsupported-format"


def test_outdated_files_do_not_count_for_status_or_latest_check(client, history):
    before = client.get("/api/status").json()
    (history / "reports" / "drift-29990101-000000.json").write_text("{}", encoding="utf-8")
    (history / "reports" / "tenantfit-29990101-000000.json").write_text("{}", encoding="utf-8")
    assert client.get("/api/status").json() == before
    assert client.get("/api/fitcheck/latest").json()["id"] != "tenantfit-29990101-000000"


def test_detail_routes_document_409():
    from .test_contract import OPENAPI

    for path in ("/api/reports/{id}", "/api/plans/{id}"):
        assert "409" in OPENAPI["paths"][path]["get"]["responses"]


def test_lists_are_newest_first(client, history):
    source = json.loads((history / "reports" / "drift-20261107-120000.json").read_text(encoding="utf-8"))
    source["CreatedUtc"] = "2026-11-08T08:00:00.1234567Z"  # 7 fraction digits, as the core writes them
    (history / "reports" / "drift-20261108-080000.json").write_text(json.dumps(source), encoding="utf-8")
    items = client.get("/api/reports", params={"kind": "drift"}).json()["items"]
    assert [item["id"] for item in items] == ["drift-20261108-080000", "drift-20261107-120000"]
    assert client.get("/api/status").json()["reportId"] == "drift-20261108-080000"


def test_audit_paging_and_filters(client):
    first = client.get("/api/audit", params={"pageSize": 2}).json()
    assert first["total"] == 6 and len(first["items"]) == 2 and first["page"] == 1
    third = client.get("/api/audit", params={"pageSize": 2, "page": 3}).json()
    assert len(third["items"]) == 2
    beyond = client.get("/api/audit", params={"pageSize": 2, "page": 9}).json()
    assert beyond["items"] == [] and beyond["total"] == 6
    fit = client.get("/api/audit", params={"mode": "fitcheck"}).json()
    assert fit["total"] == 1 and fit["items"][0]["Mode"] == "fitcheck"
    later = client.get("/api/audit", params={"since": "2027-01-01T00:00:00Z"}).json()
    assert later["total"] == 0


def test_broken_audit_lines_are_skipped(client, history):
    with (history / "audit.jsonl").open("a", encoding="utf-8") as handle:
        handle.write("not json\n{\"Mode\": \"plan\"}\n")
    assert client.get("/api/audit").json()["total"] == 6


def test_empty_history(tmp_path):
    client = TestClient(create_app(tmp_path / "History"))
    assert client.get("/api/plans").json()["items"] == []
    assert client.get("/api/reports").json()["items"] == []
    assert client.get("/api/audit").json()["total"] == 0
    status = client.get("/api/status").json()
    assert status == {"schemaVersion": "2", "lastComparisonUtc": None, "differences": None, "fitStatus": None, "reportId": None}
    response = client.get("/api/fitcheck/latest")
    assert response.status_code == 404 and response.json()["code"] == "not-found"
