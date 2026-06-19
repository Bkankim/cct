#!/usr/bin/env bash
# cct 계정 스위처 설치 — macOS / Linux / WSL2 공용. 멱등(여러 번 실행해도 안전).
#   로컬(clone):  bash install.sh
#   원격 한 줄:    curl -fsSL https://raw.githubusercontent.com/Bkankim/cct/main/install.sh | bash
set -eu

REPO_RAW="https://raw.githubusercontent.com/Bkankim/cct/main"
DEST="${HOME}/.claude"
mkdir -p "$DEST"

# 런처 확보: 스크립트 파일로 실행됐고($0가 실제 파일) 옆에 cct.sh 있으면 복사(clone 모드).
# curl|bash 처럼 파이프로 실행되면 $0가 파일이 아니므로 → 원격 다운로드 (cwd의 엉뚱한 cct.sh 회피)
SRC_DIR=""
[ -f "$0" ] && SRC_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo "")"
if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/cct.sh" ]; then
  cp "$SRC_DIR/cct.sh" "$DEST/cct.sh"
  echo "✓ 런처(로컬 복사): $DEST/cct.sh"
else
  command -v curl >/dev/null 2>&1 || { echo "❌ curl 이 필요합니다."; exit 1; }
  curl -fsSL "$REPO_RAW/cct.sh" -o "$DEST/cct.sh"
  echo "✓ 런처(원격 다운로드): $DEST/cct.sh"
fi

# tokens.env 템플릿 (없을 때만 — 기존 토큰 보존)
if [ ! -f "$DEST/tokens.env" ]; then
  printf '# Claude Code 계정 토큰  (평문! chmod 600 · git 금지)\n# 등록: cct add <라벨>   예: cct add gv / cct add pro1\n' > "$DEST/tokens.env"
  echo "✓ tokens.env 템플릿 생성"
else
  echo "• tokens.env 이미 존재 — 보존"
fi
chmod 600 "$DEST/tokens.env"

# 로컬 .gitignore
printf 'tokens.env\n.credentials.json\n*.key\n*.pem\n' > "$DEST/.gitignore"

# 전역 gitignore 안전망 (git 있을 때)
if command -v git >/dev/null 2>&1; then
  GIG="${HOME}/.gitignore_global"; touch "$GIG"
  grep -qx 'tokens.env' "$GIG" 2>/dev/null || printf 'tokens.env\n.claude/tokens.env\n' >> "$GIG"
  git config --global core.excludesfile "$GIG" || true
  echo "✓ 전역 gitignore: $GIG"
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
[ -n "$touched" ] || { printf '\n# Claude Code 계정 스위처(cct)\n%s\n' "$LINE" >> "${HOME}/.bashrc"; echo "✓ ~/.bashrc 생성·추가"; }

echo
echo "설치 완료. 새 터미널을 열거나:  source ~/.claude/cct.sh"
echo "계정 등록:  cct add gv   →   cct add pro1 ...   ('claude setup-token' 으로 발급)"
echo "확인:       cct ls  /  cct check  /  cct fp  /  cct help"
echo "(선택) claude 단축 alias:  alias cc='claude --dangerously-skip-permissions'"
