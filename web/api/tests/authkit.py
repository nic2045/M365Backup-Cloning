"""Test keys and tokens for the sign-in (issue #60). Keys are made per test run; nothing calls Entra ID."""

from __future__ import annotations

import secrets
import time
from typing import Any

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa

from m365api.auth import LOCAL_AUDIENCE, LOCAL_ISSUER, AuthConfig, entra_issuer

TENANT = "00000000-0000-4000-8000-000000000001"  # made up for tests
AUDIENCE = "api://m365cloning-test"
LOCAL_SECRET = secrets.token_hex(32).encode("ascii")  # made per run, never a fixed value

KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
OTHER_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


class StaticKeys:
    """Key provider with the public test key (stands in for the JWKS of the tenant)."""

    def __init__(self, key=KEY):
        self.public = key.public_key()

    def key_for(self, token: str) -> object:
        return self.public


def config(local: bool = True) -> AuthConfig:
    return AuthConfig(TENANT, (AUDIENCE,), StaticKeys(), LOCAL_SECRET if local else b"")


def entra_token(roles: list[str] | None = None, key=KEY, **override: Any) -> str:
    now = int(time.time())
    claims: dict[str, Any] = {
        "iss": entra_issuer(TENANT), "aud": AUDIENCE, "tid": TENANT, "iat": now, "nbf": now, "exp": now + 3600,
        "name": "Test Reader", "roles": ["Reader"] if roles is None else roles,
    }
    claims.update(override)
    claims = {k: v for k, v in claims.items() if v is not None}
    return jwt.encode(claims, key, algorithm="RS256", headers={"kid": "test"})


def local_token(roles: list[str] | None = None, secret: bytes = LOCAL_SECRET, lifetime: int = 60, **override: Any) -> str:
    now = int(time.time())
    claims: dict[str, Any] = {"iss": LOCAL_ISSUER, "aud": LOCAL_AUDIENCE, "sub": "local-admin", "iat": now,
                              "exp": now + lifetime, "roles": ["Reader"] if roles is None else roles}
    claims.update(override)
    return jwt.encode(claims, secret, algorithm="HS256")


def bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}
