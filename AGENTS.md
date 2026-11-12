# cct 에이전트 지침

이 파일이 리포 지침의 실물이다. `CLAUDE.md`는 이 파일을 임포트하는 한 줄이다.
구조·절차·결정은 여기에 옮겨 적지 않고 `README.md`에 둔다.

## 목표
여러 Claude 계정의 setup-token을 로컬 지갑에 두고 사용자가 `cct <라벨>`로 직접 고르게 하는 셸 도구다.
프록시, 자동 라우터, 로드밸런서, 데몬으로 키우지 않는다(README "의도적으로 하지 않는 것").
기능을 더할 때는 사용자의 명시적 선택을 대신하지 않는지부터 본다.

## 확인 명령
- `shellcheck cct.sh install.sh tests/cct_test.sh cct-token.sh cct-session-hook.sh`
- `zsh -n cct.sh`
- `bash tests/cct_test.sh all`
- `uv run --with pytest pytest dashboard/tests -q`

## README 길잡이
`README.md`는 자동으로 실리지 않는다. 아래 일을 하기 전에 해당 절을 직접 읽는다.
- 명령·종료 코드·환경 변수를 바꿀 때: "명령", "기본 동작과 환경 변수"
- 지갑 쓰기·백업·잠금을 건드릴 때: "저장·백업·잠금", "위협 모델과 운영 보안"
- 대시보드를 건드릴 때: "대시보드 (선택)", "결정과 절충"
- 시험을 더하거나 돌릴 때: "시험"
- 기능 범위를 넓힐 때: "의도적으로 하지 않는 것"

## 실지갑과 실호출
- `CCT_ENV_FILE`을 주지 않으면 cct는 `~/.claude/tokens.env` 실지갑을 읽는다(`cct.sh` 64행).
- `cct usage`, `cct check`, `cct fp`, `cct who`는 실제 API 호출이라 계정 사용량을 쓴다. 인자 파싱만 볼 때도 임시 지갑(`CCT_ENV_FILE`)과 PATH의 가짜 `claude`·`curl`로 감싼다(`tests/cct_test.sh`의 방식).
- 대시보드를 띄워 확인할 때는 `--fake`(픽스처 모드)를 쓴다. 실지갑 서버(기본 포트 8790)는 조회 버튼 하나가 실호출이다.
- 토큰 값은 출력·로그·시험 기대값·커밋 어디에도 넣지 않는다.

## 코드가 오해를 부르는 곳
- `cct.sh`는 Bash와 Zsh 양쪽에서 source된다. 한쪽 전용 문법을 쓰지 않는다(CI가 `bash -n`과 `zsh -n`을 둘 다 돈다).
- 서브커맨드 이름은 라벨로 쓸 수 없다(`cct.sh` 178행 목록). 새 서브커맨드를 더하면 `tests/cct_test.sh`가 그 이름을 라벨로 쓰는 곳이 없는지 먼저 찾는다.
- 대시보드 서버는 cct를 `/bin/zsh -f`와 고정된 PATH로 부른다(`dashboard/server.py`의 `Cct.base_env`). rc 파일을 읽지 않으므로 `cct.sh`에서 새 외부 도구를 부르면 그 PATH에서 찾히는지 본다.
- 대시보드에 지갑 해석이나 사용률 조회를 파이썬으로 다시 짜지 않는다. 필요한 출력은 cct 쪽에 더하고(`cct usage --json`처럼) 서버는 그것을 부른다.

## 공개 리포 규칙
- 예시, 픽스처, 스크린샷의 계정 라벨은 중립 이름만 쓴다. 실제로 쓰는 계정 라벨을 넣지 않는다.
- 스크린샷은 `--fake`로 찍는다.
- `README.md`를 고치면 `README.en.md`의 같은 절도 맞춘다(두 파일은 절 구성이 같다).
- 사용자에게 보이는 변화는 `CHANGELOG.md` 맨 위 "Unreleased" 절에 영어로 적는다.
