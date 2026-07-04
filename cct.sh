# shellcheck shell=bash
# cct — 휴대용 Claude 계정 지갑 / Portable Claude Account Wallet
# 한 번 발급한 장기 setup-token들을 로컬 지갑에 두고 사용자가 계정을 명시 전환한다.
# bash/zsh · macOS/Linux/WSL2 공용. 프록시·오케스트레이터·자동 라우터가 아니다.
#   cct [claude 인자...]        → 활성(sticky) 또는 기본 라벨로 실행
#   cct <라벨> [claude 인자...] → 해당 계정을 명시 선택해 실행
#   cct run <라벨> [...]        → 예약어 라벨을 포함해 명시 실행
#   cct ls|list                 → 등록 계정 목록 (값 미표시)
#   cct add <라벨>              → setup-token 등록/교체 (화면 미표시 입력)
#   cct rm <라벨> [--force]     → 계정 삭제 (기본 확인)
#   cct rename <기존> <새>      → 토큰 값을 유지하고 라벨 변경
#   cct status                  → 지갑/활성 계정/Claude 로컬 상태 (오프라인)
#   cct doctor                  → 지갑 구조/권한/잠금 진단 (오프라인)
#   cct check [라벨]            → 토큰 유효성 점검 (실제 호출)
#   cct fp|who [라벨]           → 계정 지문 (실제 호출)
#   cct active                  → 현재 활성(sticky) 라벨 표시
#   cct off                     → 활성 라벨과 현재 셸 인증 환경 해제
#   cct help                    → 도움말
# (cc / ㅊㅊ 는 별도 alias = 그냥 claude. 단 sticky 활성 시 같은 활성 토큰을 물려받음.)
#
# 환경변수 노브:
#   CCT_SKIP_PERMS=0     → --dangerously-skip-permissions 끄기 (기본 1=켜짐)
#   CCT_CLAUDE_FLAGS     → claude 에 추가로 넘길 플래그(공백 구분)
#   CCT_DISABLE_WEB_FEATURES=0 → 라벨 실행에서도 Advisor/비필수 웹 호출 허용
#   CCT_DEFAULT_LABEL=gv → 라벨 없는 'cct' 가 쓸 기본 setup-token 라벨 (기본 gv)
#   CCT_STICKY=0         → sticky 끄기 (기존 inline 주입, 셸/디스크 미변경)
#   CCT_ACTIVE_FILE      → 활성 프로필 저장 경로 (기본 tokens.env 옆 cct-active)
#
# 종료코드 (cct check):  0 유효 / 1 무효(또는 점검불가) / 2 토큰없음.  전체 점검은 하나라도 문제면 1.
#
# 호환성 메모(BREAKING) — 자세한 내용은 CHANGELOG.md:
#   - cct check 가 실패 시 비제로 종료코드를 반환(이전엔 항상 0).
#   - 라벨 없는 cct 는 키체인 폴백 없이 기본 라벨(CCT_DEFAULT_LABEL, 기본 gv)의 setup-token 으로 실행.
#   - 기본이 sticky: cct <라벨> 가 활성 프로필을 저장+현재 셸 export 하고, 새 셸도 source 시 자동 로드.
#     그냥 claude / cc / 새 터미널도 마지막 선택 계정을 유지(cct <다른라벨>/cct off 전까지). 끄려면 CCT_STICKY=0.
#   - cct add 는 라벨 문자셋([a-z0-9_][a-z0-9_]*)·예약어를 검사한다.

CCT_ENV_FILE="${CCT_ENV_FILE:-$HOME/.claude/tokens.env}"
CCT_PROBE_MODEL="${CCT_PROBE_MODEL:-claude-haiku-4-5-20251001}"

_cct_key() { printf 'CCT_TOKEN_%s' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"; }

_cct_parent_dir() {
  local parent
  case "$1" in
    */*) parent="${1%/*}"; [ -n "$parent" ] || parent="/" ;;
    *) parent="." ;;
  esac
  printf '%s' "$parent"
}

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
  local LC_ALL=C
  case "${1-}" in
    "") echo "❌ 라벨이 비어 있음" >&2; return 2 ;;
    *[!a-z0-9_]*|[!a-z0-9_]*)
      echo "❌ 라벨은 소문자 영문/숫자/_ 만 허용 (받은 값: '$1')" >&2; return 2 ;;
  esac
  return 0
}

# 예약어(서브커맨드)와 충돌하는 라벨 거부.  rc 0 = 예약됨.
_cct_reserved_label() {  # $1 = label
  case "${1-}" in help|ls|list|add|run|rm|rename|status|doctor|check|fp|who|off|active) return 0 ;; *) return 1 ;; esac
}

_cct_list() {
  local labels lc v active
  active="$(_cct_active_label)"
  labels="$(_cct_labels)"
  [ -n "$labels" ] || { echo "  (등록된 계정 없음 — cct add <라벨>)"; return; }
  printf '%s\n' "$labels" | while IFS= read -r lc; do
    [ -n "$lc" ] || continue
    v="$(_cct_envtok "$(_cct_key "$lc")")"
    if [ "$lc" = "$active" ]; then
      [ -n "$v" ] && echo "  cct $lc   ← 활성" || echo "  cct $lc   (비어있음)   ← 활성"
    else
      [ -n "$v" ] && echo "  cct $lc" || echo "  cct $lc   (비어있음)"
    fi
  done
}

# 시간제한 실행 (timeout > gtimeout > perl > 무제한)
_cct_run_limited() {
  local secs="$1"; shift
  if   command -v timeout  >/dev/null 2>&1; then timeout  -k 1 "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout -k 1 "$secs" "$@"
  elif command -v perl     >/dev/null 2>&1; then
    perl -e '
      use strict;
      use warnings;
      use Errno qw(EINTR);
      use POSIX ();
      use Time::HiRes qw(time sleep);

      my $seconds = shift @ARGV;
      exit 125 unless defined $seconds && @ARGV;
      pipe(my $start_read, my $start_write) or exit 125;
      my $pid = fork();
      exit 125 unless defined $pid;

      if ($pid == 0) {
        close $start_write;
        my $start = "";
        my $count = sysread($start_read, $start, 1);
        close $start_read;
        exit 125 unless defined $count && $count == 1;
        exec { $ARGV[0] } @ARGV;
        exit 126;
      }

      close $start_read;
      unless (POSIX::setpgid($pid, $pid)) {
        close $start_write;
        waitpid($pid, 0);
        exit 125;
      }
      unless (syswrite($start_write, "1", 1) == 1) {
        close $start_write;
        kill "KILL", -$pid;
        waitpid($pid, 0);
        exit 125;
      }
      close $start_write;

      my $deadline = time() + $seconds;
      my ($waited, $status);
      while (1) {
        do {
          $waited = waitpid($pid, POSIX::WNOHANG());
        } while ($waited == -1 && $! == EINTR);
        if ($waited == $pid) {
          $status = $?;
          last;
        }
        exit 125 if $waited == -1;
        my $remaining = $deadline - time();
        last if $remaining <= 0;
        sleep($remaining < 0.01 ? $remaining : 0.01);
      }

      if ($waited == 0) {
        kill "TERM", -$pid;
        my $grace_deadline = time() + 0.2;
        while (time() < $grace_deadline) {
          do {
            $waited = waitpid($pid, POSIX::WNOHANG());
          } while ($waited == -1 && $! == EINTR);
          last if $waited == -1;
          sleep 0.01;
        }
        kill "KILL", -$pid;
        if ($waited == 0) {
          do {
            $waited = waitpid($pid, 0);
          } while ($waited == -1 && $! == EINTR);
        }
        exit 124;
      }

      exit 125 unless $waited == $pid;
      exit POSIX::WEXITSTATUS($status) if POSIX::WIFEXITED($status);
      exit 128 + POSIX::WTERMSIG($status) if POSIX::WIFSIGNALED($status);
      exit 125;
    ' "$secs" "$@"
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

_cct_wallet_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

_cct_wallet_busy() {
  echo "❌ wallet busy: 다른 cct 프로세스가 지갑을 변경 중이거나 잠금 상태를 확인할 수 없음" >&2
  return 1
}

_cct_wallet_read_lock_owner() {
  awk '
    NR == 1 && NF == 2 &&
      $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ &&
      length($1) <= 18 && length($2) <= 18 &&
      ($1 + 0) > 0 && ($2 + 0) > 0 {
        pid = $1
        epoch = $2
        next
      }
    { bad = 1 }
    END {
      if (NR == 1 && !bad) print pid " " epoch
      else exit 1
    }
  ' "$1" 2>/dev/null
}

_cct_wallet_pid_state() {
  local pid="$1" out rc probe
  if kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  [ -x /bin/ps ] || return 2
  out="$(LC_ALL=C /bin/ps -p "$pid" -o pid= 2>/dev/null)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    [ "$(printf '%s\n' "$out" | awk -v p="$pid" '$1 == p { found++ } END { print found + 0 }')" -eq 1 ] &&
      return 0
    return 2
  fi
  probe="$(LC_ALL=C /bin/ps -p "$$" -o pid= 2>/dev/null)" || return 2
  [ "$(printf '%s\n' "$probe" | awk -v p="$$" '$1 == p { found++ } END { print found + 0 }')" -eq 1 ] ||
    return 2
  return 1
}

_cct_wallet_release_lock() {
  local lock="$1" expected="$2" current
  [ -x /bin/rm ] && [ -x /bin/rmdir ] ||
    return 1
  [ ! -L "$lock" ] && [ -d "$lock" ] ||
    return 1
  [ ! -L "$lock/owner" ] && [ -f "$lock/owner" ] ||
    return 1
  current="$(_cct_wallet_read_lock_owner "$lock/owner")" ||
    return 1
  [ "$current" = "$expected" ] ||
    return 1
  /bin/rm -f -- "$lock/owner" 2>/dev/null &&
    /bin/rmdir -- "$lock" 2>/dev/null
}

_cct_wallet_create_lock() {
  local lock="$1" now="$2" owner
  _cct_wallet_lock_owner=""
  _cct_wallet_lock_candidate="$lock"
  mkdir "$lock" 2>/dev/null || {
    _cct_wallet_lock_candidate=""
    return 1
  }
  [ -x /bin/sh ] && [ -x /bin/rmdir ] || return 1
  if /bin/sh -c "umask 077; printf '%s %s\\n' \"\$PPID\" \"\$1\" > \"\$2\"" \
    cct-lock-owner "$now" "$lock/owner"; then
    owner="$(_cct_wallet_read_lock_owner "$lock/owner")" || owner=""
    if [ -n "$owner" ]; then
      _cct_wallet_lock_owner="$owner"
      return 0
    fi
  fi
  /bin/rmdir -- "$lock" 2>/dev/null
  _cct_wallet_lock_candidate=""
  return 1
}

_cct_wallet_acquire_lock() {
  local lock="$1" now owner pid epoch state
  now="$(date +%s)" || {
    echo "❌ wallet lock: 현재 시간 확인 실패" >&2
    return 1
  }

  if _cct_wallet_create_lock "$lock" "$now"; then
    return 0
  fi

  # A symlink, non-directory, malformed owner, or live PID is never reclaimed.
  # Ownership is compared again during release to preserve a substituted owner.
  [ ! -L "$lock" ] || { _cct_wallet_busy; return 1; }
  [ -d "$lock" ] || { _cct_wallet_busy; return 1; }
  owner="$(_cct_wallet_read_lock_owner "$lock/owner")" ||
    { _cct_wallet_busy; return 1; }
  pid="${owner%% *}"
  epoch="${owner#* }"
  case "$pid:$epoch" in
    *[!0-9:]*|:*|*:) _cct_wallet_busy; return 1 ;;
  esac

  if _cct_wallet_pid_state "$pid"; then
    _cct_wallet_busy
    return 1
  else
    state=$?
    if [ "$state" -ne 1 ]; then
      _cct_wallet_busy
      return 1
    fi
  fi

  # Reclaim only the exact dead owner we observed. A substituted owner wins.
  if ! _cct_wallet_release_lock "$lock" "$owner"; then
    _cct_wallet_busy
    return 1
  fi
  _cct_wallet_create_lock "$lock" "$now" ||
    { _cct_wallet_busy; return 1; }
}

_cct_wallet_mutate() (
  operation="$1"
  old_key="$2"
  old_label="$3"
  new_key="$4"
  new_label="$5"
  active_action="$6"
  active_label="$7"
  tok="${_cct_wallet_token-}"
  lock="${CCT_ENV_FILE}.lock"
  backup="${CCT_ENV_FILE}.bak"
  tmp=""
  backup_tmp=""
  rollback_tmp=""
  locked=0
  lock_owner=""
  _cct_wallet_lock_candidate=""
  transaction_pending=0
  rc=0
  success_rc=0
  active=""

  umask 077
  _cct_wallet_cleanup() {
    local original_status=$? cleanup_status=0 candidate_owner
    [ -z "$tmp" ] || /bin/rm -f -- "$tmp" 2>/dev/null
    [ -z "$backup_tmp" ] || /bin/rm -f -- "$backup_tmp" 2>/dev/null
    [ -z "$rollback_tmp" ] || /bin/rm -f -- "$rollback_tmp" 2>/dev/null
    if [ "$locked" -eq 1 ]; then
      if _cct_wallet_release_lock "$lock" "$lock_owner"; then
        locked=0
      else
        cleanup_status=1
      fi
    elif [ "$_cct_wallet_lock_candidate" = "$lock" ]; then
      candidate_owner="$(_cct_wallet_read_lock_owner "$lock/owner")" || candidate_owner=""
      if [ -n "$candidate_owner" ]; then
        _cct_wallet_release_lock "$lock" "$candidate_owner" || cleanup_status=1
      else
        /bin/rmdir -- "$lock" 2>/dev/null || cleanup_status=1
      fi
      _cct_wallet_lock_candidate=""
    fi
    if [ "$original_status" -eq 0 ] && [ "$cleanup_status" -ne 0 ]; then
      return 1
    fi
    return "$original_status"
  }
  _cct_wallet_restore_locked() {
    rollback_tmp=""
    [ -f "$backup" ] && [ ! -L "$backup" ] &&
      [ "$(_cct_wallet_mode "$backup")" = "600" ] || return 1
    rollback_tmp="$(mktemp "${CCT_ENV_FILE}.tmp.XXXXXX" 2>/dev/null)" || {
      rollback_tmp=""
      return 1
    }
    chmod 600 "$rollback_tmp" 2>/dev/null &&
      cp "$backup" "$rollback_tmp" 2>/dev/null &&
      chmod 600 "$rollback_tmp" 2>/dev/null &&
      [ "$(_cct_wallet_mode "$rollback_tmp")" = "600" ] &&
      mv "$rollback_tmp" "$CCT_ENV_FILE" 2>/dev/null || return 1
    rollback_tmp=""
  }
  # shellcheck disable=SC2317,SC2329
  _cct_wallet_on_signal() {
    trap '' HUP INT TERM
    if [ "$transaction_pending" -eq 1 ]; then
      if _cct_wallet_restore_locked; then
        transaction_pending=0
        echo "❌ signal 수신 — wallet 롤백 완료" >&2
      else
        echo "❌ signal 수신 — wallet 롤백 실패" >&2
      fi
    fi
    exit 1
  }
  trap '_cct_wallet_cleanup' EXIT
  trap '_cct_wallet_on_signal' HUP INT TERM

  _cct_wallet_acquire_lock "$lock" || exit 1
  lock_owner="$_cct_wallet_lock_owner"
  locked=1
  _cct_wallet_lock_candidate=""
  case "$operation" in
    remove)
      active="$(_cct_active_label)"
      if [ "$active" = "$old_label" ]; then active_action=delete
      else active_action=""; fi
      ;;
    rename)
      active="$(_cct_active_label)"
      if [ "$active" = "$old_label" ]; then active_action="write"
      else active_action=""; fi
      ;;
  esac

  tmp="$(mktemp "${CCT_ENV_FILE}.tmp.XXXXXX" 2>/dev/null)" || {
    echo "❌ wallet temp 생성 실패: $CCT_ENV_FILE" >&2
    exit 1
  }
  chmod 600 "$tmp" 2>/dev/null || {
    echo "❌ wallet temp 권한 설정 실패: $CCT_ENV_FILE" >&2
    exit 1
  }

  case "$operation" in
    store)
      if [ -f "$CCT_ENV_FILE" ]; then
        tok="$tok" lbl="$old_label" awk -v k="$old_key" '
          BEGIN { t = ENVIRON["tok"]; l = ENVIRON["lbl"]; key_seen = 0; label_seen = 0 }
          $0 ~ ("^" k "=") {
            print k "=" t
            key_seen = 1
            next
          }
          $0 ~ ("^#cctlabel:" k "=") {
            print "#cctlabel:" k "=" l
            label_seen = 1
            next
          }
          { print }
          END {
            if (!key_seen) print k "=" t
            if (!label_seen) print "#cctlabel:" k "=" l
          }
        ' "$CCT_ENV_FILE" > "$tmp" || {
          echo "❌ wallet 내용 생성 실패: $CCT_ENV_FILE" >&2
          exit 1
        }
      else
        printf '%s=%s\n#cctlabel:%s=%s\n' "$old_key" "$tok" "$old_key" "$old_label" > "$tmp" || {
          echo "❌ wallet 내용 생성 실패: $CCT_ENV_FILE" >&2
          exit 1
        }
      fi
      ;;
    remove)
      awk -v k="$old_key" '
        BEGIN { key_seen = 0 }
        index($0, k "=") == 1 { key_seen = 1; next }
        index($0, "#cctlabel:" k "=") == 1 { next }
        { print }
        END { if (!key_seen) exit 42 }
      ' "$CCT_ENV_FILE" > "$tmp" || {
        echo "❌ wallet 계정 삭제 내용 생성 실패: $CCT_ENV_FILE" >&2
        exit 1
      }
      ;;
    rename)
      awk -v oldk="$old_key" -v newk="$new_key" -v newlabel="$new_label" '
        BEGIN { key_seen = 0; label_seen = 0; target_seen = 0 }
        index($0, oldk "=") == 1 {
          print newk substr($0, length(oldk) + 1)
          key_seen = 1
          next
        }
        index($0, newk "=") == 1 {
          target_seen = 1
          print
          next
        }
        index($0, "#cctlabel:" oldk "=") == 1 {
          print "#cctlabel:" newk "=" newlabel
          label_seen = 1
          next
        }
        { print }
        END {
          if (!key_seen) exit 42
          if (target_seen) exit 43
          if (!label_seen) print "#cctlabel:" newk "=" newlabel
        }
      ' "$CCT_ENV_FILE" > "$tmp" || {
        echo "❌ wallet 계정 이름 변경 내용 생성 실패: $CCT_ENV_FILE" >&2
        exit 1
      }
      ;;
    *)
      echo "❌ wallet mutation 종류가 유효하지 않음" >&2
      exit 1
      ;;
  esac

  chmod 600 "$tmp" 2>/dev/null || {
    echo "❌ wallet temp 권한 설정 실패: $CCT_ENV_FILE" >&2
    exit 1
  }

  if [ -e "$CCT_ENV_FILE" ] || [ -L "$CCT_ENV_FILE" ]; then
    [ ! -L "$backup" ] || {
      echo "❌ wallet backup 경로가 심볼릭 링크임: $backup" >&2
      exit 1
    }
    if [ -e "$backup" ] && [ ! -f "$backup" ]; then
      echo "❌ wallet backup 경로가 일반 파일이 아님: $backup" >&2
      exit 1
    fi
    backup_tmp="$(mktemp "${backup}.tmp.XXXXXX" 2>/dev/null)" || {
      echo "❌ wallet backup temp 생성 실패: $backup" >&2
      exit 1
    }
    chmod 600 "$backup_tmp" 2>/dev/null || {
      echo "❌ wallet backup temp 권한 설정 실패: $backup" >&2
      exit 1
    }
    cp "$CCT_ENV_FILE" "$backup_tmp" 2>/dev/null || {
      echo "❌ wallet backup 생성 실패: $backup" >&2
      exit 1
    }
    chmod 600 "$backup_tmp" 2>/dev/null || {
      echo "❌ wallet backup 권한 설정 실패: $backup" >&2
      exit 1
    }
    [ "$(_cct_wallet_mode "$backup_tmp")" = "600" ] || {
      echo "❌ wallet backup 권한 확인 실패: $backup" >&2
      exit 1
    }
    mv "$backup_tmp" "$backup" 2>/dev/null || {
      echo "❌ wallet backup atomic replace 실패: $backup" >&2
      exit 1
    }
    backup_tmp=""
  fi

  [ -z "$active_action" ] || transaction_pending=1
  mv "$tmp" "$CCT_ENV_FILE" 2>/dev/null || {
    echo "❌ wallet atomic replace 실패: $CCT_ENV_FILE" >&2
    exit 1
  }
  tmp=""
  [ "$transaction_pending" -eq 0 ] || trap '' HUP INT TERM
  active_failed=0
  case "$active_action" in
    "") ;;
    delete) _cct_active_delete_checked || active_failed=1 ;;
    write) _cct_active_write_atomic "$active_label" || active_failed=1 ;;
    *) active_failed=1 ;;
  esac
  if [ "$active_failed" -ne 0 ]; then
    if _cct_wallet_restore_locked; then
      transaction_pending=0
      echo "❌ 활성 프로필 변경 실패 — wallet 롤백 완료" >&2
    else
      echo "❌ 활성 프로필 변경 실패 — wallet 롤백도 실패" >&2
    fi
    trap '_cct_wallet_on_signal' HUP INT TERM
    exit 1
  fi
  if [ "$transaction_pending" -eq 1 ]; then
    transaction_pending=0
    trap '_cct_wallet_on_signal' HUP INT TERM
  fi
  [ -z "$active_action" ] || success_rc=10
  trap '' HUP INT TERM
  trap - EXIT
  _cct_wallet_cleanup
  rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
  exit "$success_rc"
)

_cct_wallet_store_account() {
  _cct_wallet_mutate store "$1" "$2" "" "" "" ""
}

_cct_wallet_remove_account() {
  local rc
  _cct_wallet_active_changed=0
  if _cct_wallet_mutate remove "$1" "$2" "" "" "${3-}" ""; then
    rc=0
  else
    rc=$?
  fi
  case "$rc" in
    0) return 0 ;;
    10) _cct_wallet_active_changed=1; return 0 ;;
    *) return "$rc" ;;
  esac
}

_cct_wallet_rename_account() {
  local rc
  _cct_wallet_active_changed=0
  if _cct_wallet_mutate rename "$1" "$2" "$3" "$4" "${5-}" "$4"; then
    rc=0
  else
    rc=$?
  fi
  case "$rc" in
    0) return 0 ;;
    10) _cct_wallet_active_changed=1; return 0 ;;
    *) return "$rc" ;;
  esac
}

_cct_add() {
  local label key tok dupkey existing_label ans action _cct_wallet_token
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
  # N5: 디렉터리만 먼저 보장. 지갑 파일 자체는 잠금 안에서 원자적으로 생성/교체한다.
  mkdir -p "$(_cct_parent_dir "$CCT_ENV_FILE")" 2>/dev/null || {
    echo "❌ 디렉터리 생성 실패: $(_cct_parent_dir "$CCT_ENV_FILE")" >&2
    return 1
  }
  # C#1: 키가 이미 있으면 원본 라벨 비교 — 같은 라벨이면 조용히 갱신, 다른 라벨이면 충돌 경고+확인(기본 거부)
  if grep -qE "^$key=" "$CCT_ENV_FILE" 2>/dev/null; then
    action="갱신"
    existing_label="$(_cct_label_for "$key")"
    if [ "$existing_label" != "$label" ]; then
      echo "⚠️  라벨 '$label' 는 기존 라벨 '$existing_label' 와 같은 키($key)로 정규화됩니다(대소문자/기호 차이)." >&2
      printf '   기존 토큰을 덮어쓸까요? [y/N] ' >&2
      read -r ans || ans=
      case "$ans" in y|Y|yes|YES) ;; *) echo "취소함 (기존 '$existing_label' 유지)." >&2; return 1 ;; esac
    fi
  else action="추가"; fi
  # 동일 토큰 중복 감지: 다른 라벨과 값이 같으면 같은 계정 재사용(브라우저 세션) 의심 — 경고만
  dupkey="$(grep -oE '^CCT_TOKEN_[A-Za-z0-9_]+' "$CCT_ENV_FILE" 2>/dev/null | while IFS= read -r ek; do
    [ "$ek" = "$key" ] && continue
    [ "$(_cct_envtok "$ek")" = "$tok" ] && { printf '%s' "$ek"; break; }
  done || true)"
  [ -n "$dupkey" ] && echo "⚠️  이 토큰은 기존 '$dupkey' 와 동일 — 같은 계정 재사용 의심(다시 로그인했는지 확인). 저장은 진행."
  _cct_wallet_token="$tok"
  unset tok
  _cct_wallet_store_account "$key" "$label" || {
    unset _cct_wallet_token
    echo "❌ [$label] 저장 실패 ($action) — 경로/권한 확인: $CCT_ENV_FILE" >&2
    return 1
  }
  if [ "${CCT_STICKY:-1}" != "0" ] && [ "$(_cct_active_label)" = "$label" ]; then
    _cct_apply_env "$_cct_wallet_token"
  fi
  unset _cct_wallet_token
  echo "✓ [$label] $action 완료"
  echo "→ 'cct $label' 로 사용 / 'cct check $label' 로 점검"
}

# 계정 지문: org-id + rate-limit 윈도. 7d_reset 가 동일하면 같은 계정(중복)
_cct_fp_one() {
  local tok H org r5 r7 u5
  _cct_validate_label "${1-}" || return
  tok="$(_cct_envtok "$(_cct_key "$1")")"
  [ -n "$tok" ] || { printf '  %-8s 토큰없음\n' "$1"; return; }
  H="$(
    printf 'Authorization: Bearer %s\n' "$tok" |
      curl -s -m 25 -D - -o /dev/null https://api.anthropic.com/v1/messages \
        -H @- -H "anthropic-version: 2023-06-01" \
        -H "anthropic-beta: oauth-2025-04-20" -H "content-type: application/json" \
        -d "{\"model\":\"$CCT_PROBE_MODEL\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
        2>/dev/null || true
  )"
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
    "cct — 휴대용 Claude 계정 지갑 / Portable Claude Account Wallet" \
    "한 번 등록한 장기 setup-token으로 사용자가 계정을 명시 전환합니다." \
    "프록시·오케스트레이터·자동 라우터가 아니며 macOS/Linux/WSL2에서 동작합니다." \
    "" \
    "  cct [claude 인자...]        활성(sticky) 라벨로 실행 — 없으면 CCT_DEFAULT_LABEL(기본 gv)" \
    "  cct <라벨> [claude 인자...] 해당 계정을 명시 선택하고 Claude 인자를 전달" \
    "  cct run <라벨> [...]        예약어 라벨도 명시 실행       예: cct run rm --version" \
    "  cct ls | cct list           등록 계정 목록 (토큰 값 미표시)" \
    "  cct add <라벨>              setup-token 등록/교체 (숨김 입력)" \
    "  cct rm <라벨> [--force]     계정 삭제 (기본 확인 [y/N])" \
    "  cct rename <기존> <새>      토큰 값은 유지하고 라벨·활성 상태 변경" \
    "  cct status                  지갑·활성 계정·Claude 상태 표시 (오프라인)" \
    "  cct doctor                  지갑 구조·권한·백업·잠금 진단 (오프라인)" \
    "  cct check [라벨]            토큰 유효성 점검 (실제 호출)" \
    "  cct fp [라벨] | cct who [라벨]  계정 지문·중복 점검 (실제 호출)" \
    "  cct active                  현재 sticky 활성 라벨 표시" \
    "  cct off                     활성 라벨과 현재 셸 cct 인증 환경 해제" \
    "  cct help                    이 도움말" \
    "" \
    "종료코드: 일반적으로 성공 0 / 실행·상태 실패 1 / 사용법·라벨 오류 2." \
    "          check는 유효 0 / 무효·점검불가 1 / 토큰없음 2 (전체는 하나라도 문제면 1)." \
    "          doctor는 FAIL 없음 0 / 상태 FAIL 1 / 사용법 오류 2." \
    "라벨:     [a-z0-9_][a-z0-9_]* (예약어 라벨 실행은 cct run 사용)." \
    "지갑:     \${CCT_ENV_FILE:-~/.claude/tokens.env}, backup은 .bak, 변경 중 lock은 .lock/." \
    "보안:     setup-token은 비밀번호급. 지갑/backup은 mode 600, Git·평문 cloud sync 금지." \
    "수명:     setup-token은 long-lived지만 고정 수명·영구성을 보장하지 않으며 정책에 따라 재발급 필요." \
    "sticky:   cct <라벨> 선택을 현재 셸과 cct-active에 기억. cct off로 해제." \
    "" \
    "환경변수: CCT_SKIP_PERMS=0  CCT_CLAUDE_FLAGS='...'  CCT_DEFAULT_LABEL=gv  CCT_STICKY=0" \
    "          CCT_DISABLE_WEB_FEATURES=0  CCT_ENV_FILE=...  CCT_ACTIVE_FILE=..." \
    "호환성/BREAKING 변경은 CHANGELOG.md 참고."
}

# 혹시 cct alias 가 있으면 제거 — 함수 정의 충돌 방지 (cc 는 건드리지 않음)
unalias cct 2>/dev/null || true

# ── sticky 활성 프로필 ────────────────────────────────────────────────
# 마지막으로 고른 cct <라벨> 을 "활성 프로필"로 기억해, 그냥 `claude`/`cc`/새
# 터미널도 같은 계정으로 인증되게 한다. CCT_STICKY=0 이면 비활성(기존 inline 주입).
# 활성 라벨은 tokens.env 옆 cct-active 파일에 저장(CCT_ACTIVE_FILE 로 변경 가능).
_cct_active_file() {
  local parent
  if [ -n "${CCT_ACTIVE_FILE:-}" ]; then
    printf '%s' "$CCT_ACTIVE_FILE"
    return
  fi
  parent="$(_cct_parent_dir "$CCT_ENV_FILE")"
  if [ "$parent" = "/" ]; then printf '/cct-active'
  else printf '%s/cct-active' "$parent"; fi
}

_cct_active_raw_label() {
  local f v
  f="$(_cct_active_file)"
  [ ! -L "$f" ] && [ -f "$f" ] && [ -r "$f" ] || return 1
  awk '
    NR == 1 { sub(/\r$/, ""); value = $0; next }
    { extra = 1 }
    END {
      if (NR == 1 && !extra) print value
      else exit 1
    }
  ' "$f" 2>/dev/null
}

_cct_active_label() {
  local v
  v="$(_cct_active_raw_label)" || return 0
  _cct_label_is_valid "$v" || return 0
  _cct_account_exists "$(_cct_key "$v")" || return 0
  printf '%s' "$v"
}

_cct_apply_env() {  # $1=token — 현재 셸에 토큰(+웹기능 차단 플래그) export
  export CLAUDE_CODE_OAUTH_TOKEN="$1"
  if [ "${CCT_DISABLE_WEB_FEATURES:-1}" = "0" ]; then
    unset CLAUDE_CODE_DISABLE_ADVISOR_TOOL CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC CLAUDE_CODE_DISABLE_BACKGROUND_PLUGIN_REFRESH
  else
    export CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_DISABLE_BACKGROUND_PLUGIN_REFRESH=1
  fi
}

_cct_active_write_atomic() (
  label="$1"
  f="$(_cct_active_file)"
  tmp=""
  umask 077
  [ -x /bin/rm ] || exit 1
  trap '[ -z "$tmp" ] || /bin/rm -f -- "$tmp" 2>/dev/null' EXIT
  trap 'exit 1' HUP INT TERM
  [ ! -L "$f" ] || exit 1
  if [ -e "$f" ] && [ ! -f "$f" ]; then
    exit 1
  fi
  mkdir -p "$(_cct_parent_dir "$f")" 2>/dev/null || exit 1
  tmp="$(mktemp "${f}.tmp.XXXXXX" 2>/dev/null)" || exit 1
  chmod 600 "$tmp" 2>/dev/null || exit 1
  printf '%s\n' "$label" > "$tmp" 2>/dev/null || exit 1
  chmod 600 "$tmp" 2>/dev/null || exit 1
  mv "$tmp" "$f" 2>/dev/null || exit 1
  tmp=""
)

_cct_active_delete_checked() {
  local f
  f="$(_cct_active_file)"
  [ ! -L "$f" ] || return 1
  [ -e "$f" ] || return 0
  [ -f "$f" ] && [ -x /bin/rm ] || return 1
  /bin/rm -f -- "$f" 2>/dev/null || return 1
  [ ! -e "$f" ] && [ ! -L "$f" ]
}

_cct_active_change_locked() (
  action="$1"
  label="${2-}"
  expected_token="${3-}"
  lock="${CCT_ENV_FILE}.lock"
  locked=0
  lock_owner=""
  _cct_wallet_lock_candidate=""
  rc=0

  umask 077
  _cct_active_lock_cleanup() {
    local original_status=$? cleanup_status=0 candidate_owner
    if [ "$locked" -eq 1 ]; then
      if _cct_wallet_release_lock "$lock" "$lock_owner"; then
        locked=0
      else
        cleanup_status=1
      fi
    elif [ "$_cct_wallet_lock_candidate" = "$lock" ]; then
      candidate_owner="$(_cct_wallet_read_lock_owner "$lock/owner")" || candidate_owner=""
      if [ -n "$candidate_owner" ]; then
        _cct_wallet_release_lock "$lock" "$candidate_owner" || cleanup_status=1
      else
        /bin/rmdir -- "$lock" 2>/dev/null || cleanup_status=1
      fi
      _cct_wallet_lock_candidate=""
    fi
    if [ "$original_status" -eq 0 ] && [ "$cleanup_status" -ne 0 ]; then
      return 1
    fi
    return "$original_status"
  }
  # shellcheck disable=SC2317,SC2329
  _cct_active_lock_signal() {
    trap '' HUP INT TERM
    exit 1
  }
  trap '_cct_active_lock_cleanup' EXIT
  trap '_cct_active_lock_signal' HUP INT TERM

  _cct_wallet_acquire_lock "$lock" || exit 1
  lock_owner="$_cct_wallet_lock_owner"
  locked=1
  _cct_wallet_lock_candidate=""

  case "$action" in
    write)
      key="$(_cct_key "$label")"
      current_token="$(_cct_envtok "$key")"
      if [ -z "$current_token" ] || [ "$current_token" != "$expected_token" ]; then
        echo "❌ '$label' 계정이 선택 중 변경되었음. 다시 시도하세요." >&2
        exit 1
      fi
      _cct_active_write_atomic "$label" || exit 1
      ;;
    delete)
      _cct_active_delete_checked || exit 1
      ;;
    *)
      exit 1
      ;;
  esac

  trap '' HUP INT TERM
  trap - EXIT
  _cct_active_lock_cleanup
  rc=$?
  exit "$rc"
)

_cct_off() {  # sticky 해제: 저장 파일 삭제 + 현재 셸 env 해제
  _cct_active_change_locked delete || {
    echo "❌ 활성 프로필 해제 실패: $(_cct_active_file)" >&2
    return 1
  }
  unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_DISABLE_ADVISOR_TOOL CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC CLAUDE_CODE_DISABLE_BACKGROUND_PLUGIN_REFRESH
  echo "✓ 활성 프로필 해제 — 이후 cct <라벨> 로 다시 선택"
}

_cct_active_show() {  # 현재 활성 프로필 표시
  local a; a="$(_cct_active_label)"
  if [ -n "$a" ]; then echo "활성 프로필: $a   (해제: cct off)"
  else echo "활성 프로필 없음 — cct <라벨> 로 선택 (기본 ${CCT_DEFAULT_LABEL:-gv})"; fi
}

_cct_account_exists() {
  grep -q "^$1=" "$CCT_ENV_FILE" 2>/dev/null
}

_cct_label_is_valid() {
  local LC_ALL=C
  case "${1-}" in
    ""|*[!a-z0-9_]*|[!a-z0-9_]*) return 1 ;;
    *) return 0 ;;
  esac
}

_cct_claude_binary() {
  if [ -n "${ZSH_VERSION:-}" ]; then
    whence -p claude 2>/dev/null || true
  else
    type -P claude 2>/dev/null || true
  fi
}

_cct_account_count() {
  if [ ! -f "$CCT_ENV_FILE" ] || [ -L "$CCT_ENV_FILE" ]; then
    printf '0'
    return
  fi
  awk -F= '
    /^CCT_TOKEN_[A-Z0-9_]+=/ {
      if (!seen[$1]++) count++
    }
    END { print count + 0 }
  ' "$CCT_ENV_FILE" 2>/dev/null
}

_cct_status() {
  [ "$#" -eq 0 ] || {
    echo "사용법: cct status" >&2
    return 2
  }
  local mode accounts active active_file default_label sticky cb version probe_status

  if [ -L "$CCT_ENV_FILE" ]; then
    mode="symbolic-link"
    accounts="unavailable"
  elif [ -f "$CCT_ENV_FILE" ]; then
    mode="$(_cct_wallet_mode "$CCT_ENV_FILE")"
    [ -n "$mode" ] || mode="unknown"
    accounts="$(_cct_account_count)"
  else
    mode="missing"
    accounts="0"
  fi

  active_file="$(_cct_active_file)"
  if [ ! -e "$active_file" ] && [ ! -L "$active_file" ]; then
    active="none"
  else
    active="$(_cct_active_raw_label)" || active=""
    if ! _cct_label_is_valid "$active" ||
      ! _cct_account_exists "$(_cct_key "$active")"; then
      active="invalid"
    fi
  fi
  if [ -z "$active" ]; then
    active="invalid"
  fi
  default_label="${CCT_DEFAULT_LABEL:-gv}"
  _cct_label_is_valid "$default_label" || default_label="invalid"
  if [ "${CCT_STICKY:-1}" = "0" ]; then sticky="disabled"; else sticky="enabled"; fi
  cb="$(_cct_claude_binary)"

  printf 'wallet: %s\n' "$CCT_ENV_FILE"
  printf 'mode: %s\n' "$mode"
  printf 'accounts: %s\n' "$accounts"
  printf 'active: %s\n' "$active"
  printf 'default: %s\n' "$default_label"
  printf 'sticky: %s\n' "$sticky"
  if [ -z "$cb" ]; then
    printf 'claude: missing\n'
    printf 'claude-version: unavailable\n'
  else
    printf 'claude: %s\n' "$cb"
    if version="$(
      (
        unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_DISABLE_ADVISOR_TOOL \
          CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC CLAUDE_CODE_DISABLE_BACKGROUND_PLUGIN_REFRESH
        _cct_run_limited 5 "$cb" --version </dev/null 2>/dev/null
      )
    )"; then
      probe_status=0
    else
      probe_status=$?
    fi
    if [ "$probe_status" -eq 0 ]; then
      version="$(printf '%s\n' "$version" | awk '
        NR == 1 {
          gsub(/\r/, "")
          numeric = "[0-9]+\\.[0-9]+(\\.[0-9]+)?(\\.[0-9]+)?"
          if ($0 ~ ("^" numeric "$") ||
              $0 ~ ("^" numeric " \\(Claude Code\\)$") ||
              $0 ~ ("^Claude Code (fixture )?" numeric "$"))
            print substr($0, 1, 200)
          else
            print "unavailable"
          exit
        }
      ')"
    else
      version="unavailable"
    fi
    [ -n "$version" ] || version="unavailable"
    printf 'claude-version: %s\n' "$version"
  fi
}

_cct_doctor_structure() {
  awk '
    function fail(message) {
      printf "FAIL structure: line %d: %s\n", NR, message
      failed = 1
    }
    function valid_label(label) {
      return label ~ /^[a-z0-9_]+$/
    }
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^[[:space:]]*$/) next
      if (line ~ /^#cctlabel:/) {
        if (line !~ /^#cctlabel:CCT_TOKEN_[A-Z0-9_]+=/) {
          fail("malformed annotation")
          next
        }
        split_at = index(line, "=")
        key = substr(line, 11, split_at - 11)
        label = substr(line, split_at + 1)
        annotation_total++
        annotation_key[annotation_total] = key
        annotation_line[annotation_total] = NR
        annotation_count[key]++
        if (annotation_count[key] > 1)
          fail("duplicate annotation " key)
        if (!valid_label(label) || key != "CCT_TOKEN_" toupper(label))
          fail("invalid annotation ownership " key)
        next
      }
      if (line ~ /^[[:space:]]*#/) next
      if (line ~ /^CCT_TOKEN_/) {
        split_at = index(line, "=")
        if (!split_at) {
          fail("malformed key")
          next
        }
        key = substr(line, 1, split_at - 1)
        if (key !~ /^CCT_TOKEN_[A-Z0-9_]+$/) {
          fail("malformed key")
          next
        }
        value = substr(line, split_at + 1)
        if (length(value) == 0)
          fail("empty value for " key)
        key_count[key]++
        if (key_count[key] == 1) account_count++
        else fail("duplicate key " key)
        next
      }
      fail("malformed entry")
    }
    END {
      for (i = 1; i <= annotation_total; i++) {
        key = annotation_key[i]
        if (!(key in key_count)) {
          printf "FAIL structure: line %d: orphan annotation %s\n",
            annotation_line[i], key
          failed = 1
        }
      }
      if (!failed)
        printf "PASS structure: %d account(s), annotations valid\n", account_count
      exit failed ? 1 : 0
    }
  ' "$CCT_ENV_FILE"
}

_cct_doctor() {
  [ "$#" -eq 0 ] || {
    echo "사용법: cct doctor" >&2
    return 2
  }
  local failed=0 mode active_file active default_label backup lock owner
  local pid epoch now age cb state

  if [ -L "$CCT_ENV_FILE" ]; then
    echo "FAIL wallet: symbolic link"
    failed=1
  elif [ ! -e "$CCT_ENV_FILE" ]; then
    echo "FAIL wallet: missing"
    failed=1
  elif [ ! -f "$CCT_ENV_FILE" ]; then
    echo "FAIL wallet: not a regular file"
    failed=1
  elif [ ! -r "$CCT_ENV_FILE" ]; then
    echo "FAIL wallet: unreadable"
    failed=1
  else
    mode="$(_cct_wallet_mode "$CCT_ENV_FILE")"
    if [ "$mode" = "600" ]; then
      echo "PASS wallet: readable regular file, mode 600"
    else
      printf 'FAIL wallet: mode %s (expected 600)\n' "${mode:-unknown}"
      failed=1
    fi
    _cct_doctor_structure || failed=1
  fi

  active_file="$(_cct_active_file)"
  if [ -L "$active_file" ]; then
    echo "FAIL active: symbolic link"
    failed=1
  elif [ ! -e "$active_file" ]; then
    echo "PASS active: none"
  elif [ ! -f "$active_file" ] || [ ! -r "$active_file" ]; then
    echo "FAIL active: unreadable or not a regular file"
    failed=1
  else
    mode="$(_cct_wallet_mode "$active_file")"
    if [ "$mode" != "600" ]; then
      printf 'FAIL active: mode %s (expected 600)\n' "${mode:-unknown}"
      failed=1
    elif active="$(_cct_active_raw_label)" &&
      _cct_label_is_valid "$active"; then
      if _cct_account_exists "$(_cct_key "$active")"; then
        echo "PASS active: label resolves"
      else
        echo "FAIL active: unresolved label"
        failed=1
      fi
    else
      echo "FAIL active: malformed label"
      failed=1
    fi
  fi

  default_label="${CCT_DEFAULT_LABEL:-gv}"
  if ! _cct_label_is_valid "$default_label"; then
    echo "FAIL default: malformed label"
    failed=1
  elif _cct_account_exists "$(_cct_key "$default_label")"; then
    echo "PASS default: label resolves"
  else
    echo "FAIL default: unresolved label"
    failed=1
  fi

  backup="${CCT_ENV_FILE}.bak"
  if [ -L "$backup" ]; then
    echo "FAIL backup: symbolic link"
    failed=1
  elif [ ! -e "$backup" ]; then
    echo "PASS backup: absent"
  elif [ ! -f "$backup" ] || [ ! -r "$backup" ]; then
    echo "FAIL backup: unreadable or not a regular file"
    failed=1
  else
    mode="$(_cct_wallet_mode "$backup")"
    if [ "$mode" = "600" ]; then
      echo "PASS backup: mode 600"
    else
      printf 'FAIL backup: mode %s (expected 600)\n' "${mode:-unknown}"
      failed=1
    fi
  fi

  lock="${CCT_ENV_FILE}.lock"
  if [ -L "$lock" ]; then
    echo "FAIL lock: symbolic link"
    failed=1
  elif [ ! -e "$lock" ]; then
    echo "PASS lock: absent"
  elif [ ! -d "$lock" ]; then
    echo "FAIL lock: not a directory"
    failed=1
  elif [ -L "$lock/owner" ] || [ ! -f "$lock/owner" ] || [ ! -r "$lock/owner" ]; then
    echo "FAIL lock: malformed owner metadata"
    failed=1
  else
    owner="$(awk '
      NR == 1 && NF == 2 &&
        $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ &&
        length($1) <= 18 && length($2) <= 18 &&
        ($1 + 0) > 0 && ($2 + 0) > 0 {
          pid = $1
          epoch = $2
          next
        }
      { bad = 1 }
      END {
        if (NR == 1 && !bad) print pid " " epoch
        else exit 1
      }
    ' "$lock/owner" 2>/dev/null)" || owner=""
    if [ -z "$owner" ]; then
      echo "FAIL lock: malformed owner metadata"
      failed=1
    else
      pid="${owner%% *}"
      epoch="${owner#* }"
      now="$(date +%s 2>/dev/null)" || now=""
      if [ -z "$now" ]; then
        echo "FAIL lock: current time unavailable"
        failed=1
      else
        age=$((now - epoch))
        if _cct_wallet_pid_state "$pid"; then
          echo "WARN lock: live mutation in progress"
        else
          state=$?
          if [ "$state" -eq 2 ]; then
            echo "WARN lock: owner liveness unknown"
          elif [ "$age" -lt 0 ]; then
            echo "FAIL lock: malformed owner timestamp"
            failed=1
          else
            echo "FAIL lock: dead or stale owner"
            failed=1
          fi
        fi
      fi
    fi
  fi

  cb="$(_cct_claude_binary)"
  if [ -n "$cb" ]; then
    echo "PASS claude: executable found"
  else
    echo "FAIL claude: missing"
    failed=1
  fi

  if [ -n "${BASH_VERSION:-}" ] || [ -n "${ZSH_VERSION:-}" ]; then
    echo "PASS shell: Bash or Zsh sourced state detected"
  else
    echo "FAIL shell: Bash/Zsh sourced state missing"
    failed=1
  fi

  [ "$failed" -eq 0 ]
}

_cct_rm() {
  local label key force=0 ans removed_token
  [ "$#" -ge 1 ] || { echo "사용법: cct rm <라벨> [--force]" >&2; return 2; }
  [ "$#" -le 2 ] || { echo "사용법: cct rm <라벨> [--force]" >&2; return 2; }
  label="$1"
  _cct_validate_label "$label" || return 2
  if [ "$#" -eq 2 ]; then
    [ "$2" = "--force" ] || {
      echo "❌ 알 수 없는 옵션: $2" >&2
      return 2
    }
    force=1
  fi
  key="$(_cct_key "$label")"
  _cct_account_exists "$key" || {
    echo "❌ '$label' 계정 없음" >&2
    return 1
  }
  removed_token="$(_cct_envtok "$key")"
  if [ "$force" -eq 0 ]; then
    printf "'%s' 계정을 삭제할까요? [y/N] " "$label" >&2
    read -r ans || ans=
    case "$ans" in y|Y|yes|YES) ;; *) echo "취소함." >&2; return 1 ;; esac
  fi
  _cct_wallet_remove_account "$key" "$label" || {
    echo "❌ [$label] 삭제 트랜잭션 실패" >&2
    return 1
  }
  if [ "$_cct_wallet_active_changed" -eq 1 ] ||
    { [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] &&
      [ "${CLAUDE_CODE_OAUTH_TOKEN:-}" = "$removed_token" ]; }; then
    unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_DISABLE_ADVISOR_TOOL \
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC CLAUDE_CODE_DISABLE_BACKGROUND_PLUGIN_REFRESH
  fi
  echo "✓ [$label] 계정 삭제 완료"
}

_cct_rename() {
  local old_label new_label old_key new_key
  [ "$#" -eq 2 ] || {
    echo "사용법: cct rename <기존> <새>" >&2
    return 2
  }
  old_label="$1"
  new_label="$2"
  _cct_validate_label "$old_label" || return 2
  _cct_validate_label "$new_label" || return 2
  _cct_reserved_label "$new_label" && {
    echo "❌ '$new_label' 는 예약어(서브커맨드)라 새 라벨로 쓸 수 없음." >&2
    return 2
  }
  old_key="$(_cct_key "$old_label")"
  new_key="$(_cct_key "$new_label")"
  _cct_account_exists "$old_key" || {
    echo "❌ '$old_label' 계정 없음" >&2
    return 1
  }
  _cct_account_exists "$new_key" && {
    echo "❌ '$new_label' 계정이 이미 존재함" >&2
    return 1
  }
  _cct_wallet_rename_account "$old_key" "$old_label" "$new_key" "$new_label" || {
    echo "❌ [$old_label] 이름 변경 트랜잭션 실패" >&2
    return 1
  }
  echo "✓ [$old_label] → [$new_label] 이름 변경 완료"
}

_cct_launch_label() {
  local label="$1" key tok
  shift
  local command_args=(claude)
  [ "${CCT_SKIP_PERMS:-1}" = "0" ] || command_args+=(--dangerously-skip-permissions)
  case "${CCT_CLAUDE_FLAGS:-}" in
  *[![:space:]]*)
    local _extra
    if [ -n "${ZSH_VERSION:-}" ]; then
      read -rA _extra <<< "$CCT_CLAUDE_FLAGS"
    else
      read -ra _extra <<< "$CCT_CLAUDE_FLAGS"
    fi
    command_args+=("${_extra[@]}")
    ;;
  esac
  key="$(_cct_key "$label")"; tok="$(_cct_envtok "$key")"
  if [ -z "$tok" ]; then
    { echo "❌ '$label' 토큰 없음 (키 $key). 등록된 계정:"; _cct_list; echo "→ 등록: cct add $label"; } >&2
    return 1
  fi
  echo "▶ $label 로 실행"
  if [ "${CCT_STICKY:-1}" = "0" ]; then
    if [ "${CCT_DISABLE_WEB_FEATURES:-1}" = "0" ]; then
      (
        unset CLAUDE_CODE_DISABLE_ADVISOR_TOOL CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC CLAUDE_CODE_DISABLE_BACKGROUND_PLUGIN_REFRESH
        CLAUDE_CODE_OAUTH_TOKEN="$tok" command "${command_args[@]}" "$@"
      )
    else
      CLAUDE_CODE_OAUTH_TOKEN="$tok" \
        CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1 \
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
        CLAUDE_CODE_DISABLE_BACKGROUND_PLUGIN_REFRESH=1 \
        command "${command_args[@]}" "$@"
    fi
  else
    _cct_active_change_locked write "$label" "$tok" || {
      echo "❌ 활성 프로필 저장 실패: $(_cct_active_file)" >&2
      return 1
    }
    _cct_apply_env "$tok"
    command "${command_args[@]}" "$@"
  fi
}

cct() {
  local label=""
  case "${1-}" in
    help)     _cct_help; return ;;
    ls|list)  _cct_list; return ;;
    add)      shift; _cct_add "$@"; return ;;
    run)      shift
              [ -n "${1-}" ] || { echo "사용법: cct run <라벨> [claude 인자...]" >&2; return 2; }
              label="$1"; shift
              _cct_validate_label "$label" || return 2
              _cct_launch_label "$label" "$@"; return ;;
    rm)       shift; _cct_rm "$@"; return ;;
    rename)   shift; _cct_rename "$@"; return ;;
    status)   shift; _cct_status "$@"; return ;;
    doctor)   shift; _cct_doctor "$@"; return ;;
    check)    shift; _cct_check "$@"; return ;;
    fp|who)   shift; _cct_fp "$@"; return ;;
    off)      _cct_off; return ;;
    active)   _cct_active_show; return ;;
    ""|-*)    # 라벨 없는 실행: sticky 활성 프로필 → 없으면 기본 라벨(CCT_DEFAULT_LABEL, 기본 gv).
              # 키체인 폴백 금지. 남은 인자($@)는 그대로 claude 플래그로 전달(shift 안 함).
              [ "${CCT_STICKY:-1}" = "0" ] || label="$(_cct_active_label)"
              [ -n "$label" ] || label="${CCT_DEFAULT_LABEL:-gv}"
              _cct_validate_label "$label" || { echo "❌ 라벨 '$label' 가 유효하지 않음 (CCT_DEFAULT_LABEL/활성 프로필 확인)." >&2; return 2; } ;;
    *)        label="$1"; shift
              _cct_reserved_label "$label" && { echo "❌ '$label' 는 예약어(서브커맨드)라 라벨로 쓸 수 없음." >&2; return 2; }
              _cct_validate_label "$label" || return 2 ;;
  esac
  _cct_launch_label "$label" "$@"
}

# ── 새 셸 시작 시 활성 프로필 자동 로드 (sticky) ──────────────────────
# 저장된 활성 라벨의 토큰을 현재 셸에 export → 그냥 `claude` 도 마지막 선택 계정 유지.
# CCT_STICKY=0 이면 건너뜀. 토큰을 못 찾으면 조용히 통과(키체인 폴백).
if [ "${CCT_STICKY:-1}" != "0" ]; then
  _cct_boot_label="$(_cct_active_label)"
  if [ -n "$_cct_boot_label" ]; then
    _cct_boot_tok="$(_cct_envtok "$(_cct_key "$_cct_boot_label")")"
    [ -n "$_cct_boot_tok" ] && _cct_apply_env "$_cct_boot_tok"
    unset _cct_boot_tok
  fi
  unset _cct_boot_label
fi
