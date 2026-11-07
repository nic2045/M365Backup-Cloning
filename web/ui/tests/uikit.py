"""Test sign-in for the interface (issue #60): own keys, a fake Entra ID, no network."""

from __future__ import annotations

import secrets
import time
from typing import Any
from urllib.parse import parse_qs, urlparse

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa

from m365api.auth import AuthConfig, entra_issuer
from m365ui.auth import LocalConfig, OidcConfig, UiAuth
from m365ui.passwords import hash_password

TENANT = "00000000-0000-4000-8000-000000000001"  # made up for tests
CLIENT = "00000000-0000-4000-8000-0000000000c1"  # made up for tests
API_AUDIENCE = "api://m365cloning-test"
LOCAL_SECRET = secrets.token_hex(32).encode("ascii")  # made per run, never a fixed value
LOCAL_PASSWORD = "pw-" + secrets.token_hex(12)  # made per run
KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
OTHER_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
OIDC = OidcConfig(TENANT, CLIENT, f"{API_AUDIENCE}/access_as_user", "http://testserver/auth/callback")
LOCAL_HASH = hash_password(LOCAL_PASSWORD)


def token(claims: dict[str, Any], key=KEY) -> str:
    return jwt.encode({k: v for k, v in claims.items() if v is not None}, key, algorithm="RS256", headers={"kid": "t"})


class FakeEntra:
    """Stands in for the token endpoint and the signing keys of the tenant."""

    def __init__(self, roles=("Reader",), name="Test Person", **id_override):
        self.roles, self.name, self.id_override = list(roles), name, id_override
        self.redeemed: list[dict[str, str]] = []
        self.nonce = ""

    def redeem(self, config: OidcConfig, code: str, verifier: str) -> dict[str, Any]:
        self.redeemed.append({"code": code, "verifier": verifier})
        now = int(time.time())
        id_claims = {"iss": config.issuer, "aud": config.client_id, "tid": config.tenant_id, "iat": now,
                     "exp": now + 3600, "nonce": self.nonce, "name": self.name, "roles": self.roles}
        id_claims.update(self.id_override)
        key = id_claims.pop("_key", KEY)
        access = token({"iss": entra_issuer(TENANT), "aud": API_AUDIENCE, "tid": TENANT, "iat": now,
                        "exp": now + 3600, "name": self.name, "roles": self.roles})
        return {"id_token": token(id_claims, key), "access_token": access, "token_type": "Bearer"}

    def key_for(self, config: OidcConfig, tok: str) -> object:
        return KEY.public_key()


def ui_auth(provider: FakeEntra | None = None, local: bool = False, role: str = "Reader") -> UiAuth:
    return UiAuth(OIDC, LocalConfig("local-admin", LOCAL_HASH, role, LOCAL_SECRET) if local else None,
                  provider or FakeEntra())


def api_auth() -> AuthConfig:
    class Keys:
        def key_for(self, tok: str) -> object:
            return KEY.public_key()

    return AuthConfig(TENANT, (API_AUDIENCE,), Keys(), LOCAL_SECRET)


def sign_in(web, auth: UiAuth):
    """Runs the code flow against the fake Entra ID; returns the callback response."""
    start = web.get("/auth/start", follow_redirects=False)
    assert start.status_code == 303
    query = parse_qs(urlparse(start.headers["location"]).query)
    provider = auth.provider
    provider.nonce = query["nonce"][0]
    return web.get("/auth/callback", params={"code": "test-code", "state": query["state"][0]}, follow_redirects=False)
