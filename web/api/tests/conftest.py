"""Builds a History folder from the contract examples (web/mock/responses.json, made from the core fixtures)."""

from __future__ import annotations

import json
from datetime import datetime, timezone
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
    # Jobs (issue #14): the job file is the job state without what the API adds (progress, cancel marker, log).
    jobs = root / "jobs"
    jobs.mkdir()
    for key, example in MOCK.items():
        method, url = key.split(" ", 1)
        if method != "GET" or example["status"] != 200 or not url.startswith("/api/jobs/"):
            continue
        body = dict(example["body"])
        log = body.pop("log", [])
        for extra in ("schemaVersion", "cancelRequested", "progress"):
            body.pop(extra)
        (jobs / f"{body['id']}.json").write_text(
            json.dumps({"SchemaVersion": "2", "Kind": "job", "Job": body, "Confirm": {}}), encoding="utf-8")
        if log:
            (jobs / f"{body['id']}.log").write_text("\n".join(log) + "\n", encoding="utf-8")
    # The audit log is append only and the API lists newest first: write the example lines oldest first.
    lines = [json.dumps(item) for item in reversed(MOCK["GET /api/audit"]["body"]["items"])]
    (root / "audit.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return root


@pytest.fixture()
def history(tmp_path: Path) -> Path:
    return write_history(tmp_path / "History")


# The examples were made at this time; a running job of the examples is not yet stale then.
CLOCK = datetime(2026, 11, 7, 12, 20, tzinfo=timezone.utc)


class FakeLauncher:
    """Stands in for the job runner process: records the job files it was asked to start."""

    def __init__(self, fail: bool = False):
        self.started: list[Path] = []
        self.fail = fail

    def __call__(self, job_path: Path, out_path: Path) -> None:
        if self.fail:
            raise FileNotFoundError("pwsh")
        self.started.append(job_path)


@pytest.fixture()
def launcher() -> FakeLauncher:
    return FakeLauncher()


@pytest.fixture()
def app(history: Path, launcher: FakeLauncher):
    return create_app(history, authkit.config(), launcher=launcher, clock=lambda: CLOCK)


@pytest.fixture()
def client(app) -> TestClient:
    """Signed in as Reader (Entra ID test token)."""
    return TestClient(app, headers=authkit.bearer(authkit.entra_token()))


@pytest.fixture()
def anonymous(app) -> TestClient:
    return TestClient(app)
