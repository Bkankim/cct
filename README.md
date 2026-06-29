# cct — 휴대용 Claude 계정 지갑

**한국어** · [English](README.en.md)

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

| 명령 | 동작 | 주요 종료 코드 |
|---|---|---|
| `cct [claude 인자...]` | 활성(sticky) 라벨로 실행하고, 없으면 `CCT_DEFAULT_LABEL`(기본 `gv`) 사용 | Claude 종료 코드, 설정 오류 `1`, 사용법/라벨 오류 `2` |
| `cct <라벨> [claude 인자...]` | 해당 계정을 선택하고 Claude 인자를 그대로 전달 | Claude 종료 코드, 계정 없음 `1`, 라벨 오류 `2` |
| `cct run <라벨> [claude 인자...]` | `rm` 같은 예약어 라벨도 충돌 없이 명시 실행 | Claude 종료 코드, 계정 없음 `1`, 사용법/라벨 오류 `2` |
| `cct ls` / `cct list` | 등록 계정 목록 표시(토큰 값 미표시) | 성공 `0` |
| `cct add <라벨>` | setup-token 등록 또는 기존 토큰 교체(숨김 입력) | 성공 `0`, 취소/저장 실패 `1`, 사용법 오류 `2` |
| `cct rm <라벨> [--force]` | 기본 `[y/N]` 확인 후 계정과 주석 삭제 | 성공 `0`, 취소/실패 `1`, 사용법 오류 `2` |
| `cct rename <기존> <새>` | 토큰 값은 유지하고 라벨과 활성 상태를 변경 | 성공 `0`, 충돌/실패 `1`, 사용법 오류 `2` |
| `cct status` | 지갑 경로·mode·계정 수·활성/기본 라벨·sticky·로컬 Claude 버전 표시(오프라인) | 성공 `0`, 사용법 오류 `2` |
| `cct doctor` | 지갑 구조·권한·백업·잠금·Claude·셸 상태를 `PASS/WARN/FAIL`로 진단(오프라인) | FAIL 없음 `0`, 상태 실패 `1`, 사용법 오류 `2` |
| `cct check [라벨]` | 실제 Claude 호출로 토큰 유효성 점검 | 유효 `0`, 무효/점검 불가 `1`, 토큰 없음 `2`; 전체 점검은 하나라도 문제면 `1` |
| `cct fp [라벨]` / `cct who [라벨]` | 실제 호출에서 얻은 계정 지문으로 중복 여부 점검 | 유효 형식 라벨은 토큰 없음·응답 실패도 출력으로만 알리고 `0`, 라벨 형식 오류 `2` |
| `cct active` | 현재 sticky 활성 라벨 표시 | 성공 `0` |
| `cct off` | 활성 파일과 현재 셸의 cct 인증 환경 해제 | 성공 `0`, 상태 삭제 실패 `1` |
| `cct help` | 내장 도움말 표시 | 성공 `0` |

라벨은 소문자 영문, 숫자, 밑줄만 허용한다: `[a-z0-9_][a-z0-9_]*`. `cct <라벨>`은 기본적으로 Advisor와 비필수 웹 호출을 차단한다. 필요할 때만 `CCT_DISABLE_WEB_FEATURES=0 cct <라벨>`로 허용할 수 있다.

Sticky는 기본으로 켜져 있다. `cct <라벨>`이 선택한 계정을 현재 셸과 mode `600`의 `~/.claude/cct-active`에 기억하므로 이후 일반 `claude` 실행과 새 터미널도 같은 계정을 쓴다. `cct off`로 해제하거나 `CCT_STICKY=0`으로 저장하지 않는 실행을 선택할 수 있다.

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

동시 변경은 `tokens.env.lock/` 디렉터리로 직렬화한다. 최근 살아 있는 작업자가 있으면 변경을 거부한다. 죽은 작업자 또는 60초를 넘긴 stale lock은 다음 변경 시 안전 조건을 확인한 뒤 회수할 수 있다. `cct doctor`는 상태만 보고하며 복구하거나 파일을 수정하지 않는다.

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

MIT — [LICENSE](LICENSE)
