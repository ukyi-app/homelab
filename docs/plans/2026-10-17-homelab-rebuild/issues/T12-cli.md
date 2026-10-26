# T12 CLI

- 단계: P2 플랫폼 구축 (재분해 T05 2026-10-18)
- 상태: 완료(2026-10-26. 2026-10-23 착수, T10 선행은 사용자 결정으로 완화. 운영 통합 검증(T12-05) 통과, 후속은 검증 절 끝)
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
  - 보안 설정에 PR 생성 `pull_request_creation_policy=collaborators_only`(`gh api -X PATCH repos/ukyi-app/<app>`)를 넣는다. 저장소마다라 새 저장소에는 따로 켜야 한다(U38 대책, 2026-10-22. 기존 다섯 저장소는 모두 `all`이었다). interaction limit은 org 단위라 따로 걸지 않는다.
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
- 확인한 항목(2026-10-26, 기록은 `approvals.md`의 같은 날 행). main을 `bun build --compile`한 실행 파일과 사람 자격(`gh`, `infisical login`, kubeconfig)으로 `homelab-probe`(앱 + DB + 영속 Valkey)와 `homelab-probe2`(DB만)에 돌렸다. 앞뒤 비교는 스냅샷으로 했다: main과 열린 PR, Infisical 키 이름과 값 해시, 클러스터 리소스 버전과 Secret 해시, DB 데이터 해시, Valkey 키 수. 해시 값은 저장소 밖에 두고 같음·다름만 적는다.
  - 재실행 불변(시나리오 5): `app add`·`db add`·`cache add`를 `--apply`로 두 번 돌렸다. 둘 다 exit 0이고 모든 단계가 `same`이었다(T11에서 손으로 등록한 상태와 같아 첫 실행도 `same`). 새 PR은 없었고, 앞뒤 스냅샷(Infisical 해시, DB 데이터 해시, Valkey 키 수, Secret 해시)이 같았다.
  - `plan` 부수효과 0(AC-P13): 쓰기 명령 16개를 `plan`으로 돌렸다(`app new`, `app add`, `db add`, `cache add`, `secret set`, `secret sync`, `db rotate`, `cache rotate`, `db restore --to`, `db restore-check`, `cache restore`, `rollback --to`, `rollback --release`, `app remove`, `data purge` 둘). 앞뒤 스냅샷이 같았다. 차이는 그사이 push된 다른 열린 PR(#893)의 head 하나였다. exit 1 셋은 예상한 멈춤이다: `secret sync`는 아직 없는 키, `db restore`는 T1 뒤 백업 없음, `data purge homelab-probe`는 앱이 아직 있음.
  - 출력과 종료 코드: 명령마다 사람용 출력과 `--json`(`homelab-cli/v1`)을 저장했고 시크릿 값은 없었다. 종료 코드 0(완료·변경 없음), 1(실패·사전 확인 멈춤), 3(PR 병합 대기)을 봤다. 64(사용법 오류), 중복 플래그 거부, 중간 실패 뒤 재실행은 `bun test`(cli 시험, 필수 `ci`)가 본다.
  - 쓰기 명령(시나리오 2·3·8·9·10의 CLI 경로):
    - `secret set homelab-probe T12_PROBE`(값은 stdin) → `app add` 갱신 PR #895 → `secret sync`. 첫 sync는 Argo CD 반영 전이라 ExternalSecret이 없어 exit 1이었다. 반영 뒤 다시 돌려 exit 0(파드 재시작), ExternalSecret 6/6 Ready, 파드 env에 그 키 이름이 있었다.
    - `db rotate` → `--finish`: 새 값으로 접속, 옛 값 거부, `/healthz/db` 200. `--finish`가 `PASSWORD_PREVIOUS`를 지웠고 재실행은 `same`. DB 데이터 해시는 그대로였다.
    - `cache rotate` → `--finish`: 서버가 새 값으로 인증, `/healthz/cache` 200, Valkey 키 수 그대로(영속). `--finish`는 옛 값 거부와 수동 백업 Job 성공을 본 뒤 `PASSWORD_PREVIOUS`를 지웠고 재실행은 `same`.
    - `rollback --to <앞 커밋>`: PR #897(`hold: true`). 반영 뒤 파드 imageID가 그 digest였다. 반영 전 `status`는 exit 1로 차이를 잡았다. 최신 커밋으로 `--to` PR #898 → `--release` PR #899(`hold: false`). 재실행 `same`, `status` exit 0.
    - `cache restore` → `--finish`: PR #900(서버 내림)·#901(복원 모드)·#902(끄기). R2 백업 하나에서 키 수가 백업과 같았고, `appendonly yes`, 검증 키 0개, 일회성 Job·실행 기록 0개.
    - `db restore --to T1` → `--finish`: T1 뒤 행을 하나 쓰고, 마지막 백업 뒤 시각이라 온디맨드 base backup을 먼저 만들었다(설계 C.7). PR #903(앱 멈춤)·#904(재개). 복원 뒤 T1 앞 행은 남고 T1 뒤 행만 사라졌다. ACL은 원본과 같고 역할 승격은 없었다. 임시 객체 0개, `--finish`가 잠금을 지웠다.
    - `db restore-check`: 최신 base backup으로 임시 Cluster를 만들어 Database CR 2개의 DB를 확인한 뒤 정리하고 기록을 지웠다.
    - `github apply`: 변경 없음, exit 0(apply 전 state 백업은 저장소 밖). 뒤 `github verify` 0.
    - `app remove` PR #905: Application·Deployment가 사라지고 데이터(DB, 영속 Valkey)는 남았다. 재실행 `same`, `data list`에 `homelab-probe`·`homelab-probe2`.
  - 읽기 명령: `doctor` exit 0, `status homelab-probe`·`status --platform`, `data list`(#894 뒤 exit 0), `github plan` exit 0(변경 없음), `github verify`. `logs`는 이번 운영 기록에 출력이 남지 않아 `bun test`로만 확인했다.
  - `github verify` = 래퍼: 같은 main에서 `homelab github verify`와 바로 뒤 `tools/tf-github.sh verify`가 둘 다 exit 0.
  - `app new`: `plan`으로 템플릿 `app-main` active, 같은 이름 저장소 없음, `app-repos.json` PR 계획까지 봤다(아무것도 쓰지 않음). app_main 생성만인지의 판정(래퍼 `plan --plan-json`)은 목록 병합 뒤 단계라 `bun test`가 본다. 실제 생성은 T13 시나리오 1이다.
  - 등록·데이터 정리: `app remove` 뒤 `data purge`를 둘 다 돌렸다(실행 직전 사용자 재승인). 첫 실행은 앱 워크로드 없음을 보고 폐기 확인 기록(`database/data-purge-<app>`)을 남긴 뒤, 그 뒤 백업이 없어 exit 1로 멈췄다. 온디맨드 백업(CNPG `Backup`, Valkey 백업 Job) → PR 1 #906·#907(`purge: true`, 데이터 차트 1.0.2) → PR 2 #909·#910(`data/<app>/` 삭제) → Infisical 키 삭제(터미널에서 앱 이름을 다시 친 뒤). 끝에 `data list`에 둘 다 없고 두 purge 재실행은 `same`이었다. 마지막 스냅샷에서 두 앱의 Infisical 키 0개, DB·Valkey 데이터 없음, 폐기 확인 기록 0개. 설계대로 남긴 것: 빈 앱 ns, 빈 Infisical 폴더, R2 백업(보존 기간 동안).
  - 배포 절차: `bun cli/build.ts --install`이 `~/.local/bin/homelab`에 설치하고 `homelab --version`이 `homelab 0.1.0 (<커밋 12자>)`를 낸다. 검증 중 두 번 다시 설치했고 그때마다 앞 파일이 `homelab.prev`로 남았다. 되돌리기(`homelab.prev`를 제자리로)는 `cli/README.md` 절차이고 이번에는 쓰지 않았다.
  - 운영에서 찾아 고친 것:
    - #894: core의 `kubectl` 목록 조회가 `-A`를 하위 명령 앞에 둬 kubectl 1.36이 거부했다(`data list`·purge PV 확인 실패). 시험 스텁도 같은 순서를 거부하게 했다(설계 B.8 E7).
    - #908: purge 시험이 저장소의 실제 `data/` 파일을 읽어, 그 파일을 바꾸는 purge PR 1(#906·#907)의 필수 `ci`를 깨뜨렸다. 시험을 fixture로 옮겼다.
    - 옛 저장소의 `bun link`(`~/.bun/bin/homelab`)가 PATH 앞에서 새 CLI를 가렸다. 사용자 결정으로 지웠고, `doctor`가 이제 경고한다(#894).
- 후속(이 티켓 밖으로 넘김):
  - CLI 출력과 분기(운영에서 본 P3): `secret sync`는 Argo CD 반영 전(ExternalSecret 없음)이면 실패(1) 대신 대기(3)가 맞다. `rollback --release`가 이미지를 그대로 둔다는 안내를 출력에도 한 줄(설계 C.7에는 이 기록 PR에서 적었다). `data purge` 출력에서 단계는 `same`인데 지난 '동기화 대기' 주의 줄이 남는다. 앱 ns가 없는 데이터에도 '앱 ns …는 남는다' 문구가 나온다. Infisical 세션 만료(Unauthorized)가 '읽지 못함'으로만 보인다(`infisical login` 안내가 맞다).
  - `restore.md` 1절: CLI `cache restore`가 기록 `suspect.marker`로 멈춘 뒤 손으로 확인하고 실행 기록(앱 ns ConfigMap `restore-vk`)을 지우는 절차. 검증 키는 CLI처럼 `homelab:restore:*` 전부를 키 수에서 빼고 정리 때 지운다(복원 중 정기 백업에 옛 검증 키가 섞일 수 있다, #891 리뷰).
  - `db restore`의 R2 되돌림 사본(1단계 자동 덤프) 삭제: 사람 작업이다. 명령은 저장소 밖에 있다.
  - Renovate PR #878(bun 1.4.4): 봇 PR이 `ci.yaml`의 sha256을 바꾸지 않아 ci가 실패한다. bun과 sha256을 같은 커밋에서 바꾸는 우리 PR로 올린다.
  - T11에서 넘어온 둘은 T12에서 정리하지 않았다. T13 전에 정한다: 앱 역할 간 PostgreSQL 기본 PUBLIC CONNECT를 데이터 차트에서 막을지, 시작하자마자 같은 클러스터 안 상대에 붙는 앱의 첫 접속 재시도를 앱 계약(앱 템플릿 README)에 적을지.

## 되돌리는 방법

설계 E7 "되돌리는 방법"을 따른다.

- CLI는 로컬 도구라 이전 실행 파일로 돌아간다.
- CLI가 만든 PR은 닫는다.
- `homelab github apply`로 바꾼 GitHub 보호 설정은 T10의 되돌리는 방법을 따른다(래퍼와 같은 root를 쓴다).
