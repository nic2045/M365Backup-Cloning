"""Exports of the desired state (issue #27, ADR 0018): list and detail read History/reports/desired-export-*.json only."""

from __future__ import annotations

import json

from m365api.contract import errors


def test_list_is_newest_first_with_counts(client):
    body = client.get("/api/desired-exports").json()
    assert errors("DesiredExportList", body) == []
    ids = [item["id"] for item in body["items"]]
    assert ids == ["desired-export-20261107-123000", "desired-export-20261106-123000"]
    first = body["items"][0]
    assert (first["files"], first["added"], first["changed"], first["removed"], first["skipped"]) == (42, 2, 1, 1, 2)
    assert body["items"][1]["unchanged"] is True and body["items"][1]["commit"] == ""


def test_detail_has_the_changes_and_the_skipped_resources(client):
    body = client.get("/api/desired-exports/desired-export-20261107-123000").json()
    assert errors("DesiredExportResponse", body) == []
    export = body["export"]
    assert {c["Change"] for c in export["Changes"]} == {"added", "changed", "removed"}
    assert all(s["Reason"].startswith("secret:") for s in export["Skipped"])


def test_exports_are_not_backups_or_reports(client):
    assert client.get("/api/intune-backups/desired-export-20261107-123000").status_code == 404
    assert client.get("/api/desired-exports/intune-backup-20261107-120000").status_code == 404
    ids = [item["id"] for item in client.get("/api/reports").json()["items"]]
    assert not any(i.startswith("desired-export-") for i in ids)


def test_older_format_is_listed_as_outdated_and_refused_with_409(client, history):
    (history / "reports" / "desired-export-20200101-000000.json").write_text(
        json.dumps({"SchemaVersion": "1", "Kind": "desiredexport"}), encoding="utf-8")
    items = {i["id"]: i for i in client.get("/api/desired-exports").json()["items"]}
    assert items["desired-export-20200101-000000"]["state"] == "outdated"
    detail = client.get("/api/desired-exports/desired-export-20200101-000000")
    assert detail.status_code == 409 and detail.json()["code"] == "unsupported-format"


def test_a_file_with_content_is_refused(client, history):
    path = history / "reports" / "desired-export-20261107-123000.json"
    content = json.loads(path.read_text(encoding="utf-8"))
    content["Changes"][0]["Content"] = {"Password": "x"}
    path.write_text(json.dumps(content), encoding="utf-8")
    assert client.get("/api/desired-exports/desired-export-20261107-123000").status_code == 409


def test_guids_are_masked(client, history):
    path = history / "reports" / "desired-export-20261107-123000.json"
    content = json.loads(path.read_text(encoding="utf-8"))
    content["Skipped"][0]["Name"] = "Policy 11111111-2222-3333-4444-555555555555"
    path.write_text(json.dumps(content), encoding="utf-8")
    text = client.get("/api/desired-exports/desired-export-20261107-123000").text
    assert "11111111-2222-3333-4444-555555555555" not in text


def test_bad_ids_and_anonymous_are_refused(client, anonymous):
    assert client.get("/api/desired-exports/DESIRED").status_code == 400
    assert anonymous.get("/api/desired-exports").status_code == 401
