# cct dashboard

cct 지갑의 계정별 구독 사용량을 한 화면에서 보는 로컬 대시보드다.
`cct usage --all` 을 매번 타이핑하는 대신 브라우저로 보고, 테일넷을 통해 다른 기기(Windows 등)에서도 같은 화면을 연다.

읽기 전용이 기본이고, 지갑을 바꾸는 동작은 전부 cct 명령을 거친다. 토큰 값은 화면·로그·응답 어디에도 나타나지 않는다.

![대시보드](screenshots/desktop-1400.png)

스크린샷 3종(`screenshots/`)은 픽스처 모드(`--fake`)로 찍은 데모이며 계정 라벨은 블러 처리했다.

## 구성

```
브라우저 ──https(테일넷 전용)──▶ tailscale serve :8444 ──▶ 127.0.0.1:8790 server.py
                                                              │  zsh -f -c 'source cct.sh; cct ...'
                                                              ├─▶ cct usage --json (라벨 병렬, 실프로브)
                                                              ├─▶ cct status / doctor / ls / check / use / off / add / rm / rename
                                                              ├─▶ ~/.claude/orca-usage-cache.json (읽기 전용)
                                                              ├─▶ ~/.claude/cct-dash-state.json (캐시·설정·알림, mode 600)
                                                              ├─▶ ~/.claude/cct-dash-data.sqlite3 (히스토리·토큰 집계, mode 600)
                                                              └─▶ ~/.claude/projects/**/*.jsonl (읽기 전용 스캔 - 토큰·비용)
```

서버는 프로브 로직을 재구현하지 않고 cct 를 호출한다. rate-limit 헤더 계약과 폴백, 지갑 잠금 트랜잭션이 cct 한 곳에만 남는다.

## 실행

```sh
# 픽스처 모드 (실계정 호출 0회, 개발·데모용)
uv run --script server.py --fake --port 8799

# 실제 지갑
uv run --script server.py --bind 127.0.0.1 --port 8790
```

의존성은 없다. Python 3.12 이상이면 표준 라이브러리만으로 돈다.

주요 옵션: `--bind`(기본 127.0.0.1) `--port`(기본 8790) `--web-dir` `--state-file` `--db-file` `--projects-dir` `--no-tokens` `--cct` `--live-file` `--fake` `--fixtures` `--fake-delay` `--log-level`.

## 상시 실행과 테일넷 공개

```sh
cp launchd/com.bkan.cct-dash.plist ~/Library/LaunchAgents/
plutil -lint ~/Library/LaunchAgents/com.bkan.cct-dash.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.bkan.cct-dash.plist

# 테일넷에만 노출 (macOS GUI 배포판은 파일 경로 서빙이 막혀 있어 포트 프록시만 된다)
/Applications/Tailscale.app/Contents/MacOS/Tailscale serve --bg --https=8444 http://127.0.0.1:8790
```

로그는 `~/Library/Logs/cct-dash.log`. 내릴 때는 아래 두 줄이다.

```sh
/Applications/Tailscale.app/Contents/MacOS/Tailscale serve --https=8444 off
launchctl bootout gui/$(id -u)/com.bkan.cct-dash
```

## 화면

| 영역 | 내용 | 비용 |
|---|---|---|
| 상단 바 | 연결 상태·마지막 갱신·오늘 프로브 예산·자동갱신 주기·전체 갱신, `···` 에 활성 해제와 쓰기 모드 | 갱신 시 프로브 |
| 활성 계정 바 | 활성 라벨과 sticky·기본 여부, statusline 캐시의 rate_limits·모델·컨텍스트·세션 비용, 갈아탈 계정 1개(가장 빡빡한 창 기준)와 전환 버튼 | 프로브 없음 |
| 알림 스트립 | 임계 초과·프로브 실패 활성 알림과 최근 기록. 임계값과 macOS 알림 수준은 `···` 설정에서 조정 | 프로브 없음 |
| 계정 카드 | 라벨별 5h/7d/7f 한 줄 미터(사용률 바 + 남은 시간 · 리셋 시각)·사용률 히스토리 스파크라인·상태 배지·org·check, `···` 에 점검/복사/이름변경/삭제. 대화 중인 계정은 statusline 캐시로 5h/7d 가 자동 갱신된다 | 갱신·점검 시 프로브 (자동 갱신은 프로브 없음) |
| 계정 상세 (`#/account/<라벨>`) | 카드를 누르면 열린다. 사용률·토큰 타임라인, 5시간 구간 기록(도달 시각·외부 사용 추정), 세션·요청별 토큰과 API 환산, 모델·프로젝트별 비중, 이번 달 API 환산과 월 구독료 대비 배수. 계정 귀속은 `cct-session-hook.sh` 기록(`~/.claude/cct-sessions.jsonl`) 기준 | 프로브 없음 |
| 프로바이더 | GPT(ChatGPT/Codex)·Grok(xAI) 구독 사용량 - 미연결이면 OAuth 온보딩 카드, 연결 후 5h/7d·주간 미터 | 프로브 없음 (메타데이터 조회) |
| 리셋 타임라인 | 다음 24시간의 창 리셋 시점 | 프로브 없음 |
| 진단 | `cct doctor` 를 PASS / WARN / FAIL 로. 정상은 접고 경고·실패만 펼친다. 하단에 `cct status` 요약 | 프로브 없음 |
| 토큰·비용 | `~/.claude/projects` JSONL 로컬 집계 - 일별 비용 차트, 모델별 토큰·비용 표, 재스캔 | 프로브 없음 (디스크 읽기만) |
| 실행 로그 | 서버가 실행한 cct 명령과 rc, 소요 시간 (기본 접힘) | 프로브 없음 |

사용률 바는 65% 미만 여유, 65~89% 주의, 90% 이상 또는 `rejected` 를 위험으로 칠한다. 모든 카드가 같은 자리에 같은 항목을 놓고, 값이 없는 창은 숫자를 만들지 않고 `미확인` · `미지원` · `응답 실패` 처럼 사유를 적는다.

## 프로브 비용

`cct usage` 는 계정마다 `api.anthropic.com/v1/messages` 로 실제 요청(프리미엄 모델, max_tokens 32)을 보내고 응답 헤더의 rate-limit 값을 읽는다. setup-token 은 `user:inference` 스코프뿐이라 공식 usage API 가 403 이고, 헤더가 유일한 창구다.

조회가 곧 소비다. 그래서 갱신 정책이 기능의 일부다.

- 자동갱신 하한 15분을 서버가 강제한다. 클라이언트 값은 신뢰하지 않는다.
- 같은 라벨을 60초 안에 다시 요청하면 429 `too_soon` 이다.
- 서버 기동 직후에는 자동 프로브를 하지 않는다. 재시작 루프가 사용량을 태우지 않게 하기 위해서다.
- 헤더의 예산 칩이 오늘 프로브 횟수와 추정 토큰을 보여준다.

6계정을 30분마다 갱신하면 하루 약 288회다. 기본값은 자동갱신 끔이며, 필요할 때 헤더에서 켠다.

## 사용률 히스토리와 스파크라인

프로브가 돌 때마다 라벨별 5h/7d/7f 사용률을 sqlite(`~/.claude/cct-dash-data.sqlite3`, mode 600)에 한 줄씩 적재한다. 90일이 지난 행은 자동 삭제한다. 카드의 스파크라인은 `GET /api/history?hours=24|48|168` 로 그리며, 라벨당 최대 240점이 되도록 서버가 버킷 평균으로 줄인다.

히스토리도 프로브가 만든 데이터다. 자동갱신이 꺼져 있으면 수동 갱신 시점만 점으로 남고, 조회 자체는 프로브를 유발하지 않는다.

## 임계치 알림

사용률 바 색과 같은 임계(기본 주의 65% / 위험 90%, `···` 설정에서 1~99 조정)를 서버가 프로브 결과마다 평가한다.

- 창 사용률이 임계를 처음 넘으면 발화하고, 같은 수준으로 계속 넘어 있으면 재발화하지 않는다(도배 방지). warn 에서 crit 로 오르면 다시 발화하고, 임계 아래로 내려오면 해소로 기록한다.
- 창 상태 `rejected` 와 프로브 실패(`no_response`/`parse_error`)는 사용률과 무관하게 위험이다.
- macOS 알림 센터 발송은 osascript 를 쓴다. 수준은 끔 / 위험만(기본) / 주의부터. 메시지에는 라벨·창·퍼센트만 담는다. 픽스처 모드는 화면 기록만 하고 발송하지 않는다.
- 알림 평가도 프로브가 있어야 일어난다. 자동갱신이 꺼져 있으면 수동 갱신 시점에만 평가된다.

## 토큰·비용 분석 (로컬 JSONL)

ccusage 처럼 Claude Code 세션 로그(`~/.claude/projects/**/*.jsonl`)를 읽어 날짜 x 모델로 토큰과 비용을 집계한다. 네트워크·프로브와 무관한 로컬 디스크 읽기다.

- 집계 대상은 `type=="assistant"` 의 `message.usage` 뿐이다. `<synthetic>` 과 `isApiErrorMessage` 는 제외하고, sidechain(서브에이전트)은 실사용이라 포함한다.
- 중복 제거는 `message.id + requestId` 전역 keep-first 다. 같은 응답이 content 블록 단위로 여러 줄 기록되고 세션 이어쓰기로 파일 간 복제도 있어, dedup 없이는 2배 이상 과대집계된다(실측).
- 캐시 쓰기는 `usage.cache_creation` 의 5m/1h 분해값으로 나눠 과금한다. 실측상 캐시 쓰기의 85~100% 가 1h(2x 단가)라, 총량에 5m 단가를 일괄 적용하는 방식(ccusage/LiteLLM)은 크게 과소평가된다.
- 단가표는 server.py 의 `PRICING` 상수(출처 주석 포함, USD/MTok)다. 미등록 모델은 비용 합계에서 빼고 화면에 "단가 미상 N건" 으로 알린다. 단가표가 바뀌면 다음 기동에서 전체를 재집계한다.
- 스캔은 mtime+size 증분이다. 초회 전수는 약 3초(847MB · 1,100파일 실측), 이후에는 바뀐 파일만 다시 읽는다. `GET /api/tokens` 가 10분 넘게 낡은 스캔을 보면 백그라운드로 다시 돌고, 재스캔 버튼은 즉시 돈다.
- Claude Code 로그 보존창은 약 30일이라 원본은 사라진다. DB 적재분은 파일이 지워져도 남아 그 너머의 이력 저장소가 된다.

## 프로바이더 사용량 (GPT·Grok)

Claude 지갑과 별개로, GPT(ChatGPT/Codex)와 Grok(xAI SuperGrok) 구독 사용량을 같은 화면에서 추적한다. 미연결 상태에서는 로고와 "계정 연결" 버튼만 있는 온보딩 카드가 뜨고, 버튼을 누르면 브라우저에서 해당 서비스의 OAuth 로그인이 열린다. 로그인을 마치면 카드가 사용률 미터로 바뀐다.

- **인증**: 각 서비스의 공식 CLI(Codex CLI·Grok CLI)가 쓰는 공개 PKCE 클라이언트로 브라우저 OAuth 를 수행한다. 클라이언트 시크릿이 없는 공개 플로우이며, 콜백은 `localhost:1455`(OpenAI) / `127.0.0.1:56121`(xAI) 1회용 리스너가 받는다. 해당 포트를 CLI 로그인이 점유 중이면 409 로 알린다. xAI 는 리다이렉트 대신 코드 표시 화면을 줄 때가 있어(실측), 진행 중 카드에 코드(또는 전체 리다이렉트 URL) 붙여넣기 입력을 둔다.
- **저장**: 토큰은 `~/.claude/cct-dash-providers.json` (mode 600) 에만 저장한다. cct 지갑(`tokens.env`)과 섞지 않는다. refresh token 은 회전하므로 갱신 즉시 저장한다.
- **조회**: OpenAI 는 `chatgpt.com/backend-api/wham/usage` (5h·7d 창), xAI 는 `cli-chat-proxy.grok.com/v1/billing` (주간 크레딧 %) 를 읽는다. 메타데이터 GET 이라 구독 사용량을 소비하지 않으며, 대시보드가 열려 있을 때 15분 넘게 낡으면 자동 재조회한다(10분 주기 점검).
- **고지**: 두 조회 모두 각 서비스의 **비공식 내부 엔드포인트**다. 정책 변경으로 언제든 끊길 수 있고, 그 경우 카드에 "조회 실패" 로 표시될 뿐 지갑·계정에는 영향이 없다. 구독 OAuth 를 자사 클라이언트 밖에서 차단하는 정책 변화가 온 전례(Anthropic, 2026-02)도 있으므로, 이 기능은 언제든 중단될 수 있는 편의로 취급한다.
- **끄기**: `--no-providers` 로 섹션 자체를 비활성화할 수 있고, 저장 경로는 `--providers-file` 로 바꾼다. 연결 해제 버튼은 저장된 토큰을 삭제한다.

## 보안

- 서버는 127.0.0.1 에만 바인드한다. 외부 노출은 tailscale serve 가 맡는다.
- 지갑을 바꾸는 `add` / `rm` / `rename` 은 요청에 `X-CCT-Write: 1` 헤더가 있어야 하고, 화면에서는 쓰기 모드 토글을 켜야 보인다.
- 토큰은 stdin 으로만 cct 에 전달한다. argv·로그·응답·예외 메시지에 남지 않는다. 저장과 로깅 전에 `sk-ant-` 패턴을 마스킹한다.
- statusline 캐시에서는 화이트리스트한 필드만 읽는다. 경로와 세션 식별자는 내보내지 않는다.
- 상태 파일은 `~/.claude/cct-dash-state.json` (mode 600). 공개 리포 안에는 상태를 두지 않는다.
- 히스토리·토큰 DB 는 `~/.claude/cct-dash-data.sqlite3` (mode 600). JSONL 에서는 날짜·모델·토큰 수만 뽑고 메시지 본문·경로·세션 ID 는 저장도 노출도 하지 않는다.
- 프로바이더 토큰은 `~/.claude/cct-dash-providers.json` (mode 600). access·refresh 값은 `/api/state` 응답·실행 로그·예외 메시지 어디에도 싣지 않고, 화면에는 이메일·플랜·사용률만 나간다.

## 테스트

```sh
uv run --with pytest pytest tests -q
```

전부 `--fake` 경로이고 실계정 호출은 0회다. 파서, 마스킹, 경로 탈출 차단, 쓰기 게이트, 갱신 하한, 상태 파일 권한과 복원, 실행 argv·stdin 계약에 더해 히스토리 적재·다운샘플·보존, 알림 발화·해소·승격·수준별 발송, 설정 검증, JSONL 파싱 규칙(전역 dedup·synthetic 제외·캐시 5m/1h 분리 과금·costUSD 우선), 증분 스캔을 덮는다.

## 문서

설계 배경과 작업 이력은 [PLAN.md](PLAN.md) 에 있다. 초기 목업은 [mockup/](mockup/) 에 남겨 두었다.
