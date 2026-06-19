# Claude Code 계정 스위칭 런처 (cct) — .env 방식 · bash/zsh · macOS/WSL2 공용
#   cct                → 현재 인증된 프로필로 실행 (claude --dangerously-skip-permissions)
#   cct <라벨>         → CCT_TOKEN_<라벨> 토큰 주입해 실행        (예: cct gv / cct pro1)
#   cct ls             → 등록된 계정 목록 (값 미표시)
#   cct add <라벨>     → 토큰 등록/갱신 (화면 미표시 입력)
#   cct check [라벨]   → 토큰 유효성 점검 (실제 호출). 라벨 없으면 전체
#   cct help           → 도움말
# (cc / ㅊㅊ 는 별도 alias = 그냥 claude. cct 와 충돌하지 않음)

CCT_ENV_FILE="${CCT_ENV_FILE:-$HOME/.claude/tokens.env}"
CCT_PROBE_MODEL="${CCT_PROBE_MODEL:-claude-haiku-4-5-20251001}"

# 라벨 → 키 (대문자 + 영숫자/언더스코어만)
_cct_key() { printf 'CCT_TOKEN_%s' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9_')"; }

# tokens.env 에서 KEY 값만 안전 추출 (source 안 함, CRLF·따옴표 제거)
_cct_envtok() {
  [ -f "$CCT_ENV_FILE" ] || return 1
  grep -E "^$1=" "$CCT_ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\"'\r"
}

# 등록된 라벨(소문자) 한 줄씩
_cct_labels() {
  [ -f "$CCT_ENV_FILE" ] || return 0
  grep -oE '^CCT_TOKEN_[A-Za-z0-9_]+=' "$CCT_ENV_FILE" 2>/dev/null | sed 's/^CCT_TOKEN_//;s/=$//' | tr '[:upper:]' '[:lower:]'
}

_cct_list() {
  local labels lc v
  labels="$(_cct_labels)"
  [ -n "$labels" ] || { echo "  (등록된 계정 없음 — cct add <라벨>)"; return; }
  printf '%s\n' "$labels" | while IFS= read -r lc; do
    [ -n "$lc" ] || continue
    v="$(_cct_envtok "$(_cct_key "$lc")")"
    [ -n "$v" ] && echo "  cct $lc" || echo "  cct $lc   (비어있음)"
  done
}

# 시간제한 실행 (timeout > gtimeout > perl > 무제한)
_cct_run_limited() {
  local secs="$1"; shift
  if   command -v timeout  >/dev/null 2>&1; then timeout  "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  elif command -v perl     >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
  else "$@"; fi
}

_cct_check_one() {  # $1 = 라벨
  local tok; tok="$(_cct_envtok "$(_cct_key "$1")")"
  if [ -z "$tok" ]; then echo "  $1 : ❓ 토큰 없음"; return 2; fi
  # </dev/null 필수: 전체 점검 루프에서 claude 가 while 루프의 stdin(다음 라벨)을 삼키는 것 방지
  if CLAUDE_CODE_OAUTH_TOKEN="$tok" _cct_run_limited 30 claude -p "ok" --model "$CCT_PROBE_MODEL" </dev/null >/dev/null 2>&1; then
    echo "  $1 : ✅ 유효"
  else
    echo "  $1 : ❌ 무효/실패 (재발급 필요할 수 있음)"
  fi
}

_cct_check() {
  if [ -n "$1" ]; then _cct_check_one "$1"; return; fi
  local labels lc
  labels="$(_cct_labels)"
  [ -n "$labels" ] || { echo "  (등록된 계정 없음)"; return; }
  echo "전체 계정 토큰 점검 (실제 호출, 계정당 ~수초)…"
  printf '%s\n' "$labels" | while IFS= read -r lc; do [ -n "$lc" ] && _cct_check_one "$lc"; done
}

_cct_add() {
  local label key tok dupkey
  [ -n "$1" ] || { echo "사용법: cct add <라벨>    예: cct add pro1"; return 2; }
  label="$1"; key="$(_cct_key "$label")"
  echo "[$label] 등록 — ⚠️ 'claude auth login' 때 브라우저가 '$label' 계정이었는지 먼저 확인하세요."
  echo "  (auth status 는 어느 계정인지 안 알려줌 → 중복 발급은 여기서만 막을 수 있음)"
  echo "  'claude setup-token' 토큰을 붙여넣고 엔터 (화면 미표시):"
  read -rs tok; echo
  [ -n "$tok" ] || { echo "❌ 입력 없음, 취소"; return 1; }
  touch "$CCT_ENV_FILE"; chmod 600 "$CCT_ENV_FILE"
  # 동일 토큰 중복 감지: 다른 라벨과 값이 같으면 같은 계정 재사용(브라우저 세션) 의심
  dupkey="$(grep -oE '^CCT_TOKEN_[A-Za-z0-9_]+' "$CCT_ENV_FILE" 2>/dev/null | while IFS= read -r ek; do
    [ "$ek" = "$key" ] && continue
    [ "$(_cct_envtok "$ek")" = "$tok" ] && { printf '%s' "$ek"; break; }
  done)"
  [ -n "$dupkey" ] && echo "⚠️  이 토큰은 기존 '$dupkey' 와 동일 — 같은 계정 재사용 의심(다시 로그인했는지 확인). 저장은 진행."
  if grep -qE "^$key=" "$CCT_ENV_FILE" 2>/dev/null; then
    tok="$tok" awk -v k="$key" 'BEGIN{t=ENVIRON["tok"]} $0 ~ ("^" k "=") {print k"="t; next} {print}' "$CCT_ENV_FILE" > "$CCT_ENV_FILE.tmp" && mv "$CCT_ENV_FILE.tmp" "$CCT_ENV_FILE"
    echo "✓ [$label] 갱신 완료"
  else
    printf '%s=%s\n' "$key" "$tok" >> "$CCT_ENV_FILE"
    echo "✓ [$label] 추가 완료"
  fi
  chmod 600 "$CCT_ENV_FILE"; unset tok
  echo "→ 'cct $label' 로 사용 / 'cct check $label' 로 점검"
}

# 계정 지문: org-id + rate-limit 윈도. 7d_reset 가 동일하면 같은 계정(중복)
_cct_fp_one() {
  local tok H org r5 r7 u5
  tok="$(_cct_envtok "$(_cct_key "$1")")"
  [ -n "$tok" ] || { printf '  %-8s 토큰없음\n' "$1"; return; }
  H="$(curl -s -m 25 -D - -o /dev/null https://api.anthropic.com/v1/messages \
    -H "Authorization: Bearer $tok" -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: oauth-2025-04-20" -H "content-type: application/json" \
    -d "{\"model\":\"$CCT_PROBE_MODEL\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" </dev/null 2>/dev/null)"
  org="$(printf '%s' "$H" | awk -F': ' 'tolower($1)=="anthropic-organization-id"{print $2}' | tr -d '\r' | cut -c1-8)"
  r5="$(printf '%s' "$H" | awk -F': ' 'tolower($1)=="anthropic-ratelimit-unified-5h-reset"{print $2}' | tr -d '\r')"
  r7="$(printf '%s' "$H" | awk -F': ' 'tolower($1)=="anthropic-ratelimit-unified-7d-reset"{print $2}' | tr -d '\r')"
  u5="$(printf '%s' "$H" | awk -F': ' 'tolower($1)=="anthropic-ratelimit-unified-5h-utilization"{print $2}' | tr -d '\r')"
  [ -n "$org" ] || { printf '  %-8s 응답실패\n' "$1"; return; }
  printf '  %-8s org:%s  7d_reset:%-11s  5h_reset:%-11s  util5h:%s\n' "$1" "$org" "$r7" "$r5" "$u5"
}

_cct_fp() {
  echo "계정 지문 (실호출) — 7d_reset 가 같으면 = 같은 계정(중복)!"
  if [ -n "$1" ]; then _cct_fp_one "$1"; return; fi
  local labels lc
  labels="$(_cct_labels)"
  [ -n "$labels" ] || { echo "  (등록된 계정 없음)"; return; }
  printf '%s\n' "$labels" | while IFS= read -r lc; do [ -n "$lc" ] && _cct_fp_one "$lc"; done
}

_cct_help() {
  printf '%s\n' \
    "cct — Claude Code 계정 스위처  (cc/ㅊㅊ 는 그냥 claude)" \
    "  cct                현재 인증된 프로필로 실행 (--dangerously-skip-permissions)" \
    "  cct <라벨>         해당 계정 토큰으로 실행          예: cct gv / cct pro1" \
    "  cct ls             등록된 계정 목록" \
    "  cct add <라벨>     토큰 등록/갱신 (화면 미표시 입력)  예: cct add pro1" \
    "  cct check [라벨]   토큰 유효성 점검 (실제 호출). 라벨 없으면 전체" \
    "  cct fp [라벨]      계정 지문 — 중복 탐지(7d_reset 같으면 같은 계정)" \
    "  cct help           이 도움말"
}

# 혹시 cct alias 가 있으면 제거 — 함수 정의 충돌 방지 (cc 는 건드리지 않음)
unalias cct 2>/dev/null || true

cct() {
  local label key tok
  case "$1" in
    help)     _cct_help; return ;;
    ls|list)  _cct_list; return ;;
    add)      shift; _cct_add "$@"; return ;;
    check)    shift; _cct_check "$@"; return ;;
    fp|who)   shift; _cct_fp "$@"; return ;;
    ""|-*)    command claude --dangerously-skip-permissions "$@"; return ;;
  esac
  label="$1"; shift
  key="$(_cct_key "$label")"; tok="$(_cct_envtok "$key")"
  if [ -z "$tok" ]; then
    { echo "❌ '$label' 토큰 없음 (키 $key). 등록된 계정:"; _cct_list; echo "→ 등록: cct add $label"; } >&2
    return 1
  fi
  echo "▶ $label 로 실행"
  CLAUDE_CODE_OAUTH_TOKEN="$tok" command claude --dangerously-skip-permissions "$@"
}
