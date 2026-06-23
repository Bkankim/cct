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

# Fake claude shim: prints received args+token to stderr; exits 1 if the token
# contains BAD (lets a single `cct check` run produce a mixed result), else 0.
mk_shim(){ # $1 = bin dir
  mkdir -p "$1"
  cat > "$1/claude" <<'SHIM'
#!/usr/bin/env bash
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

# -------------------------------------------------------------------------
test_install(){
  echo "== install.sh (H1 core.excludesfile preservation, N1 SHELL rc) =="
  local H G rc MINE

  echo "-- (a) fresh HOME + SHELL=/bin/zsh -> .zshrc, not .bashrc"
  H="$(mktemp -d)"; G="$H/.gitconfig"
  ( cd "$REPO" && HOME="$H" GIT_CONFIG_GLOBAL="$G" SHELL=/bin/zsh bash install.sh ) >/dev/null 2>&1; rc=$?
  chk "installer rc=0" "0" "$rc"
  chk ".zshrc has source line" "1" "$(grep -c 'source ~/.claude/cct.sh' "$H/.zshrc" 2>/dev/null || echo 0)"
  chk ".bashrc not created" "no" "$([ -e "$H/.bashrc" ] && echo yes || echo no)"
  chk "local .claude/.gitignore has tokens.env" "1" "$(grep -c '^tokens.env$' "$H/.claude/.gitignore" 2>/dev/null || echo 0)"

  echo "-- (b) preexisting core.excludesfile preserved + appended, no set-eu abort"
  H="$(mktemp -d)"; G="$H/.gitconfig"; MINE="$H/.mine_ignore"
  HOME="$H" GIT_CONFIG_GLOBAL="$G" git config --global core.excludesfile "$MINE"
  printf 'build/\n' > "$MINE"
  ( cd "$REPO" && HOME="$H" GIT_CONFIG_GLOBAL="$G" SHELL=/bin/bash bash install.sh ) >/dev/null 2>&1; rc=$?
  chk "installer rc=0" "0" "$rc"
  chk "config unchanged" "$MINE" "$(HOME="$H" GIT_CONFIG_GLOBAL="$G" git config --global --get core.excludesfile)"
  chk "existing file got tokens.env" "1" "$(grep -c '^tokens.env$' "$MINE" 2>/dev/null || echo 0)"
  chk "existing file got .claude/tokens.env" "1" "$(grep -c '^\.claude/tokens\.env$' "$MINE" 2>/dev/null || echo 0)"
  chk "existing build/ rule preserved" "1" "$(grep -c '^build/$' "$MINE" 2>/dev/null || echo 0)"
  chk "no ~/.gitignore_global created" "no" "$([ -e "$H/.gitignore_global" ] && echo yes || echo no)"

  echo "-- (c) no config -> sets ~/.gitignore_global, exits 0"
  H="$(mktemp -d)"; G="$H/.gitconfig"
  ( cd "$REPO" && HOME="$H" GIT_CONFIG_GLOBAL="$G" SHELL=/bin/bash bash install.sh ) >/dev/null 2>&1; rc=$?
  chk "installer rc=0" "0" "$rc"
  chk "config -> .gitignore_global" "$H/.gitignore_global" "$(HOME="$H" GIT_CONFIG_GLOBAL="$G" git config --global --get core.excludesfile)"
  chk ".gitignore_global has tokens.env" "1" "$(grep -c '^tokens.env$' "$H/.gitignore_global" 2>/dev/null || echo 0)"
  chk ".gitignore_global has .claude/tokens.env" "1" "$(grep -c '^\.claude/tokens\.env$' "$H/.gitignore_global" 2>/dev/null || echo 0)"

  echo "-- (d) idempotent re-run (no duplicate lines)"
  H="$(mktemp -d)"; G="$H/.gitconfig"; MINE="$H/.mine_ignore"
  HOME="$H" GIT_CONFIG_GLOBAL="$G" git config --global core.excludesfile "$MINE"; printf 'build/\n.claude/tokens.env\n' > "$MINE"
  mkdir -p "$H/.claude"; printf 'keep-me\n' > "$H/.claude/.gitignore"
  ( cd "$REPO" && HOME="$H" GIT_CONFIG_GLOBAL="$G" SHELL=/bin/zsh bash install.sh ) >/dev/null 2>&1
  ( cd "$REPO" && HOME="$H" GIT_CONFIG_GLOBAL="$G" SHELL=/bin/zsh bash install.sh ) >/dev/null 2>&1; rc=$?
  chk "2nd run rc=0" "0" "$rc"
  chk "tokens.env appended once" "1" "$(grep -c '^tokens.env$' "$MINE")"
  chk ".claude/tokens.env preserved once" "1" "$(grep -c '^\.claude/tokens\.env$' "$MINE")"
  chk "local .gitignore preserves user rule" "1" "$(grep -c '^keep-me$' "$H/.claude/.gitignore")"
  chk "local .gitignore tokens.env once" "1" "$(grep -c '^tokens.env$' "$H/.claude/.gitignore")"
  chk ".zshrc source line once" "1" "$(grep -c 'source ~/.claude/cct.sh' "$H/.zshrc")"
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
  cap="$(cct use 2>&1 >/dev/null)"
  chk_has "labeled run disables web-only feature calls" "web=[1,1,1]" "$cap"
  cap="$(CCT_DISABLE_WEB_FEATURES=0 cct use 2>&1 >/dev/null)"
  chk_has "CCT_DISABLE_WEB_FEATURES=0 opt-out" "web=[<unset>,<unset>,<unset>]" "$cap"

  echo "-- N6: check probes the real binary, not a shell claude function/alias"
  claude(){ echo "SHADOW-FN" >&2; return 9; }   # shadowing function must be bypassed
  cct check good >/dev/null 2>&1; chk "probe bypasses claude function -> 0" "0" "$?"
  unset -f claude
  cap="$(PATH="/usr/bin:/bin" cct check good 2>&1)"; rc=$?
  chk "claude off PATH -> rc 1" "1" "$rc"
  chk_has "claude off PATH -> probe-unavailable msg" "점검 불가" "$cap"

  echo "-- H2: update path leaves tokens.env at mode 600"
  chk "tokens.env mode 600" "600" "$(stat -f '%Lp' "$CCT_ENV_FILE" 2>/dev/null || stat -c '%a' "$CCT_ENV_FILE")"

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

case "${1:-all}" in
  install) test_install ;;
  cct)     test_cct ;;
  extra)   test_extra ;;
  all)     test_install; test_cct; test_extra ;;
  *) echo "usage: $0 [install|cct|extra|all]"; exit 2 ;;
esac

echo
echo "TOTAL pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
