#!/bin/sh
# cct 활성 프로필의 setup-token 을 stdout 으로 출력한다.
# 용도: 명령값 시크릿을 지원하는 외부 도구가 cct 활성 계정을 실시간으로 따라가는 브릿지.
#       예) aside models.json:  "apiKey": "!<홈경로>/.claude/cct-token.sh"
# 활성 프로필이 없거나 토큰이 없으면 아무것도 출력하지 않고 비제로 종료.
set -u

# LC_ALL=C 고정: 라벨 검증(case)·대소문자 변환(tr)·필드 추출(awk)이 로케일
# 콜레이션에 흔들리지 않도록 본체(cct.sh)와 동일한 기준을 강제한다.
# (예: en_US.UTF-8 에서는 a-z 범위에 대문자가 섞여 잘못된 라벨이 통과한다.)
LC_ALL=C
export LC_ALL

ENV_FILE="${CCT_ENV_FILE:-$HOME/.claude/tokens.env}"
# 활성 파일 경로는 본체 _cct_active_file 와 동일하게 계산한다:
# CCT_ACTIVE_FILE 가 지정되면 그대로, 아니면 지갑(ENV_FILE) 부모 디렉터리의 형제 cct-active.
if [ -n "${CCT_ACTIVE_FILE:-}" ]; then
  ACTIVE_FILE="$CCT_ACTIVE_FILE"
else
  case "$ENV_FILE" in
    */*) _parent="${ENV_FILE%/*}"; [ -n "$_parent" ] || _parent="/" ;;
    *)   _parent="." ;;
  esac
  if [ "$_parent" = "/" ]; then ACTIVE_FILE="/cct-active"
  else ACTIVE_FILE="$_parent/cct-active"; fi
fi

[ -f "$ACTIVE_FILE" ] || exit 1
[ -f "$ENV_FILE" ] || exit 1

label="$(head -n1 "$ACTIVE_FILE" 2>/dev/null)"
label="${label%%[[:space:]]*}"
[ -n "$label" ] || exit 1
case "$label" in
  *[!a-z0-9_]*) exit 1 ;;
esac

key="CCT_TOKEN_$(printf '%s' "$label" | tr '[:lower:]' '[:upper:]')"
tok="$(awk -v k="$key" '
  BEGIN { p = k "=" }
  index($0, p) == 1 {
    v = substr($0, length(p) + 1)
    gsub(/\r/, "", v); gsub(/"/, "", v); gsub(/\047/, "", v)
    print v
    exit
  }
' "$ENV_FILE" 2>/dev/null)"

[ -n "$tok" ] || exit 1
printf '%s' "$tok"
