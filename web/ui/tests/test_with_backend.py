"""The pages against the real API server (web/api), in process.

The API reads a History folder built from the contract examples, so both sides
use the same data as the mock. This shows that the interface works with the
real server, not only with the mock answers.
"""

import json
import re
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from m365api import create_app as create_api
from m365ui.api_client import HttpClient
from m365ui.main import create_app as create_ui

MOCK = json.loads((Path(__file__).resolve().parents[2] / "mock" / "responses.json").read_text(encoding="utf-8"))["responses"]
GUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")


def write_history(root: Path) -> Path:
    reports = root / "reports"
    reports.mkdir(parents=True)
    for key, example in MOCK.items():
        url = key.split(" ", 1)[1]
        body = example["body"]
        if example["status"] != 200 or "?" in url:
            continue
        if url.startswith("/api/reports/"):
            (reports / f"{body['id']}.json").write_text(json.dumps(body["report"]), encoding="utf-8")
        elif url.startswith("/api/plans/"):
            plan_file = {"SchemaVersion": body["schemaVersion"], "Kind": body["kind"], "CreatedUtc": body["createdUtc"],
                         "PlanHash": body["planHash"], "Plan": body["plan"]}
            (reports / f"{body['id']}.json").write_text(json.dumps(plan_file), encoding="utf-8")
    lines = [json.dumps(item) for item in reversed(MOCK["GET /api/audit"]["body"]["items"])]
    (root / "audit.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return root


@pytest.fixture()
def web(tmp_path):
    api = TestClient(create_api(write_history(tmp_path / "History")))
    return TestClient(create_ui(HttpClient(http=api)))


def plan_and_report_ids():
    reports = [k.split("/")[-1] for k, v in MOCK.items() if k.startswith("GET /api/reports/") and v["status"] == 200]
    plans = [k.split("/")[-1] for k, v in MOCK.items() if k.startswith("GET /api/plans/") and v["status"] == 200]
    return reports, plans


REPORTS, PLANS = plan_and_report_ids()
PAGES = ["/", "/reports", "/reports?kind=tenantfit", "/plans", "/plans?kind=apply", "/audit", "/audit?mode=fitcheck"] \
    + [f"/reports/{r}" for r in REPORTS] + [f"/plans/{p}" for p in PLANS]


@pytest.mark.parametrize("page", PAGES)
def test_pages_work_with_the_real_api(web, page):
    r = web.get(page)
    assert r.status_code == 200, r.text[:500]
    assert "Example data" not in r.text  # not the mock
    assert not GUID.search(r.text)


def test_unknown_plan_is_404_from_the_real_api(web):
    r = web.get("/plans/apply-plan-19990101-000000")
    assert r.status_code == 404


def test_outdated_files_are_shown_and_explained(tmp_path):
    """Issue #59: a file in an older format is listed as 'Outdated' and its page says how to regenerate it."""
    history = write_history(tmp_path / "History")
    (history / "reports" / "apply-plan-20200101-000000.json").write_text(json.dumps({"Kind": "apply", "Plan": {}}), encoding="utf-8")
    (history / "reports" / "drift-20200101-000000.json").write_text("{not json", encoding="utf-8")
    web = TestClient(create_ui(HttpClient(http=TestClient(create_api(history)))))

    plans = web.get("/plans")
    assert plans.status_code == 200
    assert "apply-plan-20200101-000000" in plans.text and "Outdated" in plans.text
    assert "regenerate the plan with the script" in plans.text

    reports = web.get("/reports")
    assert reports.status_code == 200 and "Outdated" in reports.text

    detail = web.get("/plans/apply-plan-20200101-000000")
    assert detail.status_code == 409
    assert "older or unknown format" in detail.text and "Regenerate the plan or report" in detail.text
    assert "unsupported-format" in detail.text
    assert web.get("/reports/drift-20200101-000000").status_code == 409
