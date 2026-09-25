#!/usr/bin/env bash
# cct SessionStart 훅 - claude 세션이 열릴 때 어느 cct 라벨로 열렸는지 한 줄 남긴다.
#   stdin : Claude Code SessionStart 훅 입력 JSON (session_id, source, ...)
#   env   : CCT_LABEL (cct 가 claude 를 띄울 때 넘긴 라벨)
#   출력  : ${CCT_SESSIONS_FILE:-~/.claude/cct-sessions.jsonl} 에
#           {"ts":<epoch>,"session_id":"...","label":"...","source":"..."} 추가 (mode 600)
# 대시보드가 이 기록으로 대화 기록(jsonl)의 메시지를 계정별로 나눈다.
# stdout 은 claude 컨텍스트로 들어가므로 아무것도 출력하지 않고, 실패해도 세션을 막지 않게 항상 0.

input="$(cat)"
file="${CCT_SESSIONS_FILE:-$HOME/.claude/cct-sessions.jsonl}"

field() {  # 평탄한 "key":"value" 문자열 필드만 추출 (jq 의존 없음)
  printf '%s' "$input" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

sid="$(field session_id)"
src="$(field source)"

# 값은 JSON 에 그대로 박으므로 형식을 좁혀서만 받는다. 하나라도 어긋나면 기록하지 않는다.
case "${CCT_LABEL:-}" in ""|*[!a-z0-9_]*) exit 0 ;; esac
case "$sid" in ""|*[!A-Za-z0-9-]*) exit 0 ;; esac
case "$src" in *[!a-z_]*) exit 0 ;; esac

{
  umask 077
  printf '{"ts":%s,"session_id":"%s","label":"%s","source":"%s"}\n' \
    "$(date +%s)" "$sid" "$CCT_LABEL" "$src" >> "$file"
} 2>/dev/null
exit 0
