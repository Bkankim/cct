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
import hashlib
import json
import logging
import math
import mimetypes
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlsplit

VERSION = "0.4.0"

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

# 히스토리·알림·토큰 분석 (0.2.0)
HIST_RETAIN_DAYS = 90        # 사용률 히스토리 보관 일수
HIST_MAX_POINTS = 240        # /api/history 라벨당 최대 점 수(초과 시 버킷 평균)
ALERT_WARN_DEFAULT = 65      # 주의 임계(%) - 프론트 색 임계와 같은 기본값
ALERT_CRIT_DEFAULT = 90      # 위험 임계(%)
ALERT_EVENTS_MAX = 50        # 알림 이력 보관 수
NOTIFY_DEFAULT = "crit"      # macOS 알림 수준: off | crit | warn
NOTIFY_LEVELS = ("off", "crit", "warn")
ALERT_RANK = {"warn": 1, "crit": 2}
TOKENS_RESCAN_SEC = 600      # JSONL 재스캔 최소 간격(초)
TOKENS_DAYS_MAX = 120        # /api/tokens 조회 상한(일)
TOKENS_DAYS_DEFAULT = 30

TOKEN_RE = re.compile(r"sk-ant-[A-Za-z0-9_-]{8,}")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
LS_RE = re.compile(r"^\s*cct (\S+)(\s+\(비어있음\))?(\s+← 활성)?\s*$")
DOCTOR_RE = re.compile(r"^(PASS|WARN|FAIL) (.+)$")
LABEL_RE = re.compile(r"^[a-z0-9_]+$")
SESSION_RE = re.compile(r"^[A-Za-z0-9-]{1,80}$")

# cct 예약어(라벨로 쓸 수 없다). use 는 WP1 에서 추가되는 서브커맨드다.
RESERVED = {
    "help", "ls", "list", "add", "run", "rm", "rename", "status", "doctor",
    "check", "fp", "who", "usage", "off", "active", "refresh", "use",
}

# statusline 캐시에서 읽어도 되는 최상위 필드만(경로·세션 식별자 노출 금지, PLAN 2.3)
LIVE_KEYS = ("rate_limits", "model", "context_window", "cost", "version")

log = logging.getLogger("cct-dash")


def _load_providers_module():
    """providers.py 를 파일 경로로 로드한다.

    server.py 자체가 importlib 로 로드되는 테스트 환경에서도 sys.path 에
    의존하지 않도록 같은 방식으로 옆 파일을 읽는다. 이미 로드돼 있으면 재사용.
    """
    import importlib.util
    name = "cct_dash_providers"
    if name in sys.modules:
        return sys.modules[name]
    path = Path(__file__).resolve().parent / "providers.py"
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    sys.modules[name] = mod
    return mod


pv = _load_providers_module()


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


def alert_text(item: dict) -> str:
    """알림 센터·이력용 한 줄. 라벨·창·퍼센트만 담는다(토큰·경로 없음)."""
    label, win, level = item.get("label"), item.get("win"), item.get("level")
    if win == "probe":
        return "%s 프로브 실패 - 토큰 무효·만료 가능성" % label
    util = item.get("util")
    pct = ("%d%%" % round(util * 100)) if isinstance(util, (int, float)) else "-"
    if item.get("status") == "rejected":
        return "%s %s 창 차단(rejected) - 리셋까지 대기" % (label, win)
    kind = "위험" if level == "crit" else "주의"
    return "%s %s %s - %s 임계 초과" % (label, win, pct, kind)


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


# ---------------------------------------------------------------- 히스토리·토큰 저장소

# 모델 단가 (USD / MTok). 최장 프리픽스 매칭이라 파생 ID 를 포괄한다
# (claude-fable-5-1 -> claude-fable-5, claude-haiku-4-5-20251001 -> claude-haiku-4-5).
# 캐시 쓰기는 5m(1.25x input)/1h(2x input)를 분리 과금한다 - 실측상 cache write 의
# 85~100% 가 1h 라서 5m 단가 일괄 적용(ccusage/LiteLLM 방식)은 큰 과소평가가 된다.
# 단가표가 바뀌면 pricing_version 이 달라져 다음 스캔에서 전체 재집계된다.
# 출처: platform.claude.com pricing/models overview (2026-09-17 확인),
#       fable 5 는 anthropic.com 발표 페이지. opus-4-8 은 공시 미확인 - Opus 4 계열 추정.
PRICING: dict[str, dict[str, float]] = {
    "claude-opus-5": {"input": 5.0, "output": 25.0, "cache_write_5m": 6.25,
                      "cache_write_1h": 10.0, "cache_read": 0.5},
    "claude-fable-5": {"input": 10.0, "output": 50.0, "cache_write_5m": 12.5,
                       "cache_write_1h": 20.0, "cache_read": 1.0},
    "claude-sonnet-5": {"input": 2.0, "output": 10.0, "cache_write_5m": 2.5,
                        "cache_write_1h": 4.0, "cache_read": 0.2},
    "claude-haiku-4-5": {"input": 1.0, "output": 5.0, "cache_write_5m": 1.25,
                         "cache_write_1h": 2.0, "cache_read": 0.1},
    "claude-opus-4-8": {"input": 15.0, "output": 75.0, "cache_write_5m": 18.75,
                        "cache_write_1h": 30.0, "cache_read": 1.5},
}


TOKENS_SCHEMA = 2
ACCOUNT_BUCKET_SEC = 900       # 계정 상세 타임라인 막대 1칸(15분)
WINDOW_5H_SEC = 5 * 3600


def pricing_version() -> str:
    """단가표 지문. 값이 바뀌면 토큰 집계를 처음부터 다시 만든다."""
    # 스키마 버전도 섞는다 - 행 모양이 바뀌면(2: at·session·project 추가) 전체 재집계.
    payload = json.dumps({"pricing": PRICING, "schema": TOKENS_SCHEMA}, sort_keys=True)
    return hashlib.sha1(payload.encode("utf-8")).hexdigest()[:12]


def price_for(model: str) -> dict[str, float] | None:
    """모델 ID 에 맞는 단가를 찾는다(가장 긴 프리픽스 우선)."""
    best = None
    for prefix, price in PRICING.items():
        if model.startswith(prefix) and (best is None or len(prefix) > len(best[0])):
            best = (prefix, price)
    return best[1] if best else None


def entry_cost(model: str, tokens: dict[str, int], cost_usd: Any) -> float | None:
    """엔트리 1건의 비용(USD). 로그의 costUSD 를 우선하고, 없으면 단가표로 계산한다."""
    if isinstance(cost_usd, (int, float)) and not isinstance(cost_usd, bool):
        return float(cost_usd)
    price = price_for(model)
    if price is None:
        return None
    return (
        tokens.get("input", 0) * price.get("input", 0.0)
        + tokens.get("output", 0) * price.get("output", 0.0)
        + tokens.get("cache_5m", 0) * price.get("cache_write_5m", 0.0)
        + tokens.get("cache_1h", 0) * price.get("cache_write_1h", 0.0)
        + tokens.get("cache_read", 0) * price.get("cache_read", 0.0)
    ) / 1e6


class DashDB:
    """사용률 히스토리와 JSONL 토큰 집계 저장소(sqlite, 표준 라이브러리만).

    ":memory:" 는 연결마다 다른 DB 가 되므로 연결 1개를 락으로 감싸 공유한다.
    파일 DB 는 상태 파일과 같은 규칙으로 ~/.claude/ 아래(mode 600)에만 둔다.
    """

    def __init__(self, path: str | Path = ":memory:"):
        self.is_file = str(path) != ":memory:"
        self.path = str(Path(path).expanduser()) if self.is_file else ":memory:"
        self._lock = threading.RLock()
        if self.is_file:
            Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(self.path, check_same_thread=False)
        with self._lock, self.conn:
            if self.is_file:
                self.conn.execute("PRAGMA journal_mode=WAL")
            self.conn.execute(
                "CREATE TABLE IF NOT EXISTS history ("
                " at INTEGER NOT NULL, label TEXT NOT NULL, state TEXT,"
                " u5 REAL, u7 REAL, uf REAL, r5 INTEGER, r7 INTEGER, rf INTEGER,"
                " PRIMARY KEY (at, label))")
            self.conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_history_at ON history(at)")
            self.conn.execute(
                "CREATE TABLE IF NOT EXISTS tokens_files ("
                " path TEXT PRIMARY KEY, mtime INTEGER, size INTEGER)")
            self.conn.execute(
                "CREATE TABLE IF NOT EXISTS tokens_entries ("
                " uniq TEXT PRIMARY KEY, date TEXT NOT NULL, model TEXT NOT NULL,"
                " input INTEGER, output INTEGER, cache_5m INTEGER, cache_1h INTEGER,"
                " cache_read INTEGER, cost REAL)")
            cols = {r[1] for r in self.conn.execute("PRAGMA table_info(tokens_entries)")}
            for col, typ in (("at", "INTEGER"), ("session", "TEXT"), ("project", "TEXT")):
                if col not in cols:     # 0.3 이하 DB - 새 칸은 재집계(스키마 지문)로 채워진다
                    self.conn.execute("ALTER TABLE tokens_entries ADD COLUMN %s %s" % (col, typ))
            self.conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_tokens_date ON tokens_entries(date)")
            self.conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_tokens_session ON tokens_entries(session)")
            self.conn.execute(
                "CREATE TABLE IF NOT EXISTS limit_events ("
                " uniq TEXT PRIMARY KEY, at INTEGER, session TEXT, kind TEXT,"
                " resets_at INTEGER)")
            self.conn.execute(
                "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")
        if self.is_file:
            for suffix in ("", "-wal", "-shm"):
                try:
                    os.chmod(self.path + suffix, 0o600)
                except OSError:
                    pass

    def close(self) -> None:
        with self._lock:
            try:
                self.conn.close()
            except sqlite3.Error:
                pass

    # -- meta
    def meta_get(self, key: str) -> str | None:
        with self._lock:
            row = self.conn.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return row[0] if row else None

    def meta_set(self, key: str, value: str) -> None:
        with self._lock, self.conn:
            self.conn.execute(
                "INSERT INTO meta (key, value) VALUES (?, ?)"
                " ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, value))

    # -- 사용률 히스토리
    def record_usage(self, label: str, usage: dict, at: int | None = None) -> None:
        """프로브 1회의 창 사용률을 한 줄로 남긴다. 실패 프로브는 NULL 로 남아 공백이 된다."""
        at = at or now_i()
        windows = usage.get("windows") or {}

        def pick(key: str) -> tuple[float | None, int | None]:
            w = windows.get(key)
            if not isinstance(w, dict):
                return None, None
            util = w.get("utilization")
            reset = w.get("reset")
            return (
                float(util) if isinstance(util, (int, float)) else None,
                int(reset) if isinstance(reset, int) else None,
            )

        u5, r5 = pick("5h")
        u7, r7 = pick("7d")
        uf, rf = pick("7d_oi")
        with self._lock, self.conn:
            self.conn.execute(
                "INSERT OR REPLACE INTO history"
                " (at, label, state, u5, u7, uf, r5, r7, rf)"
                " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (at, label, usage.get("state"), u5, u7, uf, r5, r7, rf))
            self.conn.execute(
                "DELETE FROM history WHERE at < ?",
                (now_i() - HIST_RETAIN_DAYS * 86400,))

    def history_series(self, hours: int, max_points: int = HIST_MAX_POINTS) -> dict:
        """라벨별 [at, u5, u7, uf] 목록. 점이 많으면 버킷 평균으로 줄인다."""
        since = now_i() - hours * 3600
        bucket = max(1, (hours * 3600) // max_points)
        with self._lock:
            rows = self.conn.execute(
                "SELECT label, (at/?)*? AS b, AVG(u5), AVG(u7), AVG(uf)"
                " FROM history WHERE at >= ? GROUP BY label, b ORDER BY b",
                (bucket, bucket, since)).fetchall()
        series: dict[str, list] = {}
        for label, at, u5, u7, uf in rows:
            series.setdefault(label, []).append([int(at), u5, u7, uf])
        return series

    def label_history(self, label: str, since: int) -> list[tuple]:
        """계정 1개의 원본 프로브 행 (at, u5, u7, uf, r5) 시각순."""
        with self._lock:
            return self.conn.execute(
                "SELECT at, u5, u7, uf, r5 FROM history WHERE label=? AND at >= ?"
                " ORDER BY at", (label, since)).fetchall()

    def history_count(self) -> int:
        with self._lock:
            return int(self.conn.execute("SELECT COUNT(*) FROM history").fetchone()[0])

    # -- 토큰 집계
    def file_meta(self, path: str) -> tuple[int, int] | None:
        with self._lock:
            row = self.conn.execute(
                "SELECT mtime, size FROM tokens_files WHERE path=?", (path,)).fetchone()
        return (int(row[0]), int(row[1])) if row else None

    def set_file_meta(self, path: str, mtime: int, size: int) -> None:
        with self._lock, self.conn:
            self.conn.execute(
                "INSERT INTO tokens_files (path, mtime, size) VALUES (?, ?, ?)"
                " ON CONFLICT(path) DO UPDATE SET mtime=excluded.mtime, size=excluded.size",
                (path, mtime, size))

    def add_entries(self, rows: list[tuple]) -> None:
        """(uniq, date, model, input, output, cache_5m, cache_1h, cache_read, cost
        [, at, session, project]) 벌크 삽입. 뒤 3칸이 없는 행은 NULL 로 채운다.

        uniq PRIMARY KEY 라 재파싱·중복 라인은 INSERT OR IGNORE 로 자연히 걸러진다.
        """
        if not rows:
            return
        rows = [tuple(r) + (None,) * (12 - len(r)) for r in rows]
        with self._lock, self.conn:
            self.conn.executemany(
                "INSERT OR IGNORE INTO tokens_entries"
                " (uniq, date, model, input, output, cache_5m, cache_1h,"
                "  cache_read, cost, at, session, project)"
                " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", rows)

    def tokens_reset(self) -> None:
        """단가표가 바뀌었을 때 집계를 처음부터 다시 만들기 위해 비운다."""
        with self._lock, self.conn:
            self.conn.execute("DELETE FROM tokens_entries")
            self.conn.execute("DELETE FROM limit_events")
            self.conn.execute("DELETE FROM tokens_files")

    def tokens_count(self) -> int:
        with self._lock:
            return int(self.conn.execute("SELECT COUNT(*) FROM tokens_entries").fetchone()[0])

    def add_limit_events(self, rows: list[tuple]) -> None:
        """(uniq, at, session, kind, resets_at) - 한도 거절(rate_limit) 에러 줄."""
        if not rows:
            return
        with self._lock, self.conn:
            self.conn.executemany(
                "INSERT OR IGNORE INTO limit_events (uniq, at, session, kind, resets_at)"
                " VALUES (?, ?, ?, ?, ?)", rows)

    def session_limit_events(self, sessions: list[str], since: int) -> list[tuple]:
        if not sessions:
            return []
        marks = ",".join("?" * len(sessions))
        with self._lock:
            return self.conn.execute(
                "SELECT at, session, kind, resets_at FROM limit_events"
                " WHERE session IN (%s) AND at >= ? ORDER BY at" % marks,
                (*sessions, since)).fetchall()

    def session_entries(self, sessions: list[str], since: int) -> list[tuple]:
        """세션들의 메시지 행 (at, session, project, model, input, output, cache_5m,
        cache_1h, cache_read, cost) 을 시각순으로."""
        if not sessions:
            return []
        marks = ",".join("?" * len(sessions))
        with self._lock:
            return self.conn.execute(
                "SELECT at, session, project, model, input, output, cache_5m, cache_1h,"
                " cache_read, cost FROM tokens_entries"
                " WHERE session IN (%s) AND at >= ? ORDER BY at" % marks,
                (*sessions, since)).fetchall()

    def tokens_report(self, days: int) -> list[tuple]:
        """날짜 x 모델 집계 행. cost 합계와 '비용 미상' 엔트리 수를 함께 돌려준다."""
        since = time.strftime(
            "%Y-%m-%d", time.localtime(now_i() - (days - 1) * 86400))
        with self._lock:
            return self.conn.execute(
                "SELECT date, model, COUNT(*), SUM(input), SUM(output),"
                " SUM(cache_5m), SUM(cache_1h), SUM(cache_read), SUM(cost),"
                " SUM(CASE WHEN cost IS NULL THEN 1 ELSE 0 END)"
                " FROM tokens_entries WHERE date >= ?"
                " GROUP BY date, model ORDER BY date DESC, model", (since,)).fetchall()


def iso_epoch(ts: Any) -> int | None:
    """ISO 타임스탬프를 epoch 초로. 해석 불가면 None."""
    if not isinstance(ts, str) or len(ts) < 10:
        return None
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp())


def local_date(ts: Any) -> str | None:
    """ISO 타임스탬프를 로컬 타임존 날짜(YYYY-MM-DD)로. 해석 불가면 None."""
    if not isinstance(ts, str) or len(ts) < 10:
        return None
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return time.strftime("%Y-%m-%d", time.localtime(dt.timestamp()))


def limit_event(obj: dict, path: Path, lineno: int) -> tuple | None:
    """rate_limit 에러 줄을 (uniq, at, session, kind, resets_at) 로. 아니면 None."""
    if obj.get("error") != "rate_limit":
        return None
    at = iso_epoch(obj.get("timestamp"))
    sid = obj.get("sessionId")
    if at is None or not isinstance(sid, str) or not sid:
        return None
    quota = obj.get("quotaLimits") if isinstance(obj.get("quotaLimits"), dict) else {}
    kind = quota.get("rateLimitType")
    resets = quota.get("resetsAt")
    uuid = obj.get("uuid")
    uniq = uuid if isinstance(uuid, str) and uuid else "f:%s:%d" % (path.name, lineno)
    return (uniq, at, sid, kind if isinstance(kind, str) else None,
            resets if isinstance(resets, int) else None)


def parse_claude_jsonl(path: Path, events: list | None = None) -> list[tuple]:
    """Claude Code 세션 로그 한 파일에서 토큰 사용 엔트리만 뽑는다.

    메시지 본문은 읽는 즉시 버린다 - 반환 값에는 날짜·모델·토큰 수·비용만 담는다.
    중복 키는 message.id + requestId (ccusage 와 같은 규칙), 둘 다 없으면
    파일명+행번호+타임스탬프 해시로 대체한다(append-only 라 행번호가 안정적).
    """
    rows: list[tuple] = []
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return rows
    with fh:
        for lineno, line in enumerate(fh):
            # json.loads 전에 싼 문자열 검사로 사용량 없는 줄(user 등)을 걸러낸다.
            if ('"usage"' not in line and '"costUSD"' not in line
                    and (events is None or '"rate_limit"' not in line)):
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if not isinstance(obj, dict):
                continue
            if obj.get("isApiErrorMessage"):
                ev = limit_event(obj, path, lineno) if events is not None else None
                if ev:
                    events.append(ev)
                continue
            msg = obj.get("message")
            if not isinstance(msg, dict):
                continue
            usage = msg.get("usage")
            if not isinstance(usage, dict) or not usage:
                continue
            model = msg.get("model") or obj.get("model")
            if not isinstance(model, str) or not model or model == "<synthetic>":
                continue
            date = local_date(obj.get("timestamp"))
            if date is None:
                continue

            def tok(src: dict, key: str) -> int:
                value = src.get(key)
                return int(value) if isinstance(value, int) and value > 0 else 0

            # 캐시 쓰기는 5m/1h 단가가 달라 분해값을 쓴다. 분해가 없는(구버전) 로그는
            # ccusage 와 같은 방식으로 총량을 5m 으로 간주한다.
            breakdown = usage.get("cache_creation")
            if isinstance(breakdown, dict):
                cache_5m = tok(breakdown, "ephemeral_5m_input_tokens")
                cache_1h = tok(breakdown, "ephemeral_1h_input_tokens")
            else:
                cache_5m = tok(usage, "cache_creation_input_tokens")
                cache_1h = 0
            tokens = {
                "input": tok(usage, "input_tokens"),
                "output": tok(usage, "output_tokens"),
                "cache_5m": cache_5m,
                "cache_1h": cache_1h,
                "cache_read": tok(usage, "cache_read_input_tokens"),
            }
            if not any(tokens.values()):
                continue
            mid, rid = msg.get("id"), obj.get("requestId")
            if isinstance(mid, str) and mid and isinstance(rid, str) and rid:
                uniq = mid + ":" + rid
            else:
                seed = "%s:%d:%s" % (path.name, lineno, obj.get("timestamp"))
                uniq = "f:" + hashlib.sha1(seed.encode("utf-8")).hexdigest()
            cost = entry_cost(model, tokens, obj.get("costUSD"))
            sid = obj.get("sessionId")
            cwd = obj.get("cwd")
            rows.append((uniq, date, model, tokens["input"], tokens["output"],
                         tokens["cache_5m"], tokens["cache_1h"],
                         tokens["cache_read"], cost, iso_epoch(obj.get("timestamp")),
                         sid if isinstance(sid, str) and sid else None,
                         Path(cwd).name if isinstance(cwd, str) and cwd else None))
    return rows


def load_sessions(path: str | Path) -> dict[str, list[tuple[int, str]]]:
    """cct-session-hook.sh 기록을 세션ID -> [(시각, 라벨)] (시각순) 으로 읽는다.

    같은 세션을 다른 계정으로 이어 열면 줄이 더 붙는다 - 메시지는 자기 시각 이전의
    가장 최근 줄의 라벨로 귀속한다(label_at). 깨진 줄은 건너뛴다.
    """
    out: dict[str, list[tuple[int, str]]] = {}
    try:
        fh = open(Path(path).expanduser(), encoding="utf-8", errors="replace")
    except OSError:
        return out
    with fh:
        for line in fh:
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if not isinstance(obj, dict):
                continue
            ts, sid, label = obj.get("ts"), obj.get("session_id"), obj.get("label")
            if (isinstance(ts, int) and isinstance(sid, str) and sid
                    and isinstance(label, str) and LABEL_RE.match(label)):
                out.setdefault(sid, []).append((ts, label))
    for marks in out.values():
        marks.sort()
    return out


def label_at(marks: list[tuple[int, str]], at: int | None) -> str | None:
    """세션 기록 marks 기준으로 시각 at 의 메시지가 어느 라벨인지."""
    label = None
    for ts, lbl in marks:
        if at is not None and ts > at:
            break
        label = lbl
    return label if at is not None else None


def account_windows(history: list[tuple], msgs: list[dict], limits: list[dict],
                    now: int) -> list[dict]:
    """프로브 기록의 5h 초기화 시각(r5)으로 창을 나누고, 창마다 로컬 사용·한도 도달을 붙인다.

    도달 시각은 사용률이 처음 100% 로 찍힌 프로브와 첫 five_hour 한도 에러 중 이른 쪽.
    """
    wins: dict[int, dict] = {}
    for at, u5, _u7, _uf, r5 in history:
        if not isinstance(r5, int):
            continue
        w = wins.setdefault(r5, {"reset": r5, "start": r5 - WINDOW_5H_SEC,
                                 "active": r5 > now, "peak": 0.0, "hit_at": None,
                                 "requests": 0, "input": 0, "output": 0,
                                 "cache_create": 0, "cache_read": 0, "cost": 0.0,
                                 "sessions": 0})
        if isinstance(u5, (int, float)):
            w["peak"] = max(w["peak"], float(u5))
            if u5 >= 1.0 and w["hit_at"] is None:
                w["hit_at"] = at
    for w in wins.values():
        inside = [m for m in msgs if w["start"] <= m["at"] < w["reset"]]
        for m in inside:
            w["requests"] += 1
            for key in ("input", "output", "cache_create", "cache_read", "cost"):
                w[key] += m[key]
        w["sessions"] = len({m["session"] for m in inside})
        for ev in limits:
            if ev["kind"] == "five_hour" and w["start"] <= ev["at"] < w["reset"]:
                if w["hit_at"] is None or ev["at"] < w["hit_at"]:
                    w["hit_at"] = ev["at"]
                break
    return sorted(wins.values(), key=lambda w: -w["reset"])


def account_insights(windows: list[dict], summary: dict, history: list[tuple],
                     now: int, tracking_since: int | None = None) -> dict:
    """상세 화면 분석 카드용 추정치. 창의 external_pct 도 여기서 채운다.

    tokens_per_pct: 5h 1% 당 로컬 토큰. 외부 사용이 섞인 창은 비율이 낮아지므로
    로컬 사용이 있는 창 중 비율이 가장 높은(가장 순수한) 창을 기준으로 삼는다.
    """
    def wtokens(w: dict) -> int:
        return w["input"] + w["output"] + w["cache_create"] + w["cache_read"]

    ratios = [wtokens(w) / (w["peak"] * 100) for w in windows
              if w["requests"] and w["peak"] > 0]
    per_pct = max(ratios) if ratios else None
    for w in windows:
        local = wtokens(w) / per_pct if per_pct else 0.0
        if tracking_since is None or w["start"] < tracking_since:
            w["external_pct"] = None                 # 훅 기록 전 - 로컬 몫을 알 수 없다
        elif not w["requests"]:
            w["external_pct"] = w["peak"] * 100      # 로컬 사용이 없으면 전부 밖에서 쓴 것
        else:
            w["external_pct"] = max(0.0, w["peak"] * 100 - local) if per_pct else None
    closed = [w for w in windows if not w["active"] and w["external_pct"] is not None]
    peak_sum = sum(w["peak"] * 100 for w in closed)
    eta = None
    active = next((w for w in windows if w["active"]), None)
    if active:
        pts = [(at, u5) for at, u5, _u7, _uf, r5 in history
               if r5 == active["reset"] and isinstance(u5, (int, float))]
        if len(pts) >= 2 and pts[-1][1] > pts[-2][1] and pts[-1][1] < 1.0:
            (t1, u1), (t2, u2) = pts[-2], pts[-1]
            eta = int(t2 + (1.0 - u2) * (t2 - t1) / (u2 - u1))
            if eta >= active["reset"]:
                eta = None                  # 이 속도면 초기화 전에 안 닿는다
    fed = summary["input"] + summary["cache_create"] + summary["cache_read"]
    return {
        "tokens_per_pct": per_pct,
        "external_share": (sum(w["external_pct"] for w in closed) / peak_sum
                           if peak_sum else None),
        "eta_5h": eta,
        "cache_read_share": summary["cache_read"] / fed if fed else None,
        "limit_hits": sum(1 for w in windows if w["hit_at"] is not None),
    }


class TokenScanner:
    """~/.claude/projects JSONL 증분 스캐너. 백그라운드 스레드 1개로만 돈다.

    mtime+size 가 같은 파일은 건너뛰고, 바뀐 파일만 다시 파싱한다(uniq 로 dedup).
    실프로브·네트워크와 무관한 로컬 디스크 읽기라 프로브 예산을 쓰지 않는다.
    """

    def __init__(self, db: DashDB, root: str | Path, enabled: bool = True):
        self.db = db
        self.root = Path(root).expanduser()
        self.enabled = enabled
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None
        self.scanning = False
        self.progress = {"done": 0, "total": 0}
        self.error: str | None = None
        raw = db.meta_get("tokens_scanned_at")
        self.scanned_at: int | None = int(raw) if raw and raw.isdigit() else None
        if db.meta_get("pricing_version") != pricing_version():
            # 단가표가 바뀌면 저장된 cost 가 낡으므로 전체 재집계한다.
            db.tokens_reset()
            db.meta_set("pricing_version", pricing_version())
            self.scanned_at = None

    def stale(self) -> bool:
        return self.scanned_at is None or (now_i() - self.scanned_at) > TOKENS_RESCAN_SEC

    def kick(self, force: bool = False) -> bool:
        """스캔 스레드를 시작한다. 이미 도는 중이거나 최신이면 False."""
        if not self.enabled:
            return False
        with self._lock:
            if self.scanning or (not force and not self.stale()):
                return False
            self.scanning = True
            self.error = None
            self._thread = threading.Thread(
                target=self._scan, name="tokens-scan", daemon=True)
            self._thread.start()
            return True

    def _scan(self) -> None:
        try:
            try:
                files = sorted(self.root.rglob("*.jsonl"))
            except OSError:
                files = []
            self.progress = {"done": 0, "total": len(files)}
            for path in files:
                try:
                    st = path.stat()
                except OSError:
                    self.progress["done"] += 1
                    continue
                meta = (int(st.st_mtime), int(st.st_size))
                if self.db.file_meta(str(path)) != meta:
                    events: list[tuple] = []
                    self.db.add_entries(parse_claude_jsonl(path, events))
                    self.db.add_limit_events(events)
                    self.db.set_file_meta(str(path), *meta)
                self.progress["done"] += 1
            self.scanned_at = now_i()
            self.db.meta_set("tokens_scanned_at", str(self.scanned_at))
        except Exception as exc:                          # 스캐너는 죽지 않는다
            self.error = type(exc).__name__
            log.warning("토큰 스캔 실패: %s", type(exc).__name__)
        finally:
            self.scanning = False


def notify_macos(title: str, message: str) -> bool:
    """macOS 알림 센터로 보낸다. osascript 가 없거나 실패해도 동작에는 영향 없다."""
    exe = shutil.which("osascript")
    if not exe:
        return False
    script = "display notification %s with title %s" % (
        json.dumps(message, ensure_ascii=False), json.dumps(title, ensure_ascii=False))
    try:
        proc = subprocess.run([exe, "-e", script], capture_output=True, timeout=5)
        return proc.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


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
            "settings": {"auto_min": auto_min, "alert_warn": ALERT_WARN_DEFAULT,
                         "alert_crit": ALERT_CRIT_DEFAULT, "notify": NOTIFY_DEFAULT},
            "alerts": {"active": {}, "events": []},
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
                warn = raw["settings"].get("alert_warn")
                crit = raw["settings"].get("alert_crit")
                if (isinstance(warn, int) and isinstance(crit, int)
                        and 1 <= warn < crit <= 99):
                    self.data["settings"]["alert_warn"] = warn
                    self.data["settings"]["alert_crit"] = crit
                notify = raw["settings"].get("notify")
                if notify in NOTIFY_LEVELS:
                    self.data["settings"]["notify"] = notify
            if isinstance(raw.get("alerts"), dict):
                active = raw["alerts"].get("active")
                events = raw["alerts"].get("events")
                self.data["alerts"] = {
                    "active": active if isinstance(active, dict) else {},
                    "events": (events if isinstance(events, list) else [])[:ALERT_EVENTS_MAX],
                }
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

    def settings_view(self) -> dict:
        with self._lock:
            return dict(self.data["settings"])

    def set_setting(self, key: str, value: Any) -> None:
        with self._lock:
            self.data["settings"][key] = value

    def alert_conf(self) -> tuple[int, int, str]:
        with self._lock:
            s = self.data["settings"]
            return (s.get("alert_warn", ALERT_WARN_DEFAULT),
                    s.get("alert_crit", ALERT_CRIT_DEFAULT),
                    s.get("notify", NOTIFY_DEFAULT))

    # -- 알림
    def update_alerts(self, label: str, new: dict[str, dict]) -> tuple[list, list]:
        """라벨 하나의 활성 알림을 교체하고 (새로 발화, 해소) 목록을 돌려준다.

        같은 키가 같은 수준으로 계속 걸려 있으면 재발화하지 않는다(도배 방지).
        수준이 올라가면(warn -> crit) 다시 발화하고 since 는 유지한다.
        """
        now = now_i()
        fired: list[dict] = []
        cleared: list[dict] = []
        with self._lock:
            active = self.data["alerts"]["active"]
            old = {k: v for k, v in active.items()
                   if isinstance(v, dict) and v.get("label") == label}
            for key, item in new.items():
                prev = old.get(key)
                item = dict(item)
                item["since"] = prev.get("since", now) if isinstance(prev, dict) else now
                rank_new = ALERT_RANK.get(item.get("level"), 0)
                rank_old = ALERT_RANK.get(prev.get("level"), 0) if isinstance(prev, dict) else 0
                if rank_new > rank_old:
                    fired.append(dict(item))
                active[key] = item
            for key, prev in old.items():
                if key not in new:
                    active.pop(key, None)
                    cleared.append(dict(prev))
        return fired, cleared

    def add_alert_event(self, event: dict) -> None:
        with self._lock:
            self.data["alerts"]["events"].insert(0, event)
            del self.data["alerts"]["events"][ALERT_EVENTS_MAX:]

    def alerts_view(self, events_limit: int = 20) -> dict:
        with self._lock:
            active = [dict(v) for v in self.data["alerts"]["active"].values()
                      if isinstance(v, dict)]
            events = [dict(e) for e in self.data["alerts"]["events"][:events_limit]]
        active.sort(key=lambda x: (-ALERT_RANK.get(x.get("level"), 0),
                                   x.get("label") or "", x.get("win") or ""))
        return {"active": active, "events": events}

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
                 auto_tick: float = 5.0, db: DashDB | None = None,
                 scanner: TokenScanner | None = None, notifier=None,
                 providers=None, sessions_file: str | Path | None = None):
        self.cct = cct
        self.sessions_file = sessions_file     # cct-session-hook.sh 기록 (계정별 귀속)
        self.state = state
        self.providers = providers            # ProviderManager | None (GPT·Grok 사용량)
        self.db = db or DashDB()          # 기본은 프로세스 내 메모리 DB(테스트 친화)
        self.scanner = scanner
        self.notifier = notifier          # callable(title, message) - 실서버는 notify_macos
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
        if self.providers is not None:
            self.providers.close()
        self.db.close()

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
            "settings": self.state.settings_view(),
            "alerts": self.state.alerts_view(),
            "providers": self.providers.view() if self.providers is not None else [],
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
        self.db.record_usage(label, usage)
        self._update_alerts(label, usage)
        probe = usage.get("probe") or {}
        fallback = 1 if isinstance(probe, dict) and probe.get("fallback") else 0
        self.state.bump_usage(1, fallback)
        self.state.log_add(result.cmd, result.rc, result.ms)
        self._last_probe[label] = time.time()
        return usage

    # -- 임계치 알림
    @staticmethod
    def _notify_wanted(level: str | None, notify_lv: str) -> bool:
        if notify_lv == "off":
            return False
        if notify_lv == "crit":
            return level == "crit"
        return level in ("warn", "crit")   # notify_lv == "warn"

    def _update_alerts(self, label: str, usage: dict) -> None:
        """프로브 결과 하나로 그 라벨의 활성 알림을 다시 계산하고 교차 이벤트를 발화한다."""
        warn_at, crit_at, notify_lv = self.state.alert_conf()
        new: dict[str, dict] = {}
        if usage.get("state") in ("no_response", "parse_error"):
            new[label + "|probe"] = {"label": label, "win": "probe", "level": "crit",
                                     "util": None, "status": usage.get("state")}
        windows = usage.get("windows") or {}
        for win, key in (("5h", "5h"), ("7d", "7d"), ("7f", "7d_oi")):
            w = windows.get(key)
            if not isinstance(w, dict):
                continue
            util = w.get("utilization")
            status = w.get("status")
            level = None
            if status == "rejected":
                level = "crit"
            elif isinstance(util, (int, float)):
                if util * 100 >= crit_at:
                    level = "crit"
                elif util * 100 >= warn_at:
                    level = "warn"
            if level:
                new["%s|%s" % (label, win)] = {
                    "label": label, "win": win, "level": level,
                    "util": util if isinstance(util, (int, float)) else None,
                    "status": status,
                }
        fired, cleared = self.state.update_alerts(label, new)
        now = now_i()
        for item in cleared:
            self.state.add_alert_event({"at": now, "label": label,
                                        "win": item.get("win"), "level": "ok",
                                        "util": item.get("util")})
        for item in fired:
            self.state.add_alert_event({"at": now, "label": label,
                                        "win": item.get("win"),
                                        "level": item.get("level"),
                                        "util": item.get("util")})
            if self.notifier and self._notify_wanted(item.get("level"), notify_lv):
                try:
                    self.notifier("cct 대시보드", alert_text(item))
                except Exception:                     # 알림 실패는 기능에 영향 없다
                    log.warning("알림 발송 실패")

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
        """부분 갱신: auto_min / alert_warn / alert_crit / notify 중 온 것만 검증해 반영한다."""
        touched = False
        if "auto_min" in body:
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
            touched = True
        if "alert_warn" in body or "alert_crit" in body:
            cur_warn, cur_crit, _ = self.state.alert_conf()
            warn = body.get("alert_warn", cur_warn)
            crit = body.get("alert_crit", cur_crit)
            for name, v in (("alert_warn", warn), ("alert_crit", crit)):
                if isinstance(v, bool) or not isinstance(v, int):
                    return self._err(400, "bad_request", "%s 은 정수여야 합니다" % name)
            if not 1 <= warn < crit <= 99:
                return self._err(400, "bad_threshold",
                                 "임계는 1 <= 주의 < 위험 <= 99 여야 합니다")
            self.state.set_setting("alert_warn", warn)
            self.state.set_setting("alert_crit", crit)
            touched = True
        if "notify" in body:
            notify = body.get("notify")
            if notify not in NOTIFY_LEVELS:
                return self._err(400, "bad_request", "notify 는 off/crit/warn 중 하나입니다")
            self.state.set_setting("notify", notify)
            touched = True
        if not touched:
            return self._err(400, "bad_request", "변경할 설정이 없습니다")
        self.state.save()
        settings = self.state.settings_view()
        return self._ok({"settings": settings, "auto_min": settings.get("auto_min"),
                         "next_auto_at": self.next_auto_at})

    # -- 히스토리·토큰 분석 (프로브 0회 - 로컬 저장소만 읽는다)
    def api_history(self, query: dict) -> tuple[int, dict]:
        try:
            hours = int((query.get("hours") or ["24"])[0])
        except (TypeError, ValueError):
            return self._err(400, "bad_request", "hours 는 정수여야 합니다")
        hours = max(1, min(hours, HIST_RETAIN_DAYS * 24))
        return 200, {"ok": True, "hours": hours,
                     "series": self.db.history_series(hours)}

    def api_tokens(self, query: dict) -> tuple[int, dict]:
        try:
            days = int((query.get("days") or [str(TOKENS_DAYS_DEFAULT)])[0])
        except (TypeError, ValueError):
            return self._err(400, "bad_request", "days 는 정수여야 합니다")
        days = max(1, min(days, TOKENS_DAYS_MAX))
        if self.scanner is not None:
            self.scanner.kick()      # 낡았으면 백그라운드 재스캔(디스크 읽기만)
        return 200, self._tokens_payload(days)

    def api_account(self, query: dict) -> tuple[int, dict]:
        """계정 1개의 상세 - 세션 훅 기록으로 이 맥의 메시지를 그 계정에 귀속한다."""
        label = (query.get("label") or [""])[0]
        if not LABEL_RE.match(label):
            return self._err(400, "bad_label", "label 형식이 올바르지 않습니다")
        try:
            days = int((query.get("days") or ["7"])[0])
        except (TypeError, ValueError):
            return self._err(400, "bad_request", "days 는 정수여야 합니다")
        days = max(1, min(days, TOKENS_DAYS_MAX))
        session = (query.get("session") or [None])[0]
        if session is not None:
            if not SESSION_RE.match(session):
                return self._err(400, "bad_session", "session 형식이 올바르지 않습니다")
            return 200, self._session_requests(label, session, days)
        if self.scanner is not None:
            self.scanner.kick()
        return 200, self._account_payload(label, days)

    def _session_requests(self, label: str, session: str, days: int) -> dict:
        """세션 1개에서 이 계정에 귀속된 요청 목록(대화 내용 없이 토큰·비용만)."""
        marks = load_sessions(self.sessions_file) if self.sessions_file else {}
        reqs = []
        for (at, _sid, _project, model, i, o, c5m, c1h, cr,
             cost) in self.db.session_entries([session], now_i() - days * 86400):
            if session not in marks or label_at(marks[session], at) != label:
                continue
            reqs.append({"at": at, "model": model, "input": int(i or 0),
                         "output": int(o or 0), "cache_create": int(c5m or 0) + int(c1h or 0),
                         "cache_read": int(cr or 0), "cost": float(cost or 0.0)})
        return {"ok": True, "label": label, "session": session, "requests": reqs}

    def _account_payload(self, label: str, days: int) -> dict:
        since = now_i() - days * 86400
        marks = load_sessions(self.sessions_file) if self.sessions_file else {}
        mine = [sid for sid, m in marks.items() if any(lbl == label for _, lbl in m)]
        tracking_since = min((m[0][0] for m in marks.values() if m), default=None)
        msgs = []
        for (at, sid, project, model, i, o, c5m, c1h, cr,
             cost) in self.db.session_entries(mine, since):
            if label_at(marks[sid], at) != label:
                continue
            msgs.append({"at": at, "session": sid, "project": project or "-",
                         "model": model, "input": int(i or 0), "output": int(o or 0),
                         "cache_create": int(c5m or 0) + int(c1h or 0),
                         "cache_read": int(cr or 0), "cost": float(cost or 0.0)})

        def blank(**keys) -> dict:
            return dict(keys, requests=0, input=0, output=0, cache_create=0,
                        cache_read=0, cost=0.0)

        def bump(dst: dict, m: dict) -> None:
            dst["requests"] += 1
            for key in ("input", "output", "cache_create", "cache_read", "cost"):
                dst[key] += m[key]

        summary = blank()
        sessions: dict[str, dict] = {}
        models: dict[str, dict] = {}
        projects: dict[str, dict] = {}
        for m in msgs:
            bump(summary, m)
            s = sessions.setdefault(m["session"], blank(
                session=m["session"], project=m["project"], start=m["at"],
                end=m["at"], models={}, limit_errors=0))
            s["end"] = m["at"]
            s["models"][m["model"]] = s["models"].get(m["model"], 0) + 1
            bump(s, m)
            bump(models.setdefault(m["model"], blank(model=m["model"])), m)
            bump(projects.setdefault(m["project"], blank(project=m["project"])), m)
        summary["sessions"] = len(sessions)
        limits = []
        for at, sid, kind, resets in self.db.session_limit_events(mine, since):
            if label_at(marks[sid], at) != label:
                continue
            limits.append({"at": at, "session": sid, "kind": kind, "resets_at": resets})
            if sid in sessions:
                sessions[sid]["limit_errors"] += 1
        history = self.db.label_history(label, since)
        windows = account_windows(history, msgs, limits, now_i())
        buckets: dict[int, dict] = {}
        for m in msgs:
            at = m["at"] - m["at"] % ACCOUNT_BUCKET_SEC
            b = buckets.setdefault(at, {"at": at, "tokens": 0, "cost": 0.0, "models": {}})
            tokens = m["input"] + m["output"] + m["cache_create"] + m["cache_read"]
            b["tokens"] += tokens
            b["cost"] += m["cost"]
            b["models"][m["model"]] = b["models"].get(m["model"], 0) + tokens
        by_cost = lambda rows: sorted(rows, key=lambda x: -x["cost"])
        return {"ok": True, "label": label, "days": days, "summary": summary,
                "sessions": sorted(sessions.values(), key=lambda x: -x["start"]),
                "models": by_cost(models.values()),
                "projects": by_cost(projects.values()), "limits": limits,
                "history": [list(h) for h in history], "windows": windows,
                "insights": account_insights(windows, summary, history, now_i(),
                                             tracking_since),
                "tracking_since": tracking_since,
                "bucket_sec": ACCOUNT_BUCKET_SEC,
                "buckets": sorted(buckets.values(), key=lambda b: b["at"])}

    def api_tokens_scan(self) -> tuple[int, dict]:
        if self.scanner is None or not self.scanner.enabled:
            return self._err(409, "scan_disabled", "이 모드에서는 JSONL 스캔을 하지 않습니다")
        if self.scanner.scanning:
            return self._err(409, "busy", "이미 스캔이 진행 중입니다")
        started = self.scanner.kick(force=True)
        return 200, {"ok": True, "started": started,
                     "scanning": self.scanner.scanning}

    # -- 프로바이더(GPT·Grok) - 토큰 값은 어떤 응답·로그에도 싣지 않는다
    def _provider_err(self, exc) -> tuple[int, dict]:
        http = {"unknown_provider": 400, "not_connected": 400,
                "no_refresh": 401, "port_busy": 409}.get(exc.code, 502)
        return self._err(http, "provider_%s" % exc.code, exc.message)

    def _require_provider(self, body: dict) -> tuple[str | None, tuple | None]:
        pid = body.get("provider")
        if not isinstance(pid, str) or pid not in pv.PROVIDER_IDS:
            return None, self._err(400, "bad_provider", "provider 는 openai|xai 여야 합니다")
        return pid, None

    def api_providers_login(self, body: dict) -> tuple[int, dict]:
        if self.providers is None:
            return self._err(503, "providers_off", "프로바이더 추적이 꺼져 있습니다")
        pid, err = self._require_provider(body)
        if err:
            return err
        t0 = time.monotonic()
        try:
            out = self.providers.start_login(pid)
        except pv.ProviderError as exc:
            self.state.log_add("provider login %s" % pid, 1,
                               int((time.monotonic() - t0) * 1000))
            return self._provider_err(exc)
        self.state.log_add("provider login %s" % pid, 0,
                           int((time.monotonic() - t0) * 1000))
        return self._ok({"login": out})

    def api_providers_code(self, body: dict) -> tuple[int, dict]:
        """수동 코드 폴백 - 리다이렉트가 안 될 때 화면의 코드를 붙여넣는다. 코드 값은 로그에 남기지 않는다."""
        if self.providers is None:
            return self._err(503, "providers_off", "프로바이더 추적이 꺼져 있습니다")
        pid, err = self._require_provider(body)
        if err:
            return err
        code = body.get("code")
        if not isinstance(code, str) or not code.strip():
            return self._err(400, "bad_code", "code 가 비어 있습니다")
        try:
            self.providers.submit_code(pid, code)
        except pv.ProviderError as exc:
            self.state.log_add("provider code %s" % pid, 1, 0)
            return self._provider_err(exc)
        self.state.log_add("provider code %s" % pid, 0, 0)
        return self._ok()

    def api_providers_logout(self, body: dict) -> tuple[int, dict]:
        if self.providers is None:
            return self._err(503, "providers_off", "프로바이더 추적이 꺼져 있습니다")
        pid, err = self._require_provider(body)
        if err:
            return err
        try:
            self.providers.logout(pid)
        except pv.ProviderError as exc:
            return self._provider_err(exc)
        self.state.log_add("provider logout %s" % pid, 0, 0)
        return self._ok()

    def api_providers_refresh(self, body: dict) -> tuple[int, dict]:
        """연결된 프로바이더의 사용량 재조회. 메타데이터 GET 만이라 사용량을 소비하지 않는다."""
        if self.providers is None:
            return self._err(503, "providers_off", "프로바이더 추적이 꺼져 있습니다")
        pid = body.get("provider")
        if pid is not None and (not isinstance(pid, str) or pid not in pv.PROVIDER_IDS):
            return self._err(400, "bad_provider", "provider 는 openai|xai 여야 합니다")
        t0 = time.monotonic()
        try:
            self.providers.refresh_usage(pid, force=bool(body.get("force", True)))
        except pv.ProviderError as exc:
            self.state.log_add("provider usage %s" % (pid or "all"), 1,
                               int((time.monotonic() - t0) * 1000))
            return self._provider_err(exc)
        self.state.log_add("provider usage %s" % (pid or "all"), 0,
                           int((time.monotonic() - t0) * 1000))
        return self._ok()

    def _tokens_payload(self, days: int) -> dict:
        rows = self.db.tokens_report(days)
        days_map: dict[str, dict] = {}
        models: dict[str, dict] = {}
        total = {"entries": 0, "input": 0, "output": 0, "cache_create": 0,
                 "cache_read": 0, "cost": 0.0, "unknown": 0}

        def bump(dst: dict, row: dict) -> None:
            for key in ("entries", "input", "output", "cache_create", "cache_read",
                        "cost", "unknown"):
                dst[key] = dst.get(key, 0) + row[key]

        for date, model, entries, i, o, c5m, c1h, cr, cost, unknown in rows:
            # 표시 계약은 cache_create(쓰기 총량) 하나 - 5m/1h 는 과금에서만 갈린다.
            row = {"model": model, "entries": int(entries or 0), "input": int(i or 0),
                   "output": int(o or 0), "cache_create": int(c5m or 0) + int(c1h or 0),
                   "cache_read": int(cr or 0), "cost": float(cost or 0.0),
                   "unknown": int(unknown or 0)}
            day = days_map.setdefault(date, {"date": date, "entries": 0, "input": 0,
                                             "output": 0, "cache_create": 0,
                                             "cache_read": 0, "cost": 0.0, "unknown": 0,
                                             "models": []})
            bump(day, row)
            day["models"].append(row)
            m = models.setdefault(model, {"model": model, "entries": 0, "input": 0,
                                          "output": 0, "cache_create": 0,
                                          "cache_read": 0, "cost": 0.0, "unknown": 0})
            bump(m, row)
            bump(total, row)
        scanner = self.scanner
        # 픽스처 모드는 스캐너가 없다 - 재스캔 불가(enabled=False)로 알리되,
        # 시드가 meta 에 남긴 스캔 시각은 그대로 보여준다.
        scanned_at = scanner.scanned_at if scanner else None
        if scanned_at is None:
            raw = self.db.meta_get("tokens_scanned_at")
            scanned_at = int(raw) if raw and raw.isdigit() else None
        return {
            "ok": True,
            "days_window": days,
            "enabled": bool(scanner and scanner.enabled),
            "scanning": bool(scanner.scanning) if scanner else False,
            "scanned_at": scanned_at,
            "progress": dict(scanner.progress) if scanner else {"done": 0, "total": 0},
            "error": scanner.error if scanner else None,
            "days": sorted(days_map.values(), key=lambda d: d["date"], reverse=True),
            "models": sorted(models.values(), key=lambda m: -m["cost"]),
            "total": total,
        }



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
        url = urlsplit(self.path)
        path = url.path
        if path == "/api/state":
            code, payload = self.app.api_state()
            self._send(code, payload)
            return
        if path == "/api/live":
            code, payload = self.app.api_live()
            self._send(code, payload)
            return
        if path == "/api/history":
            code, payload = self.app.api_history(parse_qs(url.query))
            self._send(code, payload)
            return
        if path == "/api/account":
            code, payload = self.app.api_account(parse_qs(url.query))
            self._send(code, payload)
            return
        if path == "/api/tokens":
            code, payload = self.app.api_tokens(parse_qs(url.query))
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
            elif path == "/api/tokens/scan":
                code, payload = app.api_tokens_scan()
            elif path == "/api/providers/login":
                code, payload = app.api_providers_login(body)
            elif path == "/api/providers/code":
                code, payload = app.api_providers_code(body)
            elif path == "/api/providers/logout":
                code, payload = app.api_providers_logout(body)
            elif path == "/api/providers/refresh":
                code, payload = app.api_providers_refresh(body)
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

def seed_fake_db(db: DashDB, cct: "FakeCct") -> None:
    """픽스처 모드 렌더 검증용 합성 데이터(결정적 수식만, 실측 아님).

    히스토리는 비어 있을 때만 48시간치를 만들고, 토큰 집계는 매 기동마다
    다시 만들어 단가표 변경이 픽스처 화면에도 반영되게 한다.
    """
    now = now_i()
    if db.history_count() == 0:
        step, points = 1800, 96                      # 30분 간격 x 48시간
        for label in cct.order:
            obj = cct.usage_lines.get(label) or {}
            windows = obj.get("windows") or {}
            w5 = (windows.get("5h") or {}).get("utilization")
            w7 = (windows.get("7d") or {}).get("utilization")
            wf = (windows.get("7d_oi") or {}).get("utilization")
            if w5 is None and w7 is None:
                continue
            salt = (sum(ord(c) for c in label) % 7) / 10.0
            for i in range(points):
                at = now - (points - 1 - i) * step
                frac = i / (points - 1)
                u7 = None if w7 is None else max(0.0, min(1.0, (
                    w7 - (1 - frac) * 0.3 + 0.02 * math.sin(i / 4 + salt))))
                uf = None if wf is None else max(0.0, min(1.0, (
                    wf - (1 - frac) * 0.2 + 0.015 * math.sin(i / 5 + salt))))
                u5 = None if w5 is None else max(0.0, min(1.0, (
                    abs(math.sin(i / 9 + salt * 6)) * max(w5, 0.35))))
                db.record_usage(label, {"state": "ok", "windows": {
                    "5h": {"utilization": u5}, "7d": {"utilization": u7},
                    "7d_oi": {"utilization": uf}}}, at=at)
    db.tokens_reset()
    fake_models = [("claude-fable-5-20260301", 1.0), ("claude-haiku-4-5-20251001", 0.35)]
    rows = []
    for d in range(30):
        date = time.strftime("%Y-%m-%d", time.localtime(now - d * 86400))
        wave = 0.5 + 0.5 * abs(math.sin(d / 3.7))
        for model, scale in fake_models:
            base = int(2.2e6 * wave * scale)
            tokens = {"input": int(base * 0.04), "output": int(base * 0.02),
                      "cache_5m": int(base * 0.03), "cache_1h": int(base * 0.27),
                      "cache_read": base}
            rows.append(("fake:%s:%s" % (date, model), date, model,
                         tokens["input"], tokens["output"], tokens["cache_5m"],
                         tokens["cache_1h"], tokens["cache_read"],
                         entry_cost(model, tokens, None)))
    db.add_entries(rows)
    db.meta_set("tokens_scanned_at", str(now))


def build_parser() -> argparse.ArgumentParser:
    here = Path(__file__).resolve().parent
    p = argparse.ArgumentParser(description="cct 대시보드 서버")
    p.add_argument("--bind", default="127.0.0.1", help="바인드 주소 (기본 127.0.0.1)")
    p.add_argument("--port", type=int, default=8790, help="포트 (기본 8790)")
    p.add_argument("--web-dir", default=str(here / "web"), help="정적 파일 디렉터리")
    p.add_argument("--state-file", default=None,
                   help="상태 파일 (기본 ~/.claude/cct-dash-state.json, --fake 는 .fake.json)")
    p.add_argument("--db-file", default=None,
                   help="히스토리·토큰 DB (기본 ~/.claude/cct-dash-data.sqlite3,"
                        " --fake 는 .fake.sqlite3)")
    p.add_argument("--projects-dir", default=str(Path("~/.claude/projects").expanduser()),
                   help="Claude Code 세션 로그(JSONL) 루트")
    p.add_argument("--sessions-file",
                   default=str(Path("~/.claude/cct-sessions.jsonl").expanduser()),
                   help="cct-session-hook.sh 가 남기는 세션->라벨 기록 (계정별 상세)")
    p.add_argument("--no-tokens", action="store_true",
                   help="JSONL 토큰 스캔 비활성화")
    p.add_argument("--cct", default=str(Path("~/.claude/cct.sh").expanduser()),
                   help="cct.sh 경로 (기본 ~/.claude/cct.sh)")
    p.add_argument("--live-file", default=None,
                   help="statusline 캐시 (기본 ~/.claude/orca-usage-cache.json)")
    p.add_argument("--providers-file", default=pv.DEFAULT_STORE,
                   help="GPT·Grok 자격증명·사용량 캐시 (기본 %s)" % pv.DEFAULT_STORE)
    p.add_argument("--no-providers", action="store_true",
                   help="GPT·Grok 프로바이더 추적 비활성화")
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
        default_db = Path("~/.claude/cct-dash-data.fake.sqlite3").expanduser()
    else:
        cct = Cct(args.cct)
        default_state = Path("~/.claude/cct-dash-state.json").expanduser()
        default_live = Path("~/.claude/orca-usage-cache.json").expanduser()
        default_db = Path("~/.claude/cct-dash-data.sqlite3").expanduser()
        if not Path(args.cct).is_file():
            print("경고: cct.sh 가 없다 - %s" % args.cct, file=sys.stderr)

    state = State(args.state_file or default_state)
    db = DashDB(args.db_file or default_db)
    if args.fake:
        seed_fake_db(db, cct)            # type: ignore[arg-type]
        scanner = None                   # 픽스처 모드는 실로그를 읽지 않는다
        notifier = None                  # 알림도 이력에만 남긴다
        providers = None if args.no_providers else pv.FakeProviderManager(fixtures)
    else:
        scanner = None if args.no_tokens else TokenScanner(db, args.projects_dir)
        notifier = notify_macos
        providers = None if args.no_providers else \
            pv.ProviderManager(pv.ProviderStore(args.providers_file))
    app = App(
        cct=cct,
        state=state,
        web_dir=args.web_dir,
        live_file=args.live_file or default_live,
        bind=args.bind,
        port=args.port,
        db=db,
        scanner=scanner,
        notifier=notifier,
        providers=providers,
        sessions_file=None if args.fake else args.sessions_file,
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
