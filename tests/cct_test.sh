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

wallet_mode(){
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

wallet_sha(){
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

wallet_inode(){
  stat -f '%i' "$1" 2>/dev/null || stat -c '%i' "$1"
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
  chk "characterization wallet mode 600" "600" "$(stat -f '%Lp' "$CCT_ENV_FILE" 2>/dev/null || stat -c '%a' "$CCT_ENV_FILE")"
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

case "${1:-all}" in
  install) test_install ;;
  cct)     test_cct ;;
  extra)   test_extra ;;
  sticky)  test_sticky ;;
  wallet)  test_wallet ;;
  all)     test_install; test_cct; test_extra; test_sticky; test_wallet ;;
  *) echo "usage: $0 [install|cct|extra|sticky|wallet|all]"; exit 2 ;;
esac

echo
echo "TOTAL pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
