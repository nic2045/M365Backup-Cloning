"""Sign-in of the web interface (issue #60, ADR 0010).

* Entra ID: OpenID Connect, authorization code flow with PKCE (S256), state and nonce. The ID token is
  checked (signature with the tenant's keys, audience, issuer, tenant, expiry, nonce). The access token
  for the API stays on the server, in the session; it is never written into a page or a script.
* Local account: fallback on the same machine. Off unless configured, offered and accepted only from the
  loopback address without proxy headers. Password hash (scrypt, passwords.py) from the environment or a
  secret store. The interface then sends the API a short-lived token signed with a secret both share.

Sessions live in the memory of the process (a restart signs everyone out). The browser only holds a
random session id in an HttpOnly cookie (SameSite=Lax, Secure on https). Every session has a CSRF token
for forms that change something (logout now, the write actions of issue #14 later).
The OIDC provider is injectable, so tests use their own keys and never call Entra ID.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import logging
import os
import secrets
import threading
import time
from dataclasses import dataclass, field
from typing import Any, Mapping, Protocol
from urllib.parse import urlencode

import httpx
import jwt

from .passwords import is_valid_hash, verify_password

log = logging.getLogger("m365ui.auth")

ROLES = ("Reader", "Applier", "Resetter")
# The local account is a break-glass account: management only (issue #79, ADR 0016). It reads and may run
# the setup check of the configuration (role Reader); reports, apply and reset need an Entra ID sign-in.
LOCAL_ROLES = ("Reader",)
IMPLIED = {"Reader": {"Reader"}, "Applier": {"Applier", "Reader"}, "Resetter": {"Resetter", "Reader"}}
LOOPBACK = frozenset({"127.0.0.1", "::1"})
PROXY_HEADERS = ("forwarded", "x-forwarded-for", "x-real-ip", "x-forwarded-host")

SESSION_COOKIE = "m365ui_session"
STATE_COOKIE = "m365ui_oidc_state"
LOGIN_CSRF_COOKIE = "m365ui_login_csrf"
SESSION_MAX_AGE = 8 * 3600
PENDING_MAX_AGE = 10 * 60
LOCAL_API_TOKEN_LIFETIME = 60
LOCAL_ISSUER = "m365cloning-local"
LOCAL_AUDIENCE = "m365cloning-api"
MIN_SECRET_BYTES = 32
LOCKOUT_FAILURES = 5
LOCKOUT_SECONDS = 300


def effective_roles(claimed: Any) -> frozenset[str]:
    out: set[str] = set()
    for r in claimed if isinstance(claimed, (list, tuple, set, frozenset)) else ():
        out |= IMPLIED.get(str(r), set())
    return frozenset(out)


def is_local_request(client_host: str | None, headers: Mapping[str, str]) -> bool:
    lower = {k.lower() for k in headers}
    return client_host in LOOPBACK and not any(h in lower for h in PROXY_HEADERS)


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def pkce_pair() -> tuple[str, str]:
    verifier = secrets.token_urlsafe(64)
    return verifier, _b64url(hashlib.sha256(verifier.encode("ascii")).digest())


# Configuration -------------------------------------------------------------------------------------------

@dataclass(frozen=True)
class OidcConfig:
    tenant_id: str
    client_id: str
    api_scope: str
    redirect_uri: str
    client_secret: str = field(default="", repr=False)  # only for a "Web" platform registration

    @property
    def issuer(self) -> str:
        return f"https://login.microsoftonline.com/{self.tenant_id}/v2.0"

    @property
    def authorize_endpoint(self) -> str:
        return f"https://login.microsoftonline.com/{self.tenant_id}/oauth2/v2.0/authorize"

    @property
    def token_endpoint(self) -> str:
        return f"https://login.microsoftonline.com/{self.tenant_id}/oauth2/v2.0/token"

    @property
    def jwks_uri(self) -> str:
        return f"https://login.microsoftonline.com/{self.tenant_id}/discovery/v2.0/keys"


@dataclass(frozen=True)
class LocalConfig:
    user: str
    password_hash: str = field(repr=False)
    role: str = "Reader"
    token_secret: bytes = field(default=b"", repr=False)

    @property
    def usable(self) -> bool:
        return bool(self.user) and is_valid_hash(self.password_hash) and self.role in LOCAL_ROLES \
            and len(self.token_secret) >= MIN_SECRET_BYTES


class OidcProvider(Protocol):
    def redeem(self, config: OidcConfig, code: str, verifier: str) -> dict[str, Any]: ...
    def key_for(self, config: OidcConfig, token: str) -> object: ...


class EntraProvider:
    """Talks to Entra ID: token endpoint and the tenant's signing keys."""

    def __init__(self, timeout: float = 10.0):
        self._timeout = timeout
        self._jwks: dict[str, jwt.PyJWKClient] = {}

    def redeem(self, config: OidcConfig, code: str, verifier: str) -> dict[str, Any]:
        data = {
            "client_id": config.client_id, "grant_type": "authorization_code", "code": code,
            "redirect_uri": config.redirect_uri, "code_verifier": verifier,
            "scope": f"openid profile {config.api_scope}",
        }
        if config.client_secret:
            data["client_secret"] = config.client_secret
        r = httpx.post(config.token_endpoint, data=data, timeout=self._timeout)
        body = r.json() if r.headers.get("content-type", "").startswith("application/json") else {}
        if r.status_code != 200:
            # Only the error code goes to the log, never the answer (it may echo the code).
            log.warning("token endpoint refused the code: %s", body.get("error", r.status_code))
            raise SignInError("The sign-in with Microsoft did not succeed.")
        return body

    def key_for(self, config: OidcConfig, token: str) -> object:
        client = self._jwks.setdefault(config.jwks_uri, jwt.PyJWKClient(config.jwks_uri, lifespan=3600, timeout=10))
        return client.get_signing_key_from_jwt(token).key


class SignInError(Exception):
    pass


def _env_flag(value: str | None) -> bool:
    return (value or "").strip().lower() in ("1", "true", "yes", "on")


def oidc_from_env(env: Mapping[str, str]) -> OidcConfig | None:
    values = [env.get(k, "").strip() for k in
              ("M365_UI_OIDC_TENANT_ID", "M365_UI_OIDC_CLIENT_ID", "M365_UI_OIDC_API_SCOPE", "M365_UI_OIDC_REDIRECT_URI")]
    if not all(values):
        return None
    return OidcConfig(*values, client_secret=env.get("M365_UI_OIDC_CLIENT_SECRET", ""))


def local_from_env(env: Mapping[str, str]) -> LocalConfig | None:
    if not _env_flag(env.get("M365_UI_LOCAL_LOGIN")):
        return None
    cfg = LocalConfig(
        env.get("M365_UI_LOCAL_USER", "").strip(),
        env.get("M365_UI_LOCAL_PASSWORD_HASH", "").strip(),
        env.get("M365_UI_LOCAL_ROLE", "Reader").strip() or "Reader",
        env.get("M365CLONING_LOCAL_TOKEN_SECRET", "").encode("utf-8"),
    )
    if cfg.role in ROLES and cfg.role not in LOCAL_ROLES:
        log.error("M365_UI_LOCAL_ROLE=%s is refused: the local account is a break-glass account for management only "
                  "and gets at most the role Reader (ADR 0016); sign in with Entra ID for reports, apply and reset. "
                  "Local sign-in stays off", cfg.role)
        return None
    if not cfg.usable:
        log.warning("local sign-in is switched on but not complete (user, hash, role, token secret); it stays off")
        return None
    return cfg


# Sessions --------------------------------------------------------------------------------------------

@dataclass
class Session:
    sid: str
    name: str
    roles: frozenset[str]
    source: str  # "entra", "local" or "example"
    csrf: str
    expires: float
    access_token: str = field(default="", repr=False)

    def has(self, role: str) -> bool:
        return role in self.roles


@dataclass
class _Pending:
    nonce: str
    verifier: str
    expires: float


class UiAuth:
    def __init__(self, oidc: OidcConfig | None = None, local: LocalConfig | None = None,
                 provider: OidcProvider | None = None, secure_cookies: bool | None = None,
                 clock: Any = time.time):
        self.oidc = oidc
        self.local = local if local and local.usable else None
        self.provider = provider or EntraProvider()
        self.secure_cookies = secure_cookies
        self.clock = clock
        self._sessions: dict[str, Session] = {}
        self._example: Session | None = None
        self._pending: dict[str, _Pending] = {}
        self._failures: list[float] = []
        self._lock = threading.Lock()

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "UiAuth":
        env = os.environ if env is None else env
        secure = env.get("M365_UI_COOKIE_SECURE")
        return cls(oidc_from_env(env), local_from_env(env), secure_cookies=_env_flag(secure) if secure else None)

    @property
    def configured(self) -> bool:
        return bool(self.oidc or self.local)

    # sessions

    def _new_session(self, name: str, roles: frozenset[str], source: str, expires: float, access_token: str = "") -> Session:
        s = Session(secrets.token_urlsafe(32), name, roles, source, secrets.token_urlsafe(32),
                    min(expires, self.clock() + SESSION_MAX_AGE), access_token)
        with self._lock:
            now = self.clock()
            for sid in [k for k, v in self._sessions.items() if v.expires <= now]:
                del self._sessions[sid]
            self._sessions[s.sid] = s
        return s

    def session(self, sid: str | None) -> Session | None:
        if not sid:
            return None
        with self._lock:
            s = self._sessions.get(sid)
            if s and s.expires <= self.clock():
                del self._sessions[sid]
                return None
            return s

    def end(self, sid: str | None) -> None:
        with self._lock:
            self._sessions.pop(sid or "", None)

    def check_csrf(self, session: Session | None, value: str | None) -> bool:
        return bool(session and value) and hmac.compare_digest(session.csrf.encode(), str(value).encode())

    def api_token(self, session: Session | None) -> str | None:
        """The bearer token for the API: the Entra access token, or a fresh short local token."""
        if session is None:
            return None
        if session.source == "entra":
            return session.access_token
        if session.source == "local" and self.local:
            now = int(self.clock())
            claims = {"iss": LOCAL_ISSUER, "aud": LOCAL_AUDIENCE, "sub": session.name, "iat": now,
                      "exp": now + LOCAL_API_TOKEN_LIFETIME, "roles": sorted(session.roles)}
            return jwt.encode(claims, self.local.token_secret, algorithm="HS256")
        return None

    # Entra ID

    def start(self) -> tuple[str, str]:
        """URL to send the browser to, and the state value for the state cookie."""
        assert self.oidc is not None
        state, nonce = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        verifier, challenge = pkce_pair()
        with self._lock:
            now = self.clock()
            for k in [k for k, v in self._pending.items() if v.expires <= now]:
                del self._pending[k]
            self._pending[state] = _Pending(nonce, verifier, now + PENDING_MAX_AGE)
        query = {
            "client_id": self.oidc.client_id, "response_type": "code", "redirect_uri": self.oidc.redirect_uri,
            "response_mode": "query", "scope": f"openid profile {self.oidc.api_scope}", "state": state,
            "nonce": nonce, "code_challenge": challenge, "code_challenge_method": "S256",
        }
        return f"{self.oidc.authorize_endpoint}?{urlencode(query)}", state

    def finish(self, code: str | None, state: str | None, state_cookie: str | None) -> Session:
        if self.oidc is None:
            raise SignInError("Sign-in with Microsoft is not configured.")
        if not code or not state or not state_cookie or not hmac.compare_digest(state.encode(), state_cookie.encode()):
            raise SignInError("The sign-in could not be matched to this browser. Start again.")
        with self._lock:
            pending = self._pending.pop(state, None)
        if pending is None or pending.expires <= self.clock():
            raise SignInError("The sign-in took too long or was already used. Start again.")
        tokens = self.provider.redeem(self.oidc, code, pending.verifier)
        id_token, access_token = tokens.get("id_token"), tokens.get("access_token")
        if not id_token or not access_token:
            raise SignInError("The sign-in with Microsoft did not succeed.")
        try:
            claims = jwt.decode(
                id_token, key=self.provider.key_for(self.oidc, id_token), algorithms=["RS256"],
                audience=self.oidc.client_id, issuer=self.oidc.issuer, leeway=60,
                options={"require": ["exp", "iat", "iss", "aud", "nonce"]},
            )
        except (jwt.PyJWTError, ValueError, KeyError) as exc:
            log.warning("ID token refused: %s", type(exc).__name__)
            raise SignInError("The sign-in with Microsoft did not succeed.") from None
        if claims.get("tid") != self.oidc.tenant_id or not hmac.compare_digest(str(claims["nonce"]).encode(), pending.nonce.encode()):
            log.warning("ID token refused: tenant or nonce does not match")
            raise SignInError("The sign-in with Microsoft did not succeed.")
        try:
            expires = float(jwt.decode(access_token, options={"verify_signature": False}).get("exp", 0)) or self.clock() + 3600
        except jwt.PyJWTError:
            expires = self.clock() + 3600  # opaque to us; the API decides
        name = str(claims.get("name") or claims.get("preferred_username") or "")
        return self._new_session(name, effective_roles(claims.get("roles")), "entra", expires, access_token)

    # Local account

    def local_allowed(self, client_host: str | None, headers: Mapping[str, str]) -> bool:
        return self.local is not None and is_local_request(client_host, headers)

    def local_login(self, user: str, password: str, client_host: str | None, headers: Mapping[str, str]) -> Session:
        if not self.local_allowed(client_host, headers):
            raise SignInError("The local account works only on this machine.")
        assert self.local is not None
        with self._lock:
            now = self.clock()
            self._failures = [t for t in self._failures if t > now - LOCKOUT_SECONDS]
            if len(self._failures) >= LOCKOUT_FAILURES:
                raise SignInError("Too many failed attempts. Wait a few minutes.")
        name_ok = hmac.compare_digest(user.encode("utf-8"), self.local.user.encode("utf-8"))
        # Always run the hash, also for a wrong name, so both cost the same time.
        password_ok = verify_password(password, self.local.password_hash if name_ok else None)
        if not (name_ok and password_ok):
            with self._lock:
                self._failures.append(self.clock())
            log.info("local sign-in refused")
            raise SignInError("User name or password is wrong.")
        roles = effective_roles([self.local.role]) & frozenset(LOCAL_ROLES)
        return self._new_session(self.local.user, roles, "local", self.clock() + SESSION_MAX_AGE)

    def example_session(self) -> Session:
        """Mock mode without any sign-in configured: an example person, so the pages can be tried. The person has
        every role, so the buttons can be tried too: in mock mode a button only shows the example answer and
        nothing is started (issue #14). The CSRF token is made once per process."""
        if self._example is None:
            self._example = Session("", "Example user", frozenset({"Reader", "Applier", "Resetter"}), "example",
                                    secrets.token_urlsafe(32), float("inf"))
        return self._example

    def new_login_csrf(self) -> str:
        return secrets.token_urlsafe(32)
