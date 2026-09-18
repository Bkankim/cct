"""cct 대시보드 외부 프로바이더(GPT·Grok) 사용량 추적.

오픈코덱스·Codex CLI·Grok CLI 가 실사용하는 공개 PKCE 클라이언트 플로우를 이식했다:
- openai: Codex CLI 공개 클라이언트 → auth.openai.com, 콜백 localhost:1455
- xai:    Grok CLI 공개 클라이언트 → auth.x.ai(OIDC discovery), 콜백 127.0.0.1:56121

사용량 조회는 각 서비스의 내부 엔드포인트(비공식)를 쓴다. 정책 변경으로 언제든
끊길 수 있으며, 그 경우 화면에 오류로 표시될 뿐 지갑·계정에는 영향이 없다.

원칙(서버와 동일):
- 표준 라이브러리만 쓴다(의존성 0).
- 토큰 값은 응답·로그·예외 메시지 어디에도 남기지 않는다.
- 자격증명 파일은 mode 600, 원자적 교체(tmp + os.replace)로만 쓴다.
- refresh token 은 회전한다: 갱신 응답을 받는 즉시 저장한다. 저장 전에 죽으면
  재로그인 외에 복구 수단이 없으므로 갱신→저장 사이에 다른 I/O 를 두지 않는다.
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import secrets
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any, Callable
from urllib import error as urlerror
from urllib import request as urlrequest
from urllib.parse import parse_qs, urlencode, urlsplit

log = logging.getLogger("cct-dash.providers")

DEFAULT_STORE = "~/.claude/cct-dash-providers.json"
LOGIN_TIMEOUT_SEC = 600         # 로그인 콜백 대기 상한
HTTP_TIMEOUT_SEC = 20           # 토큰·사용량 HTTP 타임아웃
REFRESH_SKEW_SEC = 120          # 만료 이 초 전부터 미리 갱신
USAGE_COOLDOWN_SEC = 60         # 같은 프로바이더 사용량 재조회 최소 간격
DISCOVERY_TTL_SEC = 3600        # OIDC discovery 캐시

# 공개 PKCE 클라이언트 상수. 이 값들은 각 CLI 배포물에 포함된 공개 식별자다(시크릿 아님).
SPECS: dict[str, dict[str, Any]] = {
    "openai": {
        "name": "GPT",
        "vendor": "OpenAI · ChatGPT/Codex",
        "auth_url": "https://auth.openai.com/oauth/authorize",
        "token_url": "https://auth.openai.com/oauth/token",
        "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
        "scope": "openid profile email offline_access",
        "callback_host": "localhost",
        "callback_port": 1455,
        "callback_path": "/auth/callback",
        # Codex CLI 와 같은 단순화 플로우·조직 클레임을 요청한다.
        "extra_auth_params": {
            "codex_cli_simplified_flow": "true",
            "id_token_add_organizations": "true",
            "originator": "cct_dashboard",
        },
    },
    "xai": {
        "name": "Grok",
        "vendor": "xAI · SuperGrok",
        "discovery_url": "https://auth.x.ai/.well-known/openid-configuration",
        "client_id": "b1a00492-073a-47ea-816f-4c329264a828",
        "scope": "openid profile email offline_access grok-cli:access api:access",
        "callback_host": "127.0.0.1",
        "callback_port": 56121,
        "callback_path": "/callback",
        "extra_auth_params": {},        # nonce 는 요청마다 생성해 붙인다
    },
}
PROVIDER_IDS = tuple(SPECS)

OPENAI_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
XAI_BILLING_URL = "https://cli-chat-proxy.grok.com/v1/billing"
XAI_GROK_CLIENT_VERSION = "0.2.93"


class ProviderError(Exception):
    """토큰 값을 절대 담지 않는 사용자 표시용 오류."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


# ---------------------------------------------------------------- 공통 유틸

def now_i() -> int:
    return int(time.time())


def make_pkce() -> tuple[str, str]:
    """(verifier, challenge). RFC 7636 S256."""
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(48)).rstrip(b"=").decode()
    digest = hashlib.sha256(verifier.encode()).digest()
    challenge = base64.urlsafe_b64encode(digest).rstrip(b"=").decode()
    return verifier, challenge


def decode_jwt_payload(token: str) -> dict:
    parts = token.split(".")
    if len(parts) != 3 or not parts[1]:
        return {}
    try:
        pad = "=" * (-len(parts[1]) % 4)
        return json.loads(base64.urlsafe_b64decode(parts[1] + pad))
    except Exception:
        return {}


def iso_to_epoch(value: Any) -> int | None:
    if not isinstance(value, str):
        return None
    try:
        return int(datetime.fromisoformat(value).timestamp())
    except ValueError:
        return None


def http_json(url: str, headers: dict[str, str] | None = None,
              form: dict[str, str] | None = None,
              timeout: float = HTTP_TIMEOUT_SEC) -> dict:
    """GET(form=None) 또는 form-urlencoded POST 후 JSON 파싱.

    실패 시 ProviderError 만 올린다 - 예외 문자열에 요청 헤더(토큰)가 섞이지 않게
    urllib 예외를 여기서 끊는다.
    """
    data = urlencode(form).encode() if form is not None else None
    req = urlrequest.Request(url, data=data, headers={"Accept": "application/json",
                                                      **(headers or {})})
    if form is not None:
        req.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with urlrequest.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
    except urlerror.HTTPError as exc:
        code = "http_%d" % exc.code
        detail = ""
        try:
            err = json.loads(exc.read())
            if isinstance(err, dict):
                e = err.get("error")
                if isinstance(e, str):
                    detail = e
                elif isinstance(e, dict) and isinstance(e.get("message"), str):
                    detail = e["message"]
        except Exception:
            pass
        raise ProviderError(code, "HTTP %d%s" % (exc.code, " · %s" % detail[:120] if detail else ""))
    except Exception as exc:
        raise ProviderError("network", "네트워크 오류: %s" % type(exc).__name__)
    try:
        parsed = json.loads(body)
    except ValueError:
        raise ProviderError("bad_json", "응답이 JSON 이 아님")
    if not isinstance(parsed, dict):
        raise ProviderError("bad_json", "응답 형식이 예상과 다름")
    return parsed


# ---------------------------------------------------------------- 엔드포인트

_discovery_cache: dict[str, tuple[float, dict[str, str]]] = {}
_discovery_lock = threading.Lock()


def resolve_endpoints(spec: dict) -> dict[str, str]:
    """{'auth': ..., 'token': ...}. discovery_url 이 있으면 OIDC discovery 로 해석."""
    if "auth_url" in spec:
        return {"auth": spec["auth_url"], "token": spec["token_url"]}
    url = spec["discovery_url"]
    with _discovery_lock:
        hit = _discovery_cache.get(url)
        if hit and time.monotonic() - hit[0] < DISCOVERY_TTL_SEC:
            return hit[1]
    doc = http_json(url)
    auth, token = doc.get("authorization_endpoint"), doc.get("token_endpoint")
    if not isinstance(auth, str) or not isinstance(token, str):
        raise ProviderError("discovery", "OIDC discovery 응답에 엔드포인트가 없음")
    allowed = spec.get("endpoint_host_suffix")
    if allowed:
        for u in (auth, token):
            parsed = urlsplit(u)
            host = (parsed.hostname or "").lower()
            if parsed.scheme != "https" or not (host == allowed or host.endswith("." + allowed)):
                raise ProviderError("discovery", "discovery 가 예상 밖 호스트를 반환")
    resolved = {"auth": auth, "token": token}
    with _discovery_lock:
        _discovery_cache[url] = (time.monotonic(), resolved)
    return resolved


SPECS["xai"]["endpoint_host_suffix"] = "x.ai"


# ---------------------------------------------------------------- 자격증명 저장

class ProviderStore:
    """프로바이더 자격증명·사용량 캐시 파일. mode 600, 원자적 교체."""

    def __init__(self, path: str | Path = DEFAULT_STORE):
        self.path = Path(path).expanduser()
        self._lock = threading.RLock()
        self._data: dict[str, dict] = {}
        self.load()

    def load(self) -> None:
        with self._lock:
            try:
                raw = json.loads(self.path.read_text())
                self._data = raw if isinstance(raw, dict) else {}
            except FileNotFoundError:
                self._data = {}
            except Exception as exc:
                log.warning("프로바이더 저장소 읽기 실패(%s) - 빈 상태로 시작", type(exc).__name__)
                self._data = {}

    def save(self) -> None:
        with self._lock:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            try:
                with os.fdopen(fd, "w") as fh:
                    json.dump(self._data, fh, ensure_ascii=False, indent=1)
            except Exception:
                tmp.unlink(missing_ok=True)
                raise
            os.replace(tmp, self.path)
            os.chmod(self.path, 0o600)

    def get(self, provider: str) -> dict:
        with self._lock:
            return dict(self._data.get(provider) or {})

    def update(self, provider: str, **fields: Any) -> None:
        with self._lock:
            rec = self._data.setdefault(provider, {})
            rec.update(fields)
            self.save()

    def drop(self, provider: str) -> None:
        with self._lock:
            if provider in self._data:
                del self._data[provider]
                self.save()


# ---------------------------------------------------------------- 토큰 플로우

def creds_from_token_response(data: dict, refresh_fallback: str = "") -> dict:
    """토큰 응답 → {access, refresh, expires(초), account_id, email}."""
    access = data.get("access_token")
    if not isinstance(access, str) or not access:
        raise ProviderError("token", "토큰 응답에 access token 이 없음")
    refresh = data.get("refresh_token")
    if not isinstance(refresh, str) or not refresh:
        refresh = refresh_fallback
    expires_in = data.get("expires_in")
    if not isinstance(expires_in, (int, float)) or not (0 <= expires_in < 10 ** 10):
        expires_in = 3600
    id_token = data.get("id_token")
    payload = {}
    for tok in (id_token, access):
        if isinstance(tok, str):
            payload = decode_jwt_payload(tok)
            if payload:
                break
    account_id = extract_account_id(id_token if isinstance(id_token, str) else None, access)
    email = payload.get("email")
    return {
        "access": access,
        "refresh": refresh,
        "expires": now_i() + int(expires_in),
        "account_id": account_id,
        "email": email.lower() if isinstance(email, str) else None,
    }


def extract_account_id(id_token: str | None, access_token: str | None) -> str | None:
    """OpenAI 는 chatgpt_account_id, xAI(OIDC)는 sub 를 계정 식별자로 쓴다."""
    for tok in (id_token, access_token):
        if not tok:
            continue
        payload = decode_jwt_payload(tok)
        if not payload:
            continue
        if isinstance(payload.get("chatgpt_account_id"), str):
            return payload["chatgpt_account_id"]
        ns = payload.get("https://api.openai.com/auth")
        if isinstance(ns, dict) and isinstance(ns.get("chatgpt_account_id"), str):
            return ns["chatgpt_account_id"]
        orgs = payload.get("organizations")
        if isinstance(orgs, list) and orgs and isinstance(orgs[0], dict) \
                and isinstance(orgs[0].get("id"), str):
            return orgs[0]["id"]
        if isinstance(payload.get("sub"), str) and payload["sub"]:
            return payload["sub"]
    return None


def exchange_code(spec: dict, code: str, verifier: str, redirect_uri: str) -> dict:
    token_url = resolve_endpoints(spec)["token"]
    data = http_json(token_url, form={
        "grant_type": "authorization_code",
        "client_id": spec["client_id"],
        "code": code,
        "redirect_uri": redirect_uri,
        "code_verifier": verifier,
    })
    return creds_from_token_response(data)


def refresh_credential(spec: dict, refresh_token: str) -> dict:
    if not refresh_token:
        raise ProviderError("no_refresh", "refresh token 이 없어 재로그인이 필요")
    token_url = resolve_endpoints(spec)["token"]
    data = http_json(token_url, form={
        "grant_type": "refresh_token",
        "client_id": spec["client_id"],
        "refresh_token": refresh_token,
    })
    return creds_from_token_response(data, refresh_fallback=refresh_token)


# ---------------------------------------------------------------- 콜백 서버

_PAGE = """<!doctype html><html lang="ko"><meta charset="utf-8">
<title>cct 대시보드</title>
<body style="font-family:system-ui;background:#0C0D0E;color:#E6E7E9;
display:grid;place-items:center;min-height:90vh;margin:0">
<div style="text-align:center;max-width:26rem;padding:0 1rem">
<h2 style="font-weight:600">%s</h2><p style="color:#9A9CA1">%s</p></div></body></html>"""


class LoginSession:
    """프로바이더 1개의 진행 중 OAuth 로그인. 콜백 서버는 1회용이다."""

    def __init__(self, provider: str, spec: dict, store: ProviderStore,
                 on_done: Callable[[str], None] | None = None):
        self.provider = provider
        self.spec = spec
        self.store = store
        self.on_done = on_done
        self.state = secrets.token_urlsafe(24)
        self.verifier, self.challenge = make_pkce()
        self.error: str | None = None
        self.done = threading.Event()
        self.deadline = time.monotonic() + LOGIN_TIMEOUT_SEC
        bind_host = "127.0.0.1"
        try:
            self._httpd = HTTPServer((bind_host, spec["callback_port"]),
                                     self._make_handler())
        except OSError:
            raise ProviderError(
                "port_busy",
                "포트 %d 가 사용 중입니다 - 다른 로그인(codex/grok CLI)이 진행 중인지 확인"
                % spec["callback_port"])
        self._httpd.timeout = 1.0
        port = self._httpd.server_address[1]
        self.redirect_uri = "http://%s:%d%s" % (spec["callback_host"], port,
                                                spec["callback_path"])
        self._thread = threading.Thread(target=self._serve, daemon=True,
                                        name="oauth-%s" % provider)
        self._thread.start()

    @property
    def alive(self) -> bool:
        return not self.done.is_set() and time.monotonic() < self.deadline

    def auth_url(self) -> str:
        endpoints = resolve_endpoints(self.spec)
        params = {
            "response_type": "code",
            "client_id": self.spec["client_id"],
            "redirect_uri": self.redirect_uri,
            "scope": self.spec["scope"],
            "code_challenge": self.challenge,
            "code_challenge_method": "S256",
            "state": self.state,
            **self.spec.get("extra_auth_params", {}),
        }
        if "discovery_url" in self.spec:
            params["nonce"] = secrets.token_urlsafe(16)
        return "%s?%s" % (endpoints["auth"], urlencode(params))

    def close(self) -> None:
        self.done.set()
        try:
            self._httpd.server_close()
        except Exception:
            pass

    def submit_code(self, code: str) -> None:
        """수동 코드 폴백 - xAI 는 리다이렉트 대신 코드 표시 화면을 줄 때가 있다(실측).

        전체 리다이렉트 URL 을 붙여넣어도 code 파라미터를 꺼내 처리한다.
        """
        code = (code or "").strip()
        if "code=" in code:
            q = parse_qs(urlsplit(code).query)
            code = (q.get("code") or [""])[0]
        if not code:
            raise ProviderError("bad_code", "코드가 비어 있습니다")
        if not self.alive:
            raise ProviderError("login_expired", "로그인 세션이 만료됐습니다 - 다시 시도하세요")
        cred = exchange_code(self.spec, code, self.verifier, self.redirect_uri)
        self.store.update(self.provider, **cred, connected_at=now_i(), usage_error=None)
        self._finish(None)

    def _serve(self) -> None:
        try:
            while self.alive:
                self._httpd.handle_request()      # timeout 1초 - 루프마다 alive 재확인
        finally:
            try:
                self._httpd.server_close()
            except Exception:
                pass
            if not self.done.is_set():
                self.error = self.error or "시간 초과 - 다시 시도하세요"
                self.done.set()

    def _finish(self, error: str | None) -> None:
        self.error = error
        self.done.set()
        if self.on_done is not None:
            try:
                self.on_done(self.provider)
            except Exception as exc:
                log.warning("로그인 후처리 실패: %s", type(exc).__name__)

    def _make_handler(self) -> type[BaseHTTPRequestHandler]:
        session = self

        class Callback(BaseHTTPRequestHandler):
            def log_message(self, fmt, *args):   # 콜백 쿼리(코드)를 로그에 남기지 않는다
                pass

            def _page(self, code: int, title: str, sub: str) -> None:
                body = (_PAGE % (title, sub)).encode()
                self.send_response(code)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                url = urlsplit(self.path)
                if url.path != session.spec["callback_path"]:
                    self._page(404, "잘못된 경로", "이 창을 닫아도 됩니다.")
                    return
                q = parse_qs(url.query)
                if q.get("error"):
                    session._finish("로그인이 거부되었습니다 (%s)" % q["error"][0][:60])
                    self._page(200, "로그인 취소됨", "이 창을 닫고 대시보드로 돌아가세요.")
                    return
                state = (q.get("state") or [""])[0]
                code = (q.get("code") or [""])[0]
                if not code or not secrets.compare_digest(state, session.state):
                    self._page(400, "인증 실패", "state 가 일치하지 않습니다. 대시보드에서 다시 시도하세요.")
                    return
                try:
                    cred = exchange_code(session.spec, code, session.verifier,
                                         session.redirect_uri)
                except ProviderError as exc:
                    session._finish("토큰 교환 실패: %s" % exc.message)
                    self._page(502, "인증 실패", "토큰 교환에 실패했습니다. 대시보드에서 다시 시도하세요.")
                    return
                session.store.update(session.provider, **cred,
                                     connected_at=now_i(), usage_error=None)
                session._finish(None)
                self._page(200, "%s 연결 완료" % session.spec["name"],
                           "이 창을 닫고 대시보드로 돌아가면 사용량이 표시됩니다.")

        return Callback


# ---------------------------------------------------------------- 사용량 조회

def parse_openai_usage(data: dict) -> dict:
    """wham/usage 응답 → 정규화. 실캡처(2026-09) 기준:
    rate_limit.primary_window(5h)·secondary_window(7d) 의 used_percent·reset_at."""
    rl = data.get("rate_limit")
    if not isinstance(rl, dict):
        raise ProviderError("parse", "rate_limit 필드가 없음")
    windows = {}
    for key, name in (("primary_window", "5h"), ("secondary_window", "7d")):
        w = rl.get(key)
        if not isinstance(w, dict):
            continue
        used = w.get("used_percent")
        if not isinstance(used, (int, float)):
            continue
        entry: dict[str, Any] = {"used_pct": round(float(used), 1)}
        if isinstance(w.get("reset_at"), (int, float)):
            entry["reset_at"] = int(w["reset_at"])
        windows[name] = entry
    if not windows:
        raise ProviderError("parse", "사용량 창을 찾지 못함")
    out: dict[str, Any] = {"windows": windows}
    if isinstance(data.get("plan_type"), str):
        out["plan"] = data["plan_type"]
    if isinstance(data.get("email"), str):
        out["email"] = data["email"].lower()
    return out


def fetch_openai_usage(cred: dict) -> dict:
    headers = {"Authorization": "Bearer %s" % cred["access"]}
    if cred.get("account_id"):
        headers["ChatGPT-Account-Id"] = cred["account_id"]
    return parse_openai_usage(http_json(OPENAI_USAGE_URL, headers=headers))


def parse_xai_usage(data: dict) -> dict:
    """billing?format=credits 응답 → 정규화. 실캡처(2026-09) 기준:
    config.creditUsagePercent + currentPeriod.end(ISO) + productUsage[]."""
    config = data.get("config")
    if not isinstance(config, dict):
        raise ProviderError("parse", "config 필드가 없음")
    period = config.get("currentPeriod")
    used = config.get("creditUsagePercent", 0)
    if not isinstance(period, dict) or not isinstance(used, (int, float)):
        raise ProviderError("parse", "주간 크레딧 창을 찾지 못함")
    entry: dict[str, Any] = {"used_pct": round(float(used), 1)}
    reset_at = iso_to_epoch(period.get("end"))
    if reset_at is not None:
        entry["reset_at"] = reset_at
    products = []
    for item in config.get("productUsage") or []:
        if isinstance(item, dict) and isinstance(item.get("product"), str) \
                and isinstance(item.get("usagePercent"), (int, float)):
            products.append({"name": item["product"],
                             "used_pct": round(float(item["usagePercent"]), 1)})
    out: dict[str, Any] = {"windows": {"weekly": entry}}
    if products:
        out["products"] = products
    return out


def fetch_xai_usage(cred: dict) -> dict:
    user_id = cred.get("account_id") or ""
    headers = {
        "Authorization": "Bearer %s" % cred["access"],
        "x-xai-token-auth": "xai-grok-cli",
        "x-authenticateresponse": "authenticate-response",
        "x-grok-client-version": XAI_GROK_CLIENT_VERSION,
    }
    if user_id:
        headers["x-userid"] = user_id
    return parse_xai_usage(http_json(XAI_BILLING_URL + "?format=credits", headers=headers))


FETCHERS: dict[str, Callable[[dict], dict]] = {
    "openai": fetch_openai_usage,
    "xai": fetch_xai_usage,
}


# ---------------------------------------------------------------- 매니저

class ProviderManager:
    """서버(App)가 쓰는 파사드. view() 는 토큰 값을 절대 포함하지 않는다."""

    fake = False

    def __init__(self, store: ProviderStore | None = None,
                 specs: dict[str, dict] | None = None,
                 fetchers: dict[str, Callable[[dict], dict]] | None = None):
        self.store = store or ProviderStore()
        self.specs = specs or SPECS
        self.fetchers = fetchers or FETCHERS
        self._sessions: dict[str, LoginSession] = {}
        self._lock = threading.Lock()
        self._last_fetch: dict[str, float] = {}

    # -- 조회
    def view(self) -> list[dict]:
        out = []
        for pid, spec in self.specs.items():
            rec = self.store.get(pid)
            session = self._sessions.get(pid)
            connected = bool(rec.get("access"))
            item = {
                "id": pid,
                "name": spec["name"],
                "vendor": spec.get("vendor", ""),
                "connected": connected,
                "login_pending": bool(session and session.alive),
                "login_error": session.error if session and session.done.is_set() else None,
            }
            if connected:
                item.update({
                    "email": rec.get("email"),
                    "connected_at": rec.get("connected_at"),
                    "usage": rec.get("usage"),
                    "usage_at": rec.get("usage_at"),
                    "usage_error": rec.get("usage_error"),
                })
            out.append(item)
        return out

    # -- 로그인
    def start_login(self, provider: str) -> dict:
        spec = self._spec(provider)
        with self._lock:
            old = self._sessions.pop(provider, None)
            if old is not None:
                old.close()
            session = LoginSession(provider, spec, self.store,
                                   on_done=self._after_login)
            try:
                url = session.auth_url()
            except ProviderError:
                session.close()
                raise
            self._sessions[provider] = session
        return {"auth_url": url}

    def _after_login(self, provider: str) -> None:
        """콜백 스레드에서 호출 - 연결 직후 사용량을 한 번 채운다."""
        if self.store.get(provider).get("access"):
            try:
                self.refresh_usage(provider, force=True)
            except ProviderError:
                pass                                  # 오류는 usage_error 로 이미 기록됨

    def submit_code(self, provider: str, code: str) -> None:
        """진행 중 로그인 세션에 수동 코드를 전달한다(리다이렉트 실패 폴백)."""
        self._spec(provider)
        with self._lock:
            session = self._sessions.get(provider)
        if session is None:
            raise ProviderError("no_login", "진행 중인 로그인이 없습니다 - 연결을 먼저 시작하세요")
        session.submit_code(code)          # 성공 시 _finish → on_done 이 사용량을 채운다

    def logout(self, provider: str) -> None:
        self._spec(provider)
        with self._lock:
            session = self._sessions.pop(provider, None)
            if session is not None:
                session.close()
        self.store.drop(provider)

    # -- 사용량
    def refresh_usage(self, provider: str | None = None, force: bool = False) -> None:
        targets = [provider] if provider else \
            [p for p in self.specs if self.store.get(p).get("access")]
        for pid in targets:
            self._refresh_one(pid, force)

    def _refresh_one(self, provider: str, force: bool) -> None:
        spec = self._spec(provider)
        rec = self.store.get(provider)
        if not rec.get("access"):
            raise ProviderError("not_connected", "%s 는 연결되어 있지 않습니다" % spec["name"])
        last = self._last_fetch.get(provider, 0.0)
        if not force and time.monotonic() - last < USAGE_COOLDOWN_SEC:
            return
        self._last_fetch[provider] = time.monotonic()
        try:
            cred = self._ensure_fresh(provider, spec, rec)
            usage = self.fetchers[provider](cred)
        except ProviderError as exc:
            self.store.update(provider, usage_error={
                "code": exc.code, "message": exc.message, "at": now_i()})
            raise
        fields: dict[str, Any] = {"usage": usage, "usage_at": now_i(), "usage_error": None}
        if usage.get("email") and not rec.get("email"):
            fields["email"] = usage["email"]
        self.store.update(provider, **fields)

    def _ensure_fresh(self, provider: str, spec: dict, rec: dict) -> dict:
        if rec.get("expires", 0) - REFRESH_SKEW_SEC > now_i():
            return rec
        cred = refresh_credential(spec, rec.get("refresh") or "")
        # refresh 회전: 새 자격증명을 즉시 저장한다(위 모듈 docstring 참고).
        self.store.update(provider, **cred)
        return {**rec, **cred}

    def close(self) -> None:
        with self._lock:
            for session in self._sessions.values():
                session.close()
            self._sessions.clear()

    def _spec(self, provider: str) -> dict:
        spec = self.specs.get(provider)
        if spec is None:
            raise ProviderError("unknown_provider", "지원하지 않는 프로바이더: %s" % provider[:20])
        return spec


class FakeProviderManager(ProviderManager):
    """--fake 모드: 픽스처 파일만 읽고 네트워크·저장소를 건드리지 않는다."""

    fake = True

    def __init__(self, fixtures: str | Path):
        self._fixture_path = Path(fixtures) / "providers.json"
        try:
            self._fixture = json.loads(self._fixture_path.read_text())
        except Exception:
            self._fixture = {}
        self._connected: dict[str, bool] = {
            pid: bool((self._fixture.get(pid) or {}).get("connected"))
            for pid in SPECS}

    def view(self) -> list[dict]:
        out = []
        for pid, spec in SPECS.items():
            fx = self._fixture.get(pid) or {}
            connected = self._connected.get(pid, False)
            item = {"id": pid, "name": spec["name"], "vendor": spec.get("vendor", ""),
                    "connected": connected, "login_pending": False, "login_error": None}
            if connected:
                item.update({
                    "email": fx.get("email"),
                    "connected_at": fx.get("connected_at"),
                    "usage": self._relative_usage(fx.get("usage")),
                    "usage_at": fx.get("usage_at") or now_i() - 180,
                    "usage_error": fx.get("usage_error"),
                })
            out.append(item)
        return out

    @staticmethod
    def _relative_usage(usage: Any) -> Any:
        """픽스처의 reset_in(초)을 지금 기준 reset_at 으로 바꿔 데모 화면이 늘 살아 보이게 한다."""
        if not isinstance(usage, dict):
            return usage
        out = json.loads(json.dumps(usage))
        for w in (out.get("windows") or {}).values():
            if isinstance(w, dict) and isinstance(w.get("reset_in"), (int, float)):
                w["reset_at"] = now_i() + int(w.pop("reset_in"))
        return out

    def start_login(self, provider: str) -> dict:
        if provider not in SPECS:
            raise ProviderError("unknown_provider", "지원하지 않는 프로바이더: %s" % provider[:20])
        self._connected[provider] = True              # 픽스처 모드는 즉시 연결로 간주
        return {"auth_url": "", "fake": True}

    def submit_code(self, provider: str, code: str) -> None:
        if provider not in SPECS:
            raise ProviderError("unknown_provider", "지원하지 않는 프로바이더: %s" % provider[:20])
        self._connected[provider] = True

    def logout(self, provider: str) -> None:
        if provider not in SPECS:
            raise ProviderError("unknown_provider", "지원하지 않는 프로바이더: %s" % provider[:20])
        self._connected[provider] = False

    def refresh_usage(self, provider: str | None = None, force: bool = False) -> None:
        return None

    def close(self) -> None:
        return None
