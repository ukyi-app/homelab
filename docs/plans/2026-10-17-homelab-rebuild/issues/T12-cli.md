# T12 CLI

- 단계: P2 플랫폼 구축 (재분해 T05 2026-10-18)
- 상태: 대기
- 명세: [../spec.md](../spec.md)
- Blocked by: T10, T11
  - 읽기 명령(`doctor`, `status`)은 T10 뒤 먼저 착수할 수 있다. 나머지와 완료는 T11 뒤다(설계 E.0, E7).
- 선행 결정: D-28(확정(사용자 2026-10-18): GitHub 보호 설정은 Terraform `infra/github`, 이 티켓의 `homelab github` 명령이 T10의 래퍼를 감싼다), D-29(확정(사용자 2026-10-18): 앱 저장소는 public만)
- 연결 AC: AC-P13
- 수행: 에이전트 + 사람 (CLI가 만든 PR 검토·병합, `homelab github apply` 승인)

## 목표

앱 등록·DB/Valkey 추가·상태 확인을 얇은 CLI로 묶는다. 언어는 Bun·TypeScript가 기본값이다.

## 범위

플랫폼 프롬프트 §8의 목표 UX: 앱 등록, DB/Valkey 추가, `plan`, PR 안내, 준비 상태, 로그, 롤백 계획, 비밀번호 회전, 삭제와 데이터 폐기 분리, 사람용 출력과 JSON.

- 만들 것(설계 E7): `cli/`(설계 C.7의 명령), 시험(`plan` 부수효과 0 단언 포함), `bun build --compile` 배포 절차.
- `homelab github plan`·`apply`·`verify` (D-28): T10의 래퍼 `tools/tf-github.sh`와 같은 규칙으로 감싼다(토큰 종류별 확인, fetch한 `origin/main`의 임시 worktree에서만 실행, `TF_CLI_ARGS*`·`TF_LOG*` unset, `TF_CLI_CONFIG_FILE`은 래퍼 소유 설정 파일로 고정, plan 종료 코드 0·2만, delete는 `--allow-destroy`로만, apply 전 state 백업, apply 실패 뒤 ruleset 재import). 설계 문서 C.3.9·C.7.
- `homelab app new` (D-29): private 선택지(`--private`)를 두지 않는다. 템플릿 main의 `app-main`이 active인지 확인 → `infra/github/app-repos.json` PR → 병합 뒤 재실행으로 public 저장소 생성, 보안 설정(`gh api`), `homelab github apply`로 `app-main`(설계 C.7).
- `homelab app add` (D-29): 앱 저장소가 private이거나 GHCR 패키지를 익명으로 받을 수 없으면 멈춘다. 봇 저장소(T14가 만든 기존 저장소)도 이 명령으로 등록한다(설계 E9).

## 제약

- `plan`은 읽기 전용이다. 비밀번호 생성, Infisical 쓰기, DB 생성이 일어나지 않는다. `homelab github plan`·`verify`는 `-lock=false`라 R2에 잠금 객체도 쓰지 않는다. 잠금은 `homelab github apply`만 잡는다.
- 배포 상태는 새 저장소를 만들지 않고 GitHub 기록과 Argo CD 상태를 읽는다.

## 필요한 자격

- 새 외부 자격은 없다(설계 E7).
- CLI는 사람의 `gh` 로그인, `infisical login`, kubeconfig를 쓰고 자격을 저장하지 않는다(설계 C.7).
- `homelab github`은 T10 래퍼와 같은 자격을 쓴다: `GITHUB_TOKEN`(owner `gh auth token` 또는 만료 있는 fine-grained PAT, 환경변수로만)과 Infisical `homelab-admin`의 `/terraform/state` R2 키(준비 T09).
- `homelab db restore`는 사람 kubeconfig의 `database` ns 쓰기 권한이 필요하다(설계 C.5.7).

## 완료 조건

- 시나리오 5(재실행해도 데이터·비밀번호 불변)를 `homelab-probe`로 통과한다.
- `plan` 실행 전후로 Git·Infisical·클러스터(DB 포함) 상태가 같다 (AC-P13).
- 사람용 출력과 JSON 출력을 낸다.
- CLI 경로 재확인: 설계 C.7의 쓰기 명령(`app add`, `db add`, `cache add`, `secret set`, `db rotate`, `db restore`, `rollback`, `app remove`, `data purge`, `github apply`)과 읽기 명령(`status`, `data list`, `github plan`, `github verify`)을 `homelab-probe`에 한 번씩 실행해, T10·T11 동등 절차와 같은 확인을 통과한다(시나리오 2·3·8·9·10의 CLI 경로).
- `homelab github verify`가 래퍼 `tools/tf-github.sh verify`와 같은 종료 코드를 낸다.
- `app new`는 `plan`만 본다. 실제 생성은 T13의 시나리오 1이다.
- 끝에 `app remove`·`data purge`로 `homelab-probe`의 등록과 데이터를 지운다.

## 검증

- 같은 등록 명령을 두 번 실행해 비교한다.
- 중간에 실패시킨 뒤 재실행으로 이어지는지 확인한다.
- `bun test`. 외부 명령 argv를 기록하는 PATH 스텁으로 모든 명령을 `plan` 모드로 돌려 쓰기 부명령이 0건임을 단언한다(설계 C.7, L50).
- 위 명령마다 T10·T11 동등 절차의 확인 명령을 다시 실행한다(설계 E5·E6 표 아래).

## 되돌리는 방법

설계 E7 "되돌리는 방법"을 따른다.

- CLI는 로컬 도구라 이전 실행 파일로 돌아간다.
- CLI가 만든 PR은 닫는다.
- `homelab github apply`로 바꾼 GitHub 보호 설정은 T10의 되돌리는 방법을 따른다(래퍼와 같은 root를 쓴다).
