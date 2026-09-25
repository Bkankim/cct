# cct - 휴대용 Claude 계정 지갑

**한국어** · [English](README.en.md)

[![cct 대시보드](dashboard/screenshots/desktop-1400.png)](#대시보드-선택)

<sub>선택 기능인 [로컬 대시보드](#대시보드-선택) - 픽스처 데모이며 계정 라벨은 블러 처리했다. cct 자체는 셸 도구다.</sub>

여러 Claude 계정을 한 번씩 `claude setup-token`으로 인증해 장기 토큰을 로컬 지갑에 등록하고, 필요할 때 `cct <라벨>`로 직접 선택하는 셸 도구다. 지갑을 안전하게 옮기면 새 환경에서 계정마다 브라우저 OAuth 로그인을 반복하지 않고 Claude Code를 사용할 수 있다.

**macOS / Linux / WSL2에서 동작한다.** 프록시, 오케스트레이터, 자동 라우터, 로드밸런서가 아니다. 어떤 계정을 쓸지는 항상 사용자가 명시적으로 고른다.

## 설치

스크립트를 확인한 뒤 설치하는 방식을 권장한다.

```sh
git clone https://github.com/Bkankim/cct.git
cd cct
bash install.sh
exec "$SHELL"
```

한 줄 설치도 가능하다. `curl | bash`는 원격 코드를 바로 실행하므로 먼저 내용을 확인하길 권장한다.

```sh
curl -fsSL https://raw.githubusercontent.com/Bkankim/cct/main/install.sh | bash
```

설치 프로그램은 `cct.sh`를 `~/.claude/cct.sh`에 설치하고 Bash/Zsh 시작 파일에 `source` 줄을 추가한다. 지갑이 없을 때만 mode `600` 템플릿을 만들며, 재설치할 때 기존 `tokens.env`, 백업, 활성 라벨, 진행 중인 잠금/임시 파일을 덮어쓰지 않는다. Git ignore 규칙도 기존 사용자 설정을 유지하며 필요한 항목만 추가한다.

## 빠른 시작

신뢰할 수 있는 환경에서 계정별로 한 번 인증하고 setup-token을 등록한다.

```sh
claude auth login --claudeai  # 브라우저에 표시된 계정 확인
claude setup-token            # 발급된 값을 복사
cct add work                  # 숨김 입력에 붙여넣기

cct work                      # work 계정을 명시적으로 선택해 실행
cct personal                  # personal 계정으로 전환
```

`setup-token`은 장기 사용을 위한 현재 수단이지만 고정된 수명이나 영구성을 보장하지 않는다. 실제 수명과 정책은 바뀔 수 있으며, 만료·폐기·정책 변경 시 해당 계정에서 토큰을 다시 발급해 `cct add <라벨>`로 교체해야 한다.

## 명령

| 명령 | 동작 |
|---|---|
| `cct [claude 인자...]` | 활성(sticky) 라벨로 실행. 활성 라벨이 없으면 `CCT_DEFAULT_LABEL`(기본 `gv`) |
| `cct <라벨> [claude 인자...]` | 해당 계정으로 실행하고 Claude 인자를 그대로 전달 |
| `cct run <라벨> [claude 인자...]` | `rm` 같은 예약어 라벨도 충돌 없이 실행 |
| `cct use <라벨>` | claude를 띄우지 않고 활성 라벨만 전환 |
| `cct active` | 현재 활성 라벨 표시 |
| `cct refresh` | 다른 터미널에서 바꾼 활성 라벨을 현재 셸에 반영 |
| `cct off` | 활성 상태와 현재 셸의 cct 인증 환경 해제 |
| `cct ls` / `cct list` | 등록 계정 목록 (토큰 값 미표시) |
| `cct add <라벨>` | setup-token 등록 또는 교체 (숨김 입력) |
| `cct rm <라벨> [--force]` | `[y/N]` 확인 후 계정 삭제 |
| `cct rename <기존> <새>` | 토큰은 그대로 두고 라벨만 변경 |
| `cct status` | 지갑 경로·mode·계정 수·활성/기본 라벨·Claude 버전 (오프라인) |
| `cct doctor` | 지갑·권한·백업·잠금·셸 상태를 `PASS/WARN/FAIL`로 진단 (오프라인) |
| `cct check [라벨]` | 실제 호출로 토큰 유효성 점검 |
| `cct fp [라벨]` / `cct who [라벨]` | 실제 호출의 계정 지문으로 중복 계정 점검 |
| `cct usage [--json] [라벨\|--all]` | 구독 5h/7d/7f 사용률과 리셋 시각 (프로브 ≤32토큰). `--json`은 라벨당 JSON 한 줄(NDJSON) |
| `cct help` | 내장 도움말 |

라벨은 소문자 영문, 숫자, 밑줄만 허용한다: `[a-z0-9_][a-z0-9_]*`.

**종료 코드**는 `0` 성공, `1` 실행 실패(계정·토큰 없음, 취소, 저장 실패, 무효 토큰), `2` 사용법·라벨 형식 오류다. 실행 명령(`cct`, `cct <라벨>`, `cct run`)은 claude의 종료 코드를 그대로 돌려준다. 예외는 셋이다. `cct doctor`는 FAIL이 있으면 `1`, `cct check`는 토큰이 없으면 `2`이고 전체 점검은 하나라도 문제면 `1`, `cct fp`·`cct who`·`cct usage`는 토큰 없음·응답 실패를 출력으로만 알리고 `0`이다.

### 기본 동작과 환경 변수

`cct <라벨>`은 아래 동작을 기본으로 켜며, 각각 환경 변수로 바꿀 수 있다.

| 변수 | 기본 | 효과 |
|---|---|---|
| `CCT_STICKY` | `1` | 선택한 계정을 현재 셸과 활성 파일(mode `600`)에 기억해 이후 `claude`와 새 터미널도 같은 계정을 쓴다. `0`이면 저장하지 않는다 |
| `CCT_ACTIVE_FILE` | `tokens.env` 옆 `cct-active` | 활성 라벨 파일 경로 |
| `CCT_DEFAULT_LABEL` | `gv` | 활성 라벨이 없을 때 쓰는 라벨 |
| `CCT_SKIP_PERMS` | `1` | claude를 `--dangerously-skip-permissions`로 실행 |
| `CCT_CLAUDE_FLAGS` | 없음 | claude에 추가로 넘길 플래그 (공백 구분) |
| `CCT_DISABLE_WEB_FEATURES` | `1` | Advisor·텔레메트리·에러 리포팅 등 비필수 웹 호출 차단. 자동업데이트는 유지 |
| `CCT_FIX_ONBOARDING` | `1` | env 토큰으로 실행할 때 로그인 마법사가 뜨지 않도록 Claude 설정의 `hasCompletedOnboarding`을 보정. 파일이 없거나 symlink·깨진 JSON이면 건드리지 않고 mode를 유지 |
| `CCT_GJC_WARN` | `1` | gjc(가재코드)에 저장된 anthropic 자격증명이 env 토큰보다 우선할 때 경고만 출력 (삭제하지 않음) |

- 이미 열린 터미널은 다른 터미널의 전환을 자동으로 따라가지 않는다. 그 셸에서 `cct refresh`를 실행한다.
- 계정을 적용·해제할 때 `CLAUDE_CODE_OAUTH_TOKEN`과 함께 `ANTHROPIC_OAUTH_TOKEN`도 같은 값으로 export·해제해, env를 상속하는 다른 도구(gjc, aside 등)도 활성 계정을 따라간다.
- 웹 호출 차단에 쓰는 `DISABLE_TELEMETRY` 등은 범용 변수명이다. 같은 변수를 직접 쓰고 있었다면 `cct off`, 활성 계정의 `cct rm`, 활성 라벨이 없을 때의 `cct refresh`, opt-out이 그 셸에서 해제하고, `cct <라벨>`은 `1`로 덮어쓴다. 자동업데이트를 끄려면 `DISABLE_AUTOUPDATER=1`을 직접 지정한다. cct는 이 변수를 읽거나 쓰지 않는다.
- env 상속 대신 명령값 시크릿을 받는 도구에는 설치기가 함께 놓는 `~/.claude/cct-token.sh`(mode `700`)를 쓴다. 활성 계정의 setup-token을 stdout으로만 출력하고, 활성 계정·토큰이 없으면 출력 없이 비제로 종료한다. 예: aside `models.json`의 `"apiKey": "!<홈경로>/.claude/cct-token.sh"`는 호출 시점의 활성 계정을 따라간다.

## 대시보드 (선택)

`dashboard/`에 지갑 상태를 한 화면에서 보는 로컬 웹 대시보드가 있다. 계정별 5h/7d/7f 사용률과 리셋 시각, 갈아탈 계정 추천, `cct doctor` 진단, 로컬 토큰·비용 집계, GPT·Grok 구독 사용량을 보여준다. 빌드 도구·외부 리소스 없이 바닐라 HTML/CSS/JS와 표준 라이브러리 파이썬 서버로만 돈다.

```sh
uv run --script dashboard/server.py --port 8790          # 실지갑
uv run --script dashboard/server.py --fake --port 8799   # 픽스처 모드(실프로브 0회)
```

계정 카드를 누르면 그 계정의 상세(5h 구간별 사용률, 한도 도달 시각, 세션·요청별 토큰과 API 환산 비용, 모델·프로젝트별 비중, 외부 사용 추정)가 열린다. 계정 구분은 설치기가 `~/.claude/settings.json`의 SessionStart에 등록하는 `~/.claude/cct-session-hook.sh`가 담당한다. `cct`로 띄운 세션마다 `{시각, 세션ID, 라벨}` 한 줄을 `~/.claude/cct-sessions.jsonl`(mode `600`)에 남기고, 토큰과 대화 내용은 적지 않는다. 등록을 원하지 않으면 `CCT_NO_SESSION_HOOK=1 bash install.sh`. 상세 화면에 계정의 월 구독료를 넣으면 이번 달 API 환산 비용이 구독료의 몇 배인지 보여 준다. 세션이 돌고 있는 계정의 사용률은 Claude Code가 응답마다 갱신하는 statusline 캐시(`~/.claude/orca-usage-cache.json`)에서 읽어 자동 반영하므로 조회 호출이 없다. 이 맥에서 `cct`로 실행한 세션만 계정별로 나뉘고, 웹·앱·다른 PC 사용은 사용률로만 보인다.

기본은 `127.0.0.1` 바인드와 읽기 우선이고, 토큰 값은 화면·응답·로그 어디에도 나오지 않는다. 사용률 조회는 실제 API 호출이라 사용량을 조금 소비한다. 화면 구성, 프로브 비용, 상시 실행, GPT·Grok 연동과 고지는 [dashboard/README.md](dashboard/README.md)에 있다.

<details>
<summary>400px 모바일 · 쓰기 모드 화면</summary>

![400px 모바일](dashboard/screenshots/mobile-400.png)

![쓰기 모드](dashboard/screenshots/write-mode-1400.png)

</details>

스크린샷은 모두 픽스처 모드(`--fake`)로 찍은 데모이며 계정 라벨은 블러 처리했다.

## 휴대성과 OSS 경계

실제 자격 증명은 저장소 밖의 `~/.claude/tokens.env`(또는 `CCT_ENV_FILE`)에만 있다. 공개 저장소에는 실제 지갑이 없고, clone만으로는 어떤 계정에도 접근할 수 없다. `.gitignore`와 installer의 전역 ignore는 실수 방지 장치일 뿐 보안 경계가 아니므로, 자격 증명 파일을 Git에 추가하지 않는 책임은 사용자에게 있다.

다른 환경으로 옮길 때는 비밀번호 매니저의 보안 파일 전송 기능처럼 암호화된 경로를 사용한다.

```sh
mkdir -p ~/.claude
# 비밀번호 매니저에서 tokens.env를 ~/.claude/tokens.env로 복원
chmod 600 ~/.claude/tokens.env
cct doctor
```

평문 클라우드 동기화, 메신저, 이메일, Git 커밋으로 지갑을 옮기지 않는다. 파일 형식은 줄 단위 `CCT_TOKEN_<라벨>=<SETUP_TOKEN>`이며 예시의 `<SETUP_TOKEN>`은 실제 토큰이 아닌 자리표시자다.

## 저장·백업·잠금

`add`, `rm`, `rename`은 같은 디렉터리의 mode `600` 임시 파일과 atomic `mv`를 사용한다. 기존 지갑을 바꾸기 전에 rolling backup `tokens.env.bak`을 mode `600`으로 만든다. 한 번의 백업만 유지되므로 변경 전 장기 보관본이 필요하면 별도의 암호화 저장소에서 관리한다.

동시 변경은 `tokens.env.lock/` 디렉터리로 직렬화한다. owner 메타데이터의 PID가 살아 있으면 기록된 epoch의 나이와 관계없이 항상 busy로 처리한다. 다음 변경은 형식이 유효한 owner의 PID가 죽었을 때만 관찰한 owner가 그대로인지 다시 확인한 뒤 잠금을 회수할 수 있다. epoch는 진단용 시각 정보일 뿐 timeout이나 회수 조건이 아니다. `cct doctor`는 상태만 보고하며 복구하거나 파일을 수정하지 않는다.

지갑 손상 시 먼저 모든 cct 변경 작업이 끝났는지 확인한 뒤 백업을 복원한다.

```sh
cp ~/.claude/tokens.env.bak ~/.claude/tokens.env
chmod 600 ~/.claude/tokens.env
cct doctor
```

활성 계정의 삭제·이름 변경은 지갑과 활성 파일을 하나의 복구 가능한 트랜잭션으로 처리한다. 활성 상태 기록이 실패하면 검증된 백업에서 지갑을 되돌린다.

## 위협 모델과 운영 보안

- setup-token은 계정 비밀번호와 같은 민감도로 취급한다. 노출된 토큰은 해당 계정에서 폐기하거나 재발급하고 `cct add <라벨>`로 교체한다.
- 휴대성을 위해 지갑은 평문으로 저장된다. mode `600`은 다른 로컬 사용자의 일반 접근을 제한하지만 관리자, 악성 코드, 손상된 계정, 디스크 탈취를 막지 못한다. macOS FileVault, Linux 전체 디스크 암호화, Windows BitLocker 같은 at-rest 암호화를 함께 사용한다.
- `tokens.env.bak`도 원본과 같은 비밀이다. 백업·스냅샷·진단 자료에 포함할 때 동일하게 보호한다.
- WSL2에서는 지갑을 Linux 홈의 `~/.claude`에 둔다. `/mnt/c`는 Linux `chmod 600` 의미가 약해질 수 있으므로 사용하지 않는다.
- 공유 PC, 공개 CI, 셸 trace(`set -x`), 프로세스 인자, 로그에 토큰을 노출하지 않는다. `status`와 `doctor`는 토큰을 출력하거나 네트워크로 검증하지 않는다.
- 만료나 서버 측 폐기는 정상적인 운영 사건이다. cct는 OAuth refresh를 보관하거나 자동 재인증하지 않으므로 해당 계정의 setup-token을 다시 발급해야 한다.

## 의도적으로 하지 않는 것

cct는 OAuth refresh 서비스, 프록시, 오케스트레이터, 자동/쿼터 기반 라우터, 로드밸런서, GUI, 데몬이 아니다. 계정 상태를 보고 최적 계정을 고르지 않으며, 사용자의 명시적 선택을 대신하지 않는다. macOS Keychain이나 별도 런타임도 필수로 요구하지 않는다.

## 라이선스

MIT - [LICENSE](LICENSE)
