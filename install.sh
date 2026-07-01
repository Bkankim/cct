#!/usr/bin/env bash
# cct 계정 스위처 설치 — macOS / Linux / WSL2 공용. 멱등(여러 번 실행해도 안전).
#   로컬(clone):  bash install.sh
#   원격 한 줄:    curl -fsSL https://raw.githubusercontent.com/Bkankim/cct/main/install.sh | bash
set -eu

REPO_RAW="https://raw.githubusercontent.com/Bkankim/cct/main"
DEST="${HOME}/.claude"
mkdir -p "$DEST"

append_missing() {
  local file="$1" line="$2"
  if grep -qxF "$line" "$file" 2>/dev/null; then
    return
  fi
  if [ -s "$file" ] && [ "$(tail -c 1 "$file" | wc -l | tr -d ' ')" -eq 0 ]; then
    printf '\n' >> "$file" || return 1
  fi
  printf '%s\n' "$line" >> "$file"
}

append_wallet_ignores() {
  local file="$1" pattern
  for pattern in \
    "tokens.env" \
    ".claude/tokens.env" \
    "tokens.env.bak" \
    ".claude/tokens.env.bak" \
    "tokens.env.tmp.*" \
    ".claude/tokens.env.tmp.*" \
    "tokens.env.lock/" \
    ".claude/tokens.env.lock/"
  do
    append_missing "$file" "$pattern" || return 1
  done
}

# 런처 확보: 스크립트 파일로 실행됐고($0가 실제 파일) 옆에 cct.sh 있으면 복사(clone 모드).
# curl|bash 처럼 파이프로 실행되면 $0가 파일이 아니므로 → 원격 다운로드 (cwd의 엉뚱한 cct.sh 회피)
SRC_DIR=""
[ -f "$0" ] && SRC_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo "")"
LAUNCHER="$DEST/cct.sh"
LAUNCHER_TMP="$DEST/.cct.sh.install.$$"
if [ -e "$LAUNCHER" ] || [ -L "$LAUNCHER" ]; then
  if [ ! -f "$LAUNCHER" ] || [ -L "$LAUNCHER" ]; then
    echo "❌ 런처 경로가 일반 파일이 아닙니다: $LAUNCHER" >&2
    exit 1
  fi
fi
cleanup_launcher_tmp() {
  rm -f "$LAUNCHER_TMP"
}
abort_launcher_install() {
  cleanup_launcher_tmp
  trap - EXIT HUP INT TERM
  exit 1
}
trap cleanup_launcher_tmp EXIT
trap abort_launcher_install HUP INT TERM
if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/cct.sh" ]; then
  cp "$SRC_DIR/cct.sh" "$LAUNCHER_TMP"
  launcher_message="✓ 런처(로컬 복사): $LAUNCHER"
else
  command -v curl >/dev/null 2>&1 || { echo "❌ curl 이 필요합니다."; exit 1; }
  curl -fsSL "$REPO_RAW/cct.sh" -o "$LAUNCHER_TMP"
  launcher_message="✓ 런처(원격 다운로드): $LAUNCHER"
fi
mv "$LAUNCHER_TMP" "$LAUNCHER"
trap - EXIT HUP INT TERM
echo "$launcher_message"

# tokens.env 템플릿 (없을 때만 — 기존 토큰 보존)
WALLET="$DEST/tokens.env"
if [ ! -e "$WALLET" ] && [ ! -L "$WALLET" ]; then
  (
    umask 077
    printf '# Claude Code 계정 토큰  (평문! chmod 600 · git 금지)\n# 등록: cct add <라벨>   예: cct add gv / cct add pro1\n' > "$WALLET"
  )
  chmod 600 "$WALLET"
  echo "✓ tokens.env 템플릿 생성"
else
  echo "• tokens.env 이미 존재 — 보존"
fi

# 로컬 .gitignore
LOCAL_IGNORE="$DEST/.gitignore"
if { [ -e "$LOCAL_IGNORE" ] || [ -L "$LOCAL_IGNORE" ]; } && [ ! -f "$LOCAL_IGNORE" ]; then
  echo "❌ 로컬 gitignore 경로가 일반 파일이 아닙니다: $LOCAL_IGNORE" >&2
  exit 1
fi
touch "$LOCAL_IGNORE"
append_wallet_ignores "$LOCAL_IGNORE"
append_missing "$LOCAL_IGNORE" ".credentials.json"
append_missing "$LOCAL_IGNORE" "*.key"
append_missing "$LOCAL_IGNORE" "*.pem"

# 전역 gitignore 안전망 (git 있을 때)
if command -v git >/dev/null 2>&1; then
  # 기존 core.excludesfile 보존: set -eu 에서 미설정 키의 비제로 rc 로 중단되지 않게 || true 가드
  CUR="$(git config --global --get core.excludesfile 2>/dev/null || true)"
  if [ -n "$CUR" ]; then
    TILDE="~"
    case "$CUR" in
      "$TILDE") GIG="$HOME" ;;
      "$TILDE"/*) GIG="$HOME/${CUR#"$TILDE"/}" ;;
      /*) GIG="$CUR" ;;
      *) GIG="$PWD/$CUR" ;;
    esac
  else
    GIG="${HOME}/.gitignore_global"
  fi

  global_ignore_ok=1
  if { [ -e "$GIG" ] || [ -L "$GIG" ]; } && [ ! -f "$GIG" ]; then
    global_ignore_ok=0
  elif ! touch "$GIG" 2>/dev/null || ! append_wallet_ignores "$GIG" 2>/dev/null; then
    global_ignore_ok=0
  fi

  if [ "$global_ignore_ok" -eq 1 ] && [ -z "$CUR" ]; then
    if ! git config --global core.excludesfile "$GIG"; then
      global_ignore_ok=0
    fi
  fi

  if [ "$global_ignore_ok" -eq 1 ]; then
    echo "✓ 전역 gitignore: $GIG"
  else
    echo "⚠ 전역 gitignore 경로 접근 불가(건너뜀): $GIG"
  fi
fi

# 셸 rc 에 source 추가 (멱등). cc/ㅊㅊ alias 는 강제하지 않음(빌드 PC의 cc=컴파일러 충돌 회피)
LINE='source ~/.claude/cct.sh'
touched=
for RC in "${HOME}/.zshrc" "${HOME}/.bashrc"; do
  [ -e "$RC" ] || continue
  if grep -qF "$LINE" "$RC"; then echo "• $RC 이미 설정됨"; else
    printf '\n# Claude Code 계정 스위처(cct)\n%s\n' "$LINE" >> "$RC"; echo "✓ $RC 에 추가"
  fi
  touched=1
done
if [ -z "$touched" ]; then
  # rc 파일이 하나도 없으면 로그인 셸($SHELL)에 맞는 rc 선택 (새 macOS=zsh 인데 .bashrc 에만 넣어 안 읽히는 문제 방지)
  case "$(basename "${SHELL:-}")" in
    zsh) RC="${HOME}/.zshrc" ;;
    *)   RC="${HOME}/.bashrc" ;;
  esac
  printf '\n# Claude Code 계정 스위처(cct)\n%s\n' "$LINE" >> "$RC"; echo "✓ $RC 생성·추가"
fi

echo
echo "설치 완료. 새 터미널을 열거나:  source ~/.claude/cct.sh"
echo "계정 등록:  cct add gv   →   cct add pro1 ...   ('claude setup-token' 으로 발급)"
echo "확인:       cct ls  /  cct check  /  cct fp  /  cct help"
echo "(선택) claude 단축 alias:  alias cc='claude --dangerously-skip-permissions'"
