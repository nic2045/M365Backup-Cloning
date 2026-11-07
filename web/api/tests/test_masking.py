"""No answer carries a full tenant ID or any other GUID (ADR 0009, issue #55)."""

from __future__ import annotations

import copy
import json
import re

from m365api.masking import GUID_RE, mask_response, shorten

from .conftest import MOCK

PROD_TENANT = "tenant-prod-0001"  # invented Prod tenant ID of the contract fixtures
GUID_PROD = "11111111-2222-4333-8444-555555555555"  # invented, GUID shaped
GUID_OTHER = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"  # invented, GUID shaped


def all_answers(client) -> list[str]:
    urls = ["/api/reports", "/api/plans", "/api/audit", "/api/fitcheck/latest", "/api/status"]
    for item in client.get("/api/reports").json()["items"]:
        urls.append(f"/api/reports/{item['id']}")
    for item in client.get("/api/plans").json()["items"]:
        urls.append(f"/api/plans/{item['id']}")
    texts = []
    for url in urls:
        response = client.get(url)
        assert response.status_code == 200, (url, response.text)
        texts.append(response.text)
    return texts


def add_guid_plan(history) -> None:
    """A reset plan whose partner entries and properties carry GUID-shaped tenant IDs."""
    body = copy.deepcopy(MOCK["GET /api/plans/dev-baseline-plan-20261107-120000"]["body"])
    text = json.dumps(body).replace(PROD_TENANT, GUID_PROD)
    body = json.loads(text)
    body["plan"]["Actions"][0]["Properties"]["SomeObjectId"] = GUID_OTHER
    plan_file = {
        "SchemaVersion": body["schemaVersion"],
        "Kind": body["kind"],
        "CreatedUtc": "2026-11-07T13:00:00Z",
        "PlanHash": body["planHash"],
        "Plan": body["plan"],
    }
    (history / "reports" / "dev-baseline-plan-20261107-130000.json").write_text(json.dumps(plan_file), encoding="utf-8")


def test_shorten_matches_the_audit_log():
    assert shorten("tenant-prod-0001") == "tenant-p..."
    assert shorten("short") == "short"


def test_the_fixtures_carry_the_full_prod_tenant_id():
    # Guard: the contract fixtures really contain the value the API must hide.
    assert PROD_TENANT in json.dumps(MOCK)


def test_no_answer_carries_the_prod_tenant_id(client):
    for text in all_answers(client):
        assert PROD_TENANT not in text


def test_no_answer_carries_a_full_guid(client, history):
    add_guid_plan(history)
    texts = all_answers(client)
    joined = "\n".join(texts)
    assert GUID_RE.search(joined) is None
    assert "11111111..." in joined  # the partner tenant is shown shortened
    assert "aaaaaaaa..." in joined


def test_partner_entries_and_names_are_masked():
    body = {
        "Protected": [{"Kind": "Partner", "Name": PROD_TENANT, "Source": "baseline"}],
        "Actions": [{"Name": f"Prod tenant as partner ({PROD_TENANT})", "Properties": {"PartnerTenantId": PROD_TENANT}}],
    }
    masked = json.dumps(mask_response(body))
    assert PROD_TENANT not in masked
    assert "tenant-p..." in masked


def test_mask_keeps_hashes():
    digest = "0d6578ecf6d5388ccd2e041e1c6d060eca66633338193e8f2bdc17be0f3152ce"
    assert mask_response({"PlanHash": digest}) == {"PlanHash": digest}
    assert re.fullmatch(r"[0-9a-f]{64}", digest)
