"""Sign-in of the interface (issue #60, ADR 0010). Fake Entra ID and own keys; nothing leaves the process."""

from __future__ import annotations

import logging
import re
from urllib.parse import parse_qs, urlparse

import pytest
from fastapi.testclient import TestClient

import uikit
from m365api import create_app as create_api
from m365ui import auth as authmod
from m365ui.api_client import ApiResponse, BaseClient, HttpClient, MockClient
from m365ui.auth import LocalConfig, UiAuth
from m365ui.main import create_app
from m365ui.passwords import hash_password, is_valid_hash, verify_password

PAGES = ["/", "/reports", "/plans", "/audit", "/plans/apply-plan-20261107-120000"]


class TokenClient(BaseClient):
    """Remembers the token of each call and answers like a small API."""

    mock = False

    def __init__(self, status: int = 200):
        self.tokens: list[str | None] = []
        self.status = status

    def _get(self, path, params, token=None):
        self.tokens.append(token)
        if self.status != 200:
            return ApiResponse(self.status, {"code": "unauthorized", "message": "Sign in first."})
        if path == "/api/status":
            return ApiResponse(200, {"schemaVersion": "2", "lastComparisonUtc": None, "differences": 0,
                                     "fitStatus": "green", "reportId": None})
        return ApiResponse(404, {"code": "not-found", "message": "none"})


def make(client=None, auth=None, host="testclient", base_url="http://testserver"):
    auth = auth or uikit.ui_auth()
    return TestClient(create_app(client or TokenClient(), auth), client=(host, 50000), base_url=base_url), auth


# Without a session ---------------------------------------------------------------------------------------

@pytest.mark.parametrize("page", PAGES)
def test_pages_send_the_anonymous_browser_to_login(page):
    web, _ = make()
    r = web.get(page, follow_redirects=False)
    assert r.status_code == 303 and r.headers["location"] == "/login"


def test_mock_with_sign_in_configured_also_needs_login():
    web, _ = make(MockClient())
    assert web.get("/", follow_redirects=False).headers["location"] == "/login"


def test_mock_without_sign_in_shows_the_example_person():
    web = TestClient(create_app(MockClient(), UiAuth()))
    r = web.get("/")
    assert r.status_code == 200 and "Example user" in r.text and "Example data" in r.text
    assert 'action="/logout"' not in r.text


def test_real_api_without_sign_in_configured_is_closed():
    web = TestClient(create_app(TokenClient(), UiAuth()))
    r = web.get("/")
    assert r.status_code == 200 and "Sign-in is not configured" in r.text
    assert "Sign in with Microsoft" not in r.text


def test_static_files_need_no_session():
    web, _ = make()
    assert web.get("/static/app.css").status_code == 200


# Entra ID ------------------------------------------------------------------------------------------------

def test_start_uses_code_flow_with_pkce_state_and_nonce():
    web, auth = make()
    r = web.get("/auth/start", follow_redirects=False)
    url = urlparse(r.headers["location"])
    q = {k: v[0] for k, v in parse_qs(url.query).items()}
    assert url.netloc == "login.microsoftonline.com" and url.path.endswith("/oauth2/v2.0/authorize")
    assert q["response_type"] == "code" and q["code_challenge_method"] == "S256"
    assert len(q["code_challenge"]) == 43 and q["state"] and q["nonce"]
    assert q["client_id"] == uikit.CLIENT and "openid" in q["scope"].split()
    cookie = r.headers["set-cookie"].lower()
    assert authmod.STATE_COOKIE in cookie and "httponly" in cookie and "samesite=lax" in cookie


def test_sign_in_shows_name_and_roles_and_never_the_token():
    client = TokenClient()
    web, auth = make(client, uikit.ui_auth(uikit.FakeEntra(roles=["Applier"], name="Alex Example")))
    r = uikit.sign_in(web, auth)
    assert r.status_code == 303 and r.headers["location"] == "/"
    cookie = r.headers["set-cookie"].lower()
    assert "httponly" in cookie and "samesite=lax" in cookie and "secure" not in cookie
    page = web.get("/")
    assert "Alex Example" in page.text and "Applier, Reader" in page.text
    token = client.tokens[-1]
    assert token and token.count(".") == 2
    assert token not in page.text and token.split(".")[2] not in page.text
    assert page.headers["cache-control"] == "no-store"
    # The verifier went to the token endpoint, not into the page.
    assert auth.provider.redeemed[0]["verifier"] not in page.text


def test_cookies_are_secure_on_https():
    web, auth = make(base_url="https://testserver")
    r = uikit.sign_in(web, auth)
    assert "secure" in r.headers["set-cookie"].lower()


@pytest.mark.parametrize(
    "provider",
    [
        uikit.FakeEntra(_key=uikit.OTHER_KEY),
        uikit.FakeEntra(aud="someone-else"),
        uikit.FakeEntra(iss="https://login.microsoftonline.com/other/v2.0"),
        uikit.FakeEntra(tid="00000000-0000-4000-8000-000000000099"),
        uikit.FakeEntra(exp=1, iat=0),
        uikit.FakeEntra(nonce="replayed"),
    ],
    ids=["wrong-signature", "wrong-audience", "wrong-issuer", "wrong-tenant", "expired", "wrong-nonce"],
)
def test_bad_id_tokens_give_no_session(provider):
    web, auth = make(auth=uikit.ui_auth(provider))
    r = uikit.sign_in(web, auth)
    assert r.status_code == 401 and "did not succeed" in r.text
    assert web.get("/", follow_redirects=False).headers["location"] == "/login"


def test_callback_without_matching_state_cookie_is_refused():
    web, auth = make()
    start = web.get("/auth/start", follow_redirects=False)
    state = parse_qs(urlparse(start.headers["location"]).query)["state"][0]
    other, _ = make(auth=auth)  # another browser: no state cookie
    assert other.get("/auth/callback", params={"code": "c", "state": state}).status_code == 401


def test_state_is_used_once():
    web, auth = make()
    start = web.get("/auth/start", follow_redirects=False)
    state = parse_qs(urlparse(start.headers["location"]).query)["state"][0]
    auth.provider.nonce = parse_qs(urlparse(start.headers["location"]).query)["nonce"][0]
    assert web.get("/auth/callback", params={"code": "c", "state": state}, follow_redirects=False).status_code == 303
    web.cookies.set(authmod.STATE_COOKIE, state)
    assert web.get("/auth/callback", params={"code": "c", "state": state}, follow_redirects=False).status_code == 401


def test_refused_sign_in_at_microsoft():
    web, _ = make()
    r = web.get("/auth/callback", params={"error": "access_denied", "error_description": "<script>x</script>"})
    assert r.status_code == 401 and "<script>x</script>" not in r.text


def test_api_answering_401_ends_the_session():
    web, auth = make(TokenClient(status=401))
    uikit.sign_in(web, auth)
    r = web.get("/", follow_redirects=False)
    assert r.status_code == 303 and r.headers["location"] == "/login?expired=1"
    assert auth._sessions == {}


def test_api_answering_403_shows_an_error_page():
    web, auth = make(TokenClient(status=403))
    uikit.sign_in(web, auth)
    assert web.get("/").status_code == 403


# Logout and CSRF -----------------------------------------------------------------------------------------

def csrf_of(html: str) -> str:
    return re.search(r'name="csrf" value="([^"]+)"', html).group(1)


def test_logout_needs_the_csrf_token():
    web, auth = make()
    uikit.sign_in(web, auth)
    assert web.post("/logout", data={"csrf": "wrong"}).status_code == 403
    assert web.get("/").status_code == 200


def test_logout_clears_the_session():
    web, auth = make()
    uikit.sign_in(web, auth)
    page = web.get("/")
    assert 'X-CSRF-Token' in page.text  # prepared for HTMX writes (issue #14)
    r = web.post("/logout", data={"csrf": csrf_of(page.text)}, follow_redirects=False)
    assert r.status_code == 303 and r.headers["location"] == "/login"
    assert authmod.SESSION_COOKIE in r.headers["set-cookie"] and "Max-Age=0" in r.headers["set-cookie"]
    assert auth._sessions == {}
    assert web.get("/", follow_redirects=False).headers["location"] == "/login"


def test_old_session_cookie_does_not_work_after_logout():
    web, auth = make()
    uikit.sign_in(web, auth)
    sid = web.cookies.get(authmod.SESSION_COOKIE)
    web.post("/logout", data={"csrf": csrf_of(web.get("/").text)})
    other, _ = make(auth=auth)
    other.cookies.set(authmod.SESSION_COOKIE, sid)
    assert other.get("/", follow_redirects=False).status_code == 303


def test_expired_session_is_gone():
    now = [1_000_000.0]
    auth = uikit.ui_auth()
    auth.clock = lambda: now[0]
    web, _ = make(auth=auth)
    uikit.sign_in(web, auth)
    now[0] += authmod.SESSION_MAX_AGE + 1
    assert web.get("/", follow_redirects=False).status_code == 303


# Local account -------------------------------------------------------------------------------------------

def local_web(host="127.0.0.1", role="Reader", client=None):
    return make(client or TokenClient(), uikit.ui_auth(local=True, role=role), host=host)


def local_login(web, password=uikit.LOCAL_PASSWORD, user="local-admin", headers=None):
    page = web.get("/login", headers=headers or {})
    return web.post("/login/local", data={"username": user, "password": password, "csrf": csrf_of(page.text)},
                    headers=headers or {}, follow_redirects=False)


@pytest.mark.parametrize("host", ["127.0.0.1", "::1"])
def test_local_account_on_this_machine(host):
    client = TokenClient()
    web, _ = local_web(host, client=client)
    assert "Local account" in web.get("/login").text
    r = local_login(web)
    assert r.status_code == 303
    page = web.get("/")
    assert "local-admin" in page.text and "Reader" in page.text
    assert client.tokens[-1] and client.tokens[-1] not in page.text


@pytest.mark.parametrize("host", ["10.0.0.5", "testclient"])
def test_local_account_is_not_offered_from_elsewhere(host):
    web, _ = local_web(host)
    page = web.get("/login")
    assert "Local account" not in page.text and 'name="password"' not in page.text
    web.cookies.set(authmod.LOGIN_CSRF_COOKIE, "x")
    r = web.post("/login/local", data={"username": "local-admin", "password": uikit.LOCAL_PASSWORD, "csrf": "x"})
    assert r.status_code == 401 and authmod.SESSION_COOKIE not in web.cookies


def test_local_account_through_a_proxy_is_refused():
    web, _ = local_web()
    page = web.get("/login", headers={"X-Forwarded-For": "203.0.113.7"})
    assert "Local account" not in page.text
    web.cookies.set(authmod.LOGIN_CSRF_COOKIE, "x")
    r = web.post("/login/local", data={"username": "local-admin", "password": uikit.LOCAL_PASSWORD, "csrf": "x"},
                 headers={"X-Forwarded-For": "203.0.113.7"})
    assert r.status_code == 401


def test_local_account_is_off_unless_configured():
    web, _ = make(host="127.0.0.1")
    assert "Local account" not in web.get("/login").text
    assert authmod.local_from_env({}) is None
    assert authmod.local_from_env({"M365_UI_LOCAL_LOGIN": "1", "M365_UI_LOCAL_USER": "a"}) is None


def test_local_from_env_complete():
    cfg = authmod.local_from_env({
        "M365_UI_LOCAL_LOGIN": "1", "M365_UI_LOCAL_USER": "a", "M365_UI_LOCAL_PASSWORD_HASH": uikit.LOCAL_HASH,
        "M365CLONING_LOCAL_TOKEN_SECRET": uikit.LOCAL_SECRET.decode(),
    })
    assert cfg is not None and cfg.role == "Reader"
    assert "password_hash" not in repr(cfg) and uikit.LOCAL_HASH not in repr(cfg)


@pytest.mark.parametrize(("user", "password"), [("local-admin", "wrong password!"), ("someone", uikit.LOCAL_PASSWORD), ("", "")])
def test_wrong_local_credentials_are_refused(user, password):
    web, _ = local_web()
    r = local_login(web, password=password, user=user)
    assert r.status_code == 401 and "User name or password is wrong" in r.text
    assert authmod.SESSION_COOKIE not in web.cookies


def test_local_login_needs_the_form_token():
    web, _ = local_web()
    web.get("/login")
    r = web.post("/login/local", data={"username": "local-admin", "password": uikit.LOCAL_PASSWORD, "csrf": "forged"})
    assert r.status_code == 400 and authmod.SESSION_COOKIE not in web.cookies


def test_local_login_locks_after_repeated_failures():
    web, _ = local_web()
    for _ in range(authmod.LOCKOUT_FAILURES):
        local_login(web, password="wrong password!")
    r = local_login(web)
    assert r.status_code == 401 and "Too many failed attempts" in r.text


def test_local_session_works_with_the_real_api(tmp_path):
    from test_with_backend import write_history

    api = TestClient(create_api(write_history(tmp_path / "History"), uikit.api_auth()), client=("127.0.0.1", 50000))
    web, _ = local_web(client=HttpClient(http=api))
    local_login(web)
    r = web.get("/")
    assert r.status_code == 200 and "Prod and Dev" in r.text


def test_no_secret_or_token_in_the_log(caplog):
    caplog.set_level(logging.DEBUG)
    client = TokenClient()
    web, auth = make(client)
    uikit.sign_in(web, auth)
    web.get("/")
    lweb, _ = local_web()
    local_login(lweb, password="wrong password!")
    local_login(lweb)
    for secret in [t for t in client.tokens if t] + [uikit.LOCAL_PASSWORD, uikit.LOCAL_HASH, uikit.LOCAL_SECRET.decode()]:
        assert secret not in caplog.text


# Password hash -------------------------------------------------------------------------------------------

def test_password_hash_round_trip():
    stored = hash_password("a long enough password")
    assert stored.startswith("scrypt$") and is_valid_hash(stored)
    assert verify_password("a long enough password", stored)
    assert not verify_password("a long enough passworD", stored)
    assert hash_password("a long enough password") != stored  # salted


@pytest.mark.parametrize("stored", ["", "plain", "scrypt$1$8$1$AA==$AA==", "md5$x", None])
def test_invalid_hashes_never_match(stored):
    assert not verify_password("anything at all", stored)


def test_short_passwords_are_refused():
    with pytest.raises(ValueError):
        hash_password("short")


def test_unusable_local_config_is_dropped():
    assert UiAuth(local=LocalConfig("a", "not-a-hash", "Reader", uikit.LOCAL_SECRET)).local is None
    assert UiAuth(local=LocalConfig("a", uikit.LOCAL_HASH, "Admin", uikit.LOCAL_SECRET)).local is None
    assert UiAuth(local=LocalConfig("a", uikit.LOCAL_HASH, "Reader", b"short")).local is None
