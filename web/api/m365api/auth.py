"""Sign-in for the API (issue #60, ADR 0010).

Every route needs a bearer token. Two kinds are accepted, each with exactly one algorithm (no algorithm
confusion):

* Entra ID access tokens (RS256). The signature is checked with the keys of the tenant's OIDC metadata
  (JWKS), plus audience, issuer, tenant and expiry. Roles come from the ``roles`` claim (app roles).
* Tokens of the local account (HS256, issuer ``m365cloning-local``), minted by the web interface with a
  secret both sides share. Accepted only when the secret is configured and the request comes from the
  loopback address without proxy headers: the local account is a fallback on the same machine.

Nothing is configured: every request gets 401 (fail closed). Tokens are never logged.
The key provider is injectable, so tests use their own keys and never call Entra ID.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field
from typing import Iterable, Protocol

import jwt

log = logging.getLogger("m365api.auth")

ROLES = ("Reader", "Applier", "Resetter")
# Applier and Resetter include Reader (ADR 0010). Resetter does not include Applier.
IMPLIED = {"Reader": {"Reader"}, "Applier": {"Applier", "Reader"}, "Resetter": {"Resetter", "Reader"}}

LOCAL_ISSUER = "m365cloning-local"
LOCAL_AUDIENCE = "m365cloning-api"
LOCAL_MAX_LIFETIME = 15 * 60
MIN_SECRET_BYTES = 32
LOOPBACK = frozenset({"127.0.0.1", "::1"})
PROXY_HEADERS = ("forwarded", "x-forwarded-for", "x-real-ip", "x-forwarded-host")

TENANT_ENV = "M365CLONING_AUTH_TENANT_ID"
AUDIENCE_ENV = "M365CLONING_AUTH_AUDIENCE"
LOCAL_SECRET_ENV = "M365CLONING_LOCAL_TOKEN_SECRET"
LEEWAY = 60


class AuthError(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


@dataclass(frozen=True)
class Principal:
    name: str
    roles: frozenset[str]
    source: str  # "entra" or "local"

    def has(self, role: str) -> bool:
        return role in self.roles


def effective_roles(claimed: Iterable[str]) -> frozenset[str]:
    """The known roles of a token plus the roles they include; unknown names are ignored."""
    out: set[str] = set()
    for r in claimed or ():
        out |= IMPLIED.get(str(r), set())
    return frozenset(out)


class KeyProvider(Protocol):
    def key_for(self, token: str) -> object: ...


class JwksKeyProvider:
    """The signing keys of the tenant's OIDC metadata (cached by PyJWKClient)."""

    def __init__(self, jwks_uri: str):
        self._client = jwt.PyJWKClient(jwks_uri, cache_keys=True, lifespan=3600, timeout=10)

    def key_for(self, token: str) -> object:
        return self._client.get_signing_key_from_jwt(token).key


def entra_issuer(tenant_id: str) -> str:
    return f"https://login.microsoftonline.com/{tenant_id}/v2.0"


def entra_jwks_uri(tenant_id: str) -> str:
    return f"https://login.microsoftonline.com/{tenant_id}/discovery/v2.0/keys"


@dataclass
class AuthConfig:
    tenant_id: str = ""
    audiences: tuple[str, ...] = ()
    keys: KeyProvider | None = None
    local_secret: bytes = field(default=b"", repr=False)

    @property
    def entra(self) -> bool:
        return bool(self.tenant_id and self.audiences and self.keys)

    @property
    def local(self) -> bool:
        return len(self.local_secret) >= MIN_SECRET_BYTES

    @property
    def issuer(self) -> str:
        return entra_issuer(self.tenant_id)

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> "AuthConfig":
        env = dict(os.environ if env is None else env)
        tenant = env.get(TENANT_ENV, "").strip()
        audiences = tuple(a.strip() for a in env.get(AUDIENCE_ENV, "").split(",") if a.strip())
        secret = env.get(LOCAL_SECRET_ENV, "").encode("utf-8")
        if secret and len(secret) < MIN_SECRET_BYTES:
            log.warning("%s is shorter than %d bytes; local sign-in stays off", LOCAL_SECRET_ENV, MIN_SECRET_BYTES)
        return cls(tenant, audiences, JwksKeyProvider(entra_jwks_uri(tenant)) if tenant and audiences else None, secret)


def _bearer(header: str | None) -> str:
    if not header:
        raise AuthError(401, "unauthorized", "Sign in first.")
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise AuthError(401, "unauthorized", "Sign in first.")
    return token.strip()


def is_local_request(client_host: str | None, headers: dict[str, str]) -> bool:
    return client_host in LOOPBACK and not any(h in headers for h in PROXY_HEADERS)


class Verifier:
    def __init__(self, config: AuthConfig):
        self.config = config

    def principal(self, authorization: str | None, client_host: str | None, headers: dict[str, str]) -> Principal:
        cfg = self.config
        if not (cfg.entra or cfg.local):
            raise AuthError(401, "sign-in-not-configured", "Sign-in is not configured on this server.")
        token = _bearer(authorization)
        try:
            issuer = jwt.decode(token, options={"verify_signature": False}).get("iss")
        except jwt.PyJWTError:
            raise AuthError(401, "invalid-token", "The sign-in is not valid. Sign in again.") from None
        if issuer == LOCAL_ISSUER:
            return self._local(token, client_host, headers)
        return self._entra(token)

    def _entra(self, token: str) -> Principal:
        cfg = self.config
        if not cfg.entra:
            raise AuthError(401, "invalid-token", "The sign-in is not valid. Sign in again.")
        try:
            key = cfg.keys.key_for(token)  # type: ignore[union-attr]
            claims = jwt.decode(
                token, key=key, algorithms=["RS256"], audience=list(cfg.audiences), issuer=cfg.issuer,
                leeway=LEEWAY, options={"require": ["exp", "iat", "iss", "aud"]},
            )
        except jwt.ExpiredSignatureError:
            raise AuthError(401, "token-expired", "The sign-in has expired. Sign in again.") from None
        except (jwt.PyJWTError, ValueError, KeyError) as exc:
            log.info("entra token refused: %s", type(exc).__name__)
            raise AuthError(401, "invalid-token", "The sign-in is not valid. Sign in again.") from None
        if claims.get("tid") != cfg.tenant_id:
            raise AuthError(401, "invalid-token", "The sign-in is not valid. Sign in again.")
        name = str(claims.get("name") or claims.get("preferred_username") or claims.get("oid") or "")
        return Principal(name, effective_roles(claims.get("roles") or []), "entra")

    def _local(self, token: str, client_host: str | None, headers: dict[str, str]) -> Principal:
        cfg = self.config
        if not cfg.local or not is_local_request(client_host, headers):
            raise AuthError(401, "invalid-token", "The local account works only on this machine.")
        try:
            claims = jwt.decode(
                token, key=cfg.local_secret, algorithms=["HS256"], audience=LOCAL_AUDIENCE, issuer=LOCAL_ISSUER,
                leeway=5, options={"require": ["exp", "iat", "iss", "aud", "sub"]},
            )
        except jwt.ExpiredSignatureError:
            raise AuthError(401, "token-expired", "The sign-in has expired. Sign in again.") from None
        except jwt.PyJWTError as exc:
            log.info("local token refused: %s", type(exc).__name__)
            raise AuthError(401, "invalid-token", "The sign-in is not valid. Sign in again.") from None
        if int(claims["exp"]) - int(claims["iat"]) > LOCAL_MAX_LIFETIME:
            raise AuthError(401, "invalid-token", "The sign-in is not valid. Sign in again.")
        return Principal(str(claims["sub"]), effective_roles(claims.get("roles") or []), "local")


def require(verifier: Verifier, role: str, authorization: str | None, client_host: str | None,
            headers: dict[str, str]) -> Principal:
    """The signed-in person, if they hold ``role``; otherwise AuthError 401 or 403."""
    who = verifier.principal(authorization, client_host, headers)
    if not who.has(role):
        raise AuthError(403, "forbidden", f"This needs the role {role}.")
    return who
