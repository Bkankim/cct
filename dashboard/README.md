# cct dashboard

cct 지갑의 계정별 구독 사용량을 한 화면에서 보는 로컬 대시보드다.
`cct usage --all` 을 매번 타이핑하는 대신 브라우저로 보고, 테일넷을 통해 다른 기기(Windows 등)에서도 같은 화면을 연다.

읽기 전용이 기본이고, 지갑을 바꾸는 동작은 전부 cct 명령을 거친다. 토큰 값은 화면·로그·응답 어디에도 나타나지 않는다.

![대시보드](screenshots/desktop-1400.png)

## 구성

```
브라우저 ──https(테일넷 전용)──▶ tailscale serve :8444 ──▶ 127.0.0.1:8790 server.py
                                                              │  zsh -f -c 'source cct.sh; cct ...'
                                                              ├─▶ cct usage --json (라벨 병렬, 실프로브)
                                                              ├─▶ cct status / doctor / ls / check / use / off / add / rm / rename
                                                              ├─▶ ~/.claude/orca-usage-cache.json (읽기 전용)
                                                              └─▶ ~/.claude/cct-dash-state.json (캐시·설정·로그, mode 600)
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

주요 옵션: `--bind`(기본 127.0.0.1) `--port`(기본 8790) `--web-dir` `--state-file` `--cct` `--live-file` `--fake` `--fixtures` `--fake-delay` `--log-level`.

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
| 계정 카드 | 라벨별 5h/7d/7f 한 줄 미터(사용률 바 + 남은 시간 · 리셋 시각)·상태 배지·org·check, `···` 에 점검/복사/이름변경/삭제 | 갱신·점검 시 프로브 |
| 리셋 타임라인 | 다음 24시간의 창 리셋 시점 | 프로브 없음 |
| 진단 | `cct doctor` 를 PASS / WARN / FAIL 로. 정상은 접고 경고·실패만 펼친다. 하단에 `cct status` 요약 | 프로브 없음 |
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

## 보안

- 서버는 127.0.0.1 에만 바인드한다. 외부 노출은 tailscale serve 가 맡는다.
- 지갑을 바꾸는 `add` / `rm` / `rename` 은 요청에 `X-CCT-Write: 1` 헤더가 있어야 하고, 화면에서는 쓰기 모드 토글을 켜야 보인다.
- 토큰은 stdin 으로만 cct 에 전달한다. argv·로그·응답·예외 메시지에 남지 않는다. 저장과 로깅 전에 `sk-ant-` 패턴을 마스킹한다.
- statusline 캐시에서는 화이트리스트한 필드만 읽는다. 경로와 세션 식별자는 내보내지 않는다.
- 상태 파일은 `~/.claude/cct-dash-state.json` (mode 600). 공개 리포 안에는 상태를 두지 않는다.

## 테스트

```sh
uv run --with pytest pytest tests -q
```

전부 `--fake` 경로이고 실계정 호출은 0회다. 파서, 마스킹, 경로 탈출 차단, 쓰기 게이트, 갱신 하한, 상태 파일 권한과 복원, 실행 argv·stdin 계약을 덮는다.

## 문서

설계 배경과 작업 이력은 [PLAN.md](PLAN.md) 에 있다. 초기 목업은 [mockup/](mockup/) 에 남겨 두었다.
