"""Reading rules: other formats are left out of lists and refused in detail; audit paging and filters; status."""

from __future__ import annotations

import json

from fastapi.testclient import TestClient

from m365api import create_app
from m365api.contract import errors


def test_older_format_is_left_out_and_refused(client, history):
    old = {"Kind": "apply", "PlanHash": "0" * 64, "Plan": {}}  # schema version 1 had no SchemaVersion
    (history / "reports" / "apply-plan-20200101-000000.json").write_text(json.dumps(old), encoding="utf-8")
    ids = [item["id"] for item in client.get("/api/plans").json()["items"]]
    assert "apply-plan-20200101-000000" not in ids
    response = client.get("/api/plans/apply-plan-20200101-000000")
    assert response.status_code == 500
    assert response.json()["code"] == "unsupported-format"
    assert errors("Error", response.json()) == []


def test_broken_json_is_left_out(client, history):
    (history / "reports" / "drift-20200101-000000.json").write_text("{not json", encoding="utf-8")
    ids = [item["id"] for item in client.get("/api/reports").json()["items"]]
    assert "drift-20200101-000000" not in ids
    assert client.get("/api/reports/drift-20200101-000000").status_code == 500


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
