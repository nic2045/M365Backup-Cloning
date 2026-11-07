"""Sign-in of the API (issue #60, ADR 0010): every route needs a valid token and the role Reader."""

from __future__ import annotations

import logging
import secrets
import time

import pytest
from fastapi.testclient import TestClient

from m365api import create_app
from m365api.auth import AuthConfig, effective_roles
from m365api.contract import OPENAPI_PATH, errors

from . import authkit
from .test_contract import openapi_routes

READ_URLS = sorted({p.replace("{id}", "drift-20261107-120000") for _, p in openapi_routes()})


def assert_error(response, status: int, code: str | None = None):
    assert response.status_code == status, response.text
    assert errors("Error", response.json()) == []
    if code:
        assert response.json()["code"] == code


@pytest.mark.parametrize("url", READ_URLS)
def test_every_route_needs_a_token(anonymous, url):
    response = anonymous.get(url)
    assert_error(response, 401, "unauthorized")
    assert response.headers["www-authenticate"].startswith("Bearer")


@pytest.mark.parametrize("url", ["/api/status", "/api/reports", "/api/audit"])
@pytest.mark.parametrize("role", ["Reader", "Applier", "Resetter"])
def test_reader_and_the_roles_that_include_it_may_read(anonymous, url, role):
    assert anonymous.get(url, headers=authkit.bearer(authkit.entra_token([role]))).status_code == 200


@pytest.mark.parametrize("roles", [[], ["Guest"], ["reader"]])
def test_without_the_role_is_forbidden(anonymous, roles):
    assert_error(anonymous.get("/api/status", headers=authkit.bearer(authkit.entra_token(roles))), 403, "forbidden")


@pytest.mark.parametrize(
    ("token", "code"),
    [
        (lambda: authkit.entra_token(exp=int(time.time()) - 3600, iat=int(time.time()) - 7200), "token-expired"),
        (lambda: authkit.entra_token(key=authkit.OTHER_KEY), "invalid-token"),
        (lambda: authkit.entra_token(aud="api://someone-else"), "invalid-token"),
        (lambda: authkit.entra_token(iss="https://login.microsoftonline.com/other/v2.0"), "invalid-token"),
        (lambda: authkit.entra_token(tid="00000000-0000-4000-8000-000000000099"), "invalid-token"),
        (lambda: authkit.entra_token(exp=None), "invalid-token"),
        (lambda: "not-a-token", "invalid-token"),
    ],
    ids=["expired", "wrong-signature", "wrong-audience", "wrong-issuer", "wrong-tenant", "no-expiry", "garbage"],
)
def test_bad_entra_tokens_are_refused(anonymous, token, code):
    assert_error(anonymous.get("/api/status", headers=authkit.bearer(token())), 401, code)


def test_unsigned_and_symmetric_tokens_do_not_pass_as_entra(anonymous):
    import jwt

    claims = {"iss": "https://login.microsoftonline.com/%s/v2.0" % authkit.TENANT, "aud": authkit.AUDIENCE,
              "tid": authkit.TENANT, "iat": int(time.time()), "exp": int(time.time()) + 600, "roles": ["Reader"]}
    for token in (jwt.encode(claims, None, algorithm="none"), jwt.encode(claims, authkit.LOCAL_SECRET, algorithm="HS256")):
        assert_error(anonymous.get("/api/status", headers=authkit.bearer(token)), 401, "invalid-token")


@pytest.mark.parametrize("scheme", ["Basic", "Token", ""])
def test_only_the_bearer_scheme(anonymous, scheme):
    header = f"{scheme} {authkit.entra_token()}".strip()
    assert_error(anonymous.get("/api/status", headers={"Authorization": header}), 401, "unauthorized")


def test_nothing_configured_refuses_everything(history):
    client = TestClient(create_app(history, AuthConfig()), headers=authkit.bearer(authkit.entra_token()))
    assert_error(client.get("/api/status"), 401, "sign-in-not-configured")


def test_from_env_without_values_is_not_configured():
    cfg = AuthConfig.from_env({})
    assert not cfg.entra and not cfg.local


def test_from_env_ignores_a_short_local_secret():
    assert not AuthConfig.from_env({"M365CLONING_LOCAL_TOKEN_SECRET": "too-short"}).local


# Local account (fallback on the same machine).

def local_client(app, host="127.0.0.1", token=None, **headers):
    return TestClient(app, client=(host, 50000), headers=authkit.bearer(token or authkit.local_token()) | headers)


@pytest.mark.parametrize("host", ["127.0.0.1", "::1"])
def test_local_token_from_loopback(app, host):
    assert local_client(app, host).get("/api/status").status_code == 200


@pytest.mark.parametrize("host", ["10.0.0.5", "testclient", "192.168.1.20"])
def test_local_token_from_elsewhere_is_refused(app, host):
    assert_error(local_client(app, host).get("/api/status"), 401, "invalid-token")


@pytest.mark.parametrize("header", ["X-Forwarded-For", "Forwarded", "X-Real-IP"])
def test_local_token_through_a_proxy_is_refused(app, header):
    assert_error(local_client(app, **{header: "203.0.113.7"}).get("/api/status"), 401, "invalid-token")


def test_local_token_needs_local_sign_in_to_be_on(history):
    app = create_app(history, authkit.config(local=False))
    assert_error(local_client(app).get("/api/status"), 401, "invalid-token")


@pytest.mark.parametrize(
    "token",
    [
        lambda: authkit.local_token(secret=secrets.token_hex(32).encode("ascii")),
        lambda: authkit.local_token(lifetime=-30),
        lambda: authkit.local_token(lifetime=24 * 3600),
        lambda: authkit.local_token(aud="api://someone-else"),
    ],
    ids=["wrong-secret", "expired", "too-long-lived", "wrong-audience"],
)
def test_bad_local_tokens_are_refused(app, token):
    assert local_client(app, token=token()).get("/api/status").status_code == 401


def test_local_role_is_checked(app):
    assert_error(local_client(app, token=authkit.local_token(["Nobody"])).get("/api/status"), 403, "forbidden")


def test_roles_hierarchy():
    assert effective_roles(["Applier"]) == {"Applier", "Reader"}
    assert effective_roles(["Resetter"]) == {"Resetter", "Reader"}
    assert "Applier" not in effective_roles(["Resetter"])
    assert effective_roles(["Admin"]) == frozenset()


def test_tokens_never_reach_the_log(anonymous, caplog):
    caplog.set_level(logging.DEBUG)
    tokens = [authkit.entra_token(), authkit.entra_token(key=authkit.OTHER_KEY), authkit.entra_token(aud="x")]
    for token in tokens:
        anonymous.get("/api/status", headers=authkit.bearer(token))
    for token in tokens:
        assert token not in caplog.text
        assert token.split(".")[2] not in caplog.text


def test_openapi_lists_401_and_403_for_every_route():
    text = OPENAPI_PATH.read_text(encoding="utf-8")
    assert text.count('"401"') == text.count('"403"') == len(READ_URLS)
