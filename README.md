# cct — Claude Code 다계정 스위처

**한국어** · [English](README.en.md)

여러 Claude 구독 계정을 `cct <라벨>` 한 줄로 갈아끼우는 셸 도구. 계정별 장기 OAuth 토큰을 로컬에 보관하고 실행 시 주입한다. **macOS / Linux / WSL2 공용. 프록시 아님(환경변수 주입 방식).**

## 설치 (어느 PC든)

**한 줄 설치** (가장 빠름):
```sh
curl -fsSL https://raw.githubusercontent.com/Bkankim/cct/main/install.sh | bash
```
또는 **클론 후 설치** (스크립트를 먼저 확인하고 싶을 때 권장 — `curl|bash`는 원격 코드를 바로 실행하므로):
```sh
git clone https://github.com/Bkankim/cct.git
cd cct && bash install.sh
```
설치 후 `exec $SHELL`(또는 새 터미널 / `source ~/.claude/cct.sh`).
`install.sh`는 멱등(여러 번 실행 안전)이며 다음을 자동 처리한다:
- `cct.sh` → `~/.claude/cct.sh` 설치, 셸 rc(`~/.zshrc`/`~/.bashrc`)에 `source` 추가
- `~/.claude/tokens.env` 템플릿(없을 때만) 생성 + `chmod 600`
- 로컬 `.gitignore` + 전역 gitignore에 `tokens.env` 등록(실수 커밋 방지)
- ⚠️ `cc`/`ㅊㅊ` alias는 강제하지 않음(빌드 PC의 `cc`=컴파일러 충돌 회피)

## 명령
| 명령 | 동작 |
|---|---|
| `cct` | 현재 인증된 프로필로 실행 (`--dangerously-skip-permissions`) |
| `cct <라벨>` | 해당 계정 토큰으로 실행 (예: `cct gv`, `cct pro1`) |
| `cct ls` | 등록된 계정 목록 |
| `cct add <라벨>` | 토큰 등록/갱신 (화면 미표시 입력) |
| `cct check [라벨]` | 토큰 유효성 점검 (실제 호출) |
| `cct fp [라벨]` | 계정 지문 — 중복 탐지(7d_reset 같으면 같은 계정) |
| `cct help` | 도움말 |

## 토큰은 따로 (저장소에 없음)
토큰은 `~/.claude/tokens.env`(평문, 600, 키 `CCT_TOKEN_<라벨>`)에만 있고 **저장소에는 포함되지 않는다**(`.gitignore`로 차단). 새 PC에서는:
- **방법 A** — 계정마다 직접 등록:
  ```sh
  claude auth login --claudeai   # 브라우저에 뜬 계정 확인(= 정체의 유일한 진실)
  claude setup-token             # 토큰 복사
  cct add pro1                   # 붙여넣기
  ```
- **방법 B** — 기존 `tokens.env`를 안전하게 옮겨 `~/.claude/tokens.env`로 복사(비밀번호 매니저 경유 권장, 클라우드 평문 동기화 금지) 후 `chmod 600`.

## 토큰 발급
`claude setup-token`(구독 Pro/Max, 약 1년 유효). 머신 비종속이라 PC를 초기화해도 토큰 값만 있으면 동작. `sk-ant-oat01-` = 구독 OAuth(구독 사용), `sk-ant-api03-` = API 키(종량제) — 이 도구는 전자를 쓴다.

## 보안
- `tokens.env`는 평문 → `chmod 600`, **절대 커밋 금지**(자동 gitignore). 토큰 = 계정 비밀번호급, 유출 시 `claude setup-token` 재발급.
- **WSL2**: 토큰 파일은 리눅스 홈(`~/.claude`)에. `/mnt/c` 경로는 `chmod` 무력화. at-rest 보호는 Windows BitLocker.

## 라이선스
MIT — [LICENSE](LICENSE)
