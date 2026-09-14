"""WP2 서버 테스트.

전부 FakeCct(픽스처) 경로로만 돈다. 실제 cct 호출·실계정 프로브는 0회다.
실행: cd ~/cct && uv run --with pytest pytest dashboard/tests -q
"""

from __future__ import annotations

import importlib.util
import json
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"
SERVER_PY = HERE.parent / "server.py"

_spec = importlib.util.spec_from_file_location("cct_dash_server", SERVER_PY)
srv = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(srv)

WRITE = {"X-CCT-Write": "1"}
FAKE_TOKEN = "sk-ant-oat01-FIXTUREONLY-0123456789abcdef"   # 픽스처용 가짜 값


class Client:
    def __init__(self, base: str):
        self.base = base

    def req(self, method: str, path: str, body=None, headers=None):
        data = None if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(self.base + path, data=data, method=method)
        request.add_header("Content-Type", "application/json")
        for key, value in (headers or {}).items():
            request.add_header(key, value)
        try:
            with urllib.request.urlopen(request, timeout=30) as resp:
                raw = resp.read().decode("utf-8")
                if not raw:
                    return resp.status, {}
                try:
                    return resp.status, json.loads(raw)
                except ValueError:
                    return resp.status, {"raw": raw}
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8")
            try:
                return exc.code, json.loads(raw)
            except ValueError:
                return exc.code, {"raw": raw}

    def get(self, path, headers=None):
        return self.req("GET", path, None, headers)

    def post(self, path, body=None, headers=None):
        return self.req("POST", path, body if body is not None else {}, headers)


@pytest.fixture()
def app(tmp_path):
    cct = srv.FakeCct(FIXTURES, delay=0.0)
    state = srv.State(tmp_path / "cct-dash-state.json")
    application = srv.App(
        cct=cct,
        state=state,
        web_dir=tmp_path / "web",
        live_file=FIXTURES / "orca-usage-cache.json",
        bind="127.0.0.1",
        port=0,
        auto_tick=0.01,
    )
    application.fake_cct = cct
    yield application
    application.close()


@pytest.fixture()
def client(app):
    httpd = srv.make_server("127.0.0.1", 0, app)
    # poll_interval 기본값 0.5초는 teardown 마다 그대로 대기시간이 된다.
    thread = threading.Thread(target=httpd.serve_forever, args=(0.02,), daemon=True)
    thread.start()
    try:
        yield Client("http://127.0.0.1:%d" % app.port)
    finally:
        httpd.shutdown()
        httpd.server_close()


def used_cmds(app) -> list[str]:
    return [c["args"][0] for c in app.fake_cct.calls]


def calls_of(app, name: str) -> list[dict]:
    """쓰기 뒤에는 상태 재조립용 ls 가 뒤따르므로 이름으로 골라낸다."""
    return [c for c in app.fake_cct.calls if c["args"] and c["args"][0] == name]


# ---------------------------------------------------------------- 파서

def test_parse_status():
    text = (
        "wallet: /Users/x/.claude/tokens.env\nmode: 600\naccounts: 7\n"
        "active: gv\ndefault: gv\nsticky: enabled\n"
        "claude: /Users/x/.local/bin/claude\nclaude-version: 2.1.270\n"
    )
    out = srv.parse_status(text)
    assert out["accounts"] == 7
    assert out["active"] == "gv"
    assert out["claude_version"] == "2.1.270"
    assert out["mode"] == "600"


def test_parse_doctor():
    text = "PASS wallet: mode 600\nWARN lock: live mutation in progress\nFAIL active: unresolved label\n"
    items = srv.parse_doctor(text)
    assert [i["lv"] for i in items] == ["PASS", "WARN", "FAIL"]
    assert items[1]["msg"] == "lock: live mutation in progress"


def test_parse_ls_variants():
    text = (
        "  cct gv   ← 활성\n"
        "  cct pro4\n"
        "  cct spare   (비어있음)\n"
        "  cct empty_active   (비어있음)   ← 활성\n"
        "  \x1b[31mcct colored\x1b[0m\n"
        "쓰레기 줄\n"
    )
    entries = srv.parse_ls(text)
    assert [e["label"] for e in entries] == ["gv", "pro4", "spare", "empty_active", "colored"]
    assert entries[0]["active"] is True and entries[0]["has_token"] is True
    assert entries[2]["has_token"] is False and entries[2]["active"] is False
    assert entries[3]["has_token"] is False and entries[3]["active"] is True


def test_parse_usage_line_ok_and_error():
    line = '{"label":"gv","state":"ok","org":"org_9f2a","now":1,"probe":null,"windows":null}'
    assert srv.parse_usage_line(line, "gv")["state"] == "ok"
    assert srv.parse_usage_line("구독 사용량 안내\n", "gv")["state"] == "parse_error"
    assert srv.parse_usage_line("", "gv")["state"] == "parse_error"
    assert srv.parse_usage_line("[1,2]", "gv")["state"] == "parse_error"
    assert srv.parse_usage_line('{"label":"gv"}', "gv")["windows"] is None


def test_mask():
    text = "before " + FAKE_TOKEN + " after"
    masked = srv.mask(text)
    assert FAKE_TOKEN not in masked
    assert "sk-ant-***" in masked
    assert masked.startswith("before ") and masked.endswith(" after")


def test_resolve_static_blocks_traversal(tmp_path):
    base = tmp_path / "web"
    base.mkdir()
    (base / "index.html").write_text("ok", encoding="utf-8")
    (tmp_path / "secret.txt").write_text("secret", encoding="utf-8")
    assert srv.resolve_static(base, "/")[0] == (base / "index.html").resolve()
    assert srv.resolve_static(base, "/../secret.txt")[1] == "forbidden"
    assert srv.resolve_static(base, "/a/../../secret.txt")[1] == "forbidden"
    assert srv.resolve_static(base, "/none.css")[1] == "not_found"


# ---------------------------------------------------------------- 상태 파일

def test_state_file_mode_600_and_reload(tmp_path):
    path = tmp_path / "state.json"
    state = srv.State(path)
    state.set_check("gv", "valid")
    state.bump_usage(2, 1)
    state.log_add("cct usage --json gv", 0, 4180)
    state.save()
    assert (path.stat().st_mode & 0o777) == 0o600
    again = srv.State(path)
    assert again.account("gv")["check"]["result"] == "valid"
    assert again.budget_view(30, None)["usage_probes"] == 2
    assert again.budget_view(30, None)["est_tokens"] == 2 * 32 + 1
    assert again.log_view()[0]["cmd"] == "cct usage --json gv"


def test_state_rejects_below_floor_auto_min_on_load(tmp_path):
    path = tmp_path / "state.json"
    path.write_text(json.dumps({"settings": {"auto_min": 5}}), encoding="utf-8")
    assert srv.State(path).auto_min() == srv.DEFAULT_AUTO_MIN


# ---------------------------------------------------------------- /api/state

def test_api_state_schema(client, app):
    code, body = client.get("/api/state")
    assert code == 200
    assert sorted(body) == ["accounts", "budget", "doctor", "live", "log",
                            "refreshing", "server", "status"]
    assert sorted(body["server"]) == ["bind", "cct_path", "fake", "started_at", "version"]
    assert body["server"]["fake"] is True
    assert sorted(body["status"]) == ["accounts", "active", "claude", "claude_version",
                                      "default", "mode", "sticky", "wallet"]
    assert sorted(body["doctor"]) == ["at", "items", "rc"]
    assert body["doctor"]["rc"] == 0
    assert body["doctor"]["items"][1]["msg"] == "structure: 7 account(s), annotations valid"
    assert [a["label"] for a in body["accounts"]] == [
        "gv", "pro4", "pro5", "max1", "pro4b", "team", "spare"]
    first = body["accounts"][0]
    assert sorted(first) == ["active", "check", "default", "has_token", "label",
                             "usage", "usage_at"]
    assert first["active"] is True and first["default"] is True
    assert body["accounts"][-1]["has_token"] is False
    assert sorted(body["budget"]) == ["auto_min", "check_probes", "day", "est_tokens",
                                      "floor_min", "next_auto_at", "usage_probes"]
    assert body["budget"]["floor_min"] == 15
    assert sorted(body["live"]) == ["at", "context_pct", "cost_usd", "five_hour",
                                    "label_guess", "model", "seven_day", "stale"]
    assert body["refreshing"] is False
    assert isinstance(body["log"], list)


def test_api_state_does_not_probe(client, app):
    client.get("/api/state")
    client.get("/api/state")
    assert "usage" not in used_cmds(app)
    assert "check" not in used_cmds(app)
    assert app.state.budget_view(30, None)["usage_probes"] == 0


def test_snapshot_cache_limits_cct_calls(client, app):
    for _ in range(3):
        client.get("/api/state")
    # status/doctor/ls 각 1회씩만(5초 캐시)
    assert used_cmds(app).count("status") == 1
    assert used_cmds(app).count("doctor") == 1
    assert used_cmds(app).count("ls") == 1


# ---------------------------------------------------------------- 쓰기 게이트

@pytest.mark.parametrize("path,body", [
    ("/api/add", {"label": "newone", "token": FAKE_TOKEN}),
    ("/api/rm", {"label": "pro5"}),
    ("/api/rename", {"old": "pro5", "new": "pro6"}),
])
def test_write_gate_403(client, app, path, body):
    code, out = client.post(path, body)
    assert code == 403
    assert out["error"]["code"] == "write_disabled"
    assert used_cmds(app) == []          # cct 호출 자체가 없어야 한다


def test_read_endpoints_need_no_write_header(client):
    assert client.post("/api/use", {"label": "pro5"})[0] == 200
    assert client.post("/api/off")[0] == 200
    assert client.post("/api/settings", {"auto_min": 15})[0] == 200


# ---------------------------------------------------------------- add (토큰 취급)

def test_add_passes_token_only_on_stdin(client, app, tmp_path):
    code, out = client.post("/api/add", {"label": "newone", "token": FAKE_TOKEN}, WRITE)
    assert code == 200
    call = calls_of(app, "add")[-1]
    assert call["args"] == ["add", "newone"]                 # argv 에 토큰 없음
    assert FAKE_TOKEN not in " ".join(call["args"])
    assert call["stdin"] == FAKE_TOKEN + "\n"                # stdin 한 줄
    assert FAKE_TOKEN not in json.dumps(out, ensure_ascii=False)
    assert FAKE_TOKEN not in app.state.path.read_text(encoding="utf-8")
    assert all(FAKE_TOKEN not in entry["cmd"] for entry in out["state"]["log"])
    assert out["state"]["log"][0]["cmd"] == "cct add newone (stdin 전달, 값 미기록)"
    assert "newone" in [a["label"] for a in out["state"]["accounts"]]


def test_add_overwrite_needs_second_stdin_line(client, app):
    code, out = client.post("/api/add", {"label": "gv", "token": FAKE_TOKEN}, WRITE)
    assert code == 409 and out["error"]["code"] == "cct_failed"
    assert calls_of(app, "add")[-1]["stdin"] == FAKE_TOKEN + "\n"

    code, out = client.post("/api/add",
                            {"label": "gv", "token": FAKE_TOKEN, "overwrite": True}, WRITE)
    assert code == 200
    assert calls_of(app, "add")[-1]["stdin"] == FAKE_TOKEN + "\ny\n"


def test_add_rejects_bad_label_and_empty_token(client):
    assert client.post("/api/add", {"label": "UPPER", "token": FAKE_TOKEN}, WRITE)[1]["error"]["code"] == "bad_label"
    assert client.post("/api/add", {"label": "usage", "token": FAKE_TOKEN}, WRITE)[1]["error"]["code"] == "bad_label"
    assert client.post("/api/add", {"label": "ok1", "token": ""}, WRITE)[1]["error"]["code"] == "bad_request"


# ---------------------------------------------------------------- 프로브

def test_refresh_single_then_too_soon(client, app):
    code, out = client.post("/api/refresh", {"label": "gv"})
    assert code == 200
    assert out["refreshed"] == ["gv"]
    account = [a for a in out["state"]["accounts"] if a["label"] == "gv"][0]
    assert account["usage"]["state"] == "ok"
    assert account["usage"]["windows"]["7d_oi"]["utilization"] == 0.71
    assert account["usage_at"] is not None
    assert out["state"]["budget"]["usage_probes"] == 1
    assert out["state"]["budget"]["est_tokens"] == 32

    code, out = client.post("/api/refresh", {"label": "gv"})
    assert code == 429 and out["error"]["code"] == "too_soon"


def test_refresh_all_counts_budget_and_fallback(client, app):
    code, out = client.post("/api/refresh", {"all": True})
    assert code == 200
    assert sorted(out["refreshed"]) == ["gv", "max1", "pro4", "pro4b", "pro5", "team"]
    budget = out["state"]["budget"]
    assert budget["usage_probes"] == 6                 # spare 는 토큰이 없어 제외
    assert budget["est_tokens"] == 6 * 32 + 2          # pro4·team 폴백 1토큰씩
    states = {a["label"]: (a["usage"] or {}).get("state") for a in out["state"]["accounts"]}
    assert states["team"] == "no_response"
    assert states["spare"] is None
    assert states["max1"] == "ok"


def test_refresh_rebases_reset_to_future(client):
    _, out = client.post("/api/refresh", {"label": "gv"})
    account = [a for a in out["state"]["accounts"] if a["label"] == "gv"][0]
    assert account["usage"]["windows"]["5h"]["reset"] > time.time()


def test_refresh_unknown_and_no_token(client):
    code, out = client.post("/api/refresh", {"label": "nope"})
    assert code == 404 and out["error"]["code"] == "unknown_label"
    code, out = client.post("/api/refresh", {"label": "spare"})
    assert code == 409 and out["error"]["code"] == "no_token"


def test_check_endpoint(client, app):
    code, out = client.post("/api/check", {"label": "gv"})
    assert code == 200 and out["result"] == "valid"
    assert out["state"]["budget"]["check_probes"] == 1
    assert out["state"]["budget"]["est_tokens"] == 1
    assert client.post("/api/check", {"label": "team"})[1]["result"] == "invalid"
    assert client.post("/api/check", {"label": "spare"})[1]["result"] == "missing"
    account = [a for a in client.get("/api/state")[1]["accounts"] if a["label"] == "team"][0]
    assert account["check"]["result"] == "invalid" and account["check"]["at"] > 0


def test_fp_derives_duplicates(client):
    client.post("/api/refresh", {"all": True})
    code, out = client.post("/api/fp", {"label": "pro4"})
    assert code == 200
    assert out["fp"]["org"] == "org_4c1e"
    assert out["fp"]["dups"] == ["pro4b"]
    assert client.post("/api/fp", {"label": "spare"})[1]["error"]["code"] == "no_usage"


# ---------------------------------------------------------------- 전환·쓰기

def test_use_and_off(client, app):
    code, out = client.post("/api/use", {"label": "pro5"})
    assert code == 200
    assert out["hint"] == "열린 터미널은 cct refresh"
    assert out["state"]["status"]["active"] == "pro5"
    assert [a["active"] for a in out["state"]["accounts"] if a["label"] == "pro5"] == [True]
    # sticky 가 꺼진 clean env 로는 use 가 rc 1 이므로 이 호출만 CCT_STICKY=1 을 쓴다.
    assert calls_of(app, "use")[-1]["args"] == ["use", "pro5"]

    code, out = client.post("/api/off")
    assert code == 200
    assert out["state"]["status"]["active"] == "none"
    assert all(a["active"] is False for a in out["state"]["accounts"])


def test_use_without_token_fails(client):
    code, out = client.post("/api/use", {"label": "spare"})
    assert code == 409 and out["error"]["code"] == "cct_failed"
    assert "토큰 없음" in out["error"]["message"]


def test_rm_and_rename(client, app):
    client.post("/api/refresh", {"label": "pro5"})
    code, out = client.post("/api/rm", {"label": "pro5"}, WRITE)
    assert code == 200
    assert "pro5" not in [a["label"] for a in out["state"]["accounts"]]
    assert app.state.account("pro5") == {}          # 캐시된 usage 도 같이 지운다

    code, out = client.post("/api/rename", {"old": "pro4b", "new": "pro4c"}, WRITE)
    assert code == 200
    labels = [a["label"] for a in out["state"]["accounts"]]
    assert "pro4c" in labels and "pro4b" not in labels

    code, out = client.post("/api/rm", {"label": "nope"}, WRITE)
    assert code == 409 and out["error"]["code"] == "cct_failed"


def test_rename_keeps_cached_usage(client, app):
    client.post("/api/refresh", {"label": "gv"})
    client.post("/api/rename", {"old": "gv", "new": "gv2"}, WRITE)
    assert app.state.account("gv2")["usage"]["label"] == "gv2"
    assert app.state.account("gv") == {}


# ---------------------------------------------------------------- 설정·스케줄러

def test_settings_floor(client):
    code, out = client.post("/api/settings", {"auto_min": 5})
    assert code == 400 and out["error"]["code"] == "below_floor"
    code, out = client.post("/api/settings", {"auto_min": -1})
    assert code == 400 and out["error"]["code"] == "bad_request"
    code, out = client.post("/api/settings", {"auto_min": "30"})
    assert code == 400 and out["error"]["code"] == "bad_request"

    code, out = client.post("/api/settings", {"auto_min": 60})
    assert code == 200
    assert out["state"]["budget"]["auto_min"] == 60
    assert out["next_auto_at"] >= time.time() + 60 * 60 - 5

    code, out = client.post("/api/settings", {"auto_min": 0})
    assert code == 200 and out["state"]["budget"]["next_auto_at"] is None


def test_settings_persist_across_restart(client, app, tmp_path):
    client.post("/api/settings", {"auto_min": 15})
    reloaded = srv.State(app.state.path)
    assert reloaded.auto_min() == 15


def test_no_auto_probe_right_after_start(app):
    app.start_scheduler()
    time.sleep(0.25)
    assert used_cmds(app) == []
    assert app.next_auto_at >= app.started_at + srv.FLOOR_MIN * 60


def test_scheduler_fires_only_after_next_auto_at(app):
    app.next_auto_at = int(time.time()) - 1
    app.start_scheduler()
    deadline = time.time() + 5
    while time.time() < deadline and "usage" not in used_cmds(app):
        time.sleep(0.05)
    assert used_cmds(app).count("usage") == 6
    assert app.next_auto_at > time.time()


# ---------------------------------------------------------------- live·정적·오류

def test_live_whitelist(client):
    code, body = client.get("/api/live")
    assert code == 200
    raw = json.dumps(body, ensure_ascii=False)
    for forbidden in ("cwd", "workspace", "transcript_path", "session_id",
                      "scratchpad_dir", "session_name", "not-a-real-path"):
        assert forbidden not in raw
    assert body["model"] == "Opus 5"
    assert body["context_pct"] == 62
    assert body["cost_usd"] == 4.18
    assert body["five_hour"]["used_percentage"] == 6
    assert body["label_guess"] == "gv"
    assert body["stale"] is False


def test_live_missing_file_is_empty_object(tmp_path):
    live = srv.read_live(tmp_path / "없는파일.json")
    assert live["at"] is None and live["stale"] is True
    assert live["five_hour"] is None


def test_static_and_errors(client, app, tmp_path):
    code, out = client.get("/")
    assert code == 404 and out["error"]["code"] == "web_missing"
    web = Path(app.web_dir)
    web.mkdir(parents=True, exist_ok=True)
    (web / "index.html").write_text("<!doctype html><title>cct</title>", encoding="utf-8")
    code, _ = client.get("/")
    assert code == 200
    assert client.get("/api/nope")[1]["error"]["code"] == "not_found"
    assert client.post("/api/nope")[1]["error"]["code"] == "not_found"


def test_bad_json_body_does_not_echo_payload(client):
    request = urllib.request.Request(
        client.base + "/api/add", data=(b'{"token": "' + FAKE_TOKEN.encode() + b'"'),
        method="POST", headers={"Content-Type": "application/json", "X-CCT-Write": "1"})
    try:
        urllib.request.urlopen(request, timeout=10)
        raise AssertionError("400 이 와야 한다")
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8")
    assert json.loads(raw)["error"]["code"] == "bad_json"
    assert FAKE_TOKEN not in raw


# ---------------------------------------------------------------- 실경로 계약(프로세스 미실행)

def test_build_env_is_clean():
    cct = srv.Cct("/tmp/cct.sh", home="/tmp/fixture-home")
    env = cct.build_env()
    assert sorted(env) == ["CCT_STICKY", "HOME", "LC_ALL", "PATH", "TERM"]
    assert env["CCT_STICKY"] == "0" and env["LC_ALL"] == "C" and env["TERM"] == "dumb"
    assert env["PATH"].endswith("/tmp/fixture-home/.local/bin")   # cct check 가 claude 를 찾는 경로
    assert "CCT_STICKY" not in cct.build_env({"CCT_STICKY": None})
    assert cct.build_env({"CCT_STICKY": "1"})["CCT_STICKY"] == "1"


def test_real_add_uses_zsh_f_and_stdin_only(monkeypatch):
    seen = {}

    class Proc:
        returncode = 0
        stdout = "✓ [gv] 등록 완료\n"
        stderr = ""

    def fake_run(cmd, **kwargs):
        seen["cmd"] = cmd
        seen["kwargs"] = kwargs
        return Proc()

    monkeypatch.setattr(srv.subprocess, "run", fake_run)
    cct = srv.Cct("/tmp/cct.sh", home="/tmp/fixture-home")
    cct.add("gv", FAKE_TOKEN, overwrite=True)

    assert seen["cmd"][:4] == ["/bin/zsh", "-f", "-c", 'source "$1"; shift; cct "$@"']
    assert seen["cmd"][4:] == ["cct-dash", "/tmp/cct.sh", "add", "gv"]
    assert FAKE_TOKEN not in " ".join(seen["cmd"])          # argv 에 토큰 없음
    assert seen["kwargs"]["input"] == FAKE_TOKEN + "\ny\n"  # stdin 두 줄(덮어쓰기 y)
    assert "ANTHROPIC_BASE_URL" not in seen["kwargs"]["env"]
    assert seen["kwargs"]["timeout"] == srv.TIMEOUT_DEFAULT


def test_real_timeouts_and_sticky_override(monkeypatch):
    seen = []

    class Proc:
        returncode = 0
        stdout = ""
        stderr = ""

    monkeypatch.setattr(srv.subprocess, "run",
                        lambda cmd, **kw: (seen.append((cmd, kw)), Proc())[1])
    cct = srv.Cct("/tmp/cct.sh", home="/tmp/fixture-home")
    cct.usage("gv")
    cct.check("gv")
    cct.use("gv")
    assert seen[0][1]["timeout"] == srv.TIMEOUT_USAGE == 60
    assert seen[1][1]["timeout"] == srv.TIMEOUT_CHECK == 45
    assert seen[0][0][-3:] == ["usage", "--json", "gv"]
    # use 만 sticky 를 켠다(clean env 의 0 이면 cct use 가 rc 1).
    assert seen[2][1]["env"]["CCT_STICKY"] == "1"
    assert "CCT_STICKY" not in srv.Cct("/tmp/cct.sh").build_env({"CCT_STICKY": None})


def test_real_timeout_is_rc_124(monkeypatch):
    def boom(cmd, **kwargs):
        raise srv.subprocess.TimeoutExpired(cmd, kwargs.get("timeout", 1))

    monkeypatch.setattr(srv.subprocess, "run", boom)
    cct = srv.Cct("/tmp/cct.sh")
    result = cct.run(["status"])
    assert result.rc == 124 and "시간 초과" in result.err

