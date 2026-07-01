#!/usr/bin/env bash
# cct behavioral test suite — no network, no bats dependency.
# Usage:  bash tests/cct_test.sh           # run all
#         bash tests/cct_test.sh install   # only install.sh e2e
#         bash tests/cct_test.sh cct        # only cct.sh behavior
# Each test runs in an isolated mktemp HOME with a fake `claude` shim on PATH.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
chk(){ # name expected actual
  if [ "$2" = "$3" ]; then printf '  PASS %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL %s : expected[%s] got[%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
chk_has(){ # name needle haystack
  case "$3" in *"$2"*) printf '  PASS %s\n' "$1"; PASS=$((PASS+1));; *) printf '  FAIL %s : [%s] not in output\n' "$1" "$2"; FAIL=$((FAIL+1));; esac
}
chk_not_has(){
  case "$3" in *"$2"*) printf '  FAIL %s : forbidden text was present\n' "$1"; FAIL=$((FAIL+1));; *) printf '  PASS %s\n' "$1"; PASS=$((PASS+1));; esac
}

# Fake claude shim: prints received args+token to stderr; exits 1 if the token
# contains BAD (lets a single `cct check` run produce a mixed result), else 0.
mk_shim(){ # $1 = bin dir
  mkdir -p "$1"
  cat > "$1/claude" <<'SHIM'
#!/usr/bin/env bash
[ -z "${CCT_SHIM_LOG:-}" ] || printf '%s\n' "$*" >> "$CCT_SHIM_LOG"
if [ "$#" -eq 1 ] && [ "$1" = "--version" ]; then
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] ||
    [ -n "${CLAUDE_CODE_DISABLE_ADVISOR_TOOL:-}" ] ||
    [ -n "${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-}" ] ||
    [ -n "${CLAUDE_CODE_DISABLE_BACKGROUND_PLUGIN_REFRESH:-}" ]; then
    printf '%s\n' "VERSION_ENV_LEAK"
  else
    printf '%s\n' "Claude Code fixture 1.2.3"
  fi
  exit 0
fi
echo "CLAUDE args=[$*] tok=[${CLAUDE_CODE_OAUTH_TOKEN:-<unset>}]" >&2
echo "CLAUDE web=[${CLAUDE_CODE_DISABLE_ADVISOR_TOOL:-<unset>},${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-<unset>},${CLAUDE_CODE_DISABLE_BACKGROUND_PLUGIN_REFRESH:-<unset>}]" >&2
case "${CLAUDE_CODE_OAUTH_TOKEN:-}" in *BAD*) exit 1 ;; esac
exit 0
SHIM
  chmod +x "$1/claude"
}

# feed a token (and optional confirm answer) to `cct add`
add_tok(){ # label token [confirm]
  if [ "$#" -ge 3 ]; then printf '%s\n%s\n' "$2" "$3" | cct add "$1"
  else printf '%s\n' "$2" | cct add "$1"; fi
}

wallet_mode(){
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

wallet_sha(){
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

count_exact(){
  [ -f "$1" ] || {
    printf '0\n'
    return
  }
  awk -v pattern="$2" '$0 == pattern { count++ } END { print count + 0 }' "$1" 2>/dev/null
}

chk_ignore_patterns(){
  local prefix="$1" file="$2" pattern
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
    chk "$prefix: $pattern once" "1" "$(count_exact "$file" "$pattern")"
  done
}

wallet_inode(){
  stat -c '%i' "$1" 2>/dev/null || stat -f '%i' "$1"
}

write_account_fixture(){
  local file="$1"
  shift
  printf '%s\n' "$@" > "$file"
  chmod 600 "$file"
}

# -------------------------------------------------------------------------
test_install(){
  echo "== install.sh (portable wallet preservation + ignore coverage) =="
  local H G rc MINE cap wallet_before backup_before active_before temp_before owner_before
  local wallet_mode_before backup_mode_before active_mode_before temp_mode_before owner_mode_before target

  if [ "${CCT_TEST_CASE:-}" = "install-failures" ]; then
    echo "-- failure: an existing wallet symlink is preserved without following it"
    H="$(mktemp -d)/home with spaces"; mkdir -p "$H/.claude"; G="$H/git config"
    target="$H/wallet target"
    printf '%s\n' 'CCT_TOKEN_KEEP=symlink-secret' > "$target"; chmod 640 "$target"
    ln -s "$target" "$H/.claude/tokens.env"
    wallet_before="$(wallet_sha "$target")"; wallet_mode_before="$(wallet_mode "$target")"
    cap="$(cd "$REPO" && HOME="$H" GIT_CONFIG_GLOBAL="$G" SHELL=/bin/zsh bash install.sh 2>&1)"; rc=$?
    chk "symlink wallet install rc=0" "0" "$rc"
    chk "wallet remains a symlink" "yes" "$([ -L "$H/.claude/tokens.env" ] && echo yes || echo no)"
    chk "symlink target bytes preserved" "$wallet_before" "$(wallet_sha "$target")"
    chk "symlink target mode preserved" "$wallet_mode_before" "$(wallet_mode "$target")"
    chk_not_has "installer does not claim wallet template creation" "tokens.env 템플릿 생성" "$cap"
    rm -rf "${H%/home with spaces}"

    echo "-- failure: launcher copy failure cannot mutate or claim wallet success"
    H="$(mktemp -d)"; G="$H/.gitconfig"; mkdir -p "$H/.claude/cct.sh/cct.sh"
    printf '%s\n' 'CCT_TOKEN_KEEP=copy-failure-secret' > "$H/.claude/tokens.env"; chmod 600 "$H/.claude/tokens.env"
    wallet_before="$(wallet_sha "$H/.claude/tokens.env")"; wallet_mode_before="$(wallet_mode "$H/.claude/tokens.env")"
    cap="$(cd "$REPO" && HOME="$H" GIT_CONFIG_GLOBAL="$G" SHELL=/bin/bash bash install.sh 2>&1)"; rc=$?
    chk "launcher copy failure rc=1" "1" "$rc"
    chk "copy failure preserves wallet bytes" "$wallet_before" "$(wallet_sha "$H/.claude/tokens.env")"
    chk "copy failure preserves wallet mode" "$wallet_mode_before" "$(wallet_mode "$H/.claude/tokens.env")"
    chk_not_has "copy failure has no completion claim" "설치 완료" "$cap"
    chk_not_has "copy failure has no wallet creation claim" "tokens.env 템플릿 생성" "$cap"
    rm -rf "$H"

    echo "-- failure: unusable global ignore path warns without replacing config"
    H="$(mktemp -d)"; G="$H/.gitconfig"; MINE="$H/ignore-directory"; mkdir "$MINE"
    HOME="$H" GIT_CONFIG_GLOBAL="$G" git config --global core.excludesfile "$MINE"
    printf '%s\n' 'CCT_TOKEN_KEEP=global-ignore-secret' > "$H/wallet"; chmod 600 "$H/wallet"
    wallet_before="$(wallet_sha "$H/wallet")"
    cap="$(cd "$REPO" && HOME="$H" GIT_CONFIG_GLOBAL="$G" SHELL=/bin/bash bash install.sh 2>&1)"; rc=$?
    chk "global ignore warning remains nonfatal" "0" "$rc"
    chk_has "global ignore warning is explicit" "전역 gitignore 경로 접근 불가" "$cap"
    chk_not_has "global ignore does not claim success" "전역 gitignore: $MINE" "$cap"
    chk "core.excludesfile remains unchanged" "$MINE" \
      "$(HOME="$H" GIT_CONFIG_GLOBAL="$G" git config --global --get core.excludesfile)"
    chk "unrelated secret fixture preserved" "$wallet_before" "$(wallet_sha "$H/wallet")"
    rm -rf "$H"

    echo "-- failure: unusable local ignore path fails without touching seeded wallet state"
    H="$(mktemp -d)"; G="$H/.gitconfig"; mkdir -p "$H/.claude/.gitignore"
    printf '%s\n' 'CCT_TOKEN_KEEP=local-ignore-secret' > "$H/.claude/tokens.env"; chmod 640 "$H/.claude/tokens.env"
    printf '%s\n' 'CCT_TOKEN_OLD=local-ignore-backup' > "$H/.claude/tokens.env.bak"; chmod 644 "$H/.claude/tokens.env.bak"
    wallet_before="$(wallet_sha "$H/.claude/tokens.env")"; wallet_mode_before="$(wallet_mode "$H/.claude/tokens.env")"
    backup_before="$(wallet_sha "$H/.claude/tokens.env.bak")"; backup_mode_before="$(wallet_mode "$H/.claude/tokens.env.bak")"
    cap="$(cd "$REPO" && HOME="$H" GIT_CONFIG_GLOBAL="$G" SHELL=/bin/bash bash install.sh 2>&1)"; rc=$?
    chk "local ignore failure rc=1" "1" "$rc"
    chk_has "local ignore failure is explicit" "로컬 gitignore 경로가 일반 파일이 아닙니다" "$cap"
    chk_not_has "local ignore failure has no completion claim" "설치 완료" "$cap"
    chk "local ignore failure preserves wallet bytes" "$wallet_before" "$(wallet_sha "$H/.claude/tokens.env")"
    chk "local ignore failure preserves wallet mode" "$wallet_mode_before" "$(wallet_mode "$H/.claude/tokens.env")"
    chk "local ignore failure preserves backup bytes" "$backup_before" "$(wallet_sha "$H/.claude/tokens.env.bak")"
    chk "local ignore failure preserves backup mode" "$backup_mode_before" "$(wallet_mode "$H/.claude/tokens.env.bak")"
    rm -rf "$H"

    echo "-- failure: an interrupted launcher replace aborts and cleans its temporary file"
    H="$(mktemp -d)"; G="$H/.gitconfig"; mkdir -p "$H/.claude" "$H/bin"
    printf '%s\n' 'CCT_TOKEN_KEEP=signal-secret' > "$H/.claude/tokens.env"; chmod 600 "$H/.claude/tokens.env"
    wallet_before="$(wallet_sha "$H/.claude/tokens.env")"; wallet_mode_before="$(wallet_mode "$H/.claude/tokens.env")"
    cat > "$H/bin/mv" <<'SHIM'
#!/bin/sh
kill -TERM "$PPID"
exit 0
SHIM
    chmod 700 "$H/bin/mv"
    cap="$(cd "$REPO" && HOME="$H" GIT_CONFIG_GLOBAL="$G" SHELL=/bin/bash PATH="$H/bin:$PATH" bash install.sh 2>&1)"; rc=$?
    chk "interrupted launcher replace rc=1" "1" "$rc"
    chk "interrupted replace preserves wallet bytes" "$wallet_before" "$(wallet_sha "$H/.claude/tokens.env")"
    chk "interrupted replace preserves wallet mode" "$wallet_mode_before" "$(wallet_mode "$H/.claude/tokens.env")"
    chk_not_has "interrupted replace has no launcher success" "런처(로컬 복사)" "$cap"
    chk_not_has "interrupted replace has no completion claim" "설치 완료" "$cap"
    chk "interrupted replace cleans launcher temp" "0" \
      "$(find "$H/.claude" -maxdepth 1 -name '.cct.sh.install.*' -print | wc -l | tr -d ' ')"
    rm -rf "$H"
    return
  fi

  echo "-- happy: fresh HOME with spaces creates a private wallet and exact ignores"
  H="$(mktemp -d)/home with spaces"; mkdir -p "$H"; G="$H/git config"
  ( cd "$REPO" && HOME="$H" GIT_CONFIG_GLOBAL="$G" SHELL=/bin/zsh bash install.sh ) >/dev/null 2>&1; rc=$?
  chk "fresh installer rc=0" "0" "$rc"
  chk "fresh wallet exists" "yes" "$([ -f "$H/.claude/tokens.env" ] && echo yes || echo no)"
  chk "fresh wallet mode 600" "600" "$(wallet_mode "$H/.claude/tokens.env")"
  chk ".zshrc source line once" "1" "$(count_exact "$H/.zshrc" 'source ~/.claude/cct.sh')"
  chk ".bashrc not created" "no" "$([ -e "$H/.bashrc" ] && echo yes || echo no)"
  chk "default global ignore configured" "$H/.gitignore_global" \
    "$(HOME="$H" GIT_CONFIG_GLOBAL="$G" git config --global --get core.excludesfile)"
  chk_ignore_patterns "tracked repository ignore" "$REPO/.gitignore"
  chk_ignore_patterns "local wallet ignore" "$H/.claude/.gitignore"
  chk_ignore_patterns "default global ignore" "$H/.gitignore_global"
  rm -rf "${H%/home with spaces}"

  echo "-- happy: two reinstalls preserve every wallet/state artifact and user configuration"
  H="$(mktemp -d)/home with spaces"; mkdir -p "$H/.claude"; G="$H/git config"; MINE="$H/custom ignore"
  HOME="$H" GIT_CONFIG_GLOBAL="$G" git config --global core.excludesfile "$MINE"
  printf '%s' 'build/' > "$MINE"
  printf '%s' 'keep-local/' > "$H/.claude/.gitignore"
  printf '%s\n' '# user zsh config' > "$H/.zshrc"
  printf '%s\n' 'CCT_TOKEN_KEEP=wallet-secret' > "$H/.claude/tokens.env"; chmod 600 "$H/.claude/tokens.env"
  printf '%s\n' 'CCT_TOKEN_OLD=backup-secret' > "$H/.claude/tokens.env.bak"; chmod 640 "$H/.claude/tokens.env.bak"
  printf '%s\n' 'keep' > "$H/.claude/cct-active"; chmod 644 "$H/.claude/cct-active"
  printf '%s\n' 'temporary-secret' > "$H/.claude/tokens.env.tmp.live"; chmod 640 "$H/.claude/tokens.env.tmp.live"
  mkdir "$H/.claude/tokens.env.lock"
  printf '%s\n' "$$ 1" > "$H/.claude/tokens.env.lock/owner"; chmod 644 "$H/.claude/tokens.env.lock/owner"
  wallet_before="$(wallet_sha "$H/.claude/tokens.env")"; wallet_mode_before="$(wallet_mode "$H/.claude/tokens.env")"
  backup_before="$(wallet_sha "$H/.claude/tokens.env.bak")"; backup_mode_before="$(wallet_mode "$H/.claude/tokens.env.bak")"
  active_before="$(wallet_sha "$H/.claude/cct-active")"; active_mode_before="$(wallet_mode "$H/.claude/cct-active")"
  temp_before="$(wallet_sha "$H/.claude/tokens.env.tmp.live")"; temp_mode_before="$(wallet_mode "$H/.claude/tokens.env.tmp.live")"
  owner_before="$(wallet_sha "$H/.claude/tokens.env.lock/owner")"; owner_mode_before="$(wallet_mode "$H/.claude/tokens.env.lock/owner")"
  ( cd "$REPO" && HOME="$H" GIT_CONFIG_GLOBAL="$G" SHELL=/bin/zsh bash install.sh ) >/dev/null 2>&1
  ( cd "$REPO" && HOME="$H" GIT_CONFIG_GLOBAL="$G" SHELL=/bin/zsh bash install.sh ) >/dev/null 2>&1; rc=$?
  chk "second reinstall rc=0" "0" "$rc"
  chk "wallet bytes preserved" "$wallet_before" "$(wallet_sha "$H/.claude/tokens.env")"
  chk "wallet mode preserved" "$wallet_mode_before" "$(wallet_mode "$H/.claude/tokens.env")"
  chk "backup bytes preserved" "$backup_before" "$(wallet_sha "$H/.claude/tokens.env.bak")"
  chk "backup mode preserved" "$backup_mode_before" "$(wallet_mode "$H/.claude/tokens.env.bak")"
  chk "active bytes preserved" "$active_before" "$(wallet_sha "$H/.claude/cct-active")"
  chk "active mode preserved" "$active_mode_before" "$(wallet_mode "$H/.claude/cct-active")"
  chk "live temp bytes preserved" "$temp_before" "$(wallet_sha "$H/.claude/tokens.env.tmp.live")"
  chk "live temp mode preserved" "$temp_mode_before" "$(wallet_mode "$H/.claude/tokens.env.tmp.live")"
  chk "live lock owner bytes preserved" "$owner_before" "$(wallet_sha "$H/.claude/tokens.env.lock/owner")"
  chk "live lock owner mode preserved" "$owner_mode_before" "$(wallet_mode "$H/.claude/tokens.env.lock/owner")"
  chk "core.excludesfile path with spaces unchanged" "$MINE" \
    "$(HOME="$H" GIT_CONFIG_GLOBAL="$G" git config --global --get core.excludesfile)"
  chk "global custom rule preserved" "1" "$(count_exact "$MINE" "build/")"
  chk "local custom rule preserved" "1" "$(count_exact "$H/.claude/.gitignore" "keep-local/")"
  chk "existing shell rc preserved" "1" "$(count_exact "$H/.zshrc" "# user zsh config")"
  chk ".zshrc source is idempotent" "1" "$(count_exact "$H/.zshrc" 'source ~/.claude/cct.sh')"
  chk_ignore_patterns "custom global ignore" "$MINE"
  chk_ignore_patterns "reinstalled local ignore" "$H/.claude/.gitignore"
  rm -rf "${H%/home with spaces}"

  echo "-- happy: literal tilde global ignore stays configured and Bash startup is selected"
  H="$(mktemp -d)"; G="$H/.gitconfig"; mkdir -p "$H/config with spaces"
  MINE="$(printf '\176/%s' 'config with spaces/global ignore')"
  HOME="$H" GIT_CONFIG_GLOBAL="$G" git config --global core.excludesfile "$MINE"
  ( cd "$REPO" && HOME="$H" GIT_CONFIG_GLOBAL="$G" SHELL=/bin/bash bash install.sh ) >/dev/null 2>&1; rc=$?
  chk "tilde-path install rc=0" "0" "$rc"
  chk "literal tilde config preserved" "$MINE" \
    "$(HOME="$H" GIT_CONFIG_GLOBAL="$G" git config --global --get core.excludesfile)"
  chk_ignore_patterns "tilde-expanded global ignore" "$H/config with spaces/global ignore"
  chk ".bashrc source line once" "1" "$(count_exact "$H/.bashrc" 'source ~/.claude/cct.sh')"
  chk ".zshrc not created for Bash" "no" "$([ -e "$H/.zshrc" ] && echo yes || echo no)"
  rm -rf "$H"

  echo "-- happy: relative global ignore is resolved from the installer working directory"
  H="$(mktemp -d)"; G="$H/.gitconfig"; mkdir -p "$H/work"
  MINE="relative ignore"
  HOME="$H" GIT_CONFIG_GLOBAL="$G" git config --global core.excludesfile "$MINE"
  ( cd "$H/work" && HOME="$H" GIT_CONFIG_GLOBAL="$G" SHELL=/bin/bash bash "$REPO/install.sh" ) >/dev/null 2>&1; rc=$?
  chk "relative-path install rc=0" "0" "$rc"
  chk "relative config value preserved" "$MINE" \
    "$(HOME="$H" GIT_CONFIG_GLOBAL="$G" git config --global --get core.excludesfile)"
  chk_ignore_patterns "relative global ignore" "$H/work/relative ignore"
  rm -rf "$H"
}

# -------------------------------------------------------------------------
test_cct(){
  echo "== cct.sh behavior =="
  # cct.sh targets interactive bash/zsh (no `set -u`); run this section without -u
  # so unbound-positional reads (e.g. `cct check` with no label) behave as in real use.
  set +u
  local sb cap rc
  sb="$(mktemp -d)"; mk_shim "$sb/bin"
  export PATH="$sb/bin:$PATH"
  export CCT_ENV_FILE="$sb/tokens.env"
  export CCT_STICKY=0   # 이 섹션은 비고정(inline) 동작 검증
  # shellcheck disable=SC1090
  . "$REPO/cct.sh"

  echo "-- C#2: cct check exit codes (0 valid / 1 invalid / 2 missing; aggregate)"
  add_tok good "sk-good" >/dev/null 2>&1
  cct check >/dev/null 2>&1; chk "aggregate all-valid -> 0" "0" "$?"
  cct check good >/dev/null 2>&1; chk "single valid -> 0" "0" "$?"
  add_tok bad "sk-BAD" >/dev/null 2>&1
  cct check bad >/dev/null 2>&1; chk "single invalid -> 1" "1" "$?"
  cct check nosuchlabel >/dev/null 2>&1; chk "missing token -> 2" "2" "$?"
  cct check >/dev/null 2>&1; chk "aggregate mixed -> 1" "1" "$?"

  echo "-- C#1/M4: strict lowercase label validation"
  cct add 'a@b' >/dev/null 2>&1; chk "a@b rejected -> 2" "2" "$?"
  cct add '가나' >/dev/null 2>&1; chk "Hangul rejected -> 2" "2" "$?"
  cct add '' >/dev/null 2>&1; chk "empty label -> 2" "2" "$?"
  cct add '---' >/dev/null 2>&1; chk "all-dash (empty key) rejected -> 2" "2" "$?"
  cct add 'a-b' >/dev/null 2>&1; chk "dash label rejected -> 2" "2" "$?"
  cct add '-foo' >/dev/null 2>&1; chk "leading-dash label rejected -> 2" "2" "$?"
  cct add 'Work' >/dev/null 2>&1; chk "uppercase label rejected -> 2" "2" "$?"
  cct add 'Help' >/dev/null 2>&1; chk "case-variant reserved label rejected -> 2" "2" "$?"

  echo "-- C#1/M4: same-label refresh"
  add_tok work "sk-work1" >/dev/null 2>&1; chk "work accepted -> 0" "0" "$?"
  add_tok work "sk-work3" >/dev/null 2>&1; chk "same-label refresh silent -> rc 0" "0" "$?"
  chk "refreshed: token now sk-work3" "sk-work3" "$(_cct_envtok CCT_TOKEN_WORK)"

  echo "-- C#1/M4: invalid run/check labels are rejected instead of aliasing existing keys"
  printf 'CCT_TOKEN_AB=sk-ab1\n' >> "$CCT_ENV_FILE"
  cap="$(cct 'a@b' 2>&1 >/dev/null)"; rc=$?
  chk "invalid run label -> 2" "2" "$rc"
  case "$cap" in *"tok=[sk-ab1]"*) chk "invalid run did not inject normalized token" "y" "n" ;; *) chk "invalid run did not inject normalized token" "y" "y" ;; esac
  cct check 'a@b' >/dev/null 2>&1; chk "invalid check label -> 2" "2" "$?"

  echo "-- C#1 (d): cct ls shows no phantom label from annotation"
  cap="$(cct ls 2>&1)"
  chk "ls has no cctlabel phantom" "0" "$(printf '%s' "$cap" | grep -c 'cctlabel')"
  chk_has "ls lists work" "cct work" "$cap"

  echo "-- M3: reserved-subcommand labels rejected; 'use' allowed"
  cct add check >/dev/null 2>&1; chk "add check -> 2" "2" "$?"
  cct add who >/dev/null 2>&1; chk "add who -> 2" "2" "$?"
  cct add help >/dev/null 2>&1; chk "add help -> 2" "2" "$?"
  add_tok use "sk-use" >/dev/null 2>&1; chk "add use -> 0" "0" "$?"
  cap="$(cct use 2>&1 >/dev/null)"; chk_has "cct use injects sk-use" "tok=[sk-use]" "$cap"

  echo "-- N3: CRLF token still triggers duplicate warning"
  cap="$(printf '%s\r\n' "sk-good" | cct add dupacct 2>&1)"
  chk_has "CRLF dup warning fires" "동일" "$cap"

  echo "-- C#3: bare cct injects the default-label setup-token; never the ambient token or keychain"
  export CCT_DEFAULT_LABEL=use
  export CLAUDE_CODE_OAUTH_TOKEN="SENTINEL-AMBIENT"
  cap="$(cct 2>&1 >/dev/null)"
  case "$cap" in *SENTINEL-AMBIENT*) chk "ambient token did NOT reach claude" "y" "n" ;; *) chk "ambient token did NOT reach claude" "y" "y" ;; esac
  chk_has "bare cct injected default-label token" "tok=[sk-use]" "$cap"
  chk "parent shell still has sentinel" "SENTINEL-AMBIENT" "${CLAUDE_CODE_OAUTH_TOKEN:-}"
  unset CLAUDE_CODE_OAUTH_TOKEN
  cap="$(CCT_DEFAULT_LABEL=nosuchdefault cct 2>&1 >/dev/null)"; rc=$?
  chk "missing default-label token -> rc 1 (no keychain fallback)" "1" "$rc"

  echo "-- C#4: --dangerously-skip-permissions opt-out + extra flags"
  cap="$(cct 2>&1 >/dev/null)"; chk_has "default has skip-permissions" "--dangerously-skip-permissions" "$cap"
  cap="$(CCT_SKIP_PERMS=0 cct 2>&1 >/dev/null)"
  case "$cap" in *--dangerously-skip-permissions*) chk "SKIP_PERMS=0 removes flag" "y" "n";; *) chk "SKIP_PERMS=0 removes flag" "y" "y";; esac
  cap="$(CCT_CLAUDE_FLAGS='--foo --bar' cct 2>&1 >/dev/null)"
  chk_has "CCT_CLAUDE_FLAGS adds --foo" "--foo" "$cap"
  chk_has "CCT_CLAUDE_FLAGS adds --bar" "--bar" "$cap"
  unset CCT_DEFAULT_LABEL

  echo "-- C#5: labeled setup-token sessions suppress web-only feature calls by default"
  export CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1
  export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
  export CLAUDE_CODE_DISABLE_BACKGROUND_PLUGIN_REFRESH=1
  cap="$(cct use 2>&1 >/dev/null)"
  chk_has "labeled run disables web-only feature calls" "web=[1,1,1]" "$cap"
  cap="$(CCT_DISABLE_WEB_FEATURES=0 cct use 2>&1 >/dev/null)"
  chk_has "CCT_DISABLE_WEB_FEATURES=0 opt-out" "web=[<unset>,<unset>,<unset>]" "$cap"
  chk "opt-out preserves parent web disables" "1,1,1" \
    "${CLAUDE_CODE_DISABLE_ADVISOR_TOOL:-<unset>},${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-<unset>},${CLAUDE_CODE_DISABLE_BACKGROUND_PLUGIN_REFRESH:-<unset>}"

  echo "-- N6: check probes the real binary, not a shell claude function/alias"
  claude(){ echo "SHADOW-FN" >&2; return 9; }   # shadowing function must be bypassed
  cct check good >/dev/null 2>&1; chk "probe bypasses claude function -> 0" "0" "$?"
  unset -f claude
  cap="$(PATH="/usr/bin:/bin" cct check good 2>&1)"; rc=$?
  chk "claude off PATH -> rc 1" "1" "$rc"
  chk_has "claude off PATH -> probe-unavailable msg" "점검 불가" "$cap"

  echo "-- H2: update path leaves tokens.env at mode 600"
  chk "tokens.env mode 600" "600" "$(stat -c '%a' "$CCT_ENV_FILE" 2>/dev/null || stat -f '%Lp' "$CCT_ENV_FILE")"

  echo "-- N5: write failure -> rc 1 and NO success line"
  local bad="$sb/locked"; mkdir -p "$bad"; chmod 000 "$bad"
  cap="$(CCT_ENV_FILE="$bad/tokens.env" sh -c 'true'; printf '%s\n' "sk-x" | CCT_ENV_FILE="$bad/tokens.env" cct add failacct 2>&1)"; rc=$?
  chmod 755 "$bad"
  chk "write failure rc=1" "1" "$rc"
  case "$cap" in *완료*) chk "no success line on failure" "y" "n";; *) chk "no success line on failure" "y" "y";; esac

  echo "-- backward-compat: legacy tokens.env (no annotation, empty key) still works"
  local sb2; sb2="$(mktemp -d)"
  printf 'CCT_TOKEN_LEGACY=legacytok\nCCT_TOKEN_=orphantok\n' > "$sb2/tokens.env"
  cap="$(CCT_ENV_FILE="$sb2/tokens.env" cct legacy 2>&1 >/dev/null)"
  chk_has "legacy label still selectable" "tok=[legacytok]" "$cap"
  cap="$(CCT_ENV_FILE="$sb2/tokens.env" cct ls 2>&1)"
  chk_has "legacy label listed" "cct legacy" "$cap"
}

# -------------------------------------------------------------------------
# Edge cases + cross-shell smoke (install tilde expansion, zsh sourcing).
test_extra(){
  echo "== edge + cross-shell =="
  local H G rc out sbz
  export CCT_STICKY=0   # 크로스셸 스모크도 비고정(inline) 기준
  echo "-- install.sh H1: stored ~-path core.excludesfile is tilde-expanded (not literal)"
  H="$(mktemp -d)"; G="$H/.gitconfig"; mkdir -p "$H/sub"
  local tilde_path
  tilde_path="$(printf '\176/%s' 'sub/ig')"
  HOME="$H" GIT_CONFIG_GLOBAL="$G" git config --global core.excludesfile "$tilde_path"
  ( cd "$REPO" && HOME="$H" GIT_CONFIG_GLOBAL="$G" SHELL=/bin/bash bash install.sh ) >/dev/null 2>&1; rc=$?
  chk "installer rc=0" "0" "$rc"
  chk "tilde path expanded to HOME/sub/ig" "yes" "$([ -f "$H/sub/ig" ] && echo yes || echo no)"
  chk "no literal ~ dir leaked into repo" "no" "$([ -e "$REPO/~" ] && echo yes || echo no)"

  echo "-- bash set -u smoke: bare cct and cct check do not read unbound positional args"
  sbz="$(mktemp -d)"; mk_shim "$sbz/bin"
  printf 'CCT_TOKEN_GV=sk-uenv\n' > "$sbz/u.env"
  out="$(PATH="$sbz/bin:$PATH" CCT_ENV_FILE="$sbz/u.env" bash -uc ". '$REPO/cct.sh'; cct" 2>&1)"; rc=$?
  chk "bash set -u: bare cct -> 0" "0" "$rc"
  chk_has "bash set -u: bare cct injects default-label token" "tok=[sk-uenv]" "$out"
  out="$(PATH="$sbz/bin:$PATH" CCT_ENV_FILE="$sbz/empty.env" bash -uc ". '$REPO/cct.sh'; cct check" 2>&1)"; rc=$?
  chk "bash set -u: cct check -> 0" "0" "$rc"
  chk_has "bash set -u: cct check reports empty" "등록된 계정 없음" "$out"

  echo "-- bash set -e + pipefail smoke: expected misses still print diagnostics"
  sbz="$(mktemp -d)"; mk_shim "$sbz/bin"
  out="$(PATH="$sbz/bin:$PATH" CCT_ENV_FILE="$sbz/e.env" bash -e -o pipefail -c ". '$REPO/cct.sh'; cct nosuch" 2>&1)"; rc=$?
  chk "bash set -e pipefail: missing run -> 1" "1" "$rc"
  chk_has "bash set -e pipefail: missing run prints token error" "토큰 없음" "$out"
  printf 'CCT_TOKEN_GOOD=sk-good\n' > "$sbz/e.env"
  out="$(PATH="/usr/bin:/bin" CCT_ENV_FILE="$sbz/e.env" bash -e -o pipefail -c ". '$REPO/cct.sh'; cct check good" 2>&1)"; rc=$?
  chk "bash set -e pipefail: missing claude probe -> 1" "1" "$rc"
  chk_has "bash set -e pipefail: missing claude probe prints diagnostic" "점검 불가" "$out"
  out="$(printf 'sk-first\n' | PATH="$sbz/bin:$PATH" CCT_ENV_FILE="$sbz/new.env" bash -e -o pipefail -c ". '$REPO/cct.sh'; cct add first >/dev/null; cct first" 2>&1)"; rc=$?
  chk "bash set -e pipefail: first add and run -> 0" "0" "$rc"
  chk_has "bash set -e pipefail: first add injects token" "tok=[sk-first]" "$out"

  if command -v zsh >/dev/null 2>&1; then
    echo "-- zsh smoke: cct.sh sources and runs under zsh (exercises zsh-only branches)"
    sbz="$(mktemp -d)"; mk_shim "$sbz/bin"
    printf 'CCT_TOKEN_GV=sk-z0\n' > "$sbz/t.env"
    chk "zsh -n parses cct.sh" "0" "$(zsh -n "$REPO/cct.sh" >/dev/null 2>&1; echo $?)"
    out="$(PATH="$sbz/bin:$PATH" CCT_ENV_FILE="$sbz/t.env" CCT_CLAUDE_FLAGS='--za --zb' zsh -c "set +u; . '$REPO/cct.sh'; cct" 2>&1)"
    chk_has "zsh: skip-perms flag present" "--dangerously-skip-permissions" "$out"
    chk_has "zsh: CCT_CLAUDE_FLAGS split (--za)" "--za" "$out"
    chk_has "zsh: CCT_CLAUDE_FLAGS split (--zb)" "--zb" "$out"
    out="$(PATH="$sbz/bin:$PATH" CCT_ENV_FILE="$sbz/t.env" zsh -c "set +u; . '$REPO/cct.sh'; printf 'sk-z\n' | cct add zlabel >/dev/null 2>&1; cct check zlabel" 2>&1)"
    chk_has "zsh: add+check works" "✅ 유효" "$out"
  else
    echo "-- zsh smoke skipped (no zsh)"
  fi
}

# -------------------------------------------------------------------------
# sticky 활성 프로필 (cct <라벨> 기억 → 그냥 claude/새 셸도 같은 계정).
test_sticky(){
  echo "== sticky 활성 프로필 =="
  set +u
  local sb cap
  sb="$(mktemp -d)"; mk_shim "$sb/bin"
  export PATH="$sb/bin:$PATH"
  export CCT_ENV_FILE="$sb/tokens.env" CCT_ACTIVE_FILE="$sb/active"
  unset CCT_STICKY CLAUDE_CODE_OAUTH_TOKEN   # 기본 sticky ON
  # shellcheck disable=SC1090
  . "$REPO/cct.sh"
  add_tok good "sk-good" >/dev/null 2>&1
  add_tok other "sk-other" >/dev/null 2>&1

  echo "-- cct <라벨> 가 활성 프로필을 저장하고 현재 셸에 export 한다"
  cct good >/dev/null 2>&1
  chk "active file == good" "good" "$(cat "$sb/active" 2>/dev/null)"
  chk "현재 셸에 토큰 export" "sk-good" "${CLAUDE_CODE_OAUTH_TOKEN:-}"
  chk_has "cct active 표시" "활성 프로필: good" "$(cct active 2>&1)"
  chk_has "이후 그냥 claude 가 활성 토큰 사용" "tok=[sk-good]" "$(claude 2>&1)"

  echo "-- 새 셸(source)도 활성 프로필 자동 로드"
  cap="$(PATH="$sb/bin:$PATH" CCT_ENV_FILE="$sb/tokens.env" CCT_ACTIVE_FILE="$sb/active" bash -c ". '$REPO/cct.sh'; claude" 2>&1)"
  chk_has "새 셸: 자동 로드된 토큰으로 claude" "tok=[sk-good]" "$cap"

  echo "-- cct <다른라벨> 로 전환 + 라벨없는 cct 는 활성을 따른다"
  cct other >/dev/null 2>&1
  chk "active file == other" "other" "$(cat "$sb/active" 2>/dev/null)"
  chk_has "전환 후 claude 가 새 토큰" "tok=[sk-other]" "$(claude 2>&1)"
  chk_has "bare cct 가 활성(other) 사용" "tok=[sk-other]" "$(cct 2>&1)"

  echo "-- cct off 로 해제 (파일 삭제 + 현재 셸 env 해제)"
  cct off >/dev/null 2>&1
  chk "active 파일 제거" "no" "$([ -e "$sb/active" ] && echo yes || echo no)"
  chk "현재 셸 토큰 해제" "" "${CLAUDE_CODE_OAUTH_TOKEN:-}"

  echo "-- CCT_STICKY=0 이면 inline 만 (셸/디스크 미변경)"
  cap="$(PATH="$sb/bin:$PATH" CCT_ENV_FILE="$sb/tokens.env" CCT_ACTIVE_FILE="$sb/active" CCT_STICKY=0 bash -c ". '$REPO/cct.sh'; cct good >/dev/null 2>&1; echo tok=[\${CLAUDE_CODE_OAUTH_TOKEN:-<unset>}]; [ -e '$sb/active' ] && echo FILE-YES || echo FILE-NO" 2>&1)"
  chk_has "CCT_STICKY=0: 셸에 토큰 안 남음" "tok=[<unset>]" "$cap"
  chk_has "CCT_STICKY=0: active 파일 안 생김" "FILE-NO" "$cap"
}

# -------------------------------------------------------------------------
test_wallet(){
  echo "== wallet storage =="
  local sb cap rc before after inode_before inode_after dead_pid now cmd
  sb="$(mktemp -d)"
  export CCT_ENV_FILE="$sb/tokens.env"
  export CCT_STICKY=0
  printf '# user comment\nOTHER=keep\nCCT_TOKEN_ALPHA=sk-alpha-old\n#cctlabel:CCT_TOKEN_ALPHA=alpha\n' > "$CCT_ENV_FILE"
  chmod 640 "$CCT_ENV_FILE"
  # shellcheck disable=SC1090
  . "$REPO/cct.sh"

  echo "-- characterization: existing add/update behavior"
  cap="$(add_tok beta "sk-beta" 2>&1)"; rc=$?
  chk "characterization add rc=0" "0" "$rc"
  chk_has "characterization add stores token" "CCT_TOKEN_BETA=sk-beta" "$(cat "$CCT_ENV_FILE")"
  chk_has "characterization add stores annotation" "#cctlabel:CCT_TOKEN_BETA=beta" "$(cat "$CCT_ENV_FILE")"
  cap="$(add_tok alpha "sk-alpha-new" 2>&1)"; rc=$?
  chk "characterization rotate rc=0" "0" "$rc"
  chk_has "characterization rotate replaces token" "CCT_TOKEN_ALPHA=sk-alpha-new" "$(cat "$CCT_ENV_FILE")"
  chk_has "characterization preserves comments" "# user comment" "$(cat "$CCT_ENV_FILE")"
  chk_has "characterization preserves unrelated lines" "OTHER=keep" "$(cat "$CCT_ENV_FILE")"
  chk "characterization wallet mode 600" "600" "$(stat -c '%a' "$CCT_ENV_FILE" 2>/dev/null || stat -f '%Lp' "$CCT_ENV_FILE")"
  case "$cap" in *sk-alpha-new*) chk "characterization output hides token" "hidden" "exposed" ;; *) chk "characterization output hides token" "hidden" "hidden" ;; esac

  rm -rf "$sb"

  if [ "${CCT_TEST_CASE:-}" = "live-lock" ]; then
    sb="$(mktemp -d)"
    export CCT_ENV_FILE="$sb/tokens.env"
    printf '# locked wallet\nCCT_TOKEN_ALPHA=sk-alpha\n#cctlabel:CCT_TOKEN_ALPHA=alpha\n' > "$CCT_ENV_FILE"
    chmod 600 "$CCT_ENV_FILE"
    mkdir "$CCT_ENV_FILE.lock"
    printf '%s %s\n' "$$" "$(date +%s)" > "$CCT_ENV_FILE.lock/owner"
    before="$(wallet_sha "$CCT_ENV_FILE")"
    cap="$(add_tok beta "sk-beta" 2>&1)"; rc=$?
    after="$(wallet_sha "$CCT_ENV_FILE")"
    chk "live lock mutation returns nonzero" "1" "$rc"
    chk "live lock preserves wallet SHA-256" "$before" "$after"
    chk_has "live lock reports wallet busy" "wallet busy" "$cap"
    chk "live lock owner remains intact" "yes" "$([ -f "$CCT_ENV_FILE.lock/owner" ] && echo yes || echo no)"
    case "$cap" in *완료*) chk "live lock prints no success line" "no" "yes" ;; *) chk "live lock prints no success line" "no" "no" ;; esac
    rm -rf "$sb"
    return
  fi

  sb="$(mktemp -d)"
  export CCT_ENV_FILE="$sb/tokens.env"
  printf '# atomic wallet\nOTHER=keep\nCCT_TOKEN_ALPHA=sk-alpha-old\n#cctlabel:CCT_TOKEN_ALPHA=alpha\n' > "$CCT_ENV_FILE"
  chmod 640 "$CCT_ENV_FILE"

  echo "-- atomic add and rotate with rolling backup"
  before="$(wallet_sha "$CCT_ENV_FILE")"; inode_before="$(wallet_inode "$CCT_ENV_FILE")"
  cap="$(add_tok beta "sk-beta" 2>&1)"; rc=$?
  after="$(wallet_sha "$CCT_ENV_FILE")"; inode_after="$(wallet_inode "$CCT_ENV_FILE")"
  chk "atomic first add rc=0" "0" "$rc"
  chk "atomic first add replaces wallet inode" "changed" "$([ "$inode_before" != "$inode_after" ] && echo changed || echo unchanged)"
  chk "atomic first add changes wallet SHA-256" "changed" "$([ "$before" != "$after" ] && echo changed || echo unchanged)"
  chk "atomic first add backup matches original" "$before" "$(wallet_sha "$CCT_ENV_FILE.bak" 2>/dev/null || echo missing)"
  chk "atomic first add wallet mode 600" "600" "$(wallet_mode "$CCT_ENV_FILE")"
  chk "atomic first add backup mode 600" "600" "$(wallet_mode "$CCT_ENV_FILE.bak" 2>/dev/null || echo missing)"
  chk "atomic first add leaves no temp" "0" "$(find "$sb" -maxdepth 1 -name 'tokens.env.tmp.*' -print | wc -l | tr -d ' ')"
  chk "atomic first add releases lock" "no" "$([ -e "$CCT_ENV_FILE.lock" ] && echo yes || echo no)"

  before="$(wallet_sha "$CCT_ENV_FILE")"; inode_before="$(wallet_inode "$CCT_ENV_FILE")"
  cap="$(add_tok alpha "sk-alpha-new" 2>&1)"; rc=$?
  inode_after="$(wallet_inode "$CCT_ENV_FILE")"
  chk "atomic rotate rc=0" "0" "$rc"
  chk "atomic rotate replaces wallet inode" "changed" "$([ "$inode_before" != "$inode_after" ] && echo changed || echo unchanged)"
  chk "atomic rotate backup matches pre-rotate wallet" "$before" "$(wallet_sha "$CCT_ENV_FILE.bak" 2>/dev/null || echo missing)"
  chk "atomic rotate backup mode 600" "600" "$(wallet_mode "$CCT_ENV_FILE.bak" 2>/dev/null || echo missing)"
  chk "atomic rotate annotation remains singular" "1" "$(grep -c '^#cctlabel:CCT_TOKEN_ALPHA=alpha$' "$CCT_ENV_FILE")"
  chk "atomic rotate removes old token" "0" "$(grep -c '^CCT_TOKEN_ALPHA=sk-alpha-old$' "$CCT_ENV_FILE" || true)"
  chk_has "atomic rotate preserves unrelated line" "OTHER=keep" "$(cat "$CCT_ENV_FILE")"
  cap="$(add_tok gamma "sk-beta" 2>&1)"
  chk_has "duplicate-token warning preserved" "동일" "$cap"

  echo "-- stale, malformed, and symlink lock handling"
  dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid+1)); done
  now="$(date +%s)"
  mkdir "$CCT_ENV_FILE.lock"
  printf '%s %s\n' "$dead_pid" "$((now-120))" > "$CCT_ENV_FILE.lock/owner"
  cap="$(add_tok stale "sk-stale" 2>&1)"; rc=$?
  chk "dead stale lock is reclaimed" "0" "$rc"
  chk_has "stale-lock mutation stored account" "CCT_TOKEN_STALE=sk-stale" "$(cat "$CCT_ENV_FILE")"
  chk "stale-lock mutation releases lock" "no" "$([ -e "$CCT_ENV_FILE.lock" ] && echo yes || echo no)"
  rm -rf "$CCT_ENV_FILE.lock"

  mkdir "$CCT_ENV_FILE.lock"
  before="$(wallet_sha "$CCT_ENV_FILE")"
  cap="$(add_tok malformed "sk-malformed" 2>&1)"; rc=$?
  after="$(wallet_sha "$CCT_ENV_FILE")"
  chk "missing lock owner is refused" "1" "$rc"
  chk "missing lock owner preserves wallet" "$before" "$after"
  chk_has "missing lock owner reports busy" "wallet busy" "$cap"
  rm -rf "$CCT_ENV_FILE.lock"

  mkdir "$sb/lock-target"
  ln -s "$sb/lock-target" "$CCT_ENV_FILE.lock"
  before="$(wallet_sha "$CCT_ENV_FILE")"
  cap="$(add_tok symlinked "sk-symlinked" 2>&1)"; rc=$?
  after="$(wallet_sha "$CCT_ENV_FILE")"
  chk "symlink lock is refused" "1" "$rc"
  chk "symlink lock preserves wallet" "$before" "$after"
  chk "symlink lock target remains" "yes" "$([ -d "$sb/lock-target" ] && echo yes || echo no)"
  rm "$CCT_ENV_FILE.lock"

  echo "-- unsafe backup paths are refused without side effects"
  rm -f "$CCT_ENV_FILE.bak"
  mkdir "$CCT_ENV_FILE.bak"
  chmod 755 "$CCT_ENV_FILE.bak"
  before="$(wallet_sha "$CCT_ENV_FILE")"
  cap="$(add_tok backupdir "sk-backupdir" 2>&1)"; rc=$?
  after="$(wallet_sha "$CCT_ENV_FILE")"
  chk "backup directory returns nonzero" "1" "$rc"
  chk "backup directory preserves wallet" "$before" "$after"
  chk "backup directory mode is unchanged" "755" "$(wallet_mode "$CCT_ENV_FILE.bak")"
  case "$cap" in *완료*) chk "backup directory prints no success" "no" "yes" ;; *) chk "backup directory prints no success" "no" "no" ;; esac
  chmod 755 "$CCT_ENV_FILE.bak"
  rm -rf "$CCT_ENV_FILE.bak"

  echo "-- injected mutation failures preserve original and clean up"
  printf '# failure wallet\nCCT_TOKEN_ALPHA=sk-alpha\n#cctlabel:CCT_TOKEN_ALPHA=alpha\n' > "$CCT_ENV_FILE"
  chmod 600 "$CCT_ENV_FILE"
  for cmd in mktemp cp chmod mv; do
    mkdir "$sb/fail-$cmd"
    printf '#!/bin/sh\nexit 1\n' > "$sb/fail-$cmd/$cmd"
    chmod 700 "$sb/fail-$cmd/$cmd"
  done
  mkdir "$sb/fail-backup-chmod"
  printf '%s\n' \
    '#!/bin/sh' \
    "case \"\$2\" in" \
    "  \"\$CCT_FAIL_BACKUP_PATH\") exit 1 ;;" \
    "  \"\$CCT_FAIL_BACKUP_PATH\".tmp.*)" \
    "    count=\"\$(cat \"\$CCT_CHMOD_COUNT_FILE\" 2>/dev/null || printf 0)\"" \
    "    count=\$((count + 1))" \
    "    printf \"%s\\n\" \"\$count\" > \"\$CCT_CHMOD_COUNT_FILE\"" \
    "    [ \"\$count\" -ne 2 ] || exit 1" \
    '    ;;' \
    'esac' \
    "exec \"\$CCT_REAL_CHMOD\" \"\$@\"" > "$sb/fail-backup-chmod/chmod"
  chmod 700 "$sb/fail-backup-chmod/chmod"
  before="$(wallet_sha "$CCT_ENV_FILE")"
  cap="$(PATH="$sb/fail-mktemp:$PATH" add_tok tempfail "sk-tempfail" 2>&1)"; rc=$?
  chk "temp creation failure returns nonzero" "1" "$rc"
  chk "temp creation failure preserves wallet" "$before" "$(wallet_sha "$CCT_ENV_FILE")"
  case "$cap" in *완료*) chk "temp creation failure prints no success" "no" "yes" ;; *) chk "temp creation failure prints no success" "no" "no" ;; esac
  chk "temp creation failure releases lock" "no" "$([ -e "$CCT_ENV_FILE.lock" ] && echo yes || echo no)"

  before="$(wallet_sha "$CCT_ENV_FILE")"
  cap="$(PATH="$sb/fail-cp:$PATH" add_tok backupfail "sk-backupfail" 2>&1)"; rc=$?
  chk "backup failure returns nonzero" "1" "$rc"
  chk "backup failure preserves wallet" "$before" "$(wallet_sha "$CCT_ENV_FILE")"
  case "$cap" in *완료*) chk "backup failure prints no success" "no" "yes" ;; *) chk "backup failure prints no success" "no" "no" ;; esac
  chk "backup failure leaves no temp" "0" "$(find "$sb" -maxdepth 1 -name 'tokens.env.tmp.*' -print | wc -l | tr -d ' ')"
  chk "backup failure releases lock" "no" "$([ -e "$CCT_ENV_FILE.lock" ] && echo yes || echo no)"

  printf '# prior backup\nCCT_TOKEN_PRIOR=sk-prior\n' > "$CCT_ENV_FILE.bak"
  chmod 644 "$CCT_ENV_FILE.bak"
  before="$(wallet_sha "$CCT_ENV_FILE")"
  local backup_before real_chmod
  backup_before="$(wallet_sha "$CCT_ENV_FILE.bak")"
  real_chmod="$(command -v chmod)"
  rm -f "$sb/backup-chmod-count"
  cap="$(CCT_FAIL_BACKUP_PATH="$CCT_ENV_FILE.bak" \
    CCT_CHMOD_COUNT_FILE="$sb/backup-chmod-count" \
    CCT_REAL_CHMOD="$real_chmod" \
    PATH="$sb/fail-backup-chmod:$PATH" \
    add_tok backupchmodfail "sk-backupchmodfail" 2>&1)"; rc=$?
  chk "backup chmod failure returns nonzero" "1" "$rc"
  chk "backup chmod failure preserves wallet" "$before" "$(wallet_sha "$CCT_ENV_FILE")"
  chk "backup chmod failure preserves prior backup" "$backup_before" "$(wallet_sha "$CCT_ENV_FILE.bak")"
  chk "backup chmod failure copies no current secret to wide backup" "0" \
    "$(grep -c '^CCT_TOKEN_ALPHA=sk-alpha$' "$CCT_ENV_FILE.bak" || true)"
  case "$cap" in *완료*) chk "backup chmod failure prints no success" "no" "yes" ;; *) chk "backup chmod failure prints no success" "no" "no" ;; esac
  chk "backup chmod failure leaves no temp" "0" "$(find "$sb" -maxdepth 1 -name 'tokens.env*.tmp.*' -print | wc -l | tr -d ' ')"
  chk "backup chmod failure releases lock" "no" "$([ -e "$CCT_ENV_FILE.lock" ] && echo yes || echo no)"
  rm -f "$CCT_ENV_FILE.bak"

  before="$(wallet_sha "$CCT_ENV_FILE")"
  cap="$(PATH="$sb/fail-chmod:$PATH" add_tok chmodfail "sk-chmodfail" 2>&1)"; rc=$?
  chk "chmod failure returns nonzero" "1" "$rc"
  chk "chmod failure preserves wallet" "$before" "$(wallet_sha "$CCT_ENV_FILE")"
  case "$cap" in *완료*) chk "chmod failure prints no success" "no" "yes" ;; *) chk "chmod failure prints no success" "no" "no" ;; esac
  chk "chmod failure leaves no temp" "0" "$(find "$sb" -maxdepth 1 -name 'tokens.env.tmp.*' -print | wc -l | tr -d ' ')"
  chk "chmod failure releases lock" "no" "$([ -e "$CCT_ENV_FILE.lock" ] && echo yes || echo no)"

  before="$(wallet_sha "$CCT_ENV_FILE")"
  cap="$(PATH="$sb/fail-mv:$PATH" add_tok mvfail "sk-mvfail" 2>&1)"; rc=$?
  chk "mv failure returns nonzero" "1" "$rc"
  chk "mv failure preserves wallet" "$before" "$(wallet_sha "$CCT_ENV_FILE")"
  case "$cap" in *완료*) chk "mv failure prints no success" "no" "yes" ;; *) chk "mv failure prints no success" "no" "no" ;; esac
  chk "mv failure leaves no temp" "0" "$(find "$sb" -maxdepth 1 -name 'tokens.env.tmp.*' -print | wc -l | tr -d ' ')"
  chk "mv failure releases lock" "no" "$([ -e "$CCT_ENV_FILE.lock" ] && echo yes || echo no)"

  rm -rf "$sb"
}

test_accounts(){
  echo "== account lifecycle =="
  set +u
  local sb cap direct explicit rc before after active_before env_before fixture_target fixture_home
  sb="$(mktemp -d)"
  mk_shim "$sb/bin"
  export PATH="$sb/bin:$PATH"
  export CCT_ENV_FILE="$sb/tokens.env"
  export CCT_ACTIVE_FILE="$sb/cct-active"
  export CCT_STICKY=0
  unset CLAUDE_CODE_OAUTH_TOKEN
  write_account_fixture "$CCT_ENV_FILE" \
    '# account fixture' \
    'OTHER=keep' \
    'CCT_TOKEN_ALPHA=fixture-alpha' \
    '#cctlabel:CCT_TOKEN_ALPHA=alpha' \
    'CCT_TOKEN_BETA=fixture-beta' \
    '#cctlabel:CCT_TOKEN_BETA=beta' \
    'CCT_TOKEN_USE=fixture-use' \
    '#cctlabel:CCT_TOKEN_USE=use' \
    'CCT_TOKEN_RUN=fixture-legacy-run' \
    '#cctlabel:CCT_TOKEN_RUN=run' \
    'CCT_TOKEN_RM=fixture-legacy-rm' \
    '#cctlabel:CCT_TOKEN_RM=rm' \
    'CCT_TOKEN_RENAME=fixture-legacy-rename' \
    '#cctlabel:CCT_TOKEN_RENAME=rename'
  # shellcheck disable=SC1090
  . "$REPO/cct.sh"

  echo "-- characterization: normal labels and sticky selection"
  cap="$(cct alpha --version 2>&1 >/dev/null)"; rc=$?
  chk "characterization direct label launch rc=0" "0" "$rc"
  chk_has "characterization direct label forwards args" "args=[--dangerously-skip-permissions --version]" "$cap"
  chk_has "characterization direct label injects token" "tok=[fixture-alpha]" "$cap"
  export CCT_STICKY=1
  cct alpha --version >/dev/null 2>&1; rc=$?
  chk "characterization sticky direct launch rc=0" "0" "$rc"
  chk "characterization sticky direct writes active" "alpha" "$(cat "$CCT_ACTIVE_FILE" 2>/dev/null)"
  chk "characterization sticky direct exports token" "fixture-alpha" "${CLAUDE_CODE_OAUTH_TOKEN:-}"
  export CCT_STICKY=0
  rm -f "$CCT_ACTIVE_FILE"
  unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_DISABLE_ADVISOR_TOOL \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC CLAUDE_CODE_DISABLE_BACKGROUND_PLUGIN_REFRESH

  if [ "${CCT_TEST_CASE:-}" = "lifecycle-signals" ]; then
    echo "-- TERM after wallet commit restores rename and active rm transactions"
    printf '%s\n' alpha > "$CCT_ACTIVE_FILE"
    chmod 600 "$CCT_ACTIVE_FILE"
    export CLAUDE_CODE_OAUTH_TOKEN=parent-sentinel
    export CLAUDE_CODE_DISABLE_ADVISOR_TOOL=parent-advisor
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=parent-traffic
    export CLAUDE_CODE_DISABLE_BACKGROUND_PLUGIN_REFRESH=parent-refresh
    env_before="${CLAUDE_CODE_OAUTH_TOKEN},${CLAUDE_CODE_DISABLE_ADVISOR_TOOL},${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC},${CLAUDE_CODE_DISABLE_BACKGROUND_PLUGIN_REFRESH}"
    mkdir "$sb/signal-mv"
    cat > "$sb/signal-mv/mv" <<'SHIM'
#!/bin/sh
last=""
for arg do last="$arg"; done
if [ "$last" = "$CCT_SIGNAL_WALLET" ] && [ ! -e "$CCT_SIGNAL_MARKER" ]; then
  "$CCT_REAL_MV" "$@" || exit $?
  : > "$CCT_SIGNAL_MARKER"
  kill -TERM "$PPID"
  exit 0
fi
exec "$CCT_REAL_MV" "$@"
SHIM
    chmod 700 "$sb/signal-mv/mv"

    before="$(wallet_sha "$CCT_ENV_FILE")"
    active_before="$(wallet_sha "$CCT_ACTIVE_FILE")"
    CCT_SIGNAL_WALLET="$CCT_ENV_FILE" CCT_SIGNAL_MARKER="$sb/rename-term" \
      CCT_REAL_MV="$(command -v mv)" PATH="$sb/signal-mv:$PATH" \
      cct rename alpha fresh > "$sb/rename-term.out" 2>&1
    rc=$?
    chk "rename TERM after wallet commit -> 1" "1" "$rc"
    chk "rename TERM was injected" "yes" "$([ -f "$sb/rename-term" ] && echo yes || echo no)"
    chk "rename TERM restores wallet" "$before" "$(wallet_sha "$CCT_ENV_FILE")"
    chk "rename TERM preserves active" "$active_before" "$(wallet_sha "$CCT_ACTIVE_FILE")"
    chk "rename TERM preserves parent env" "$env_before" \
      "${CLAUDE_CODE_OAUTH_TOKEN},${CLAUDE_CODE_DISABLE_ADVISOR_TOOL},${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC},${CLAUDE_CODE_DISABLE_BACKGROUND_PLUGIN_REFRESH}"
    chk "rename TERM releases lock" "no" "$([ -e "$CCT_ENV_FILE.lock" ] && echo yes || echo no)"
    chk "rename TERM removes wallet temp" "0" \
      "$(find "$sb" -maxdepth 1 -name 'tokens.env.tmp.*' -print | wc -l | tr -d ' ')"
    chk "rename TERM removes active temp" "0" \
      "$(find "$sb" -maxdepth 1 -name 'cct-active.tmp.*' -print | wc -l | tr -d ' ')"

    cp "$CCT_ENV_FILE.bak" "$CCT_ENV_FILE"
    chmod 600 "$CCT_ENV_FILE"
    before="$(wallet_sha "$CCT_ENV_FILE")"
    active_before="$(wallet_sha "$CCT_ACTIVE_FILE")"
    CCT_SIGNAL_WALLET="$CCT_ENV_FILE" CCT_SIGNAL_MARKER="$sb/rm-term" \
      CCT_REAL_MV="$(command -v mv)" PATH="$sb/signal-mv:$PATH" \
      cct rm alpha --force > "$sb/rm-term.out" 2>&1
    rc=$?
    chk "active rm TERM after wallet commit -> 1" "1" "$rc"
    chk "active rm TERM was injected" "yes" "$([ -f "$sb/rm-term" ] && echo yes || echo no)"
    chk "active rm TERM restores wallet" "$before" "$(wallet_sha "$CCT_ENV_FILE")"
    chk "active rm TERM preserves active" "$active_before" "$(wallet_sha "$CCT_ACTIVE_FILE")"
    chk "active rm TERM preserves parent env" "$env_before" \
      "${CLAUDE_CODE_OAUTH_TOKEN},${CLAUDE_CODE_DISABLE_ADVISOR_TOOL},${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC},${CLAUDE_CODE_DISABLE_BACKGROUND_PLUGIN_REFRESH}"
    chk "active rm TERM releases lock" "no" "$([ -e "$CCT_ENV_FILE.lock" ] && echo yes || echo no)"
    chk "active rm TERM removes wallet temp" "0" \
      "$(find "$sb" -maxdepth 1 -name 'tokens.env.tmp.*' -print | wc -l | tr -d ' ')"
    chk "active rm TERM removes active temp" "0" \
      "$(find "$sb" -maxdepth 1 -name 'cct-active.tmp.*' -print | wc -l | tr -d ' ')"
    rm -rf "$sb"
    return
  fi

  if [ "${CCT_TEST_CASE:-}" = "lifecycle-refusals" ]; then
    echo "-- lifecycle refusals preserve wallet and active state"
    printf '%s\n' alpha > "$CCT_ACTIVE_FILE"
    chmod 600 "$CCT_ACTIVE_FILE"
    before="$(wallet_sha "$CCT_ENV_FILE")"
    active_before="$(wallet_sha "$CCT_ACTIVE_FILE")"

    cct run >/dev/null 2>&1; chk "run missing label -> 2" "2" "$?"
    cct run 'bad-label' >/dev/null 2>&1; chk "run invalid label -> 2" "2" "$?"
    cct rm >/dev/null 2>&1; chk "rm missing label -> 2" "2" "$?"
    cct rm alpha --bad >/dev/null 2>&1; chk "rm bad option -> 2" "2" "$?"
    cct rm alpha --force extra >/dev/null 2>&1; chk "rm extra args -> 2" "2" "$?"
    cct rm absent --force >/dev/null 2>&1; chk "rm absent account -> 1" "1" "$?"
    printf 'n\n' | cct rm alpha >/dev/null 2>&1
    chk "rm cancellation -> 1" "1" "$?"
    cct rename >/dev/null 2>&1; chk "rename missing args -> 2" "2" "$?"
    cct rename alpha >/dev/null 2>&1; chk "rename missing target -> 2" "2" "$?"
    cct rename alpha fresh extra >/dev/null 2>&1; chk "rename extra args -> 2" "2" "$?"
    cct rename alpha 'bad-label' >/dev/null 2>&1
    chk "rename invalid target -> 2" "2" "$?"
    cct rename alpha rm >/dev/null 2>&1
    chk "rename reserved target -> 2" "2" "$?"
    cct rename absent fresh >/dev/null 2>&1
    chk "rename absent source -> 1" "1" "$?"
    cct rename alpha beta >/dev/null 2>&1
    chk "rename existing target -> 1" "1" "$?"
    chk "refusals preserve wallet hash" "$before" "$(wallet_sha "$CCT_ENV_FILE")"
    chk "refusals preserve active hash" "$active_before" "$(wallet_sha "$CCT_ACTIVE_FILE")"
    before="$(wallet_sha "$CCT_ENV_FILE")"
    _cct_wallet_rename_account CCT_TOKEN_ALPHA alpha CCT_TOKEN_BETA beta >/dev/null 2>&1
    chk "locked rename detects concurrent target -> 1" "1" "$?"
    chk "locked rename target conflict preserves wallet" "$before" "$(wallet_sha "$CCT_ENV_FILE")"

    echo "-- active remove rollback when active deletion fails"
    mkdir "$sb/fail-active-rm"
    cat > "$sb/fail-active-rm/rm" <<'SHIM'
#!/bin/sh
if [ "$#" -eq 2 ] && [ "$1" = "-f" ] && [ "$2" = "$CCT_FAIL_ACTIVE_PATH" ]; then
  [ -f "$CCT_ENV_FILE.lock/owner" ] || exit 2
  printf 'held\n' > "$CCT_LOCK_HELD_MARKER"
  exit 1
fi
exec "$CCT_REAL_RM" "$@"
SHIM
    chmod 700 "$sb/fail-active-rm/rm"
    before="$(wallet_sha "$CCT_ENV_FILE")"
    active_before="$(wallet_sha "$CCT_ACTIVE_FILE")"
    export CLAUDE_CODE_OAUTH_TOKEN=parent-sentinel
    export CLAUDE_CODE_DISABLE_ADVISOR_TOOL=parent-advisor
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=parent-traffic
    export CLAUDE_CODE_DISABLE_BACKGROUND_PLUGIN_REFRESH=parent-refresh
    env_before="${CLAUDE_CODE_OAUTH_TOKEN},${CLAUDE_CODE_DISABLE_ADVISOR_TOOL},${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC},${CLAUDE_CODE_DISABLE_BACKGROUND_PLUGIN_REFRESH}"
    cap="$(CCT_FAIL_ACTIVE_PATH="$CCT_ACTIVE_FILE" CCT_LOCK_HELD_MARKER="$sb/rm-lock-held" \
      CCT_REAL_RM="$(command -v rm)" \
      PATH="$sb/fail-active-rm:$PATH" cct rm alpha --force 2>&1)"; rc=$?
    chk "active rm failure -> 1" "1" "$rc"
    chk "active rm rollback restores wallet" "$before" "$(wallet_sha "$CCT_ENV_FILE")"
    chk "active rm failure preserves active" "$active_before" "$(wallet_sha "$CCT_ACTIVE_FILE")"
    chk "active rm failure preserves parent env" "$env_before" \
      "${CLAUDE_CODE_OAUTH_TOKEN},${CLAUDE_CODE_DISABLE_ADVISOR_TOOL},${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC},${CLAUDE_CODE_DISABLE_BACKGROUND_PLUGIN_REFRESH}"
    chk "active rm rollback stays under wallet lock" "held" "$(cat "$sb/rm-lock-held" 2>/dev/null)"
    chk_has "active rm failure reports rollback" "롤백" "$cap"

    echo "-- active rename rollback when active write fails"
    mkdir "$sb/fail-active-mv"
    cat > "$sb/fail-active-mv/mv" <<'SHIM'
#!/bin/sh
last=""
for arg do last="$arg"; done
if [ "$last" = "$CCT_FAIL_ACTIVE_PATH" ]; then
  [ -f "$CCT_ENV_FILE.lock/owner" ] || exit 2
  printf 'held\n' > "$CCT_LOCK_HELD_MARKER"
  exit 1
fi
exec "$CCT_REAL_MV" "$@"
SHIM
    chmod 700 "$sb/fail-active-mv/mv"
    before="$(wallet_sha "$CCT_ENV_FILE")"
    active_before="$(wallet_sha "$CCT_ACTIVE_FILE")"
    env_before="${CLAUDE_CODE_OAUTH_TOKEN},${CLAUDE_CODE_DISABLE_ADVISOR_TOOL},${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC},${CLAUDE_CODE_DISABLE_BACKGROUND_PLUGIN_REFRESH}"
    cap="$(CCT_FAIL_ACTIVE_PATH="$CCT_ACTIVE_FILE" CCT_LOCK_HELD_MARKER="$sb/mv-lock-held" \
      CCT_REAL_MV="$(command -v mv)" \
      PATH="$sb/fail-active-mv:$PATH" cct rename alpha fresh 2>&1)"; rc=$?
    chk "active rename failure -> 1" "1" "$rc"
    chk "active rename rollback restores wallet" "$before" "$(wallet_sha "$CCT_ENV_FILE")"
    chk "active rename failure preserves active" "$active_before" "$(wallet_sha "$CCT_ACTIVE_FILE")"
    chk "active rename failure preserves parent env" "$env_before" \
      "${CLAUDE_CODE_OAUTH_TOKEN},${CLAUDE_CODE_DISABLE_ADVISOR_TOOL},${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC},${CLAUDE_CODE_DISABLE_BACKGROUND_PLUGIN_REFRESH}"
    chk "active rename rollback stays under wallet lock" "held" "$(cat "$sb/mv-lock-held" 2>/dev/null)"
    chk_has "active rename failure reports rollback" "롤백" "$cap"

    echo "-- held wallet lock refuses lifecycle mutation"
    mkdir "$CCT_ENV_FILE.lock"
    printf '%s %s\n' "$$" "$(date +%s)" > "$CCT_ENV_FILE.lock/owner"
    before="$(wallet_sha "$CCT_ENV_FILE")"
    cct rm beta --force >/dev/null 2>&1; rc=$?
    chk "rm held-lock failure -> 1" "1" "$rc"
    chk "rm held-lock preserves wallet" "$before" "$(wallet_sha "$CCT_ENV_FILE")"
    rm -rf "$CCT_ENV_FILE.lock"
    rm -rf "$sb"
    return
  fi

  echo "-- explicit run shares the exact launch path"
  direct="$(cct alpha --version 2>&1)"
  explicit="$(cct run alpha --version 2>&1)"
  chk "run normal rc=0" "0" "$?"
  chk "run and direct output are identical" "$direct" "$explicit"
  cap="$(cct run rm --version 2>&1)"
  chk_has "run escapes reserved legacy label" "tok=[fixture-legacy-rm]" "$cap"
  cap="$(cct use --version 2>&1)"
  chk_has "use remains an allowed direct label" "tok=[fixture-use]" "$cap"
  cct add run >/dev/null 2>&1; chk "add run is reserved -> 2" "2" "$?"
  cct add rm >/dev/null 2>&1; chk "add rm is reserved -> 2" "2" "$?"
  cct add rename >/dev/null 2>&1; chk "add rename is reserved -> 2" "2" "$?"

  export CCT_STICKY=1
  rm -f "$CCT_ACTIVE_FILE"
  unset CLAUDE_CODE_OAUTH_TOKEN
  direct="$(cct beta --version 2>&1)"
  active_before="$(cat "$CCT_ACTIVE_FILE" 2>/dev/null)"
  env_before="${CLAUDE_CODE_OAUTH_TOKEN:-}"
  rm -f "$CCT_ACTIVE_FILE"
  unset CLAUDE_CODE_OAUTH_TOKEN
  explicit="$(cct run beta --version 2>&1)"
  chk "sticky run and direct output are identical" "$direct" "$explicit"
  chk "sticky run and direct active state match" "$active_before" "$(cat "$CCT_ACTIVE_FILE" 2>/dev/null)"
  chk "sticky run and direct env match" "$env_before" "${CLAUDE_CODE_OAUTH_TOKEN:-}"
  chk "sticky active file mode 600" "600" "$(wallet_mode "$CCT_ACTIVE_FILE")"

  echo "-- remove confirms, backs up, and clears active only after commit"
  env_before="${CLAUDE_CODE_OAUTH_TOKEN:-}"
  cct rm use --force >/dev/null 2>&1; rc=$?
  chk "forced non-active rm rc=0" "0" "$rc"
  chk "forced non-active rm preserves active" "beta" "$(cat "$CCT_ACTIVE_FILE" 2>/dev/null)"
  chk "forced non-active rm preserves env" "$env_before" "${CLAUDE_CODE_OAUTH_TOKEN:-}"
  chk "forced rm removes account" "0" "$(grep -c '^CCT_TOKEN_USE=' "$CCT_ENV_FILE" || true)"

  before="$(wallet_sha "$CCT_ENV_FILE")"
  printf 'y\n' | cct rm beta >/dev/null 2>&1; rc=$?
  chk "confirmed active rm rc=0" "0" "$rc"
  chk "confirmed rm removes exact key" "0" "$(grep -c '^CCT_TOKEN_BETA=' "$CCT_ENV_FILE" || true)"
  chk "confirmed rm removes exact annotation" "0" "$(grep -c '^#cctlabel:CCT_TOKEN_BETA=' "$CCT_ENV_FILE" || true)"
  chk_has "confirmed rm preserves unrelated account" "CCT_TOKEN_ALPHA=fixture-alpha" "$(cat "$CCT_ENV_FILE")"
  chk "confirmed rm backup matches prior wallet" "$before" "$(wallet_sha "$CCT_ENV_FILE.bak")"
  chk "confirmed rm backup mode 600" "600" "$(wallet_mode "$CCT_ENV_FILE.bak")"
  chk "confirmed active rm clears active file" "no" "$([ -e "$CCT_ACTIVE_FILE" ] && echo yes || echo no)"
  chk "confirmed active rm clears token env" "" "${CLAUDE_CODE_OAUTH_TOKEN:-}"

  echo "-- rename preserves bytes and moves active state"
  printf '%s\n' \
    "CCT_TOKEN_ODD=fixture=value with 'quoted' bytes" \
    '#cctlabel:CCT_TOKEN_ODD=odd' >> "$CCT_ENV_FILE"
  chmod 600 "$CCT_ENV_FILE"
  cct rename odd exact >/dev/null 2>&1; rc=$?
  chk "rename byte-preserving account rc=0" "0" "$rc"
  chk_has "rename preserves exact token bytes" "CCT_TOKEN_EXACT=fixture=value with 'quoted' bytes" "$(cat "$CCT_ENV_FILE")"
  chk "rename removes old key" "0" "$(grep -c '^CCT_TOKEN_ODD=' "$CCT_ENV_FILE" || true)"
  chk_has "rename rewrites annotation" "#cctlabel:CCT_TOKEN_EXACT=exact" "$(cat "$CCT_ENV_FILE")"

  cct alpha --version >/dev/null 2>&1
  env_before="${CLAUDE_CODE_OAUTH_TOKEN:-}"
  before="$(wallet_sha "$CCT_ENV_FILE")"
  cct rename alpha primary >/dev/null 2>&1; rc=$?
  chk "active rename rc=0" "0" "$rc"
  chk "active rename updates active file" "primary" "$(cat "$CCT_ACTIVE_FILE" 2>/dev/null)"
  chk "active rename keeps exported token" "$env_before" "${CLAUDE_CODE_OAUTH_TOKEN:-}"
  chk "active rename backup matches prior wallet" "$before" "$(wallet_sha "$CCT_ENV_FILE.bak")"

  echo "-- help and fixture contract"
  cap="$(cct help)"
  chk_has "help documents run" "cct run <라벨>" "$cap"
  chk_has "help documents rm" "cct rm <라벨>" "$cap"
  chk_has "help documents rename" "cct rename <기존> <새>" "$cap"
  fixture_target="$sb/generated-fixture"
  fixture_home="$sb/untouched-home"
  mkdir "$fixture_home"
  printf 'untouched\n' > "$fixture_home/marker"
  before="$(wallet_sha "$fixture_home/marker")"
  cap="$(HOME="$fixture_home" bash "$REPO/tests/cct_test.sh" fixture "$fixture_target" 2>&1)"; rc=$?
  chk "fixture creates fresh isolated target" "0" "$rc"
  case "$cap" in *fixture-token*) after=exposed ;; *) after=hidden ;; esac
  chk "fixture output contains no token" "hidden" "$after"
  chk "fixture wallet mode 600" "600" "$(wallet_mode "$fixture_target/home/.claude/tokens.env")"
  chk "fixture contains only gv account" "gv" \
    "$(awk -F= '/^CCT_TOKEN_/ {sub(/^CCT_TOKEN_/, "", $1); print tolower($1)}' "$fixture_target/home/.claude/tokens.env")"
  chk "fixture fake Claude executable" "yes" "$([ -x "$fixture_target/bin/claude" ] && echo yes || echo no)"
  chk "fixture creates only allowed files" $'bin/claude\nhome/.claude/tokens.env' \
    "$(find "$fixture_target" -type f | sed "s|^$fixture_target/||" | sort)"
  chk "fixture leaves supplied HOME byte-identical" "$before" "$(wallet_sha "$fixture_home/marker")"
  chk "fixture creates nothing under supplied HOME" "no" "$([ -e "$fixture_home/.claude" ] && echo yes || echo no)"
  bash "$REPO/tests/cct_test.sh" fixture "$fixture_target" >/dev/null 2>&1
  chk "fixture refuses existing target -> 2" "2" "$?"
  chk "fixture creates no active file" "no" "$([ -e "$fixture_target/home/.claude/cct-active" ] && echo yes || echo no)"
  fixture_target="$sb/existing-empty"
  mkdir "$fixture_target"
  bash "$REPO/tests/cct_test.sh" fixture "$fixture_target" >/dev/null 2>&1
  chk "fixture refuses existing empty target -> 2" "2" "$?"

  rm -rf "$sb"
}

test_diagnostics(){
  echo "== offline diagnostics =="
  set +u
  local sb cap rc before after active_before dead_pid now target started elapsed hang_pid
  sb="$(mktemp -d)"
  mk_shim "$sb/bin"
  export PATH="$sb/bin:$PATH"
  export CCT_ENV_FILE="$sb/tokens.env"
  export CCT_ACTIVE_FILE="$sb/cct-active"
  export CCT_DEFAULT_LABEL=alpha
  export CCT_STICKY=1
  export CCT_SHIM_LOG="$sb/claude.log"
  export CLAUDE_CODE_OAUTH_TOKEN="ambient-credential-must-not-print"
  write_account_fixture "$CCT_ENV_FILE" \
    '# healthy portable wallet' \
    '  #comment with indentation is valid' \
    '' \
    'CCT_TOKEN_ALPHA=fixture-alpha-secret' \
    '#cctlabel:CCT_TOKEN_ALPHA=alpha' \
    'CCT_TOKEN_BETA=sk-ant-oat01-fixture-beta-secret' \
    '#cctlabel:CCT_TOKEN_BETA=beta'
  printf '%s\n' alpha > "$CCT_ACTIVE_FILE"
  chmod 600 "$CCT_ACTIVE_FILE"
  # shellcheck disable=SC1090
  . "$REPO/cct.sh"

  if [ "${CCT_TEST_CASE:-}" != "diagnostic-failures" ]; then
    echo "-- status reports bounded offline metadata without credential details"
    before="$(wallet_sha "$CCT_ENV_FILE")"
    active_before="$(wallet_sha "$CCT_ACTIVE_FILE")"
    cap="$(cct status 2>&1)"; rc=$?
    chk "status healthy -> 0" "0" "$rc"
    chk_has "status wallet path" "wallet: $CCT_ENV_FILE" "$cap"
    chk_has "status wallet mode" "mode: 600" "$cap"
    chk_has "status account count" "accounts: 2" "$cap"
    chk_has "status active label" "active: alpha" "$cap"
    chk_has "status default label" "default: alpha" "$cap"
    chk_has "status sticky enabled" "sticky: enabled" "$cap"
    chk_has "status real Claude path" "claude: $sb/bin/claude" "$cap"
    chk_has "status bounded Claude version" "claude-version: Claude Code fixture 1.2.3" "$cap"
    chk_not_has "status hides first fixture token" "fixture-alpha-secret" "$cap"
    chk_not_has "status hides credential prefix" "sk-ant-oat01-" "$cap"
    chk_not_has "status hides ambient credential" "ambient-credential-must-not-print" "$cap"
    chk "status preserves wallet bytes" "$before" "$(wallet_sha "$CCT_ENV_FILE")"
    chk "status preserves active bytes" "$active_before" "$(wallet_sha "$CCT_ACTIVE_FILE")"

    mkdir "$sb/noisy-bin"
    cat > "$sb/noisy-bin/claude" <<'SHIM'
#!/bin/sh
printf '%s\n' 'sk-ant-oat01-noisy-version-secret user@example.com org_id=org-secret'
SHIM
    chmod 700 "$sb/noisy-bin/claude"
    cap="$(PATH="$sb/noisy-bin:$PATH" cct status 2>&1)"; rc=$?
    chk "status with credential-like version -> 0" "0" "$rc"
    chk_has "status redacts credential-like version" "claude-version: unavailable" "$cap"
    chk_not_has "status noisy version hides credential prefix" "sk-ant-oat01-" "$cap"
    chk_not_has "status noisy version hides email" "user@example.com" "$cap"
    chk_not_has "status noisy version hides org metadata" "org_id=" "$cap"

    echo "-- doctor deterministically validates healthy local state"
    before="$(wallet_sha "$CCT_ENV_FILE")"
    active_before="$(wallet_sha "$CCT_ACTIVE_FILE")"
    cap="$(cct doctor 2>&1)"; rc=$?
    chk "doctor healthy -> 0" "0" "$rc"
    chk_has "doctor wallet PASS" "PASS wallet:" "$cap"
    chk_has "doctor structure PASS" "PASS structure:" "$cap"
    chk_has "doctor active PASS" "PASS active:" "$cap"
    chk_has "doctor default PASS" "PASS default:" "$cap"
    chk_has "doctor backup PASS" "PASS backup:" "$cap"
    chk_has "doctor lock PASS" "PASS lock:" "$cap"
    chk_has "doctor Claude PASS" "PASS claude:" "$cap"
    chk_has "doctor shell PASS" "PASS shell:" "$cap"
    chk_not_has "doctor hides first fixture token" "fixture-alpha-secret" "$cap"
    chk_not_has "doctor hides credential prefix" "sk-ant-oat01-" "$cap"
    chk_not_has "doctor hides ambient credential" "ambient-credential-must-not-print" "$cap"
    chk "doctor preserves wallet bytes" "$before" "$(wallet_sha "$CCT_ENV_FILE")"
    chk "doctor preserves active bytes" "$active_before" "$(wallet_sha "$CCT_ACTIVE_FILE")"
    chk "diagnostics invoke fake Claude only once" "1" "$(wc -l < "$CCT_SHIM_LOG" | tr -d ' ')"
    chk "diagnostics invoke only --version" "--version" "$(cat "$CCT_SHIM_LOG")"

    cct status extra >/dev/null 2>&1
    chk "status unexpected arg -> 2" "2" "$?"
    cct doctor extra >/dev/null 2>&1
    chk "doctor unexpected arg -> 2" "2" "$?"
    cct add status >/dev/null 2>&1
    chk "status is a reserved label" "2" "$?"
    cct add doctor >/dev/null 2>&1
    chk "doctor is a reserved label" "2" "$?"
    cap="$(cct help)"
    chk_has "help documents status" "cct status" "$cap"
    chk_has "help documents doctor" "cct doctor" "$cap"
    rm -rf "$sb"
    return
  fi

  echo "-- corrupt fixtures fail without mutation or secret disclosure"
  rm -f "$CCT_ENV_FILE" "$CCT_ACTIVE_FILE" "$CCT_ENV_FILE.bak"
  before="$([ -e "$CCT_ENV_FILE" ] && echo present || echo missing)"
  cap="$(cct doctor 2>&1)"; rc=$?
  chk "missing wallet -> 1" "1" "$rc"
  chk_has "missing wallet classified" "FAIL wallet: missing" "$cap"
  chk "missing wallet is not created" "$before" "$([ -e "$CCT_ENV_FILE" ] && echo present || echo missing)"

  write_account_fixture "$CCT_ENV_FILE" \
    'CCT_TOKEN_ALPHA=mode-secret' \
    '#cctlabel:CCT_TOKEN_ALPHA=alpha'
  chmod 644 "$CCT_ENV_FILE"
  before="$(wallet_sha "$CCT_ENV_FILE")"
  cap="$(cct doctor 2>&1)"; rc=$?
  chk "mode-644 wallet -> 1" "1" "$rc"
  chk_has "mode-644 wallet classified" "FAIL wallet: mode 644" "$cap"
  chk_not_has "mode failure hides token" "mode-secret" "$cap"
  chk "mode failure preserves bytes" "$before" "$(wallet_sha "$CCT_ENV_FILE")"
  chk "mode failure preserves mode" "644" "$(wallet_mode "$CCT_ENV_FILE")"

  write_account_fixture "$CCT_ENV_FILE" \
    'CCT_TOKEN_ALPHA=duplicate-secret-one' \
    '#cctlabel:CCT_TOKEN_ALPHA=alpha' \
    'CCT_TOKEN_ALPHA=duplicate-secret-two'
  before="$(wallet_sha "$CCT_ENV_FILE")"
  cap="$(cct doctor 2>&1)"; rc=$?
  chk "duplicate key -> 1" "1" "$rc"
  chk_has "duplicate reports key only" "duplicate key CCT_TOKEN_ALPHA" "$cap"
  chk_not_has "duplicate hides first token" "duplicate-secret-one" "$cap"
  chk_not_has "duplicate hides second token" "duplicate-secret-two" "$cap"
  chk "duplicate preserves bytes" "$before" "$(wallet_sha "$CCT_ENV_FILE")"

  write_account_fixture "$CCT_ENV_FILE" \
    'CCT_TOKEN_ALPHA=' \
    '#cctlabel:CCT_TOKEN_ALPHA=alpha' \
    'CCT_TOKEN_bad=invalid-key-secret'
  before="$(wallet_sha "$CCT_ENV_FILE")"
  cap="$(cct doctor 2>&1)"; rc=$?
  chk "empty token and malformed key -> 1" "1" "$rc"
  chk_has "empty token reports key only" "empty value for CCT_TOKEN_ALPHA" "$cap"
  chk_has "malformed key reports line only" "line 3: malformed key" "$cap"
  chk_not_has "malformed key hides token" "invalid-key-secret" "$cap"
  chk "empty/malformed fixture preserves bytes" "$before" "$(wallet_sha "$CCT_ENV_FILE")"

  write_account_fixture "$CCT_ENV_FILE" \
    'CCT_TOKEN_ALPHA=orphan-base-secret' \
    '#cctlabel:CCT_TOKEN_ALPHA=alpha' \
    '#cctlabel:CCT_TOKEN_GHOST=ghost'
  before="$(wallet_sha "$CCT_ENV_FILE")"
  cap="$(cct doctor 2>&1)"; rc=$?
  chk "orphan annotation -> 1" "1" "$rc"
  chk_has "orphan reports line/key only" "line 3: orphan annotation CCT_TOKEN_GHOST" "$cap"
  chk_not_has "orphan hides token" "orphan-base-secret" "$cap"
  chk "orphan preserves bytes" "$before" "$(wallet_sha "$CCT_ENV_FILE")"

  write_account_fixture "$CCT_ENV_FILE" \
    'CCT_TOKEN_ALPHA=stale-active-secret' \
    '#cctlabel:CCT_TOKEN_ALPHA=alpha'
  printf '%s\n' ghost > "$CCT_ACTIVE_FILE"
  chmod 600 "$CCT_ACTIVE_FILE"
  before="$(wallet_sha "$CCT_ENV_FILE")"
  active_before="$(wallet_sha "$CCT_ACTIVE_FILE")"
  cap="$(cct doctor 2>&1)"; rc=$?
  chk "stale active -> 1" "1" "$rc"
  chk_has "stale active classified" "FAIL active: unresolved label" "$cap"
  chk_not_has "stale active hides token" "stale-active-secret" "$cap"
  chk "stale active preserves wallet" "$before" "$(wallet_sha "$CCT_ENV_FILE")"
  chk "stale active preserves active file" "$active_before" "$(wallet_sha "$CCT_ACTIVE_FILE")"
  rm -f "$CCT_ACTIVE_FILE"

  cap="$(CCT_DEFAULT_LABEL=ghost cct doctor 2>&1)"; rc=$?
  chk "stale default -> 1" "1" "$rc"
  chk_has "stale default classified" "FAIL default: unresolved label" "$cap"
  chk_not_has "stale default hides token" "stale-active-secret" "$cap"

  cap="$(PATH="/usr/bin:/bin" cct doctor 2>&1)"; rc=$?
  chk "missing Claude -> 1" "1" "$rc"
  chk_has "missing Claude classified" "FAIL claude: missing" "$cap"

  mkdir "$sb/hang-bin"
  cat > "$sb/hang-bin/claude" <<'SHIM'
#!/bin/sh
printf '%s\n' "$$" > "$CCT_HANG_PID_FILE"
while :; do :; done
SHIM
  chmod 700 "$sb/hang-bin/claude"
  started="$(date +%s)"
  cap="$(CCT_HANG_PID_FILE="$sb/hang.pid" PATH="$sb/hang-bin:/usr/bin:/bin" cct status 2>&1)"; rc=$?
  elapsed=$(($(date +%s) - started))
  hang_pid="$(cat "$sb/hang.pid" 2>/dev/null)"
  chk "hung Claude version keeps status responsive -> 0" "0" "$rc"
  chk "hung Claude version is bounded" "yes" "$([ "$elapsed" -le 8 ] && echo yes || echo no)"
  chk_has "hung Claude version reports unavailable" "claude-version: unavailable" "$cap"
  chk "hung Claude version process is gone" "gone" \
    "$([ -n "$hang_pid" ] && kill -0 "$hang_pid" 2>/dev/null && echo live || echo gone)"

  now="$(date +%s)"
  mkdir "$CCT_ENV_FILE.lock"
  printf '%s %s\n' "$$" "$now" > "$CCT_ENV_FILE.lock/owner"
  before="$(wallet_sha "$CCT_ENV_FILE.lock/owner")"
  cap="$(cct doctor 2>&1)"; rc=$?
  chk "recent live lock is warning-only -> 0" "0" "$rc"
  chk_has "recent live lock classified WARN" "WARN lock: live mutation in progress" "$cap"
  chk "live lock owner preserved" "$before" "$(wallet_sha "$CCT_ENV_FILE.lock/owner")"
  rm -rf "$CCT_ENV_FILE.lock"

  dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid+1)); done
  mkdir "$CCT_ENV_FILE.lock"
  printf '%s %s\n' "$dead_pid" "$((now-120))" > "$CCT_ENV_FILE.lock/owner"
  before="$(wallet_sha "$CCT_ENV_FILE.lock/owner")"
  cap="$(cct doctor 2>&1)"; rc=$?
  chk "dead/stale lock -> 1" "1" "$rc"
  chk_has "dead/stale lock classified FAIL" "FAIL lock: dead or stale owner" "$cap"
  chk "dead/stale lock is not recovered" "$before" "$(wallet_sha "$CCT_ENV_FILE.lock/owner")"
  rm -rf "$CCT_ENV_FILE.lock"

  mkdir "$CCT_ENV_FILE.lock"
  printf '%s\n' 'malformed-owner-secret' > "$CCT_ENV_FILE.lock/owner"
  before="$(wallet_sha "$CCT_ENV_FILE.lock/owner")"
  cap="$(cct doctor 2>&1)"; rc=$?
  chk "malformed lock -> 1" "1" "$rc"
  chk_has "malformed lock classified FAIL" "FAIL lock: malformed owner metadata" "$cap"
  chk_not_has "malformed lock hides owner contents" "malformed-owner-secret" "$cap"
  chk "malformed lock is not deleted" "$before" "$(wallet_sha "$CCT_ENV_FILE.lock/owner")"
  rm -rf "$CCT_ENV_FILE.lock"

  cp "$CCT_ENV_FILE" "$CCT_ENV_FILE.bak"
  chmod 644 "$CCT_ENV_FILE.bak"
  before="$(wallet_sha "$CCT_ENV_FILE.bak")"
  cap="$(cct doctor 2>&1)"; rc=$?
  chk "mode-644 backup -> 1" "1" "$rc"
  chk_has "mode-644 backup classified" "FAIL backup: mode 644" "$cap"
  chk "backup mode failure preserves bytes" "$before" "$(wallet_sha "$CCT_ENV_FILE.bak")"
  chk "backup mode failure preserves mode" "644" "$(wallet_mode "$CCT_ENV_FILE.bak")"
  rm -f "$CCT_ENV_FILE.bak"

  write_account_fixture "$CCT_ENV_FILE" \
    'CCT_TOKEN_ALPHA=redaction-secret' \
    '#cctlabel:CCT_TOKEN_ALPHA=alpha' \
    'BROKEN=sk-ant-oat01-never-print-this'
  before="$(wallet_sha "$CCT_ENV_FILE")"
  cap="$(cct doctor 2>&1)"; rc=$?
  chk "malformed wallet line -> 1" "1" "$rc"
  chk_has "malformed wallet reports line number only" "line 3: malformed entry" "$cap"
  chk_not_has "malformed wallet hides token" "redaction-secret" "$cap"
  chk_not_has "malformed wallet hides raw line secret" "sk-ant-oat01-never-print-this" "$cap"
  chk "malformed wallet preserves bytes" "$before" "$(wallet_sha "$CCT_ENV_FILE")"

  write_account_fixture "$CCT_ENV_FILE" \
    'CCT_TOKEN_ALPHA=symlink-target-secret' \
    '#cctlabel:CCT_TOKEN_ALPHA=alpha'
  target="$sb/real-wallet"
  mv "$CCT_ENV_FILE" "$target"
  ln -s "$target" "$CCT_ENV_FILE"
  before="$(wallet_sha "$target")"
  cap="$(cct doctor 2>&1)"; rc=$?
  chk "symlink wallet -> 1" "1" "$rc"
  chk_has "symlink wallet classified" "FAIL wallet: symbolic link" "$cap"
  chk_not_has "symlink wallet hides token" "symlink-target-secret" "$cap"
  chk "symlink target preserves bytes" "$before" "$(wallet_sha "$target")"

  rm -f "$CCT_ENV_FILE"
  cp "$target" "$CCT_ENV_FILE"
  chmod 600 "$CCT_ENV_FILE"
  ln -s "$target" "$CCT_ENV_FILE.bak"
  cap="$(cct doctor 2>&1)"; rc=$?
  chk "symlink backup -> 1" "1" "$rc"
  chk_has "symlink backup classified" "FAIL backup: symbolic link" "$cap"
  rm -f "$CCT_ENV_FILE.bak"

  mkdir "$sb/lock-target"
  ln -s "$sb/lock-target" "$CCT_ENV_FILE.lock"
  cap="$(cct doctor 2>&1)"; rc=$?
  chk "symlink lock -> 1" "1" "$rc"
  chk_has "symlink lock classified" "FAIL lock: symbolic link" "$cap"
  chk "symlink lock is not deleted" "yes" "$([ -L "$CCT_ENV_FILE.lock" ] && echo yes || echo no)"

  rm -f "$CCT_ENV_FILE.lock"
  rm -rf "$sb"
}

make_fixture(){
  local target="${1-}"
  [ -n "$target" ] || { echo "usage: $0 fixture <new-dir>" >&2; return 2; }
  [ "$#" -eq 1 ] || { echo "usage: $0 fixture <new-dir>" >&2; return 2; }
  if [ -e "$target" ] || [ -L "$target" ]; then
    echo "fixture target already exists: $target" >&2
    return 2
  fi
  ( umask 077
    mkdir -p "$target/home/.claude" "$target/bin" || exit 1
    printf '%s\n' \
      'CCT_TOKEN_GV=fixture-token-gv' \
      '#cctlabel:CCT_TOKEN_GV=gv' > "$target/home/.claude/tokens.env" || exit 1
    chmod 600 "$target/home/.claude/tokens.env" || exit 1
    cat > "$target/bin/claude" <<'SHIM'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "$1" = "--version" ]; then
  printf '%s\n' "Claude Code fixture 1.2.3"
  exit 0
fi
echo "CLAUDE args=[$*] tok=[${CLAUDE_CODE_OAUTH_TOKEN:-<unset>}]" >&2
exit 0
SHIM
    chmod 700 "$target/bin/claude" || exit 1
  ) || {
    rm -rf "$target"
    return 1
  }
}

case "${1:-all}" in
  install) test_install ;;
  cct)     test_cct ;;
  extra)   test_extra ;;
  sticky)  test_sticky ;;
  wallet)  test_wallet ;;
  accounts) test_accounts ;;
  diagnostics)
    case "${CCT_TEST_CASE:-}" in
      ""|diagnostic-failures) test_diagnostics ;;
      *) echo "unknown diagnostics case: ${CCT_TEST_CASE}" >&2; exit 2 ;;
    esac
    ;;
  fixture) shift; make_fixture "$@"; exit $? ;;
  all)     test_install; test_cct; test_extra; test_sticky; test_wallet; test_accounts; test_diagnostics ;;
  *) echo "usage: $0 [install|cct|extra|sticky|wallet|accounts|diagnostics|fixture|all]"; exit 2 ;;
esac

echo
echo "TOTAL pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
