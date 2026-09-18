"""providers.py 테스트.

실계정·실엔드포인트 호출은 0회다. 토큰 교환은 로컬 가짜 토큰 서버,
사용량 파싱은 2026-09 실캡처 형태의 픽스처 dict 로 검증한다.
실행: cd ~/cct && uv run --with pytest pytest dashboard/tests -q
"""

from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
PROVIDERS_PY = HERE.parent / "providers.py"

_spec = importlib.util.spec_from_file_location("cct_dash_providers", PROVIDERS_PY)
pv = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(pv)


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def fake_jwt(payload: dict) -> str:
    head = b64url(json.dumps({"alg": "none"}).encode())
    body = b64url(json.dumps(payload).encode())
    return "%s.%s.sig" % (head, body)


# 2026-09 실캡처와 같은 형태(값은 합성)
WHAM_USAGE = {
    "plan_type": "plus",
    "email": "User@Example.com",
    "rate_limit": {
        "allowed": True,
        "primary_window": {"used_percent": 43, "limit_window_seconds": 18000,
                           "reset_after_seconds": 12452, "reset_at": 1789776322},
        "secondary_window": {"used_percent": 24, "limit_window_seconds": 604800,
                             "reset_after_seconds": 44365, "reset_at": 1789808235},
    },
}
XAI_BILLING = {
    "config": {
        "currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY",
                          "start": "2026-09-17T08:15:08.459639+00:00",
                          "end": "2026-09-24T08:15:08.459639+00:00"},
        "creditUsagePercent": 2.0,
        "productUsage": [{"product": "GrokBuild", "usagePercent": 2.0}],
    },
}


# ---------------------------------------------------------------- 단위

def test_pkce_challenge_matches_verifier():
    verifier, challenge = pv.make_pkce()
    assert len(verifier) >= 43
    assert challenge == b64url(hashlib.sha256(verifier.encode()).digest())
    assert pv.make_pkce()[0] != verifier


def test_decode_jwt_payload_roundtrip_and_garbage():
    assert pv.decode_jwt_payload(fake_jwt({"sub": "u1"})) == {"sub": "u1"}
    assert pv.decode_jwt_payload("not-a-jwt") == {}
    assert pv.decode_jwt_payload("a.!!!.c") == {}


def test_extract_account_id_priority():
    chat = fake_jwt({"https://api.openai.com/auth": {"chatgpt_account_id": "acc-1"}})
    assert pv.extract_account_id(chat, None) == "acc-1"
    assert pv.extract_account_id(fake_jwt({"sub": "user-9"}), None) == "user-9"
    assert pv.extract_account_id(None, None) is None


def test_parse_openai_usage_real_shape():
    out = pv.parse_openai_usage(WHAM_USAGE)
    assert out["plan"] == "plus"
    assert out["email"] == "user@example.com"
    assert out["windows"]["5h"] == {"used_pct": 43, "reset_at": 1789776322}
    assert out["windows"]["7d"] == {"used_pct": 24, "reset_at": 1789808235}


def test_parse_openai_usage_rejects_empty():
    with pytest.raises(pv.ProviderError):
        pv.parse_openai_usage({"rate_limit": {}})
    with pytest.raises(pv.ProviderError):
        pv.parse_openai_usage({})


def test_parse_xai_usage_real_shape():
    out = pv.parse_xai_usage(XAI_BILLING)
    weekly = out["windows"]["weekly"]
    assert weekly["used_pct"] == 2.0
    # 2026-09-24T08:15:08+00:00 의 epoch
    assert weekly["reset_at"] == 1790237708
    assert out["products"] == [{"name": "GrokBuild", "used_pct": 2.0}]


def test_parse_xai_usage_percent_defaults_to_zero():
    data = {"config": {"currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY",
                                         "end": "2026-09-24T00:00:00+00:00"}}}
    assert pv.parse_xai_usage(data)["windows"]["weekly"]["used_pct"] == 0.0


def test_store_mode_600_and_roundtrip(tmp_path):
    store = pv.ProviderStore(tmp_path / "prov.json")
    store.update("openai", access="tok", refresh="ref", expires=123)
    assert (tmp_path / "prov.json").stat().st_mode & 0o777 == 0o600
    again = pv.ProviderStore(tmp_path / "prov.json")
    assert again.get("openai")["refresh"] == "ref"
    again.drop("openai")
    assert pv.ProviderStore(tmp_path / "prov.json").get("openai") == {}


def test_creds_from_token_response_validates():
    with pytest.raises(pv.ProviderError):
        pv.creds_from_token_response({"expires_in": 10})
    cred = pv.creds_from_token_response(
        {"access_token": fake_jwt({"sub": "u", "email": "A@B.C"}), "expires_in": 60})
    assert cred["refresh"] == ""
    assert cred["email"] == "a@b.c"
    assert cred["account_id"] == "u"
    # 회전 안 된 refresh 는 fallback 유지
    cred = pv.creds_from_token_response({"access_token": "x.y.z"}, refresh_fallback="keep")
    assert cred["refresh"] == "keep"


# ---------------------------------------------------------------- 가짜 토큰 서버

class FakeTokenServer:
    """authorization_code·refresh_token grant 를 흉내낸다."""

    def __init__(self):
        self.requests: list[dict] = []
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, fmt, *args):
                pass

            def do_POST(self):
                length = int(self.headers.get("Content-Length", 0))
                form = dict((k, v[0]) for k, v in
                            urllib.parse.parse_qs(self.rfile.read(length).decode()).items())
                outer.requests.append(form)
                grant = form.get("grant_type")
                body = {
                    "access_token": fake_jwt({"sub": "user-1", "email": "t@x.ai",
                                              "exp": int(time.time()) + 3600}),
                    "refresh_token": "rot-%d" % len(outer.requests),
                    "expires_in": 3600,
                }
                if grant not in ("authorization_code", "refresh_token"):
                    self.send_response(400)
                    self.end_headers()
                    return
                raw = json.dumps(body).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

        self.httpd = HTTPServer(("127.0.0.1", 0), H)
        self.url = "http://127.0.0.1:%d/token" % self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


@pytest.fixture
def token_server():
    server = FakeTokenServer()
    yield server
    server.close()


def make_spec(token_url: str, port: int = 0) -> dict:
    return {"name": "T", "vendor": "test", "auth_url": "https://auth.invalid/authorize",
            "token_url": token_url, "client_id": "cid-test", "scope": "openid",
            "callback_host": "127.0.0.1", "callback_port": port,
            "callback_path": "/cb", "extra_auth_params": {"originator": "cct_test"}}


def manager_with(tmp_path, token_server, fetcher=None):
    spec = make_spec(token_server.url)
    store = pv.ProviderStore(tmp_path / "prov.json")
    fetchers = {"t": fetcher or (lambda cred: {"windows": {"5h": {"used_pct": 1}}})}
    return pv.ProviderManager(store=store, specs={"t": spec}, fetchers=fetchers)


def browser_get(url: str) -> tuple[int, str]:
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode()


# ---------------------------------------------------------------- 플로우

def test_login_flow_end_to_end(tmp_path, token_server):
    mgr = manager_with(tmp_path, token_server)
    try:
        out = mgr.start_login("t")
        session = mgr._sessions["t"]
        assert "code_challenge=" in out["auth_url"]
        assert "state=" + session.state in out["auth_url"]
        assert "originator=cct_test" in out["auth_url"]

        code, page = browser_get(session.redirect_uri + "?code=abc&state=" + session.state)
        assert code == 200 and "연결 완료" in page
        assert session.done.wait(5) and session.error is None

        rec = mgr.store.get("t")
        assert rec["refresh"].startswith("rot-")
        assert rec["account_id"] == "user-1"
        sent = token_server.requests[0]
        assert sent["grant_type"] == "authorization_code"
        assert sent["code"] == "abc"
        assert sent["redirect_uri"] == session.redirect_uri
        # 연결 직후 사용량이 채워졌다(_after_login)
        assert rec["usage"] == {"windows": {"5h": {"used_pct": 1}}}
        view = mgr.view()[0]
        assert view["connected"] is True
        assert "access" not in view and "refresh" not in view
    finally:
        mgr.close()


def test_login_rejects_state_mismatch_and_error_param(tmp_path, token_server):
    mgr = manager_with(tmp_path, token_server)
    try:
        mgr.start_login("t")
        session = mgr._sessions["t"]
        code, page = browser_get(session.redirect_uri + "?code=abc&state=WRONG")
        assert code == 400
        assert mgr.store.get("t") == {}
        assert not session.done.is_set()          # 세션은 계속 대기(재시도 가능)

        code, _ = browser_get(session.redirect_uri + "?error=access_denied")
        assert code == 200
        assert session.done.wait(5) and "거부" in session.error
        assert mgr.store.get("t") == {}
        assert not token_server.requests
    finally:
        mgr.close()


def test_login_port_busy(tmp_path, token_server):
    mgr = manager_with(tmp_path, token_server)
    try:
        mgr.start_login("t")
        taken = mgr._sessions["t"]._httpd.server_address[1]
        spec2 = make_spec(token_server.url, port=taken)
        mgr2 = pv.ProviderManager(store=pv.ProviderStore(tmp_path / "p2.json"),
                                  specs={"t": spec2}, fetchers={"t": lambda c: {}})
        with pytest.raises(pv.ProviderError) as err:
            mgr2.start_login("t")
        assert err.value.code == "port_busy"
    finally:
        mgr.close()


def test_refresh_rotates_and_persists(tmp_path, token_server):
    mgr = manager_with(tmp_path, token_server)
    try:
        mgr.store.update("t", access="old", refresh="orig", expires=pv.now_i() - 10)
        mgr.refresh_usage("t", force=True)
        rec = mgr.store.get("t")
        assert rec["refresh"] == "rot-1"          # 회전된 refresh 가 저장됨
        assert rec["expires"] > pv.now_i()
        assert token_server.requests[0]["grant_type"] == "refresh_token"
        assert token_server.requests[0]["refresh_token"] == "orig"
        assert rec["usage_at"] is not None
    finally:
        mgr.close()


def test_refresh_usage_records_error_without_token(tmp_path, token_server):
    def boom(cred):
        raise pv.ProviderError("http_401", "HTTP 401")
    mgr = manager_with(tmp_path, token_server, fetcher=boom)
    try:
        secret = "sk-SECRET-TOKEN-VALUE"
        mgr.store.update("t", access=secret, refresh="r", expires=pv.now_i() + 3600)
        with pytest.raises(pv.ProviderError):
            mgr.refresh_usage("t", force=True)
        rec = mgr.store.get("t")
        assert rec["usage_error"]["code"] == "http_401"
        assert secret not in json.dumps(rec["usage_error"])  # 오류 기록에 토큰 미포함
        view = [x for x in mgr.view() if x["id"] == "t"][0]
        assert view["usage_error"]["code"] == "http_401"
    finally:
        mgr.close()


def test_refresh_usage_cooldown(tmp_path, token_server):
    calls = []
    mgr = manager_with(tmp_path, token_server,
                       fetcher=lambda cred: calls.append(1) or {"windows": {}})
    try:
        mgr.store.update("t", access="a", refresh="r", expires=pv.now_i() + 3600)
        mgr.refresh_usage("t", force=True)
        mgr.refresh_usage("t")                    # 쿨다운 - 실제 호출 없음
        assert len(calls) == 1
        mgr.refresh_usage("t", force=True)
        assert len(calls) == 2
    finally:
        mgr.close()


def test_logout_drops_credential(tmp_path, token_server):
    mgr = manager_with(tmp_path, token_server)
    try:
        mgr.store.update("t", access="a", refresh="r", expires=1)
        mgr.logout("t")
        assert mgr.store.get("t") == {}
        assert mgr.view()[0]["connected"] is False
    finally:
        mgr.close()


def test_unknown_provider(tmp_path, token_server):
    mgr = manager_with(tmp_path, token_server)
    try:
        with pytest.raises(pv.ProviderError):
            mgr.start_login("nope")
        with pytest.raises(pv.ProviderError):
            mgr.logout("nope")
    finally:
        mgr.close()


# ---------------------------------------------------------------- 픽스처 모드

def test_fake_manager(tmp_path):
    fx = tmp_path / "providers.json"
    fx.write_text(json.dumps({
        "openai": {"connected": True, "email": "demo@example.com",
                   "usage": {"plan": "plus", "windows": {
                       "5h": {"used_pct": 43, "reset_at": pv.now_i() + 12000},
                       "7d": {"used_pct": 24, "reset_at": pv.now_i() + 400000}}}},
        "xai": {"connected": False},
    }))
    mgr = pv.FakeProviderManager(tmp_path)
    view = {x["id"]: x for x in mgr.view()}
    assert view["openai"]["connected"] is True
    assert view["openai"]["usage"]["windows"]["5h"]["used_pct"] == 43
    assert view["xai"]["connected"] is False
    assert mgr.start_login("xai")["fake"] is True
    assert {x["id"]: x for x in mgr.view()}["xai"]["connected"] is True
    mgr.logout("xai")
    assert {x["id"]: x for x in mgr.view()}["xai"]["connected"] is False


def test_real_default_specs_shape():
    for pid in ("openai", "xai"):
        spec = pv.SPECS[pid]
        assert spec["client_id"] and spec["scope"] and spec["callback_port"] > 0
    assert pv.SPECS["openai"]["callback_port"] == 1455
    assert pv.SPECS["xai"]["callback_port"] == 56121


def test_submit_code_manual_fallback(tmp_path, token_server):
    mgr = manager_with(tmp_path, token_server)
    try:
        mgr.start_login("t")
        with pytest.raises(pv.ProviderError) as err:
            mgr.submit_code("t", "   ")
        assert err.value.code == "bad_code"
        mgr.submit_code("t", "manual-abc")
        rec = mgr.store.get("t")
        assert rec["refresh"].startswith("rot-")
        assert token_server.requests[0]["code"] == "manual-abc"
        assert rec["usage"] == {"windows": {"5h": {"used_pct": 1}}}   # on_done 사용량 채움
        assert mgr._sessions["t"].done.is_set()
    finally:
        mgr.close()


def test_submit_code_accepts_full_redirect_url(tmp_path, token_server):
    mgr = manager_with(tmp_path, token_server)
    try:
        mgr.start_login("t")
        session = mgr._sessions["t"]
        mgr.submit_code("t", session.redirect_uri + "?code=from-url&state=" + session.state)
        assert token_server.requests[0]["code"] == "from-url"
    finally:
        mgr.close()


def test_submit_code_without_login(tmp_path, token_server):
    mgr = manager_with(tmp_path, token_server)
    try:
        with pytest.raises(pv.ProviderError) as err:
            mgr.submit_code("t", "abc")
        assert err.value.code == "no_login"
    finally:
        mgr.close()
