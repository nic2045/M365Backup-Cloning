"""Intune backup runs (issue #68, ADR 0014): list and detail read History/reports/intune-backup-*.json only."""

from __future__ import annotations

import json

from m365api.contract import errors


def test_list_is_newest_first_with_counts_of_both_tenants(client):
    body = client.get("/api/intune-backups").json()
    assert errors("IntuneBackupList", body) == []
    ids = [item["id"] for item in body["items"]]
    assert ids == ["intune-backup-20261107-120000", "intune-backup-20261106-120000"]
    first = body["items"][0]
    assert (first["added"], first["changed"], first["removed"]) == (1, 2, 1)
    assert body["items"][1]["unchanged"] is True and body["items"][1]["commit"] == ""


def test_detail_has_the_changes_per_tenant(client):
    body = client.get("/api/intune-backups/intune-backup-20261107-120000").json()
    assert errors("IntuneBackupResponse", body) == []
    prod, dev = body["backup"]["Tenants"]
    assert prod["Side"] == "Prod" and dev["Side"] == "Dev"
    assert {c["Change"] for c in prod["Changes"]} == {"added", "changed", "removed"}


def test_backups_are_not_in_the_reports_list(client):
    ids = [item["id"] for item in client.get("/api/reports").json()["items"]]
    assert not any(i.startswith("intune-backup-") for i in ids)


def test_a_report_id_is_not_a_backup_and_the_other_way_round(client):
    assert client.get("/api/intune-backups/drift-20261107-120000").status_code == 404
    assert client.get("/api/reports/intune-backup-20261107-120000").status_code == 404


def test_older_format_is_listed_as_outdated_and_refused_with_409(client, history):
    (history / "reports" / "intune-backup-20200101-000000.json").write_text(
        json.dumps({"SchemaVersion": "1", "Kind": "intunebackup"}), encoding="utf-8")
    items = {i["id"]: i for i in client.get("/api/intune-backups").json()["items"]}
    old = items["intune-backup-20200101-000000"]
    assert old["state"] == "outdated" and "commit" not in old
    detail = client.get("/api/intune-backups/intune-backup-20200101-000000")
    assert detail.status_code == 409 and detail.json()["code"] == "unsupported-format"


def test_a_file_with_an_extra_field_is_refused(client, history):
    path = history / "reports" / "intune-backup-20261107-120000.json"
    content = json.loads(path.read_text(encoding="utf-8"))
    content["Tenants"][0]["Content"] = "secret"
    path.write_text(json.dumps(content), encoding="utf-8")
    assert client.get("/api/intune-backups/intune-backup-20261107-120000").status_code == 409


def test_bad_or_escaping_ids_are_refused(client):
    assert client.get("/api/intune-backups/INTUNE").status_code == 400
    assert client.get("/api/intune-backups/intune-backup-..%2f..%2fconfig").status_code in (400, 404)


def test_guids_in_a_path_are_masked(client, history):
    path = history / "reports" / "intune-backup-20261107-120000.json"
    content = json.loads(path.read_text(encoding="utf-8"))
    content["Tenants"][0]["Changes"][0]["Path"] = "Settings Catalog/Policy_11111111-2222-3333-4444-555555555555.json"
    path.write_text(json.dumps(content), encoding="utf-8")
    text = client.get("/api/intune-backups/intune-backup-20261107-120000").text
    assert "11111111-2222-3333-4444-555555555555" not in text and "11111111..." in text


def test_needs_sign_in(anonymous):
    assert anonymous.get("/api/intune-backups").status_code == 401

