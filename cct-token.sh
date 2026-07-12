#!/bin/sh
# cct 활성 프로필의 setup-token 을 stdout 으로 출력한다.
# 용도: 명령값 시크릿을 지원하는 외부 도구가 cct 활성 계정을 실시간으로 따라가는 브릿지.
#       예) aside models.json:  "apiKey": "!<홈경로>/.claude/cct-token.sh"
# 활성 프로필이 없거나 토큰이 없으면 아무것도 출력하지 않고 비제로 종료.
set -u

ENV_FILE="${CCT_ENV_FILE:-$HOME/.claude/tokens.env}"
ACTIVE_FILE="${CCT_ACTIVE_FILE:-$HOME/.claude/cct-active}"

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
