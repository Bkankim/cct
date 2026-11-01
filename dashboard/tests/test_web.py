"""app.js 계정 카드 렌더 테스트 - node vm 하네스로 브라우저 없이 돈다.

실행: cd ~/cct && uv run --with pytest pytest dashboard/tests -q
"""

from __future__ import annotations

import json
import shutil
import subprocess
import time
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
APP_JS = HERE.parent / "web" / "app.js"
HARNESS = HERE / "web_harness.js"

pytestmark = pytest.mark.skipif(shutil.which("node") is None, reason="node 없음")


def render_cards(tmp_path: Path, accounts: list[dict]) -> dict[str, str]:
    state = {"server": {}, "status": {}, "accounts": accounts, "settings": {}}
    p = tmp_path / "state.json"
    p.write_text(json.dumps(state), encoding="utf-8")
    r = subprocess.run(["node", str(HARNESS), str(APP_JS), str(p)],
                       capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)


def account(label: str, windows: dict) -> dict:
    now = int(time.time())
    return {"label": label, "has_token": True, "active": False, "default": False,
            "usage_at": now,
            "usage": {"label": label, "state": "ok", "org": "f0f0f0f0", "now": now,
                      "probe": {"denied": None}, "windows": windows}}


def test_card_shows_7d_rejected_when_5h_window_missing(tmp_path):
    # 주간 한도로 막힌 뒤 5h 창이 끝나면 API 가 5h 창을 아예 안 준다(2026-11-01 실측).
    # 이때도 7d 100% 와 차단 배지가 보여야 한다 - "미확인"으로 덮이면 안 된다.
    reset = int(time.time()) + 4 * 86400
    html = render_cards(tmp_path, [account("blocked", {
        "5h": None,
        "7d": {"utilization": 1.0, "reset": reset, "status": "rejected"},
        "7d_oi": None,
    })])["blocked"]
    assert "7d 차단" in html
    assert "100%" in html
    assert '<span class="badge">미확인</span>' not in html
    assert "아직 프로브하지 않았습니다" not in html
    assert "창 없음" in html            # 5h 칸만 사유 표시


def test_card_unprobed_when_no_windows(tmp_path):
    html = render_cards(tmp_path, [account("fresh", {"5h": None, "7d": None})])["fresh"]
    assert '<span class="badge">미확인</span>' in html
    assert "아직 프로브하지 않았습니다" in html
