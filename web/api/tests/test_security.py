"""Requests can only read the files below History/reports; only GET; no CORS; local bind by default."""

from __future__ import annotations

import pytest

from m365api import __main__ as main_module
from m365api.contract import errors


@pytest.mark.parametrize(
    "url",
    [
        "/api/plans/..%2F..%2Fsecret",
        "/api/plans/%2e%2e",
        "/api/plans/APPLY-PLAN-20261107-120000",
        "/api/plans/apply-plan-2026_1107",
        "/api/reports/drift-..",
    ],
)
def test_ids_outside_the_pattern_are_refused(client, url):
    response = client.get(url)
    assert response.status_code in (400, 404)
    assert errors("Error", response.json()) == []


def test_no_path_escape_even_with_a_matching_file_outside(client, history):
    # A plan file next to History/reports must never be reachable.
    (history / "apply-plan-20261107-120001.json").write_text("{}", encoding="utf-8")
    response = client.get("/api/plans/apply-plan-20261107-120001")
    assert response.status_code == 404


def test_report_id_on_the_plan_route_is_not_found(client):
    response = client.get("/api/plans/drift-20261107-120000")
    assert response.status_code == 404
    assert response.json()["code"] == "not-found"


@pytest.mark.parametrize("method", ["post", "put", "patch", "delete"])
def test_only_get(client, method):
    response = getattr(client, method)("/api/plans")
    assert response.status_code == 405
    assert errors("Error", response.json()) == []


def test_unknown_route_gives_the_error_schema(client):
    response = client.get("/api/nothing")
    assert response.status_code == 404
    assert errors("Error", response.json()) == []


def test_no_cors_and_no_generated_docs(client):
    response = client.get("/api/status", headers={"Origin": "https://example.invalid"})
    assert "access-control-allow-origin" not in {k.lower() for k in response.headers}
    for url in ("/docs", "/redoc", "/openapi.json"):
        assert client.get(url).status_code == 404


def test_binds_to_localhost_by_default(monkeypatch):
    called = {}
    monkeypatch.delenv("M365CLONING_API_HOST", raising=False)
    monkeypatch.setattr(main_module.uvicorn, "run", lambda app, **kw: called.update(kw))
    main_module.main()
    assert called["host"] == "127.0.0.1"
