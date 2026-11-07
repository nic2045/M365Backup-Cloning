"""Builds a History folder from the contract examples (web/mock/responses.json, made from the core fixtures)."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from m365api import create_app
from m365api.contract import REPO_ROOT

from . import authkit

MOCK = json.loads((REPO_ROOT / "web" / "mock" / "responses.json").read_text(encoding="utf-8"))["responses"]


def write_history(root: Path) -> Path:
    """Writes the core files that the mock examples were made from: report and plan files, the audit log."""
    reports = root / "reports"
    reports.mkdir(parents=True)
    for key, example in MOCK.items():
        method, url = key.split(" ", 1)
        body = example["body"]
        if example["status"] != 200 or "?" in url:
            continue
        if url.startswith("/api/reports/"):
            (reports / f"{body['id']}.json").write_text(json.dumps(body["report"]), encoding="utf-8")
        elif url.startswith("/api/plans/"):
            plan_file = {
                "SchemaVersion": body["schemaVersion"],
                "Kind": body["kind"],
                "CreatedUtc": body["createdUtc"],
                "PlanHash": body["planHash"],
                "Plan": body["plan"],
            }
            (reports / f"{body['id']}.json").write_text(json.dumps(plan_file), encoding="utf-8")
    # The audit log is append only and the API lists newest first: write the example lines oldest first.
    lines = [json.dumps(item) for item in reversed(MOCK["GET /api/audit"]["body"]["items"])]
    (root / "audit.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return root


@pytest.fixture()
def history(tmp_path: Path) -> Path:
    return write_history(tmp_path / "History")


@pytest.fixture()
def app(history: Path):
    return create_app(history, authkit.config())


@pytest.fixture()
def client(app) -> TestClient:
    """Signed in as Reader (Entra ID test token)."""
    return TestClient(app, headers=authkit.bearer(authkit.entra_token()))


@pytest.fixture()
def anonymous(app) -> TestClient:
    return TestClient(app)
