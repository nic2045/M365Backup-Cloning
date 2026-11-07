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
    "/api/status": "Status",
}


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
        for op in ops.values():
            ok = op["responses"]["200"]["content"]["application/json"]["schema"]["$ref"]
            assert ok.endswith("/" + ROUTE_SCHEMA[path])
            for status in ("400", "500"):
                assert status in op["responses"], f"{path} has no {status}"


def test_only_read_routes():
    assert {method for method, _ in openapi_routes()} == {"get"}
    assert {method for method, _ in app_routes(create_app("."))} == {"get"}


@pytest.mark.parametrize("key", sorted(MOCK))
def test_answer_matches_the_contract_example(client, key):
    method, url = key.split(" ", 1)
    assert method == "GET"
    example = MOCK[key]
    response = client.get(url)
    assert response.status_code == example["status"], response.text
    body = response.json()
    if example["status"] == 200:
        path = url.split("?")[0]
        template = path if path in ROUTE_SCHEMA else path.rsplit("/", 1)[0] + "/{id}"
        assert errors(ROUTE_SCHEMA[template], body) == []
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
    ],
)
def test_bad_parameters_give_the_error_schema(client, url):
    response = client.get(url)
    assert response.status_code == 400
    assert errors("Error", response.json()) == []
    assert response.json()["code"] == "invalid-parameter"
