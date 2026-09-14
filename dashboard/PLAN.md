# cct 대시보드 구현 플랜 (위임용)

작성 2026-09-15 · 작성 주체: 목업을 만든 Codex 세션 · 대상: 구현을 이어받는 모델
이 문서 하나로 작업이 가능해야 한다. 여기 적힌 사실은 전부 2026-09-15 실측이다. 추측은 "추정"이라고 표기했다.

## 0. 한 줄 요약

목업 `~/cct/dashboard/mockup/index.html` 을 그대로 실동작으로 옮긴다. cct 에 `usage --json` 과 `use` 서브커맨드를 추가하고, Mac 에서 uv 단일 파일 서버가 cct 를 호출해 JSON 을 내려주고, 프론트는 목업 화면을 그대로 쓰되 샘플 데이터 대신 API 를 쓴다. bk-pc(Windows) 는 이미 열려 있는 tailscale serve 주소(`:8444`)로 본다.

## 1. 범위 / 비범위

범위(v1): 목업에 있는 모든 화면과 버튼을 실동작으로. 계정 카드(5h/7d/7f 게이지·리셋·status 플래그·check·org·중복 배지), 추천 배너, 활성 세션 라이브, 리셋 타임라인, doctor, 실행 로그, 자동갱신·프로브 예산, 쓰기 모드(add/rm/rename), 활성 전환(use)·해제(off).

비범위(v1 제외, 나중 티어): 사용률 히스토리 DB·스파크라인, 임계치 알림, ccusage 식 JSONL 토큰·비용 분석, Windows/WSL2 쪽 지갑 집계, 사용자 인증(테일넷 신뢰로 대체), CodexBar 연동(BK 가 사용 안 함으로 확정).

## 2. 확인된 사실

### 2.1 cct 자체

- 설치본 `~/.claude/cct.sh` 와 리포 `~/cct/cct.sh` 는 바이트 동일(`diff -q` 확인). 리포: github.com/Bkankim/cct (공개). 1911줄, bash/zsh 겸용, macOS/Linux/WSL2.
- 지갑 `~/.claude/tokens.env` (mode 600). 형식 `CCT_TOKEN_<대문자라벨>=<setup-token>` 한 줄씩, `#cctlabel:CCT_TOKEN_X=x` 주석으로 원본 라벨 보존. 활성 라벨 파일 `~/.claude/cct-active`. 잠금 디렉터리 `tokens.env.lock/`(owner 파일에 pid epoch), 백업 `tokens.env.bak`.
- 현재 6계정 등록, 활성 `gv`, 기본 `gv`, sticky enabled, Claude Code 2.1.270, claude 바이너리 `/Users/bkan/.local/bin/claude`.
- 라벨 규칙 `[a-z0-9_]+`. 예약어(`_cct_reserved_label`): help ls list add run rm rename status doctor check fp who usage off active refresh. 새 서브커맨드를 넣으면 이 목록·`cct()` 디스패치·`_cct_help`·README(ko/en) 표·CHANGELOG 를 같이 고친다.
- 출력 형식(파싱 대상):
  - `cct status`: `key: value` 줄. 키 = wallet, mode, accounts, active, default, sticky, claude, claude-version. rc 0, 인자 있으면 2.
  - `cct doctor`: `PASS|WARN|FAIL <area>: <message>` 줄. rc 0(FAIL 없음) / 1 / 2(오용).
  - `cct ls`: 비 TTY 에서 `  cct <label>`, 빈 토큰이면 `  cct <label>   (비어있음)`, 활성이면 `   ← 활성` 접미. TTY 면 ANSI 빨강.
  - `cct check [라벨]`: 실제 `claude -p ok --model $CCT_PROBE_MODEL` 호출(30초 제한). rc 0 유효 / 1 무효·점검불가 / 2 토큰없음. 전체는 하나라도 문제면 1. 이것도 실호출(비용 발생).
  - `cct fp [라벨]`: 표준 모델 프로브(max_tokens 1)로 `org:<앞8자> 7d_reset 5h_reset util5h` 출력. 7d_reset 이 같으면 같은 계정(중복). 대시보드는 usage --json 의 org+7d.reset 으로 같은 판정을 하므로 fp 엔드포인트는 선택 사항.
  - `cct usage [라벨|--all]`: 아래 2.2. rc: 사용법·라벨 오류만 2, 토큰없음·응답실패는 텍스트로 알리고 0.
  - `cct add <라벨>`: `env -i` bash 에서 `_cct_add_internal` 실행. 토큰은 `read -rs tok` 로 stdin 에서 읽는다(파이프 가능: `printf '%s\n' "$tok" | cct add x`). 라벨이 이미 있으면 `기존 토큰을 덮어쓸까요? [y/N]` 를 `read -r ans` 로 stdin 에서 읽는다(두 번째 줄 `y`). 동일 토큰이 다른 라벨에 있으면 중복 안내. 트랜잭션(잠금·백업·원자적 교체).
  - `cct rm <라벨> [--force]`, `cct rename <기존> <새>`: 비대화식 가능(rm 은 `--force`).
  - `cct off`: 비대화식. 활성 파일 삭제 + 현재 셸 env 해제.
  - `cct refresh`: 셸 로컬 동작. 서버가 대신 실행해도 의미 없음(안내만).
  - 활성 전환에는 launch 없는 서브커맨드가 없다. `cct <라벨>` 은 항상 claude 를 실행한다. 내부 함수 `_cct_active_change_locked write <라벨> <현재토큰>` 이 잠금 하에 `cct-active` 를 기록한다(토큰 인자는 "선택 중 변경" 가드용).
- 테스트 `bash tests/cct_test.sh [usage|all|...]` (bash, `chk`/`chk_has`/`chk_not_has` 헬퍼, 샌드박스 디렉터리에 `tokens.env` 픽스처와 PATH 의 `curl` 쉼으로 헤더 픽스처를 흘려 넣는 방식, `_cct_system(){ command "$@"; }` 로 절대경로 강제를 우회). CI `.github/workflows/test.yml`: macos-latest·ubuntu-latest, `shellcheck cct.sh install.sh tests/cct_test.sh cct-token.sh`, `bash -n`, `bash tests/cct_test.sh all`, `CCT_TEST_CASE=install-failures ... install`, `CCT_TEST_CASE=live-lock ... wallet`.
- 최근 커밋 `958454e chore: 전수검토 백로그 일괄`. 작업 트리에는 `dashboard/` 만 untracked.

### 2.2 usage 프로브 상세 (`_cct_usage_one`, 서브셸)

1. 프리미엄 프로브: `POST https://api.anthropic.com/v1/messages`. 헤더 `Authorization: Bearer <tok>` 은 curl `-H @-` 로 stdin 전달(argv 노출 금지 계약). `anthropic-version: 2023-06-01`, `anthropic-beta: claude-code-20250219,oauth-2025-04-20`, `user-agent: claude-cli/2.1.75 (external, cli)`, `x-app: cli`. 바디 `{"model":"$CCT_USAGE_PROBE_MODEL"(기본 claude-fable-5),"max_tokens":32,"system":"You are Claude Code, Anthropic's official CLI for Claude.","messages":[{"role":"user","content":"hi"}]}`. 응답 헤더만 받음(`-D - -o /dev/null`, `-m 25`).
2. 1행 상태코드가 200 이 아니면 `denied=<코드 또는 무응답>` 로 두고 표준 폴백 프로브: `anthropic-beta: oauth-2025-04-20`, 모델 `$CCT_PROBE_MODEL`(기본 claude-haiku-4-5-20251001), max_tokens 1.
3. 파싱 헤더: `anthropic-organization-id`(없으면 응답실패), `anthropic-ratelimit-unified-5h-{utilization,reset,status}`, `...-7d-{...}`, `...-7d_oi-{...}`(프리미엄 창 = 화면의 7f, 프리미엄 프로브 성공 시에만 실림). utilization 은 0~1 소수, reset 은 epoch 초, status 는 allowed / allowed_warning / rejected.
4. 숫자 가드: utilization 은 `''|.|*[!0-9.]*|*.*.*` 케이스로 거르고 awk 는 `LC_ALL=C` 강제(쉼표 로케일 방지). reset 은 `*[!0-9]*` 거르고 `10#` 로 10진 강제. `CCT_USAGE_NOW` 가 숫자면 now 고정(결정적 테스트용).
5. 비용: 프리미엄 프로브 최대 32 출력 토큰 + 폴백 1. 실호출이라 그 계정의 5h/7d 창을 소비한다. 6계정을 30분마다 자동갱신하면 하루 약 288회, 약 9천 토큰. 갱신 정책이 기능의 일부인 이유.
6. setup-token 은 `user:inference` 스코프뿐이라 공식 `/api/oauth/usage` 는 403 (메모리뱅크 실측). 헤더가 유일한 창구. 공식 API 시도 금지.

### 2.3 프로브 0회 소스: statusline 캐시

- `~/.claude/statusline-command.sh` 가 Claude Code statusline 입력에 `rate_limits` 가 있을 때마다 `~/.claude/orca-usage-cache.json` 에 입력 JSON 전체를 원자적으로 쓴다(Orca 사용량바 브릿지의 부산물, 건드리지 말 것).
- 쓸 필드: `rate_limits.five_hour.{used_percentage,resets_at}`, `rate_limits.seven_day.{used_percentage,resets_at}`, `model.display_name`, `context_window.used_percentage`, `cost.total_cost_usd`, `version`. 파일 mtime 을 관측 시각으로.
- 노출 금지 필드: `cwd`, `workspace`, `transcript_path`, `session_id`, `scratchpad_dir` (경로·세션 식별자).
- 한계: 계정 라벨이 없다(읽는 시점의 `cct-active` 로 추정 표기). 세션이 없으면 갱신이 멈춘다(stale 표기 필요). 7d_oi(프리미엄) 창은 없다.

### 2.4 네트워크·배치 환경

- Tailscale 1.98.9, macOS GUI 배포판. `tailscale serve` 로 파일·디렉터리 직접 서빙은 불가("Path serving is not supported on macOS due to sandbox restrictions"). 로컬 포트 프록시만 가능.
- CLI 경로 `/Applications/Tailscale.app/Contents/MacOS/Tailscale` (`tailscale` 은 PATH 에 없음). MagicDNS 이름 `bkan-macbookpro.taild94a8f.ts.net`.
- 기존 serve: `:443 → 127.0.0.1:9999`, `:8443 → 127.0.0.1:8888`(Hindsight 게이트웨이), `:8444 → 127.0.0.1:8790`(이번에 만든 목업 정적 서버). 8444 매핑은 그대로 두고 8790 의 프로세스만 실서버로 교체한다.
- 포트 `8787` 은 Hindsight-Crew rerank-server(uvicorn) 가 점유 중. 절대 죽이지 말고 쓰지도 말 것.
- launchd `com.bkan.cct-dash-mockup` (`~/Library/LaunchAgents/com.bkan.cct-dash-mockup.plist`, KeepAlive) 이 `/opt/homebrew/bin/python3 -m http.server 8790 --bind 127.0.0.1 --directory ~/cct/dashboard/mockup` 실행 중. WP4 에서 교체.
- 도구: `/opt/homebrew/bin/python3` = 3.14.7, `/opt/homebrew/bin/uv` 0.11.26, pnpm 11.15.1, node 26.4. 프론트는 빌드 없음이라 node/pnpm 불필요.
- bk-pc(Windows) 와 bkan-wsl2 가 테일넷에 있음(`~/.ssh/config` Host 항목).

### 2.5 목업

- `dashboard/mockup/index.html` 408줄, 외부 리소스 0, 바닐라 JS. 샘플 상태 객체 `S` 가 곧 `/api/state` 의 의도 스키마다. `?write=1` 로 쓰기 모드 미리보기. 스크린샷 `dashboard/mockup/screenshots/`(desktop-1400, mobile-400, write-mode-1400).
- 화면 요소와 동작(시뮬레이션): 헤더(서버 칩·마지막 프로브·오늘 프로브 예산·자동갱신 select 0/15/30/60·전체 갱신·활성 해제·쓰기 모드 토글), 지갑 상태 칩(status + doctor 요약), 추천 배너(5h 여유 → 7d 여유 정렬, 활성과 동일 계정·rejected 제외, `cct <라벨>` 복사·활성화), 활성 세션 라이브, 계정 카드(갱신/점검/지문/복사/활성화, 쓰기 모드에서 이름변경/삭제, 등록 카드), 리셋 타임라인 24h, doctor 패널, 실행 로그, 명령 매핑 표.

## 3. 아키텍처 (확정)

```
bk-pc 브라우저 ──https(tailnet only)──▶ tailscale serve :8444 ──▶ 127.0.0.1:8790 server.py (uv, stdlib)
                                                                     │  zsh -f -c 'source ~/.claude/cct.sh; cct ...'
                                                                     ├─▶ cct usage --json <라벨>  (라벨 병렬, 실프로브)
                                                                     ├─▶ cct status / doctor / ls / check / use / off / add / rm / rename
                                                                     ├─▶ ~/.claude/orca-usage-cache.json (읽기만)
                                                                     └─▶ ~/.claude/cct-dash-state.json (캐시·설정·로그, 600)
```

결정과 근거:
- 서버는 cct 를 호출한다(프로브·지갑 로직의 단일 출처). Python 으로 프로브를 재구현하지 않는다. 헤더 계약·폴백·잠금 트랜잭션이 cct 한 곳에만 남아야 한다.
- 그래서 cct 에 기계 판독 출력(`usage --json`)과 launch 없는 전환(`use`)을 먼저 넣는다. 나머지 명령의 텍스트 형식은 단순·안정적이라 그대로 파싱한다.
- 서버는 127.0.0.1 에만 바인드하고 테일넷 노출은 tailscale serve 가 맡는다. 테일넷 내 기기는 BK 소유라 v1 은 별도 인증 없음. 쓰기 작업은 헤더 게이트만.
- 프론트는 빌드 없는 단일 HTML. 추천 계정 계산·중복 판정 등 표시 로직은 클라이언트에 둔다(목업 코드 재사용). 서버는 사실만 내려준다.
- 영속은 JSON 파일 하나. 히스토리 DB 는 v1 제외.

## 4. API 계약

### 4.1 `cct usage --json [라벨|--all]` 출력

- 형식: 라벨당 JSON 객체 한 줄(NDJSON). 단일 라벨이면 한 줄. 헤더 문구("구독 사용량 ...")·빈 줄·ANSI 는 JSON 모드에서 출력하지 않는다(stdout 은 JSON 만, stderr 도 조용히).
- rc 규약은 기존과 동일(사용법·라벨 오류 2, 그 외 0). 토큰없음·응답실패는 `state` 로 표현하고 rc 0.

```json
{"label":"gv","state":"ok","org":"org_9f2a","now":1789400000,
 "probe":{"premium_model":"claude-fable-5","premium_http":200,"denied":null,"fallback":false},
 "windows":{
   "5h":{"utilization":0.06,"reset":1789415400,"status":"allowed"},
   "7d":{"utilization":0.36,"reset":1789657200,"status":"allowed"},
   "7d_oi":{"utilization":0.71,"reset":1789657200,"status":"allowed"}}}
{"label":"pro4","state":"ok","org":"org_4c1e","now":1789400000,
 "probe":{"premium_model":"claude-fable-5","premium_http":429,"denied":"429","fallback":true},
 "windows":{"5h":{...},"7d":{...},"7d_oi":null}}
{"label":"team","state":"no_response","org":null,"now":1789400000,"probe":{...,"premium_http":401,"denied":"401","fallback":true},"windows":null}
{"label":"spare","state":"no_token","org":null,"now":1789400000,"probe":null,"windows":null}
```

값 규칙:
- `state`: `ok` / `no_token`(빈 값) / `no_response`(org 헤더 없음).
- `org`: `anthropic-organization-id` 앞 8자, `[A-Za-z0-9_-]` 만 통과, 아니면 null (fp 와 동일 절단).
- `utilization`: 기존 숫자 가드 통과 시 원문 숫자 그대로(문자열 아님), 실패 시 null. `reset`: 정수 가드 통과 시 정수, 아니면 null. `status`: `[a-z_]+` 만, 아니면 null. 창 자체가 없으면(헤더 부재) 해당 키 null.
- `premium_http`: 3자리 숫자 또는 null(무응답). `denied`: 프리미엄 비 200 시 코드 문자열 또는 `"no_response"`, 200 이면 null. `fallback`: 폴백 프로브를 썼는지.
- `now`: `CCT_USAGE_NOW` 우선, 없으면 `date +%s`.
- 문자열 값은 위 화이트리스트를 통과한 것만 쓰므로 이스케이프가 필요 없다. 그래도 조립은 `builtin printf` 로 한 번에 하고, 검증 실패 값은 반드시 null 로 떨어뜨린다(따옴표 삽입 경로 차단).

### 4.2 서버 HTTP API (`server.py`)

공통: JSON 요청·응답, `Content-Type: application/json`. 에러는 `{"error":{"code":"<snake_case>","message":"<한국어>"}}` + 4xx/5xx. 어떤 응답·로그에도 토큰 값이 실리지 않는다. 쓰기 엔드포인트(★)는 요청 헤더 `X-CCT-Write: 1` 이 없으면 403 `write_disabled`.

| 메서드·경로 | 동작 | cct 호출 | 비고 |
|---|---|---|---|
| GET / | `web/index.html` 정적 | - | 캐시 금지 헤더 |
| GET /api/state | 전체 상태(캐시) | 없음(status/doctor/ls 는 5초 캐시로 오프라인 호출) | 프로브 유발 금지 |
| POST /api/refresh `{"label":"gv"}` 또는 `{"all":true}` | usage 프로브 | `usage --json <라벨>` 라벨별 병렬(최대 6 워커) | 같은 라벨 60초 내 재요청은 429 `too_soon`. 진행 중이면 409 |
| POST /api/check `{"label"}` | 토큰 점검 | `check <라벨>` rc → valid/invalid/missing | 실호출. 결과·시각 저장 |
| POST /api/fp `{"label"}` | 지문 (선택) | `fp <라벨>` 파싱 또는 usage 결과에서 파생 | 파생으로 대체 가능 |
| POST /api/use `{"label"}` | 활성 전환 | `use <라벨>` | 응답에 `hint: "열린 터미널은 cct refresh"` |
| POST /api/off | 활성 해제 | `off` | |
| POST /api/add ★ `{"label","token","overwrite":false}` | 계정 등록 | `add <라벨>`, stdin 에 `token\n` (+ overwrite 면 `y\n`) | 토큰은 stdin 만. argv·로그·응답·예외 메시지 금지. 요청 바디 로깅 금지 |
| POST /api/rm ★ `{"label"}` | 삭제 | `rm <라벨> --force` | |
| POST /api/rename ★ `{"old","new"}` | 이름 변경 | `rename <기존> <새>` | |
| POST /api/settings `{"auto_min":0|15|30|60}` | 자동갱신 | - | 15 미만 양수는 400 `below_floor`. 영속 |
| GET /api/live | statusline 캐시 | - | /api/state 에도 포함 |

### 4.3 `/api/state` 스키마 (목업 `S` 대응)

```json
{
 "server":{"version":"0.1.0","started_at":1789.., "bind":"127.0.0.1:8790","fake":false,"cct_path":"~/.claude/cct.sh"},
 "status":{"wallet":"~/.claude/tokens.env","mode":"600","accounts":6,"active":"gv","default":"gv","sticky":"enabled","claude":"/Users/bkan/.local/bin/claude","claude_version":"2.1.270"},
 "doctor":{"at":1789..,"rc":0,"items":[{"lv":"PASS","msg":"wallet: readable regular file, mode 600"}]},
 "accounts":[{"label":"gv","has_token":true,"active":true,"default":true,
   "usage":{ ...4.1 의 객체 그대로... },"usage_at":1789..,
   "check":{"result":"valid","at":1789..} }],
 "live":{"at":1789..,"stale":false,"label_guess":"gv","model":"Opus 5","context_pct":19,"cost_usd":10.76,
   "five_hour":{"used_percentage":6,"resets_at":1789415400},"seven_day":{"used_percentage":36,"resets_at":1789657200}},
 "budget":{"day":"2026-09-15","usage_probes":14,"check_probes":1,"est_tokens":449,"auto_min":30,"floor_min":15,"next_auto_at":1789..},
 "refreshing":false,
 "log":[{"at":1789..,"cmd":"cct usage --json gv","rc":0,"ms":4180}]
}
```

목업 `S.accounts[i]` 필드 대응: `token`→`has_token`, `ok`→`usage.state=="ok"`, `probeAt`→`usage_at`, `org`→`usage.org`, `w5/w7/wf`→`usage.windows["5h"/"7d"/"7d_oi"]` (u→utilization, r→reset, s→status), `denied`→`usage.probe.denied`, `check.res`→`check.result`. 프론트는 이 변환 함수 하나만 추가하면 목업 렌더 코드를 그대로 쓸 수 있다.

## 5. 작업 패키지

순서: WP1 → (WP2 ∥ WP3) → WP4 → WP5. WP2 와 WP3 는 4.2/4.3 계약을 기준으로 병렬 가능(WP2 의 `--fake` 모드가 먼저 나오면 WP3 검증이 편하다).

### WP1. cct: `usage --json` + `use` 서브커맨드

산출물: `~/cct/cct.sh`, `~/cct/tests/cct_test.sh`, `~/cct/README.md`, `~/cct/README.en.md`, `~/cct/CHANGELOG.md`. 테스트 통과 후 `cp ~/cct/cct.sh ~/.claude/cct.sh` 로 설치본 동기화(`diff -q` 로 확인. `install.sh` 는 rc 파일도 만지므로 쓰지 않는다).

태스크:
1. `_cct_usage`: `--json` 플래그 파싱(위치 무관, 중복 금지). 인자 수 검사는 `[ "$#" -le 2 ]` 로 완화하되 `--json` 을 제외한 나머지가 1개 이하인지 검사. 사용법 문구에 `[--json]` 추가. JSON 모드에서는 헤더 문구·라벨 간 빈 줄 출력 생략.
2. `_cct_usage_one`: 두 번째 인자 `$2` = `json` 이면 JSON 출력 분기(서브셸이므로 인자로 전달, 전역 변수 의존 금지). 프로브·헤더 파싱 코드는 공통으로 두고 출력만 분기. 4.1 의 값 규칙을 각 필드에 적용하는 헬퍼(`_cct_usage_json_num`, `_cct_usage_json_int`, `_cct_usage_json_word` 등: 통과 시 값, 실패 시 `null` 문자열 반환)를 추가한다. 토큰없음·응답실패 분기도 JSON 모드에선 4.1 형식으로.
3. `_cct_use` (신규): `cct use <라벨>`. 검증(`_cct_validate_label`, 예약어 거부, `_cct_wallet_require_safe`), 토큰 존재 확인(없으면 `❌ '<라벨>' 토큰 없음` rc 1), `_cct_active_change_locked write "$label" "$tok"`, 성공 시 sticky 가 켜져 있으면 `_cct_apply_env "$tok"` + `_cct_gjc_guard` (launch 분기와 같은 순서), `✓ 활성 = <라벨> (열린 다른 셸은 cct refresh)` 출력. `CCT_STICKY=0` 이면 `❌ sticky 가 꺼져 있어 use 는 의미 없음` rc 1. 인자 오류 rc 2.
4. 예약어 목록·`cct()` case·`_cct_help`·파일 상단 주석 표·README(ko/en) 명령 표·CHANGELOG(BREAKING: `use` 가 예약어가 됨) 갱신.
5. 테스트(`test_usage` 에 추가, 기존 curl 쉼·픽스처 재사용): (a) `--json alpha` 출력이 기대 JSON 과 정확히 일치(`CCT_USAGE_NOW` 고정) (b) 프리미엄 429 → `denied:"429"`, `fallback:true`, `7d_oi:null` (c) 토큰없음 → `state:"no_token"` rc 0 (d) org 헤더 없음 → `state:"no_response"` (e) 비숫자 utilization·다중 점·선행 0 reset → null (f) `--json --all` 줄 수 = 라벨 수, 헤더 문구 부재 (g) `--json a b` rc 2, `--json --json a` rc 2 (h) JSON 모드 stdout 이 `python3 -c 'import json,sys;[json.loads(l) for l in sys.stdin if l.strip()]'` 를 통과. `use` 테스트는 `test_sticky` 에 추가: 전환 후 `cct-active` 내용, rc, 토큰없음 rc 1, 예약어 rc 2, `CCT_STICKY=0` rc 1, 잠금 점유 중 실패.
6. `shellcheck cct.sh tests/cct_test.sh`, `bash -n`, `bash tests/cct_test.sh all` 전부 green. zsh 에서도 `zsh -fc 'source cct.sh; cct usage --json --all'` 가 픽스처로 동작하는지 1회 확인(테스트는 bash 기준이지만 실사용은 zsh).

수용 기준: 기존 텍스트 출력·rc 바이트 단위 불변(테스트 all 통과가 증거). JSON 모드 출력은 라벨당 1줄, 파서가 전부 파싱. 설치본 동기화 완료.

### WP2. 서버 `dashboard/server.py`

형태: 단일 파일, PEP 723 인라인 메타데이터(`# /// script` … `requires-python = ">=3.12"`, `dependencies = []`), 실행 `uv run --script dashboard/server.py --bind 127.0.0.1 --port 8790`. 표준 라이브러리만(`http.server.ThreadingHTTPServer`, `subprocess`, `json`, `threading`, `concurrent.futures`, `argparse`, `pathlib`, `time`, `re`).

옵션: `--bind`(기본 127.0.0.1, 다른 값은 경고 출력) `--port`(기본 8790) `--web-dir`(기본 `<script dir>/web`) `--state-file`(기본 `~/.claude/cct-dash-state.json`) `--cct`(기본 `~/.claude/cct.sh`) `--fake`(cct 호출을 픽스처로 대체) `--log-level`.

cct 호출 방식(고정):
- `subprocess.run(["/bin/zsh","-f","-c",'source "$1"; shift; cct "$@"',"cct-dash",CCT_SH,*args], env=CLEAN_ENV, input=stdin_text, capture_output=True, text=True, timeout=T)`. `-f` 로 rc 파일을 읽지 않고 명시 source. 절대 `zsh -l -c` 나 `zsh -i` 로 cct 를 기대하지 말 것(`.zshrc` 미로드, 부모 env 오염 함정).
- `CLEAN_ENV = {"HOME": home, "PATH": "/opt/homebrew/bin:/usr/bin:/bin:" + home + "/.local/bin", "LC_ALL": "C", "TERM": "dumb", "CCT_STICKY": "0"}`. 서버 자신의 env(특히 `ANTHROPIC_*`, `CLAUDE_*`)를 상속시키지 않는다. `~/.local/bin` 은 `cct check` 가 `claude` 를 찾기 위해 필요.
- 타임아웃: usage 60초(curl 25초 × 2 + 여유), check 45초, 그 외 15초. 초과 시 rc 124 로 로그.
- stdout/stderr 는 저장·로그 전에 항상 마스킹: `re.sub(r"sk-ant-[A-Za-z0-9_-]{8,}", "sk-ant-***", s)`. `/api/add` 는 stdin 내용을 어디에도 기록하지 않고, 예외 문자열에 입력이 섞이지 않게 한다.

내부 구조:
- `State` 클래스(락 보호) + 원자적 저장(임시 파일 → `os.replace`, mode 600). 키: `accounts{label:{usage,usage_at,check}}`, `settings{auto_min}`, `budget{day,usage_probes,check_probes}`, `log[≤200]`.
- `Cct` 어댑터: `usage(label) -> dict`(NDJSON 첫 줄 파싱; 파싱 실패는 `state:"parse_error"` 로 저장하고 rc·stderr 로그), `status()`, `doctor()`, `ls()`(정규식 `^\s*cct (\S+)(\s+\(비어있음\))?(\s+← 활성)?\s*$`), `check(label) -> rc`, `use/off/add/rm/rename`.
- `FakeCct`: 동일 인터페이스, `dashboard/tests/fixtures/*.ndjson`·텍스트 픽스처 반환, 지연 0.3초. 목업 7계정 시나리오를 그대로 픽스처로.
- 프로브 실행기: `ThreadPoolExecutor(max_workers=6)`, 라벨별 `Lock`, 전역 `refreshing` 플래그, 라벨별 마지막 프로브 시각으로 60초 `too_soon`.
- 스케줄러 스레드: `settings.auto_min`(0=끔, 하한 15) 주기로 `refresh_all`. 서버 기동 직후에는 자동 프로브를 하지 않는다(재시작 루프가 비용을 태우는 것 방지). `next_auto_at` 을 상태에 노출.
- statusline 캐시 리더: 파일 mtime 과 화이트리스트 필드만 추출, 10분 이상 오래되면 `stale:true`.
- 예산 카운터: 로컬 날짜가 바뀌면 0 으로. `est_tokens = usage_probes*32 + fallback 횟수 + check_probes*1` 근사.
- 정적 서빙: `web/` 아래 파일만(경로 정규화, 상위 디렉터리 탈출 차단), `Cache-Control: no-store`.

테스트(`dashboard/tests/test_server.py`, `uv run --with pytest pytest dashboard/tests -q`): NDJSON·status·doctor·ls 파서, 마스킹, 쓰기 게이트 403, `too_soon` 429, settings 하한 400, 상태 저장 mode 600 + 재기동 복원, `/api/add` 가 stdin 에 `token\n` / `token\ny\n` 을 넣고 argv 에 토큰이 없음(`FakeCct` 가 받은 인자 검사), 기동 직후 자동 프로브 미실행, statusline 리더 화이트리스트(경로 필드 부재). 전부 `--fake` 로. 실 cct 를 호출하는 테스트는 만들지 않는다.

수용 기준: `--fake` 로 기동해 `/api/state` 가 4.3 스키마를 만족하고, 모든 엔드포인트가 픽스처로 동작. 실계정 프로브는 WP5 의 승인 절차 전까지 0회.

### WP3. 프론트 `dashboard/web/index.html`

- 목업 파일을 복사해 시작(`mockup/` 은 참고용으로 그대로 둔다). 샘플 `S`·`sampleProbe`·`simulate` 의 가짜 지연을 제거하고, `fetch('/api/state')` → 4.3 → 목업 뷰모델 변환 함수(`toView(state)`) → 기존 렌더 함수 그대로.
- 액션: 각 버튼은 해당 POST 를 호출하고 성공 응답의 state 로 재렌더, 실패는 `error.message` 토스트. 진행 중 버튼은 disabled + 스피너(기존 CSS 재사용). 쓰기 토글이 켜져 있으면 `X-CCT-Write: 1` 헤더를 붙인다(토글 상태는 `sessionStorage`, `?write=1` 유지).
- `/api/state` 30초 폴링(프로브 유발 없음) + 카운트다운 재렌더. `refreshing:true` 면 헤더의 전체 갱신 버튼을 스피너로.
- 자동갱신 select 변경 → `POST /api/settings`. 예산 칩은 서버 값 사용.
- 라이브 카드에 `stale` 표기와 `label_guess` 표시(추정임을 문구로).
- 등록 폼: 제출 즉시 입력 필드 비우기, 응답과 무관하게 토큰을 변수에 남기지 않기(요청 바디 생성 직후 null).
- 외부 리소스 0, 빌드 0 유지. em dash 금지.

렌더 검증(필수, 목업과 같은 절차): `uv run --script dashboard/server.py --fake --port 8799` 를 띄우고 Chrome headless 로 `http://127.0.0.1:8799/` 스크린샷. 데스크톱 `--window-size=1400,1800`. 모바일 400px 은 반드시 iframe 래퍼로(`<iframe src="http://127.0.0.1:8799/" style="width:400px;height:2600px">` 를 담은 임시 HTML 을 `--window-size=400,2600` 으로 촬영). `--headless=new --disable-gpu --hide-scrollbars --virtual-time-budget=3000 --user-data-dir=/tmp/<고유>`. 이미지를 실제로 열어 보고(`view_image` 등) 잘림·겹침을 고친다. 정적 검사는 관찰이 아니다.

수용 기준: fake 서버 기준으로 목업의 모든 버튼이 실제 API 를 호출하고 화면이 응답 상태로 갱신된다. 스크린샷 3종(데스크톱·400px·쓰기 모드) 이 `dashboard/screenshots/` 에 저장.

### WP4. 배치

1. `dashboard/launchd/com.bkan.cct-dash.plist` 템플릿 작성: `ProgramArguments` = `/opt/homebrew/bin/uv run --script /Users/bkan/cct/dashboard/server.py --bind 127.0.0.1 --port 8790`, `WorkingDirectory` = `/Users/bkan/cct/dashboard`, `RunAtLoad`·`KeepAlive` true, `StandardOutPath/StandardErrorPath` = `/Users/bkan/Library/Logs/cct-dash.log`, `EnvironmentVariables` 에 `PATH=/opt/homebrew/bin:/usr/bin:/bin` 만.
2. 교체 절차: `launchctl bootout gui/$(id -u)/com.bkan.cct-dash-mockup` → 목업 plist 를 `dashboard/launchd/com.bkan.cct-dash-mockup.plist` 로 옮겨 보관(롤백용) → 새 plist 를 `~/Library/LaunchAgents/` 에 복사 → `plutil -lint` → `launchctl bootstrap gui/$(id -u) <plist>` → `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8790/` 가 200, `/api/state` 가 JSON.
3. tailscale serve 는 손대지 않는다(`:8444 → 8790` 이미 존재). `Tailscale serve status` 로 매핑만 확인.
4. 롤백: 새 잡 bootout → 목업 plist 다시 bootstrap. 완전 해제: `Tailscale serve --https=8444 off` + bootout.

### WP5. 마무리

- 문서: `dashboard/README.md`(실행·배치·API·보안·비용 정책·롤백), 루트 README(ko/en) 명령 표에 `usage --json`·`use`, CHANGELOG.
- 커밋(로컬까지, push 는 BK 가): WP1 `feat(cct): usage --json 출력과 use 서브커맨드`, WP2+3 `feat(dashboard): cct 대시보드 서버·웹 UI`, WP4 `chore(dashboard): launchd 배치 템플릿`. 메시지 한국어. 자명하지 않은 결정은 `~/.claude/docs/commit-lore.md` 규칙의 trailer 로: 예) `Constraint: setup-token 은 user:inference 스코프만 있어 /api/oauth/usage 가 403, rate-limit 헤더가 유일한 사용량 소스` / `Rejected: 서버에서 프로브 재구현 | 헤더 계약·폴백이 두 곳으로 갈라짐` / `Not-tested: 실계정 프로브는 픽스처만, 실호출 1회는 BK 승인 뒤`.
- 실계정 검증은 기본적으로 하지 않는다. BK 가 "테스트는 하지 말고 내가 확인함" 이라고 했다. 실프로브가 꼭 필요하면 먼저 물어보고, 승인 시 `POST /api/refresh {"all":true}` 정확히 1회(6계정 × 프리미엄 32토큰).
- 메모리뱅크(Hindsight personal-bk, MCP `mcp__memory_vault__retain`)가 있는 런타임이면 WP 완료 단위마다 retain: 내용은 `[완료] ...` 한 줄, 태그 `project:cct` + `kind:completion`(결정은 `kind:decision`, 함정은 `kind:gotcha`). 태그 없는 retain 은 거부된다.

## 6. 양보 불가 규칙

보안
- 토큰 값은 어디에도 나타나면 안 된다: 응답·로그·예외 메시지·argv·프로세스 목록·커밋·스크린샷. cct 로 넘길 때는 stdin 만.
- 서버 바인드는 127.0.0.1. 테일넷 노출은 tailscale serve 만. `0.0.0.0` 금지.
- 쓰기 엔드포인트는 `X-CCT-Write: 1` 없으면 403. 프론트 토글 기본 꺼짐.
- statusline 캐시에서 경로·세션 식별자 노출 금지(2.3 화이트리스트).
- `~/.claude/tokens.env`, `cct-active`, `statusline-command.sh`, `orca-usage-keeper.sh`, 키체인은 직접 읽거나 쓰지 않는다. 지갑 변경은 반드시 cct 명령 경유.

비용
- 개발·테스트 중 실프로브 0회. `--fake` 와 픽스처만. `cct check` 도 실호출이므로 동일.
- 자동갱신 하한 15분은 서버가 강제(클라이언트 값 신뢰 금지). 기동 직후 자동 프로브 금지.

스택·문서
- Python ≥ 3.12, 실행은 uv(`uv run --script`). 의존성 0 유지. JS 빌드 도구 도입 금지.
- 코드 주석·커밋·문서 한국어. em dash 금지, 하이픈(-) 사용.
- 요청 범위만 수술적으로. cct 의 기존 출력·rc·보안 관행(`builtin printf`, `_cct_system` 절대경로, curl stdin 헤더, `unset -f` 하드닝, 서브셸 격리)을 그대로 따른다. 죽은 코드 정리 금지.
- 8787 프로세스·기존 tailscale serve 매핑(443, 8443)·Orca 브릿지 스크립트에 손대지 않는다.

## 7. 검증 요약

| WP | 명령 | 기대 |
|---|---|---|
| 1 | `cd ~/cct && shellcheck cct.sh tests/cct_test.sh && bash -n cct.sh && bash tests/cct_test.sh all` | `TOTAL pass=N fail=0` |
| 1 | `diff -q ~/cct/cct.sh ~/.claude/cct.sh` | 출력 없음 |
| 2 | `uv run --with pytest pytest dashboard/tests -q` | 전부 pass |
| 2 | `uv run --script dashboard/server.py --fake --port 8799 &` 후 `curl -s localhost:8799/api/state | python3 -m json.tool` | 4.3 스키마 |
| 3 | Chrome headless 스크린샷 3종(iframe 400px 포함) 육안 확인 | 잘림·겹침 없음 |
| 4 | `launchctl print gui/$(id -u)/com.bkan.cct-dash | grep state`, `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8790/api/state` | running, 200 |
| 4 | `/Applications/Tailscale.app/Contents/MacOS/Tailscale serve status` | `:8444 → 127.0.0.1:8790` 유지 |

## 8. 함정 목록 (전부 실측)

- macOS GUI Tailscale 은 파일 경로 서빙 불가. 포트 프록시만.
- Chrome headless `--window-size=400` 은 최소 창 폭(약 500px)으로 레이아웃된 뒤 400px 로 잘려 가짜 오버플로가 보인다. 400px 검증은 iframe 래퍼 필수.
- `zsh -l -c` 는 `.zshrc` 를 읽지 않아 `cct` 함수가 없다. 항상 `zsh -f -c 'source ~/.claude/cct.sh; ...'`. 부모 env 의 `ANTHROPIC_BASE_URL` 등이 상속되면 프로브가 엉뚱한 곳으로 간다. clean env 필수.
- 8787 은 Hindsight rerank-server. 8790 은 현재 목업 정적 서버(교체 대상).
- `_cct_usage_one` 은 서브셸 + `unset -f` 하드닝. 새 헬퍼는 서브셸 안에서 호출 가능해야 하고(함수는 정의돼 있으니 호출 가능), 전역 변수 전달은 안 된다(인자로).
- utilization 은 소수(0.505)이고 `_cct_usage_pct` 는 반올림해 51% 로 만든다. JSON 은 원문 소수를 내보내고 반올림은 프론트가 한다(목업의 `pct()` 가 이미 그렇게 함).
- 7d 와 7d_oi 의 reset 이 같은 계정이 많다(타임라인 점 겹침은 목업 CSS 가 상하 오프셋으로 처리함).
- `cct add` 덮어쓰기 프롬프트는 stdin 두 번째 줄로 응답해야 한다. 첫 줄만 주면 `read -r ans` 가 EOF 로 취소된다.
- `cct check` 는 `claude` 바이너리를 PATH 에서 찾는다(`/Users/bkan/.local/bin`).
- 설치본과 리포가 갈라지면 셸에서 쓰는 cct 와 서버가 쓰는 cct 가 다른 코드가 된다. WP1 끝에 반드시 동기화.
- 공개 리포다. `dashboard/` 안에 상태 파일·plist 실물·스크린샷에 라벨 외 정보가 들어가지 않게 한다. 상태 파일은 `~/.claude/` 아래에만.

## 9. BK 확인이 필요한 미결 항목

1. 서브커맨드 이름 `use`(권장) vs `select`. `select` 는 셸 예약어와 혼동 소지가 있어 `use` 를 기본으로 잡았다.
2. 쓰기 작업(add/rm/rename)을 v1 에 넣을지, 읽기+전환만으로 시작할지. 목업에는 있고 계약도 있으니 구현은 하되 서버 플래그 `--allow-write` 기본값을 어떻게 둘지.
3. 자동갱신 기본값 30분(하한 15분) 유지 여부. 6계정이면 하루 약 288회 프로브.
4. `/api/fp` 를 별도 구현할지, usage 결과에서 파생(org + 7d.reset 동일 판정)으로 끝낼지. 파생 권장.
5. push 시점. 로컬 커밋까지만 하고 push 는 BK 가 하는 것으로 가정.

## 10. 참고 경로

- 목업: `~/cct/dashboard/mockup/index.html`, 스크린샷 `~/cct/dashboard/mockup/screenshots/`
- cct 리포 `~/cct`, 설치본 `~/.claude/cct.sh`, 테스트 `~/cct/tests/cct_test.sh`, CI `~/cct/.github/workflows/test.yml`
- statusline 캐시 `~/.claude/orca-usage-cache.json`, 래퍼 `~/.claude/statusline-command.sh`(읽기 전용 참고)
- 커밋 규칙 `~/.claude/docs/commit-lore.md`
- Tailscale CLI `/Applications/Tailscale.app/Contents/MacOS/Tailscale`
- 현재 launchd 목업 잡 `~/Library/LaunchAgents/com.bkan.cct-dash-mockup.plist`

