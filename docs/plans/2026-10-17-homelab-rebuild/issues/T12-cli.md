# T12 CLI

- 단계: P2 플랫폼 구축 (잠정)
- 상태: 대기
- 명세: [../spec.md](../spec.md)
- Blocked by: T10, T11
- 선행 결정: D-28(확정(사용자 2026-10-18): GitHub 보호 설정은 Terraform `infra/github`, 이 티켓의 `homelab github` 명령이 T10의 래퍼를 감싼다), D-29(확정(사용자 2026-10-18): 앱 저장소는 public만)
- 연결 AC: AC-P13
- 수행: 에이전트

## 목표

앱 등록·DB/Valkey 추가·상태 확인을 얇은 CLI로 묶는다. 언어는 Bun·TypeScript가 기본값이다.

## 범위

플랫폼 프롬프트 §8의 목표 UX: 앱 등록, DB/Valkey 추가, `plan`, PR 안내, 준비 상태, 로그, 롤백 계획, 비밀번호 회전, 삭제와 데이터 폐기 분리, 사람용 출력과 JSON.

- `homelab github plan`·`apply`·`verify` (D-28): T10의 래퍼 `tools/tf-github.sh`와 같은 규칙으로 감싼다(토큰 종류별 확인, fetch한 `origin/main`의 임시 worktree에서만 실행, `TF_CLI_ARGS*`·`TF_LOG*` unset, `TF_CLI_CONFIG_FILE`은 래퍼 소유 설정 파일로 고정, plan 종료 코드 0·2만, delete는 `--allow-destroy`로만, apply 전 state 백업, apply 실패 뒤 ruleset 재import). 설계 문서 C.3.9·C.7.
- `homelab app new` (D-29): private 선택지(`--private`)를 두지 않는다. 템플릿 main의 `app-main`이 active인지 확인 → `infra/github/app-repos.json` PR → 병합 뒤 재실행으로 public 저장소 생성, 보안 설정(`gh api`), `homelab github apply`로 `app-main`(설계 C.7).
- `homelab app add` (D-29): 앱 저장소가 private이거나 GHCR 패키지를 익명으로 받을 수 없으면 멈춘다. 봇 저장소(T14가 만든 기존 저장소)도 이 명령으로 등록한다(설계 E9).

## 제약

- `plan`은 읽기 전용이다. 비밀번호 생성, Infisical 쓰기, DB 생성이 일어나지 않는다. `homelab github plan`·`verify`는 `-lock=false`라 R2에 잠금 객체도 쓰지 않는다. 잠금은 `homelab github apply`만 잡는다.
- 배포 상태는 새 저장소를 만들지 않고 GitHub 기록과 Argo CD 상태를 읽는다.

## 완료 조건

- 시나리오 5(재실행해도 데이터·비밀번호 불변)를 통과한다.
- `plan` 실행 전후로 Git·Infisical·DB 상태가 같다.

## 검증

- 같은 등록 명령을 두 번 실행해 비교한다.
- 중간에 실패시킨 뒤 재실행으로 이어지는지 확인한다.
