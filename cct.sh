# Claude Code 계정 스위칭 런처 (cct) — .env 방식 · bash/zsh · macOS/WSL2 공용
#   cct                → 현재 인증된 프로필로 실행 (claude, 기본 --dangerously-skip-permissions)
#   cct <라벨>         → CCT_TOKEN_<라벨> 토큰 주입해 실행        (예: cct gv / cct pro1)
#   cct ls             → 등록된 계정 목록 (값 미표시)
#   cct add <라벨>     → 토큰 등록/갱신 (화면 미표시 입력)
#   cct check [라벨]   → 토큰 유효성 점검 (실제 호출). 라벨 없으면 전체
#   cct help           → 도움말
# (cc / ㅊㅊ 는 별도 alias = 그냥 claude. cct 와 충돌하지 않음)
#
# 환경변수 노브:
#   CCT_SKIP_PERMS=0     → --dangerously-skip-permissions 끄기 (기본 1=켜짐)
#   CCT_CLAUDE_FLAGS     → claude 에 추가로 넘길 플래그(공백 구분)
#   CCT_DISABLE_WEB_FEATURES=0 → 라벨 실행에서도 Advisor/비필수 웹 호출 허용
#
# 종료코드 (cct check):  0 유효 / 1 무효(또는 점검불가) / 2 토큰없음.  전체 점검은 하나라도 문제면 1.
#
# 호환성 메모(BREAKING) — 자세한 내용은 CHANGELOG.md:
#   - cct check 가 실패 시 비제로 종료코드를 반환(이전엔 항상 0).
#   - 라벨 없는 cct 는 환경의 stale CLAUDE_CODE_OAUTH_TOKEN 을 제거하고 실행.
#   - cct add 는 라벨 문자셋([a-z0-9_][a-z0-9_]*)·예약어를 검사한다.

CCT_ENV_FILE="${CCT_ENV_FILE:-$HOME/.claude/tokens.env}"
CCT_PROBE_MODEL="${CCT_PROBE_MODEL:-claude-haiku-4-5-20251001}"

_cct_key() { printf 'CCT_TOKEN_%s' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"; }

# tokens.env 에서 KEY 값만 안전 추출 (source 안 함, CRLF·따옴표 제거)
_cct_envtok() {
  [ -f "$CCT_ENV_FILE" ] || return 0
  awk -v k="$1" '
    BEGIN { p = k "=" }
    index($0, p) == 1 {
      v = substr($0, length(p) + 1)
      gsub(/\r/, "", v); gsub(/"/, "", v); gsub(/\047/, "", v)
      print v
      exit
    }
  ' "$CCT_ENV_FILE" 2>/dev/null
}

# 등록된 라벨(소문자) 한 줄씩.  #cctlabel: 주석은 ^CCT_TOKEN_ 앵커에 안 걸리므로 자동 제외.
_cct_labels() {
  [ -f "$CCT_ENV_FILE" ] || return 0
  awk -F= '/^CCT_TOKEN_[A-Za-z0-9_]+=/ {
    label = $1
    sub(/^CCT_TOKEN_/, "", label)
    print tolower(label)
  }' "$CCT_ENV_FILE" 2>/dev/null
}

# 키의 원본 라벨 조회: #cctlabel: 주석이 있으면 그 값을, 없으면(레거시) 소문자 키 꼬리를 반환.
_cct_label_for() {  # $1 = CCT_TOKEN_XXX
  local v
  v="$(awk -v k="#cctlabel:$1" '
    BEGIN { p = k "=" }
    index($0, p) == 1 {
      v = substr($0, length(p) + 1)
      gsub(/\r/, "", v)
      print v
      exit
    }
  ' "$CCT_ENV_FILE" 2>/dev/null)"
  if [ -n "$v" ]; then printf '%s' "$v"
  else printf '%s' "$1" | sed 's/^CCT_TOKEN_//' | tr '[:upper:]' '[:lower:]'; fi
}

# 라벨 문자셋 검증: 소문자 영숫자/언더스코어만 허용.  rc 0 통과 / 2 거부.
_cct_validate_label() {  # $1 = label
  case "${1-}" in
    "") echo "❌ 라벨이 비어 있음" >&2; return 2 ;;
    *[!a-z0-9_]*|[!a-z0-9_]*)
      echo "❌ 라벨은 소문자 영문/숫자/_ 만 허용 (받은 값: '$1')" >&2; return 2 ;;
  esac
  return 0
}

# 예약어(서브커맨드)와 충돌하는 라벨 거부.  rc 0 = 예약됨.
# ↓↓↓ 아래 cct() 의 case 문과 항상 동기화할 것 (use 는 case 에 없으므로 라벨로 허용) ↓↓↓
_cct_reserved_label() {  # $1 = label
  case "${1-}" in help|ls|list|add|check|fp|who) return 0 ;; *) return 1 ;; esac
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

# 토큰 점검.  rc 0 유효 / 1 무효 또는 점검불가 / 2 토큰없음.
_cct_check_one() {  # $1 = 라벨
  local tok cb
  _cct_validate_label "${1-}" || return 2
  tok="$(_cct_envtok "$(_cct_key "$1")")"
  if [ -z "$tok" ]; then echo "  $1 : ❓ 토큰 없음"; return 2; fi
  # N6: claude 실제 바이너리를 절대경로로 해석(사용자 claude 함수/alias 우회). timeout/gtimeout 는 이미 함수를
  #     우회하지만 perl·무제한 fallback 은 아니므로 절대경로를 모든 분기에 동일하게 넘긴다.
  if [ -n "${ZSH_VERSION:-}" ]; then cb="$(whence -p claude 2>/dev/null || true)"; else cb="$(type -P claude 2>/dev/null || true)"; fi
  if [ -z "$cb" ]; then echo "  $1 : ⚠️ 점검 불가 (claude 가 PATH 에 없음)"; return 1; fi
  # </dev/null 필수: 전체 점검 루프에서 claude 가 while 루프의 stdin(다음 라벨)을 삼키는 것 방지
  if CLAUDE_CODE_OAUTH_TOKEN="$tok" _cct_run_limited 30 "$cb" -p "ok" --model "$CCT_PROBE_MODEL" </dev/null >/dev/null 2>&1; then
    echo "  $1 : ✅ 유효"; return 0
  else
    echo "  $1 : ❌ 무효/실패 (재발급 필요할 수 있음)"; return 1
  fi
}

# 전체/단일 점검.  단일은 _cct_check_one 의 rc 그대로, 전체는 하나라도 비제로면 1.
_cct_check() {
  if [ -n "${1-}" ]; then _cct_check_one "$1"; return; fi
  local labels lc rc=0
  labels="$(_cct_labels)"
  [ -n "$labels" ] || { echo "  (등록된 계정 없음)"; return 0; }
  echo "전체 계정 토큰 점검 (실제 호출, 계정당 ~수초)…"
  # here-string 으로 루프를 현재 셸에서 실행(파이프 서브셸 금지) → rc 보존
  while IFS= read -r lc; do
    [ -n "$lc" ] || continue
    _cct_check_one "$lc" || rc=1
  done <<EOF
$labels
EOF
  return "$rc"
}

_cct_add() {
  local label key tok dupkey existing_label ans
  [ -n "${1-}" ] || { echo "사용법: cct add <라벨>    예: cct add pro1"; return 2; }
  label="$1"
  # 입력 검증을 토큰 붙여넣기 전에 먼저 (실패 시 헛수고 방지)
  _cct_reserved_label "$label" && { echo "❌ '$label' 는 예약어(서브커맨드)라 라벨로 쓸 수 없음. 다른 이름을 쓰세요." >&2; return 2; }
  _cct_validate_label "$label" || return 2
  key="$(_cct_key "$label")"
  echo "[$label] 등록 — ⚠️ 'claude auth login' 때 브라우저가 '$label' 계정이었는지 먼저 확인하세요."
  echo "  (auth status 는 어느 계정인지 안 알려줌 → 중복 발급은 여기서만 막을 수 있음)"
  echo "  'claude setup-token' 토큰을 붙여넣고 엔터 (화면 미표시):"
  if ! read -rs tok; then echo; tok=""; else echo; fi
  tok="$(printf '%s' "$tok" | tr -d '\r')"   # N3: CRLF 제거 → 중복감지/저장 일관성
  [ -n "$tok" ] || { echo "❌ 입력 없음, 취소"; return 1; }
  # N5: 디렉터리 보장 + 토큰 파일 생성/권한을 모두 검증(실패 시 즉시 중단)
  mkdir -p "$(dirname "$CCT_ENV_FILE")" 2>/dev/null || { echo "❌ 디렉터리 생성 실패: $(dirname "$CCT_ENV_FILE")" >&2; return 1; }
  touch "$CCT_ENV_FILE" 2>/dev/null || { echo "❌ 토큰 파일 생성 실패: $CCT_ENV_FILE" >&2; return 1; }
  chmod 600 "$CCT_ENV_FILE"
  # C#1: 키가 이미 있으면 원본 라벨 비교 — 같은 라벨이면 조용히 갱신, 다른 라벨이면 충돌 경고+확인(기본 거부)
  if grep -qE "^$key=" "$CCT_ENV_FILE" 2>/dev/null; then
    existing_label="$(_cct_label_for "$key")"
    if [ "$existing_label" != "$label" ]; then
      echo "⚠️  라벨 '$label' 는 기존 라벨 '$existing_label' 와 같은 키($key)로 정규화됩니다(대소문자/기호 차이)." >&2
      printf '   기존 토큰을 덮어쓸까요? [y/N] ' >&2
      read -r ans || ans=
      case "$ans" in y|Y|yes|YES) ;; *) echo "취소함 (기존 '$existing_label' 유지)." >&2; return 1 ;; esac
    fi
  fi
  # 동일 토큰 중복 감지: 다른 라벨과 값이 같으면 같은 계정 재사용(브라우저 세션) 의심 — 경고만
  dupkey="$(grep -oE '^CCT_TOKEN_[A-Za-z0-9_]+' "$CCT_ENV_FILE" 2>/dev/null | while IFS= read -r ek; do
    [ "$ek" = "$key" ] && continue
    [ "$(_cct_envtok "$ek")" = "$tok" ] && { printf '%s' "$ek"; break; }
  done || true)"
  [ -n "$dupkey" ] && echo "⚠️  이 토큰은 기존 '$dupkey' 와 동일 — 같은 계정 재사용 의심(다시 로그인했는지 확인). 저장은 진행."
  if grep -qE "^$key=" "$CCT_ENV_FILE" 2>/dev/null; then
    # 갱신: H2 = tmp 를 mv 전에 600 으로 (644 노출창 제거).  N5 = awk+mv 성공 확인 후에만 성공 출력.
    if tok="$tok" lbl="$label" awk -v k="$key" '
        BEGIN{t=ENVIRON["tok"]; l=ENVIRON["lbl"]}
        $0 ~ ("^" k "=")           {print k"="t; next}
        $0 ~ ("^#cctlabel:" k "=") {print "#cctlabel:" k "=" l; next}
        {print}
      ' "$CCT_ENV_FILE" > "$CCT_ENV_FILE.tmp" && chmod 600 "$CCT_ENV_FILE.tmp" && mv "$CCT_ENV_FILE.tmp" "$CCT_ENV_FILE"; then
      grep -qE "^#cctlabel:$key=" "$CCT_ENV_FILE" 2>/dev/null || printf '#cctlabel:%s=%s\n' "$key" "$label" >> "$CCT_ENV_FILE"
      echo "✓ [$label] 갱신 완료"
    else
      rm -f "$CCT_ENV_FILE.tmp"; echo "❌ [$label] 저장 실패 (갱신) — 경로/권한 확인: $CCT_ENV_FILE" >&2; return 1
    fi
  else
    if printf '%s=%s\n#cctlabel:%s=%s\n' "$key" "$tok" "$key" "$label" >> "$CCT_ENV_FILE"; then
      echo "✓ [$label] 추가 완료"
    else
      echo "❌ [$label] 저장 실패 (추가) — 경로/권한 확인: $CCT_ENV_FILE" >&2; return 1
    fi
  fi
  chmod 600 "$CCT_ENV_FILE"; unset tok
  echo "→ 'cct $label' 로 사용 / 'cct check $label' 로 점검"
}

# 계정 지문: org-id + rate-limit 윈도. 7d_reset 가 동일하면 같은 계정(중복)
_cct_fp_one() {
  local tok H org r5 r7 u5
  _cct_validate_label "${1-}" || return
  tok="$(_cct_envtok "$(_cct_key "$1")")"
  [ -n "$tok" ] || { printf '  %-8s 토큰없음\n' "$1"; return; }
  H="$(curl -s -m 25 -D - -o /dev/null https://api.anthropic.com/v1/messages \
    -H "Authorization: Bearer $tok" -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: oauth-2025-04-20" -H "content-type: application/json" \
    -d "{\"model\":\"$CCT_PROBE_MODEL\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" </dev/null 2>/dev/null || true)"
  org="$(printf '%s' "$H" | awk -F': ' 'tolower($1)=="anthropic-organization-id"{print $2}' | tr -d '\r' | cut -c1-8 || true)"
  r5="$(printf '%s' "$H" | awk -F': ' 'tolower($1)=="anthropic-ratelimit-unified-5h-reset"{print $2}' | tr -d '\r' || true)"
  r7="$(printf '%s' "$H" | awk -F': ' 'tolower($1)=="anthropic-ratelimit-unified-7d-reset"{print $2}' | tr -d '\r' || true)"
  u5="$(printf '%s' "$H" | awk -F': ' 'tolower($1)=="anthropic-ratelimit-unified-5h-utilization"{print $2}' | tr -d '\r' || true)"
  [ -n "$org" ] || { printf '  %-8s 응답실패\n' "$1"; return; }
  printf '  %-8s org:%s  7d_reset:%-11s  5h_reset:%-11s  util5h:%s\n' "$1" "$org" "$r7" "$r5" "$u5"
}

_cct_fp() {
  echo "계정 지문 (실호출) — 7d_reset 가 같으면 = 같은 계정(중복)!"
  if [ -n "${1-}" ]; then _cct_fp_one "$1"; return; fi
  local labels lc
  labels="$(_cct_labels)"
  [ -n "$labels" ] || { echo "  (등록된 계정 없음)"; return; }
  printf '%s\n' "$labels" | while IFS= read -r lc; do [ -n "$lc" ] && _cct_fp_one "$lc"; done
}

_cct_help() {
  printf '%s\n' \
    "cct — Claude Code 계정 스위처  (cc/ㅊㅊ 는 그냥 claude)" \
    "  cct                현재 인증된 프로필로 실행 (기본 --dangerously-skip-permissions; stale 토큰 제거)" \
    "  cct <라벨>         해당 계정 토큰으로 실행          예: cct gv / cct pro1" \
    "  cct ls             등록된 계정 목록" \
    "  cct add <라벨>     토큰 등록/갱신 (화면 미표시 입력)  예: cct add pro1" \
    "                     라벨은 [a-z0-9_][a-z0-9_]* 만, 예약어(아래 서브커맨드) 불가" \
    "  cct check [라벨]   토큰 유효성 점검 (실제 호출). 라벨 없으면 전체" \
    "                     종료코드: 0 유효 / 1 무효·점검불가 / 2 토큰없음 (전체는 하나라도 문제면 1)" \
    "  cct fp [라벨]      계정 지문 — 중복 탐지(7d_reset 같으면 같은 계정)" \
    "  cct help           이 도움말" \
    "" \
    "환경변수:  CCT_SKIP_PERMS=0 (위험 플래그 끄기)   CCT_CLAUDE_FLAGS='...' (claude 에 추가 플래그)" \
    "호환성/BREAKING 변경은 CHANGELOG.md 참고."
}

# 혹시 cct alias 가 있으면 제거 — 함수 정의 충돌 방지 (cc 는 건드리지 않음)
unalias cct 2>/dev/null || true

cct() {
  local label key tok
  # C#4: claude 플래그를 배열로 조립(워드스플릿 안전). 기본 --dangerously-skip-permissions,
  #      CCT_SKIP_PERMS=0 으로 끄고, CCT_CLAUDE_FLAGS 로 추가 플래그(공백 구분)를 덧붙인다.
  local flags=()
  [ "${CCT_SKIP_PERMS:-1}" = "0" ] || flags+=(--dangerously-skip-permissions)
  if [ -n "${CCT_CLAUDE_FLAGS:-}" ]; then
    # 글로빙 방지: bash 는 read -ra(워드분할만), zsh 는 ${(@s: :)} 로 공백 분할
    if [ -n "${ZSH_VERSION:-}" ]; then
      flags+=("${(@s: :)CCT_CLAUDE_FLAGS}")
    else
      local _extra; read -ra _extra <<< "$CCT_CLAUDE_FLAGS"; flags+=("${_extra[@]}")
    fi
  fi
  case "${1-}" in
    help)     _cct_help; return ;;
    ls|list)  _cct_list; return ;;
    add)      shift; _cct_add "$@"; return ;;
    check)    shift; _cct_check "$@"; return ;;
    fp|who)   shift; _cct_fp "$@"; return ;;
    ""|-*)    # C#3: 기본 실행은 환경의 stale 한 CLAUDE_CODE_OAUTH_TOKEN 을 제거해 '현재 인증 프로필'로 실행.
              # 서브셸로 격리 → 호출자 셸의 환경은 손대지 않음.
              ( unset CLAUDE_CODE_OAUTH_TOKEN; command claude "${flags[@]}" "$@" ); return ;;
  esac
  label="$1"; shift
  _cct_reserved_label "$label" && { echo "❌ '$label' 는 예약어(서브커맨드)라 라벨로 쓸 수 없음." >&2; return 2; }
  _cct_validate_label "$label" || return 2
  key="$(_cct_key "$label")"; tok="$(_cct_envtok "$key")"
  if [ -z "$tok" ]; then
    { echo "❌ '$label' 토큰 없음 (키 $key). 등록된 계정:"; _cct_list; echo "→ 등록: cct add $label"; } >&2
    return 1
  fi
  echo "▶ $label 로 실행"
  if [ "${CCT_DISABLE_WEB_FEATURES:-1}" = "0" ]; then
    CLAUDE_CODE_OAUTH_TOKEN="$tok" command claude "${flags[@]}" "$@"
  else
    # setup-token/CLAUDE_CODE_OAUTH_TOKEN 장기 토큰은 Claude Code 2.1.185+에서 inference-only 로 취급된다.
    # Advisor/플러그인 갱신 같은 비필수 claude.ai 웹 호출은 추가 스코프를 요구해 401을 낼 수 있으므로 기본 차단한다.
    CLAUDE_CODE_OAUTH_TOKEN="$tok" \
      CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1 \
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
      CLAUDE_CODE_DISABLE_BACKGROUND_PLUGIN_REFRESH=1 \
      command claude "${flags[@]}" "$@"
  fi
}
