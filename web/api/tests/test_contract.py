"""Contract test: the app serves exactly the routes of web/openapi.json, and every answer matches the schema."""

from __future__ import annotations

import json

import pytest
from fastapi.routing import APIRoute

from m365api import create_app
from m365api.contract import OPENAPI_PATH, errors
from m365api.masking import mask_response

from .conftest import MOCK

OPENAPI = json.loads(OPENAPI_PATH.read_text(encoding="utf-8"))
ROUTE_SCHEMA = {
    "/api/reports": "ReportList",
    "/api/reports/{id}": "ReportResponse",
    "/api/plans": "PlanList",
    "/api/plans/{id}": "PlanResponse",
    "/api/audit": "AuditPage",
    "/api/fitcheck/latest": "FitCheckResponse",
    "/api/setup-check/latest": "SetupCheckResponse",
    "/api/status": "Status",
    "/api/intune-backups": "IntuneBackupList",
    "/api/intune-backups/{id}": "IntuneBackupResponse",
    "/api/jobs": {"get": "JobList", "post": "Job"},
    "/api/jobs/{id}": "Job",
    "/api/jobs/{id}/cancel": "Job",
}
WRITE_ROUTES = {("post", "/api/jobs"), ("post", "/api/jobs/{id}/cancel")}


def schema_of(path: str, method: str) -> str:
    entry = ROUTE_SCHEMA[path]
    return entry[method] if isinstance(entry, dict) else entry


def template_of(url: str) -> str:
    path = url.split("?")[0]
    if path in ROUTE_SCHEMA:
        return path
    if path.endswith("/cancel"):
        return path.rsplit("/", 2)[0] + "/{id}/cancel"
    return path.rsplit("/", 1)[0] + "/{id}"


def app_routes(app) -> set[tuple[str, str]]:
    found = set()
    for route in app.routes:
        if isinstance(route, APIRoute):
            for method in route.methods:
                found.add((method.lower(), route.path))
    return found


def openapi_routes() -> set[tuple[str, str]]:
    return {(method, path) for path, ops in OPENAPI["paths"].items() for method in ops}


def test_app_serves_exactly_the_openapi_routes(tmp_path):
    assert app_routes(create_app(tmp_path)) == openapi_routes()


def test_every_openapi_route_names_its_schema_and_the_error_schema():
    for path, ops in OPENAPI["paths"].items():
        for method, op in ops.items():
            success = "202" if (method, path) in WRITE_ROUTES else "200"
            ok = op["responses"][success]["content"]["application/json"]["schema"]["$ref"]
            assert ok.endswith("/" + schema_of(path, method))
            for status in ("400", "401", "403", "500"):
                assert status in op["responses"], f"{path} has no {status}"
                ref = op["responses"][status]["$ref"].rsplit("/", 1)[-1]
                schema = OPENAPI["components"]["responses"][ref]["content"]["application/json"]["schema"]["$ref"]
                assert schema == "#/components/schemas/Error"


def test_every_route_needs_sign_in():
    assert OPENAPI["security"] == [{"bearerAuth": []}]
    assert OPENAPI["components"]["securitySchemes"]["bearerAuth"]["scheme"] == "bearer"
    for path, ops in OPENAPI["paths"].items():
        for method, op in ops.items():
            assert op.get("security", OPENAPI["security"]) == OPENAPI["security"]
            expected = "Applier|Resetter" if (method, path) in WRITE_ROUTES else "Reader"
            assert op["x-required-role"] == expected


def test_write_routes_are_only_the_job_routes():
    writes = {(m, p) for m, p in openapi_routes() if m != "get"}
    assert writes == WRITE_ROUTES
    assert {(m, p) for m, p in app_routes(create_app(".")) if m != "get"} == WRITE_ROUTES


@pytest.mark.parametrize("key", sorted(MOCK))
def test_answer_matches_the_contract_example(client, key):
    method, url = key.split(" ", 1)
    example = MOCK[key]
    if method == "POST":
        # Write examples are for the interface in mock mode; the API side is tested in test_jobs.py.
        assert errors(schema_of(template_of(url), "post"), example["body"]) == []
        return
    assert method == "GET"
    response = client.get(url)
    assert response.status_code == example["status"], response.text
    body = response.json()
    if example["status"] == 200:
        assert errors(schema_of(template_of(url), "get"), body) == []
        # Same content as the example, except that the API masks tenant IDs (ADR 0009).
        assert body == mask_response(example["body"])
    else:
        assert errors("Error", body) == []
        assert body["code"] == example["body"]["code"]


def test_lists_filter_by_kind(client):
    plans = client.get("/api/plans", params={"kind": "reset"}).json()["items"]
    assert {item["kind"] for item in plans} == {"reset"}
    assert {item["mode"] for item in plans} == {"Align", "Full"}
    reports = client.get("/api/reports", params={"kind": "drift"}).json()["items"]
    assert [item["kind"] for item in reports] == ["drift"]


@pytest.mark.parametrize(
    "url",
    [
        "/api/plans?kind=nope",
        "/api/reports?kind=nope",
        "/api/audit?mode=nope",
        "/api/audit?since=yesterday",
        "/api/audit?page=0",
        "/api/audit?pageSize=501",
        "/api/audit?pageSize=abc",
        "/api/audit?planHash=ABC",
        "/api/audit?planHash=" + "A" * 64,
    ],
)
def test_bad_parameters_give_the_error_schema(client, url):
    response = client.get(url)
    assert response.status_code == 400
    assert errors("Error", response.json()) == []
    assert response.json()["code"] == "invalid-parameter"


def test_audit_filters_by_plan_hash(client):
    items = MOCK["GET /api/audit"]["body"]["items"]
    wanted = next(i["PlanHash"] for i in items if i["PlanHash"])
    got = client.get("/api/audit", params={"planHash": wanted}).json()
    assert got["total"] == sum(1 for i in items if i["PlanHash"] == wanted) and got["total"] >= 1
    assert {i["PlanHash"] for i in got["items"]} == {wanted}


def test_audit_filters_by_report_mode(client):
    got = client.get("/api/audit", params={"mode": "report"}).json()
    assert got["total"] >= 1 and {i["Mode"] for i in got["items"]} == {"report"}


def test_audit_query_parameters_match_openapi():
    names = {p["name"] for p in OPENAPI["paths"]["/api/audit"]["get"]["parameters"]}
    assert names == {"mode", "since", "planHash", "page", "pageSize"}
