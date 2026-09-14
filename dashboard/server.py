#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""cct 대시보드 백엔드 (WP2).

실행:
    uv run --script dashboard/server.py --bind 127.0.0.1 --port 8790
    uv run --script dashboard/server.py --fake --port 8799   # 픽스처 모드(실프로브 0회)

원칙(PLAN.md 6 양보 불가):
- 표준 라이브러리만 쓴다(의존성 0).
- 토큰 값은 응답·로그·예외 메시지·argv 어디에도 남기지 않는다. cct 로는 stdin 으로만 넘긴다.
- 127.0.0.1 바인드만 허용한다. 테일넷 노출은 tailscale serve 가 맡는다.
- 쓰기 엔드포인트(add/rm/rename)는 X-CCT-Write: 1 헤더가 없으면 403.
- 자동갱신 하한 15분은 서버가 강제한다. 기동 직후 자동 프로브는 하지 않는다.

HTTP 응답 형태(프론트 WP3 계약):
- 성공 2xx: {"ok": true, "state": {...PLAN 4.3 스키마...}, ...엔드포인트별 부가 필드}
- 실패 4xx/5xx: {"error": {"code": "<snake_case>", "message": "<한국어>"}}
"""

from __future__ import annotations

import argparse
import json
import logging
import mimetypes
import os
import re
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

VERSION = "0.1.0"

# 정책 상수
FLOOR_MIN = 15          # 자동갱신 하한(분). 서버가 강제한다.
DEFAULT_AUTO_MIN = 30   # 자동갱신 기본값(분)
COOLDOWN_SEC = 60       # 같은 라벨 재프로브 최소 간격(초)
LOG_MAX = 200           # 실행 로그 보관 수
LIVE_STALE_SEC = 600    # statusline 캐시가 이보다 오래되면 stale
SNAPSHOT_TTL = 5.0      # status/doctor/ls 오프라인 캐시(초)
MAX_BODY = 64 * 1024    # 요청 바디 상한
PROBE_WORKERS = 6       # usage 프로브 병렬도

# cct 호출 타임아웃(초)
TIMEOUT_USAGE = 60      # curl 25초 x 2 + 여유
TIMEOUT_CHECK = 45
TIMEOUT_DEFAULT = 15

# 프로브 1회 근사 토큰(프리미엄 max_tokens 32, 폴백 1)
TOK_PER_USAGE = 32
TOK_PER_FALLBACK = 1
TOK_PER_CHECK = 1

TOKEN_RE = re.compile(r"sk-ant-[A-Za-z0-9_-]{8,}")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
LS_RE = re.compile(r"^\s*cct (\S+)(\s+\(비어있음\))?(\s+← 활성)?\s*$")
DOCTOR_RE = re.compile(r"^(PASS|WARN|FAIL) (.+)$")
LABEL_RE = re.compile(r"^[a-z0-9_]+$")

# cct 예약어(라벨로 쓸 수 없다). use 는 WP1 에서 추가되는 서브커맨드다.
RESERVED = {
    "help", "ls", "list", "add", "run", "rm", "rename", "status", "doctor",
    "check", "fp", "who", "usage", "off", "active", "refresh", "use",
}

# statusline 캐시에서 읽어도 되는 최상위 필드만(경로·세션 식별자 노출 금지, PLAN 2.3)
LIVE_KEYS = ("rate_limits", "model", "context_window", "cost", "version")

log = logging.getLogger("cct-dash")


def mask(text: str) -> str:
    """토큰 형태 문자열을 가린다. 저장·로그·응답 직전에 항상 통과시킨다."""
    if not text:
        return ""
    return TOKEN_RE.sub("sk-ant-***", text)


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text or "")


def now_i() -> int:
    return int(time.time())


def today_str() -> str:
    return time.strftime("%Y-%m-%d", time.localtime())


def valid_label(label: Any) -> bool:
    return isinstance(label, str) and bool(LABEL_RE.match(label)) and label not in RESERVED


# ---------------------------------------------------------------- 파서

def parse_status(text: str) -> dict:
    """cct status 의 'key: value' 줄을 PLAN 4.3 status 객체로."""
    out: dict[str, Any] = {
        "wallet": None, "mode": None, "accounts": None, "active": None,
        "default": None, "sticky": None, "claude": None, "claude_version": None,
    }
    for line in strip_ansi(text).splitlines():
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        key = key.strip()
        value = value.strip()
        if key == "claude-version":
            key = "claude_version"
        if key not in out:
            continue
        if key == "accounts" and value.isdigit():
            out[key] = int(value)
        else:
            out[key] = value
    return out


def parse_doctor(text: str) -> list[dict]:
    """cct doctor 의 'PASS|WARN|FAIL <area>: <message>' 줄 목록."""
    items = []
    for line in strip_ansi(text).splitlines():
        m = DOCTOR_RE.match(line.strip())
        if m:
            items.append({"lv": m.group(1), "msg": m.group(2).strip()})
    return items


def parse_ls(text: str) -> list[dict]:
    """cct ls 의 비 TTY 출력을 [{label, has_token, active}] 로."""
    entries = []
    for line in strip_ansi(text).splitlines():
        m = LS_RE.match(line.rstrip())
        if not m:
            continue
        entries.append({
            "label": m.group(1),
            "has_token": m.group(2) is None,
            "active": m.group(3) is not None,
        })
    return entries


def parse_usage_line(text: str, label: str) -> dict:
    """cct usage --json 의 NDJSON 첫 줄을 파싱한다. 실패하면 state=parse_error."""
    for line in (text or "").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except (ValueError, TypeError):
            break
        if not isinstance(obj, dict):
            break
        obj.setdefault("label", label)
        obj.setdefault("state", "parse_error")
        obj.setdefault("org", None)
        obj.setdefault("now", now_i())
        obj.setdefault("probe", None)
        obj.setdefault("windows", None)
        return obj
    return {
        "label": label, "state": "parse_error", "org": None, "now": now_i(),
        "probe": None, "windows": None,
    }


def read_live(path: str | Path, fake: bool = False) -> dict:
    """statusline 캐시를 화이트리스트 필드만 읽는다(경로·세션 식별자 제외).

    파일이 없거나 깨졌으면 같은 키를 가진 빈 객체를 돌려준다(프론트 분기 단순화).
    """
    empty = {
        "at": None, "stale": True, "label_guess": None, "model": None,
        "context_pct": None, "cost_usd": None, "five_hour": None, "seven_day": None,
    }
    try:
        p = Path(path)
        raw = json.loads(p.read_text(encoding="utf-8"))
        mtime = int(p.stat().st_mtime)
    except (OSError, ValueError):
        return empty
    if not isinstance(raw, dict):
        return empty
    data = {k: raw.get(k) for k in LIVE_KEYS}
    rl = data.get("rate_limits") or {}
    if not isinstance(rl, dict):
        rl = {}
    delta = 0
    at = mtime
    if fake:
        # 픽스처 모드: 리셋 시각을 현재 시각 기준으로 옮겨 화면이 그럴듯하게 보이도록 한다.
        base = raw.get("_fixture_now")
        if isinstance(base, int) and base > 0:
            delta = now_i() - base
        at = now_i() - 40

    def window(key: str):
        w = rl.get(key)
        if not isinstance(w, dict):
            return None
        reset = w.get("resets_at")
        if isinstance(reset, int):
            reset += delta
        return {"used_percentage": w.get("used_percentage"), "resets_at": reset}

    model = data.get("model") if isinstance(data.get("model"), dict) else {}
    ctx = data.get("context_window") if isinstance(data.get("context_window"), dict) else {}
    cost = data.get("cost") if isinstance(data.get("cost"), dict) else {}
    return {
        "at": at,
        "stale": (now_i() - at) > LIVE_STALE_SEC,
        "label_guess": None,  # 호출자가 status.active 로 채운다
        "model": model.get("display_name"),
        "context_pct": ctx.get("used_percentage"),
        "cost_usd": cost.get("total_cost_usd"),
        "five_hour": window("five_hour"),
        "seven_day": window("seven_day"),
    }



# ---------------------------------------------------------------- cct 어댑터

class CctResult:
    """cct 한 번 실행의 결과. out/err 에는 이미 마스킹된 값만 담는다."""

    __slots__ = ("rc", "out", "err", "ms", "cmd")

    def __init__(self, rc: int, out: str, err: str, ms: int, cmd: str):
        self.rc = rc
        self.out = out
        self.err = err
        self.ms = ms
        self.cmd = cmd

    @property
    def message(self) -> str:
        """토스트용 한 줄. 이미 마스킹된 문자열이다."""
        body = (self.out or self.err or "").strip()
        return body.splitlines()[0] if body else ""


class Cct:
    """실제 cct 호출. zsh -f 로 rc 파일을 건너뛰고 cct.sh 를 명시 source 한다.

    zsh -l -c / zsh -i 는 .zshrc 를 읽지 않아 cct 함수가 없다(PLAN 8 함정).
    """

    def __init__(self, cct_path: str | Path, home: str | Path | None = None):
        self.cct_path = str(cct_path)
        self.home = str(home or Path.home())
        self.fake = False

    def base_env(self) -> dict:
        # 서버 자신의 env(특히 ANTHROPIC_*, CLAUDE_*)를 상속시키지 않는다.
        # ~/.local/bin 은 cct check 가 claude 바이너리를 찾는 데 필요하다.
        return {
            "HOME": self.home,
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin:" + self.home + "/.local/bin",
            "LC_ALL": "C",
            "TERM": "dumb",
            "CCT_STICKY": "0",
        }

    def build_env(self, env_extra: dict | None = None) -> dict:
        """clean env 에 호출별 덮어쓰기를 적용한다. 값이 None 이면 그 키를 뺀다."""
        env = self.base_env()
        for key, value in (env_extra or {}).items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = value
        return env

    def run(self, args: list[str], stdin_text: str | None = None,
            timeout: int = TIMEOUT_DEFAULT, env_extra: dict | None = None) -> CctResult:
        cmd = [
            "/bin/zsh", "-f", "-c", 'source "$1"; shift; cct "$@"', "cct-dash",
            self.cct_path, *args,
        ]
        env = self.build_env(env_extra)
        t0 = time.monotonic()
        try:
            proc = subprocess.run(
                cmd, env=env, input=stdin_text, capture_output=True,
                text=True, timeout=timeout,
            )
            rc, out, err = proc.returncode, proc.stdout, proc.stderr
        except subprocess.TimeoutExpired:
            rc, out, err = 124, "", "시간 초과 (%d초)" % timeout
        except OSError as exc:
            # 예외 문자열에 stdin(토큰)이 섞이지 않도록 종류만 남긴다.
            rc, out, err = 125, "", "실행 실패: %s" % type(exc).__name__
        ms = int((time.monotonic() - t0) * 1000)
        return CctResult(rc, mask(strip_ansi(out)), mask(strip_ansi(err)), ms,
                         mask("cct " + " ".join(args)))

    # -- 읽기(오프라인)
    def status(self) -> tuple[dict, CctResult]:
        # clean env 의 CCT_STICKY=0 을 그대로 두면 status 가 항상 sticky: disabled 로 보고된다.
        # 표시용 읽기에서는 키를 빼서 cct 기본값(enabled)을 그대로 읽는다.
        r = self.run(["status"], env_extra={"CCT_STICKY": None})
        return parse_status(r.out), r

    def doctor(self) -> tuple[dict, CctResult]:
        r = self.run(["doctor"], env_extra={"CCT_STICKY": None})
        return {"at": now_i(), "rc": r.rc, "items": parse_doctor(r.out)}, r

    def ls(self) -> tuple[list[dict], CctResult]:
        r = self.run(["ls"], env_extra={"CCT_STICKY": None})
        return parse_ls(r.out), r

    # -- 프로브(실호출, 사용량 소비)
    def usage(self, label: str) -> tuple[dict, CctResult]:
        r = self.run(["usage", "--json", label], timeout=TIMEOUT_USAGE)
        return parse_usage_line(r.out, label), r

    def check(self, label: str) -> tuple[str, CctResult]:
        r = self.run(["check", label], timeout=TIMEOUT_CHECK)
        result = {0: "valid", 1: "invalid", 2: "missing"}.get(r.rc, "unknown")
        return result, r

    # -- 전환·쓰기
    def use(self, label: str) -> CctResult:
        # base_env 의 CCT_STICKY=0 을 그대로 두면 WP1 계약상 use 가 rc 1 로 거부된다.
        # 활성 전환은 sticky 기록이 목적이므로 이 호출에서만 1 로 올린다.
        return self.run(["use", label], env_extra={"CCT_STICKY": "1"})

    def off(self) -> CctResult:
        return self.run(["off"])

    def add(self, label: str, token: str, overwrite: bool = False) -> CctResult:
        # 토큰은 stdin 으로만 넘긴다. argv 에는 라벨만 들어간다.
        # 덮어쓰기 확인 프롬프트는 두 번째 줄로 답해야 한다(첫 줄만 주면 EOF 로 취소).
        stdin_text = token + "\n" + ("y\n" if overwrite else "")
        return self.run(["add", label], stdin_text=stdin_text)

    def rm(self, label: str) -> CctResult:
        return self.run(["rm", label, "--force"])

    def rename(self, old: str, new: str) -> CctResult:
        return self.run(["rename", old, new])


class FakeCct(Cct):
    """픽스처 기반 가짜 cct. run() 만 갈아끼워 파서·상위 로직은 실경로와 같은 길을 탄다.

    실제 프로세스를 띄우지 않으므로 개발·테스트 중 실프로브가 0회로 유지된다.
    """

    def __init__(self, fixtures: str | Path, home: str | Path | None = None,
                 delay: float = 0.3, rebase: bool = True):
        super().__init__(cct_path=str(Path(fixtures)) + " (fake)", home=home)
        self.fake = True
        self.fixtures = Path(fixtures)
        self.delay = delay
        self.rebase = rebase
        self.calls: list[dict] = []   # 테스트 검증용 기록. 로그·응답으로는 나가지 않는다.
        self.lock = threading.RLock()
        self._load()

    def _load(self) -> None:
        wallet = json.loads((self.fixtures / "wallet.json").read_text(encoding="utf-8"))
        self.static = wallet["status"]
        self.active = wallet.get("active") or ""
        self.default = wallet.get("default") or ""
        self.fixture_now = int(wallet.get("fixture_now", 0))
        self.accounts: dict[str, dict] = {}
        self.order: list[str] = []
        for item in wallet["accounts"]:
            self.accounts[item["label"]] = {
                "has_token": bool(item.get("has_token", True)),
                "check_rc": int(item.get("check_rc", 0)),
            }
            self.order.append(item["label"])
        self.usage_lines: dict[str, dict] = {}
        raw = (self.fixtures / "usage.ndjson").read_text(encoding="utf-8")
        for line in raw.splitlines():
            line = line.strip()
            if line:
                obj = json.loads(line)
                self.usage_lines[obj["label"]] = obj
        self.doctor_lines = [
            l for l in (self.fixtures / "doctor.txt").read_text(encoding="utf-8").splitlines()
            if l.strip()
        ]

    # -- 출력 조립(실제 cct 출력 형식을 그대로 흉내낸다)
    def _status_text(self) -> str:
        lines = [
            "wallet: %s" % self.static["wallet"],
            "mode: %s" % self.static["mode"],
            "accounts: %d" % len(self.order),
            "active: %s" % (self.active if self.active else "none"),
            "default: %s" % self.default,
            "sticky: %s" % self.static["sticky"],
            "claude: %s" % self.static["claude"],
            "claude-version: %s" % self.static["claude_version"],
        ]
        return "\n".join(lines) + "\n"

    def _ls_text(self) -> str:
        out = []
        for label in self.order:
            line = "  cct " + label
            if not self.accounts[label]["has_token"]:
                line += "   (비어있음)"
            if label == self.active:
                line += "   ← 활성"
            out.append(line)
        if not out:
            return "  (등록된 계정 없음 - cct add <라벨>)\n"
        return "\n".join(out) + "\n"

    def _doctor_text(self) -> str:
        body = "\n".join(l.replace("{accounts}", str(len(self.order))) for l in self.doctor_lines)
        return body + "\n"

    def _usage_text(self, label: str) -> str:
        obj = self.usage_lines.get(label)
        if obj is None:
            obj = {"label": label, "state": "no_token", "org": None,
                   "now": self.fixture_now, "probe": None, "windows": None}
        obj = json.loads(json.dumps(obj))
        if not self.accounts.get(label, {}).get("has_token", False):
            obj.update({"state": "no_token", "org": None, "probe": None, "windows": None})
        delta = (now_i() - self.fixture_now) if (self.rebase and self.fixture_now) else 0
        obj["now"] = int(obj.get("now") or self.fixture_now) + delta
        windows = obj.get("windows")
        if isinstance(windows, dict) and delta:
            for w in windows.values():
                if isinstance(w, dict) and isinstance(w.get("reset"), int):
                    w["reset"] += delta
        return json.dumps(obj, ensure_ascii=False) + "\n"

    # -- 실행
    def run(self, args: list[str], stdin_text: str | None = None,
            timeout: int = TIMEOUT_DEFAULT, env_extra: dict | None = None) -> CctResult:
        t0 = time.monotonic()
        if self.delay:
            time.sleep(self.delay)
        with self.lock:
            self.calls.append({"args": list(args), "stdin": stdin_text})
            rc, out, err = self._dispatch(list(args), stdin_text)
        ms = int((time.monotonic() - t0) * 1000)
        return CctResult(rc, mask(strip_ansi(out)), mask(strip_ansi(err)), ms,
                         mask("cct " + " ".join(args)))

    def _dispatch(self, args: list[str], stdin_text: str | None) -> tuple[int, str, str]:
        if not args:
            return 2, "", "사용법: cct <라벨|서브커맨드>"
        cmd, rest = args[0], args[1:]
        if cmd == "status":
            return 0, self._status_text(), ""
        if cmd == "doctor":
            rc = 1 if any(l.startswith("FAIL") for l in self.doctor_lines) else 0
            return rc, self._doctor_text(), ""
        if cmd in ("ls", "list"):
            return 0, self._ls_text(), ""
        if cmd == "usage":
            labels = [a for a in rest if a != "--json"]
            if len(labels) > 1:
                return 2, "", "사용법: cct usage [--json] [라벨|--all]"
            if not labels or labels[0] == "--all":
                return 0, "".join(self._usage_text(l) for l in self.order), ""
            if not valid_label(labels[0]):
                return 2, "", "❌ 라벨 형식 오류"
            return 0, self._usage_text(labels[0]), ""
        if cmd == "check":
            if not rest:
                rc, body = 0, "전체 계정 토큰 점검 (실제 호출, 계정당 ~수초)…\n"
                for label in self.order:
                    one_rc, text, _ = self._check_one(label)
                    body += text
                    if one_rc != 0:
                        rc = 1
                return rc, body, ""
            return self._check_one(rest[0])
        if cmd == "use":
            return self._use(rest)
        if cmd == "off":
            self.active = ""
            return 0, "✓ 활성 프로필 해제 - 이후 cct <라벨> 로 다시 선택\n", ""
        if cmd == "add":
            return self._add(rest, stdin_text)
        if cmd == "rm":
            return self._rm(rest)
        if cmd == "rename":
            return self._rename(rest)
        return 2, "", "알 수 없는 명령"

    def _check_one(self, label: str) -> tuple[int, str, str]:
        if not valid_label(label):
            return 2, "", "❌ 라벨 형식 오류"
        acc = self.accounts.get(label)
        if acc is None or not acc["has_token"]:
            return 2, "  %s : ❓ 토큰 없음\n" % label, ""
        if acc["check_rc"] == 0:
            return 0, "  %s : ✅ 유효\n" % label, ""
        return 1, "  %s : ❌ 무효/실패 (재발급 필요할 수 있음)\n" % label, ""

    def _use(self, rest: list[str]) -> tuple[int, str, str]:
        if len(rest) != 1:
            return 2, "", "사용법: cct use <라벨>"
        label = rest[0]
        if not valid_label(label):
            return 2, "", "❌ 라벨 형식 오류"
        acc = self.accounts.get(label)
        if acc is None or not acc["has_token"]:
            return 1, "", "❌ '%s' 토큰 없음" % label
        self.active = label
        return 0, "✓ 활성 = %s (열린 다른 셸은 cct refresh)\n" % label, ""

    def _add(self, rest: list[str], stdin_text: str | None) -> tuple[int, str, str]:
        if len(rest) != 1:
            return 2, "", "사용법: cct add <라벨>"
        label = rest[0]
        if not valid_label(label):
            return 2, "", "❌ 라벨 형식 오류"
        lines = (stdin_text or "").split("\n")
        token = lines[0] if lines else ""
        if not token:
            return 1, "", "❌ 토큰이 비어 있음"
        if label in self.accounts and self.accounts[label]["has_token"]:
            answer = lines[1].strip().lower() if len(lines) > 1 else ""
            if answer != "y":
                return 1, "", "취소됨 (기존 토큰 유지)"
        self.accounts[label] = {"has_token": True, "check_rc": 0}
        if label not in self.order:
            self.order.append(label)
        self.usage_lines.pop(label, None)
        return 0, "✓ [%s] 등록 완료\n" % label, ""

    def _rm(self, rest: list[str]) -> tuple[int, str, str]:
        labels = [a for a in rest if a != "--force"]
        if len(labels) != 1:
            return 2, "", "사용법: cct rm <라벨> [--force]"
        label = labels[0]
        if label not in self.accounts:
            return 1, "", "❌ '%s' 계정 없음" % label
        self.accounts.pop(label)
        self.order.remove(label)
        self.usage_lines.pop(label, None)
        if self.active == label:
            self.active = ""
        return 0, "✓ [%s] 계정 삭제 완료\n" % label, ""

    def _rename(self, rest: list[str]) -> tuple[int, str, str]:
        if len(rest) != 2:
            return 2, "", "사용법: cct rename <기존> <새>"
        old, new = rest
        if not valid_label(old) or not valid_label(new):
            return 2, "", "❌ 라벨 형식 오류"
        if old not in self.accounts:
            return 1, "", "❌ '%s' 계정 없음" % old
        if new in self.accounts:
            return 1, "", "❌ '%s' 계정이 이미 존재" % new
        self.accounts[new] = self.accounts.pop(old)
        self.order[self.order.index(old)] = new
        if old in self.usage_lines:
            obj = self.usage_lines.pop(old)
            obj["label"] = new
            self.usage_lines[new] = obj
        if self.active == old:
            self.active = new
        if self.default == old:
            self.default = new
        return 0, "✓ [%s] -> [%s] 이름 변경 완료\n" % (old, new), ""



# ---------------------------------------------------------------- 영속 상태

class State:
    """대시보드 상태 파일(캐시·설정·예산·로그). 락으로 보호하고 원자적으로 저장한다.

    공개 리포 안(~/cct)에는 두지 않는다. 기본 경로는 ~/.claude/cct-dash-state.json (mode 600).
    """

    def __init__(self, path: str | Path, auto_min: int = DEFAULT_AUTO_MIN):
        self.path = Path(path).expanduser()
        self._lock = threading.RLock()
        self.data: dict[str, Any] = {
            "accounts": {},
            "settings": {"auto_min": auto_min},
            "budget": {"day": today_str(), "usage_probes": 0, "fallback_probes": 0,
                       "check_probes": 0},
            "log": [],
        }
        self.load()

    # -- 입출력
    def load(self) -> None:
        with self._lock:
            try:
                raw = json.loads(self.path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                return
            if not isinstance(raw, dict):
                return
            if isinstance(raw.get("accounts"), dict):
                self.data["accounts"] = raw["accounts"]
            if isinstance(raw.get("settings"), dict):
                auto = raw["settings"].get("auto_min")
                if isinstance(auto, int) and (auto == 0 or auto >= FLOOR_MIN):
                    self.data["settings"]["auto_min"] = auto
            if isinstance(raw.get("budget"), dict):
                budget = dict(self.data["budget"])
                budget.update({k: v for k, v in raw["budget"].items() if k in budget})
                self.data["budget"] = budget
            if isinstance(raw.get("log"), list):
                self.data["log"] = raw["log"][:LOG_MAX]
            self._roll_budget()

    def save(self) -> None:
        with self._lock:
            payload = json.dumps(self.data, ensure_ascii=False, indent=1)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_name(self.path.name + ".tmp.%d" % os.getpid())
        fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(mask(payload))
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(str(tmp), str(self.path))
            os.chmod(str(self.path), 0o600)
        finally:
            if tmp.exists():
                try:
                    tmp.unlink()
                except OSError:
                    pass

    # -- 계정
    def account(self, label: str) -> dict:
        with self._lock:
            return dict(self.data["accounts"].get(label) or {})

    def set_usage(self, label: str, usage: dict) -> None:
        with self._lock:
            acc = self.data["accounts"].setdefault(label, {})
            acc["usage"] = usage
            acc["usage_at"] = now_i()

    def set_check(self, label: str, result: str) -> None:
        with self._lock:
            acc = self.data["accounts"].setdefault(label, {})
            acc["check"] = {"result": result, "at": now_i()}

    def drop_account(self, label: str) -> None:
        with self._lock:
            self.data["accounts"].pop(label, None)

    def rename_account(self, old: str, new: str) -> None:
        with self._lock:
            acc = self.data["accounts"].pop(old, None)
            if acc is None:
                return
            usage = acc.get("usage")
            if isinstance(usage, dict):
                usage["label"] = new
            self.data["accounts"][new] = acc

    # -- 설정
    def auto_min(self) -> int:
        with self._lock:
            value = self.data["settings"].get("auto_min", DEFAULT_AUTO_MIN)
        return value if isinstance(value, int) else DEFAULT_AUTO_MIN

    def set_auto_min(self, value: int) -> None:
        with self._lock:
            self.data["settings"]["auto_min"] = value

    # -- 예산
    def _roll_budget(self) -> None:
        budget = self.data["budget"]
        if budget.get("day") != today_str():
            budget.update({"day": today_str(), "usage_probes": 0,
                           "fallback_probes": 0, "check_probes": 0})

    def bump_usage(self, probes: int = 1, fallbacks: int = 0) -> None:
        with self._lock:
            self._roll_budget()
            self.data["budget"]["usage_probes"] += probes
            self.data["budget"]["fallback_probes"] += fallbacks

    def bump_check(self, probes: int = 1) -> None:
        with self._lock:
            self._roll_budget()
            self.data["budget"]["check_probes"] += probes

    def budget_view(self, auto_min: int, next_auto_at: int | None) -> dict:
        with self._lock:
            self._roll_budget()
            b = self.data["budget"]
            est = (b["usage_probes"] * TOK_PER_USAGE
                   + b["fallback_probes"] * TOK_PER_FALLBACK
                   + b["check_probes"] * TOK_PER_CHECK)
            return {
                "day": b["day"],
                "usage_probes": b["usage_probes"],
                "check_probes": b["check_probes"],
                "est_tokens": est,
                "auto_min": auto_min,
                "floor_min": FLOOR_MIN,
                "next_auto_at": next_auto_at,
            }

    # -- 로그
    def log_add(self, cmd: str, rc: int, ms: int) -> None:
        with self._lock:
            self.data["log"].insert(0, {"at": now_i(), "cmd": mask(cmd), "rc": rc, "ms": ms})
            del self.data["log"][LOG_MAX:]

    def log_view(self, limit: int = 40) -> list:
        with self._lock:
            return [dict(x) for x in self.data["log"][:limit]]


# ---------------------------------------------------------------- 애플리케이션

class App:
    """HTTP 핸들러가 호출하는 상태·동작 계층. 각 api_* 는 (상태코드, 페이로드)를 돌려준다."""

    def __init__(self, cct: Cct, state: State, web_dir: str | Path,
                 live_file: str | Path, bind: str = "127.0.0.1", port: int = 8790,
                 auto_tick: float = 5.0):
        self.cct = cct
        self.state = state
        self.web_dir = Path(web_dir).expanduser()
        self.live_file = Path(live_file).expanduser()
        self.bind = bind
        self.port = port
        self.fake = bool(getattr(cct, "fake", False))
        self.started_at = now_i()
        self.refreshing = False
        self._refresh_lock = threading.Lock()
        self._snap_lock = threading.RLock()
        self._snap: tuple | None = None
        self._snap_at = 0.0
        self._last_probe: dict[str, float] = {}
        self._pool = ThreadPoolExecutor(max_workers=PROBE_WORKERS, thread_name_prefix="probe")
        self._stop = threading.Event()
        self._auto_tick = auto_tick
        self._sched: threading.Thread | None = None
        # 기동 직후 자동 프로브 금지: 첫 실행 시각은 최소 auto_min 뒤로 잡는다.
        self.next_auto_at = self._compute_next(self.started_at)

    # -- 수명주기
    def start_scheduler(self) -> None:
        if self._sched is not None:
            return
        self._sched = threading.Thread(target=self._sched_loop, name="auto-refresh", daemon=True)
        self._sched.start()

    def close(self) -> None:
        self._stop.set()
        self._pool.shutdown(wait=False, cancel_futures=True)

    def _compute_next(self, base: int) -> int | None:
        auto = self.state.auto_min()
        if not auto:
            return None
        return int(base + max(auto, FLOOR_MIN) * 60)

    def _sched_loop(self) -> None:
        # wait 가 먼저 오므로 기동 직후에는 어떤 프로브도 실행되지 않는다.
        while not self._stop.wait(self._auto_tick):
            nxt = self.next_auto_at
            if not nxt or time.time() < nxt:
                continue
            try:
                labels = [e["label"] for e in self.snapshot()[2] if e["has_token"]]
                self._run_refresh(labels)
            except Exception as exc:                      # 스케줄러는 죽지 않는다
                log.warning("자동갱신 실패: %s", type(exc).__name__)
            finally:
                self.next_auto_at = self._compute_next(now_i())

    # -- 읽기 스냅샷(status/doctor/ls, 5초 캐시)
    def snapshot(self, force: bool = False) -> tuple[dict, dict, list]:
        with self._snap_lock:
            fresh = self._snap is not None and (time.monotonic() - self._snap_at) < SNAPSHOT_TTL
            if fresh and not force:
                return self._snap
            status, r1 = self.cct.status()
            doctor, r2 = self.cct.doctor()
            entries, r3 = self.cct.ls()
            for r in (r1, r2, r3):
                if r.rc != 0:     # 정상 읽기는 로그를 채우지 않는다(30초 폴링이라 소음)
                    self.state.log_add(r.cmd, r.rc, r.ms)
            self._snap = (status, doctor, entries)
            self._snap_at = time.monotonic()
            return self._snap

    def invalidate(self) -> None:
        with self._snap_lock:
            self._snap = None
            self._snap_at = 0.0

    def labels(self) -> list[str]:
        return [e["label"] for e in self.snapshot()[2]]

    # -- 상태 조립(PLAN 4.3)
    def build_state(self) -> dict:
        status, doctor, entries = self.snapshot()
        active = status.get("active")
        if active in (None, "", "none", "invalid"):
            active = None
        accounts = []
        for e in entries:
            rec = self.state.account(e["label"])
            accounts.append({
                "label": e["label"],
                "has_token": e["has_token"],
                "active": bool(e["active"]) or e["label"] == active,
                "default": e["label"] == status.get("default"),
                "usage": rec.get("usage"),
                "usage_at": rec.get("usage_at"),
                "check": rec.get("check"),
            })
        live = read_live(self.live_file, fake=self.fake)
        live["label_guess"] = active
        auto = self.state.auto_min()
        return {
            "server": {
                "version": VERSION,
                "started_at": self.started_at,
                "bind": "%s:%d" % (self.bind, self.port),
                "fake": self.fake,
                "cct_path": self.cct.cct_path,
            },
            "status": status,
            "doctor": doctor,
            "accounts": accounts,
            "live": live,
            "budget": self.state.budget_view(auto, self.next_auto_at),
            "refreshing": self.refreshing,
            "log": self.state.log_view(),
        }

    # -- 공통 헬퍼
    def _ok(self, extra: dict | None = None) -> tuple[int, dict]:
        payload = {"ok": True, "state": self.build_state()}
        if extra:
            payload.update(extra)
        return 200, payload

    @staticmethod
    def _err(code: int, name: str, message: str) -> tuple[int, dict]:
        return code, {"error": {"code": name, "message": message}}

    def _cct_err(self, result: CctResult) -> tuple[int, dict]:
        if result.rc == 124:
            return self._err(504, "timeout", "cct 호출이 시간 내에 끝나지 않았습니다")
        if result.rc == 2:
            return self._err(400, "usage_error", result.message or "cct 사용법 오류")
        return self._err(409, "cct_failed", result.message or "cct 실행 실패 (rc=%d)" % result.rc)

    def _require_label(self, body: dict, key: str = "label") -> tuple[str | None, tuple | None]:
        label = body.get(key)
        if not isinstance(label, str) or not label.strip():
            return None, self._err(400, "bad_request", "라벨이 필요합니다")
        label = label.strip()
        if not valid_label(label):
            return None, self._err(400, "bad_label",
                                   "라벨은 [a-z0-9_] 형식이어야 하고 예약어일 수 없습니다")
        return label, None

    # -- 프로브
    def _probe_one(self, label: str) -> dict:
        usage, result = self.cct.usage(label)
        self.state.set_usage(label, usage)
        probe = usage.get("probe") or {}
        fallback = 1 if isinstance(probe, dict) and probe.get("fallback") else 0
        self.state.bump_usage(1, fallback)
        self.state.log_add(result.cmd, result.rc, result.ms)
        self._last_probe[label] = time.time()
        return usage

    def _run_refresh(self, labels: list[str]) -> tuple[int, dict]:
        if not self._refresh_lock.acquire(blocking=False):
            return self._err(409, "busy", "이미 갱신이 진행 중입니다")
        self.refreshing = True
        try:
            futures = {label: self._pool.submit(self._probe_one, label) for label in labels}
            done = []
            for label, fut in futures.items():
                try:
                    fut.result()
                    done.append(label)
                except Exception as exc:
                    log.warning("프로브 실패 %s: %s", label, type(exc).__name__)
                    self.state.log_add("cct usage --json %s" % label, 125, 0)
            self.state.save()
            return 200, {"refreshed": done}
        finally:
            self.refreshing = False
            self._refresh_lock.release()

    # -- API
    def api_state(self) -> tuple[int, dict]:
        return 200, self.build_state()

    def api_live(self) -> tuple[int, dict]:
        status = self.snapshot()[0]
        live = read_live(self.live_file, fake=self.fake)
        active = status.get("active")
        live["label_guess"] = None if active in (None, "", "none", "invalid") else active
        return 200, live

    def api_refresh(self, body: dict) -> tuple[int, dict]:
        entries = self.snapshot()[2]
        known = {e["label"]: e for e in entries}
        if body.get("all"):
            targets = [l for l, e in known.items() if e["has_token"]]
        else:
            label, err = self._require_label(body)
            if err:
                return err
            if label not in known:
                return self._err(404, "unknown_label", "'%s' 계정이 지갑에 없습니다" % label)
            if not known[label]["has_token"]:
                return self._err(409, "no_token", "'%s' 는 토큰이 비어 있습니다" % label)
            targets = [label]
        if not targets:
            return self._err(409, "no_token", "프로브할 계정이 없습니다")
        now = time.time()
        fresh = [l for l in targets if (now - self._last_probe.get(l, 0.0)) < COOLDOWN_SEC]
        targets = [l for l in targets if l not in fresh]
        if not targets:
            return self._err(429, "too_soon",
                             "최근 %d초 안에 프로브했습니다 (%s)" % (COOLDOWN_SEC, ", ".join(fresh)))
        code, payload = self._run_refresh(targets)
        if code != 200:
            return code, payload
        return self._ok({"refreshed": payload["refreshed"], "skipped": fresh})

    def api_check(self, body: dict) -> tuple[int, dict]:
        label, err = self._require_label(body)
        if err:
            return err
        if label not in self.labels():
            return self._err(404, "unknown_label", "'%s' 계정이 지갑에 없습니다" % label)
        result, r = self.cct.check(label)
        self.state.set_check(label, result)
        self.state.bump_check(1)
        self.state.log_add(r.cmd, r.rc, r.ms)
        self.state.save()
        return self._ok({"label": label, "result": result})

    def api_fp(self, body: dict) -> tuple[int, dict]:
        """지문은 usage 결과에서 파생한다(org + 7d reset 동일 = 같은 계정)."""
        label, err = self._require_label(body)
        if err:
            return err
        rec = self.state.account(label)
        usage = rec.get("usage") or {}
        if usage.get("state") != "ok":
            return self._err(409, "no_usage", "'%s' 의 usage 결과가 없습니다. 먼저 갱신하세요" % label)
        windows = usage.get("windows") or {}
        w7 = windows.get("7d") or {}
        org, reset = usage.get("org"), w7.get("reset")
        dups = []
        for other in self.labels():
            if other == label:
                continue
            u = (self.state.account(other).get("usage") or {})
            w = ((u.get("windows") or {}).get("7d") or {})
            if u.get("state") == "ok" and org and u.get("org") == org and w.get("reset") == reset:
                dups.append(other)
        return self._ok({"label": label,
                         "fp": {"org": org, "reset_7d": reset, "dups": dups}})

    def api_use(self, body: dict) -> tuple[int, dict]:
        label, err = self._require_label(body)
        if err:
            return err
        r = self.cct.use(label)
        self.state.log_add(r.cmd, r.rc, r.ms)
        self.state.save()
        self.invalidate()
        if r.rc != 0:
            return self._cct_err(r)
        return self._ok({"label": label, "message": r.message,
                         "hint": "열린 터미널은 cct refresh"})

    def api_off(self) -> tuple[int, dict]:
        r = self.cct.off()
        self.state.log_add(r.cmd, r.rc, r.ms)
        self.state.save()
        self.invalidate()
        if r.rc != 0:
            return self._cct_err(r)
        return self._ok({"message": r.message})

    def api_add(self, body: dict) -> tuple[int, dict]:
        """토큰은 stdin 으로만 넘긴다. 바디·토큰은 로그·응답·예외 어디에도 남기지 않는다."""
        label, err = self._require_label(body)
        if err:
            return err
        token = body.get("token")
        if not isinstance(token, str) or not token.strip():
            return self._err(400, "bad_request", "토큰이 비어 있습니다")
        overwrite = bool(body.get("overwrite"))
        r = self.cct.add(label, token, overwrite=overwrite)
        token = None
        body.pop("token", None)
        self.state.log_add("cct add %s (stdin 전달, 값 미기록)" % label, r.rc, r.ms)
        self.invalidate()
        if r.rc != 0:
            self.state.save()
            return self._cct_err(r)
        self.state.save()
        return self._ok({"label": label, "message": r.message})

    def api_rm(self, body: dict) -> tuple[int, dict]:
        label, err = self._require_label(body)
        if err:
            return err
        r = self.cct.rm(label)
        self.state.log_add(r.cmd, r.rc, r.ms)
        self.invalidate()
        if r.rc != 0:
            self.state.save()
            return self._cct_err(r)
        self.state.drop_account(label)
        self._last_probe.pop(label, None)
        self.state.save()
        return self._ok({"label": label, "message": r.message})

    def api_rename(self, body: dict) -> tuple[int, dict]:
        old, err = self._require_label(body, "old")
        if err:
            return err
        new, err = self._require_label(body, "new")
        if err:
            return err
        r = self.cct.rename(old, new)
        self.state.log_add(r.cmd, r.rc, r.ms)
        self.invalidate()
        if r.rc != 0:
            self.state.save()
            return self._cct_err(r)
        self.state.rename_account(old, new)
        if old in self._last_probe:
            self._last_probe[new] = self._last_probe.pop(old)
        self.state.save()
        return self._ok({"old": old, "new": new, "message": r.message})

    def api_settings(self, body: dict) -> tuple[int, dict]:
        value = body.get("auto_min")
        if isinstance(value, bool) or not isinstance(value, int):
            return self._err(400, "bad_request", "auto_min 은 정수여야 합니다")
        if value < 0:
            return self._err(400, "bad_request", "auto_min 은 0 이상이어야 합니다")
        if 0 < value < FLOOR_MIN:
            # 하한은 서버가 강제한다(클라이언트 값 불신).
            return self._err(400, "below_floor",
                             "자동갱신 하한은 %d분입니다 (프로브가 사용량을 소비)" % FLOOR_MIN)
        self.state.set_auto_min(value)
        self.next_auto_at = self._compute_next(now_i())
        self.state.save()
        return self._ok({"auto_min": value, "next_auto_at": self.next_auto_at})



# ---------------------------------------------------------------- HTTP

WRITE_PATHS = {"/api/add", "/api/rm", "/api/rename"}   # X-CCT-Write: 1 필요

STATIC_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".ico": "image/x-icon",
    ".woff2": "font/woff2",
}


def resolve_static(base: Path, path: str) -> tuple[Path | None, str | None]:
    """요청 경로를 web 디렉터리 안의 실제 파일로 해석한다.

    상위 디렉터리 탈출은 차단하고 (None, "forbidden") 을 돌려준다.
    """
    rel = path.lstrip("/") or "index.html"
    if rel.endswith("/"):
        rel += "index.html"
    base_resolved = base.resolve()
    target = (base_resolved / rel).resolve()
    if target != base_resolved and base_resolved not in target.parents:
        return None, "forbidden"
    if not target.is_file():
        return None, "not_found"
    return target, None


class Handler(BaseHTTPRequestHandler):
    server_version = "cct-dash/" + VERSION
    sys_version = ""
    protocol_version = "HTTP/1.1"

    @property
    def app(self) -> App:
        return self.server.app          # type: ignore[attr-defined]

    # 요청 바디는 어떤 경우에도 로깅하지 않는다. 메서드·경로·상태만 남긴다.
    def log_message(self, fmt: str, *args) -> None:
        log.info("%s %s", self.address_string(), mask(fmt % args))

    def log_error(self, fmt: str, *args) -> None:
        log.warning("%s %s", self.address_string(), mask(fmt % args))

    def _send(self, code: int, payload: Any = None, body: bytes | None = None,
              ctype: str = "application/json; charset=utf-8") -> None:
        if body is None:
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _error(self, code: int, name: str, message: str) -> None:
        self._send(code, {"error": {"code": name, "message": message}})

    def _read_body(self) -> dict | None:
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self._error(400, "bad_request", "Content-Length 가 올바르지 않습니다")
            return None
        if length > MAX_BODY:
            self._error(413, "too_large", "요청 바디가 너무 큽니다")
            return None
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            # 파싱 실패해도 바디 내용은 메시지에 싣지 않는다(토큰 유출 차단).
            self._error(400, "bad_json", "JSON 본문을 해석할 수 없습니다")
            return None
        finally:
            del raw
        if not isinstance(data, dict):
            self._error(400, "bad_request", "JSON 객체가 필요합니다")
            return None
        return data

    # -- 정적 파일(web/ 아래만)
    def _serve_static(self, path: str) -> None:
        base = self.app.web_dir
        if not base.is_dir():
            self._error(404, "web_missing",
                        "web 디렉터리가 아직 없습니다 (WP3 프론트 미배치): %s" % base)
            return
        target, why = resolve_static(base, path)
        if why == "forbidden":
            self._error(403, "forbidden", "허용되지 않은 경로입니다")
            return
        if target is None:
            self._error(404, "not_found", "파일이 없습니다")
            return
        ctype = STATIC_TYPES.get(target.suffix.lower())
        if ctype is None:
            ctype = mimetypes.guess_type(str(target))[0] or "application/octet-stream"
        try:
            body = target.read_bytes()
        except OSError:
            self._error(500, "read_failed", "파일을 읽지 못했습니다")
            return
        self._send(200, body=body, ctype=ctype)

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
        if path == "/api/state":
            code, payload = self.app.api_state()
            self._send(code, payload)
            return
        if path == "/api/live":
            code, payload = self.app.api_live()
            self._send(code, payload)
            return
        if path.startswith("/api/"):
            self._error(404, "not_found", "없는 엔드포인트입니다")
            return
        self._serve_static(path)

    def do_HEAD(self) -> None:
        self.do_GET()

    def do_POST(self) -> None:
        path = self.path.split("?", 1)[0]
        if not path.startswith("/api/"):
            self._error(404, "not_found", "없는 엔드포인트입니다")
            return
        if path in WRITE_PATHS and self.headers.get("X-CCT-Write") != "1":
            self._error(403, "write_disabled",
                        "쓰기 모드가 꺼져 있습니다 (X-CCT-Write: 1 필요)")
            return
        body = self._read_body()
        if body is None:
            return
        app = self.app
        try:
            if path == "/api/refresh":
                code, payload = app.api_refresh(body)
            elif path == "/api/check":
                code, payload = app.api_check(body)
            elif path == "/api/fp":
                code, payload = app.api_fp(body)
            elif path == "/api/use":
                code, payload = app.api_use(body)
            elif path == "/api/off":
                code, payload = app.api_off()
            elif path == "/api/add":
                code, payload = app.api_add(body)
            elif path == "/api/rm":
                code, payload = app.api_rm(body)
            elif path == "/api/rename":
                code, payload = app.api_rename(body)
            elif path == "/api/settings":
                code, payload = app.api_settings(body)
            else:
                self._error(404, "not_found", "없는 엔드포인트입니다")
                return
        except Exception as exc:
            # 예외 문자열에 요청 바디가 섞이지 않도록 종류만 남긴다.
            log.exception("핸들러 예외: %s", type(exc).__name__)
            self._error(500, "internal", "서버 내부 오류: %s" % type(exc).__name__)
            return
        finally:
            body = None
        self._send(code, payload)


class DashServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    app: App


def make_server(bind: str, port: int, app: App) -> DashServer:
    httpd = DashServer((bind, port), Handler)
    httpd.app = app
    app.bind = bind
    app.port = httpd.server_address[1]
    return httpd


# ---------------------------------------------------------------- 진입점

def build_parser() -> argparse.ArgumentParser:
    here = Path(__file__).resolve().parent
    p = argparse.ArgumentParser(description="cct 대시보드 서버")
    p.add_argument("--bind", default="127.0.0.1", help="바인드 주소 (기본 127.0.0.1)")
    p.add_argument("--port", type=int, default=8790, help="포트 (기본 8790)")
    p.add_argument("--web-dir", default=str(here / "web"), help="정적 파일 디렉터리")
    p.add_argument("--state-file", default=None,
                   help="상태 파일 (기본 ~/.claude/cct-dash-state.json, --fake 는 .fake.json)")
    p.add_argument("--cct", default=str(Path("~/.claude/cct.sh").expanduser()),
                   help="cct.sh 경로 (기본 ~/.claude/cct.sh)")
    p.add_argument("--live-file", default=None,
                   help="statusline 캐시 (기본 ~/.claude/orca-usage-cache.json)")
    p.add_argument("--fake", action="store_true",
                   help="cct 호출을 픽스처로 대체 (실프로브 0회)")
    p.add_argument("--fixtures", default=str(here / "tests" / "fixtures"),
                   help="--fake 픽스처 디렉터리")
    p.add_argument("--fake-delay", type=float, default=0.3, help="--fake 응답 지연(초)")
    p.add_argument("--log-level", default="info",
                   choices=["debug", "info", "warning", "error"])
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(
        level=getattr(logging, args.log_level.upper()),
        format="%(asctime)s %(levelname)s %(message)s",
    )

    # 바인드 가드: 0.0.0.0 금지. 테일넷 노출은 tailscale serve 가 맡는다.
    if args.bind in ("0.0.0.0", "::", ""):
        print("거부: 서버는 127.0.0.1 에만 바인드한다 (테일넷 노출은 tailscale serve)",
              file=sys.stderr)
        return 2
    if args.bind not in ("127.0.0.1", "localhost", "::1"):
        print("경고: 127.0.0.1 이 아닌 주소에 바인드한다 - %s" % args.bind, file=sys.stderr)

    fixtures = Path(args.fixtures)
    if args.fake:
        cct: Cct = FakeCct(fixtures, delay=args.fake_delay)
        default_state = Path("~/.claude/cct-dash-state.fake.json").expanduser()
        default_live = fixtures / "orca-usage-cache.json"
    else:
        cct = Cct(args.cct)
        default_state = Path("~/.claude/cct-dash-state.json").expanduser()
        default_live = Path("~/.claude/orca-usage-cache.json").expanduser()
        if not Path(args.cct).is_file():
            print("경고: cct.sh 가 없다 - %s" % args.cct, file=sys.stderr)

    state = State(args.state_file or default_state)
    app = App(
        cct=cct,
        state=state,
        web_dir=args.web_dir,
        live_file=args.live_file or default_live,
        bind=args.bind,
        port=args.port,
    )
    httpd = make_server(args.bind, args.port, app)
    state.log_add("server start %s:%d%s" % (args.bind, app.port,
                                            " (fake)" if args.fake else ""), 0, 0)
    state.save()
    app.start_scheduler()
    print("cct 대시보드 http://%s:%d/  fake=%s  state=%s  자동갱신=%s분"
          % (args.bind, app.port, args.fake, state.path, state.auto_min()), file=sys.stderr)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        app.close()
        httpd.server_close()
        state.save()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
