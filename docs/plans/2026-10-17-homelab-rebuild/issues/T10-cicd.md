# T10 CI/CD

- 단계: P2 플랫폼 구축 (재분해 T05 2026-10-18)
- 상태: 진행 중(2026-10-20 착수. 2026-10-21까지 끝: 작성 PR #788~#791과 후속, 배포·병합 App 생성·설치, 태그 `app-chart-v1.0.0`·`app-build-v1.0.0`·`app-build-v1.0.1`, `infra/github` 1·2단계 apply와 병합 키 Secret Sync, 템플릿 교체, `homelab-probe` 생성·하드닝, 시나리오 1(통과, 승인된 한계: 앱 파드 시작 직후 약 1초 egress 공백), 시나리오 7 배포 흐름 부분(ESO 인증 장애 중 배포 PR 자동 병합·새 파드 Ready, 원복 뒤 자동 재동기화), 시나리오 11, 시나리오 15(15-11 제외), 병합 키 회전 1회(옛 키 삭제 뒤 자동 병합 성공), 리뷰 전용 App 구조 확인(C.8, AC-P12), U20(Renovate 이용 조건, 통과(조건부)), 저장소 루트 `renovate.json`(#819)과 Renovate 설치·첫 실행 확인(2026-10-21 20:54 설치·20:57 첫 job, homelab·`homelab-app-template`·`homelab-probe`), guard 1 직접 plan 시험(통과), U21(통과), U08(재시험 통과, Restrict updates: (가) 통과·(나) 실패 → 2026-10-21 21:12 결정 → apply 뒤 재시험 통과), U35(통과, fine-grained PAT 만료 머리글만 미실행), U37(통과(조건부): Codex 작업 환경을 두지 않음, 2026-10-22. 다른 저장소의 환경 부재는 사용자 확인 대기), U38(시험 대신 대책 적용: org interaction limit `collaborators_only`·저장소 다섯의 PR 생성 Collaborators only, 2026-10-22). 남은 것: Renovate의 대책 아래 동작 확인(다음 job). T13으로 넘김: 15-11(main 밖 빌드의 조건 5 거부), egress 공백 완화)
- 명세: [../spec.md](../spec.md)
- Blocked by: T07(착수), T09(완료), T08a(`infra/github` 첫 apply만. R2 잠금 시험 U02 뒤)
  - 착수: T07 뒤 바로 시작한다. 차트, 워크플로, `infra/github` HCL 같은 작성 작업은 T09와 병행한다.
  - 완료: T09 뒤. Infisical 프로젝트 `homelab-ci-deploy`·`homelab-ci-merge`와 배포 키 OIDC identity `gha-homelab-deploy`가 있어야 배포 PR이 생기고, 종단 시험(아래 CLI 없는 동등 절차)을 할 수 있다(설계 C.4.8 "T09 → T10 간선의 답").
  - `infra/github` 첫 apply: T08a의 첫 Terraform apply와 R2 잠금 동시 실행 시험(U02) 뒤에 한다. R2 state를 처음 쓰는 단계를 하나로 둔다(설계 E.0).
- 선행 결정: D-04 (확정(사용자 2026-10-18): 배포 키 OIDC, 병합 키 Secret Sync), D-07 (확정(사용자 2026-10-18, T05): 배포 digest PR만 자동 병합, 서버 강제), D-18 (확정(사용자 2026-10-18, T05): 호스팅형 Renovate App 저장소별 설치, 자동 병합 모두 끔), D-21 (확정(사용자 2026-10-18, T05): `homelab-app-template` 재사용, 내용 교체), D-23 (확정: public 유지), D-26 (확정(사용자 2026-10-18, T05): Codex Connector 유지 + 조건 다섯. (5) Codex 작업 환경 없음은 2026-10-22 더함), D-28 (확정(사용자 2026-10-18): GitHub 보호 설정 Terraform), D-29 (확정(사용자 2026-10-18): 앱 저장소 public만), D-30 (확정(사용자 2026-10-20): 내부 UI 짧은 주소 리다이렉터 `go`. 공유 차트의 `internal.name` 검사에서 `go`·`vm-go`를 예약어로 막는다)
- 참조 결정: D-24 (봇 쓰기 신원. 확정(사용자 2026-10-18, T15): 봇 전용 쓰기 GitHub App. App 생성·설치는 T19). T10은 이 신원이 없어도 자동 병합 차단 조건을 설계하고, 시험용 다른 신원으로 검증한다. D-16 (봇 PR 리뷰. 확정(사용자 2026-10-18, T15): 기본안). Codex Connector 설치 범위 축소는 확정(사용자 2026-10-18, T15): 선택 저장소로 줄이고 `homelab-bot-ops`를 뺀다. 사람이 T15에서 `homelab-bot-ops`에 운영 산출물을 처음 올리기 전에 하기로 했고, 2026-10-18 17:45에 완료했다(spec §11, D-26, [../approvals.md](../approvals.md)).
- 연결 AC: AC-P7, AC-P8, AC-P12
- 수행: 에이전트 + 사람 (GitHub App 2개와 시험 App 2개 생성·설치, Terraform github root apply(owner 로컬), Actions 허용 범위, Infisical Secret Sync와 App Connection용 PAT, GHCR 패키지 Public 전환, Renovate 설치, `homelab-probe` 저장소 생성, 템플릿 내용 교체 승인)

## 목표

앱 저장소 push부터 digest 기반 배포 PR과 병합까지의 흐름을 만든다.

## 범위

- 공통 워크플로와 공유 Helm 차트. 만들 것(설계 E5): `platform/charts/app`과 태그 `app-chart-v1.0.0`, ApplicationSet `apps`와 AppProject `apps`, `.github/workflows/app-build.yaml`과 태그 `app-build-v1.0.0`, 전체 `ci.yaml`, `deploy-merge.yaml`, `.github/workflows/README.md`(자동 병합 조건 공개, AC-P8).
  - 공유 차트는 설계 C.4.5 표의 항목을 낸다. 선택 항목 `serviceAccountName`을 더한다(봇의 `bot-reader`, 설계 C.8). 차트는 SA·바인딩을 만들지 않는다. DB·캐시 연결 env와 마이그레이션 Sync hook Job(`migration.command`, D-22)도 이 차트의 항목이고 T11이 쓴다.
  - `internal.name`은 DNS 라벨(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)이고 클러스터 접두를 붙인 `<접두><이름>`도 63자 이하여야 한다(VM은 `vm-`가 붙는다). `go`와 `vm-go`는 모든 클러스터에서 거부한다. 둘은 D-30 리다이렉터의 tailnet 이름이고, 리다이렉터가 `go/<internal.name>`을 그 앱의 tailnet 주소로 보낸다.
  - 차트 NetworkPolicy의 인터넷 443은 ipBlock `0.0.0.0/0`에 except `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10`(tailnet)을 명시한다. IPv6 허용 줄은 두지 않아 tailnet IPv6 `fd7a:115c:a1e0::/48`도 막힌다. IPv6 허용을 더할 때는 except에 `fd7a:115c:a1e0::/48`을 함께 넣는다(설계 C.4.5 네트워크 행과 "tailnet 차단"). 앱 파드가 tailnet으로 나가면 출발 주소가 NUC의 Tailscale 주소로 바뀐다(U28, 2026-10-20 확인). D-11 (c)(2026-10-20)로 NUC → 운영자 기기 길은 Tailscale에서 막히지만, `tag:nuc`가 닿는 tailnet 대상은 남고 ACL 실수 한 번이면 다시 열리므로 차트에서도 뺀다. 확인은 시나리오 1의 tailnet 불통이다(앱 라벨을 단 시험 파드에서 운영자 기기의 tailnet 주소 연결 실패, U28).
  - 앱 저장소 쪽 읽기(compare, 기본 브랜치 확인)는 App 토큰이 아니라 deploy-pr job의 `GITHUB_TOKEN`으로 한다. App 설치 토큰은 homelab 쪽(`image.yaml` 읽기, `deploy/<app>` push, PR 생성)에만 쓴다(설계 C.4.8).
  - 전체 `ci`는 platform의 로컬 Helm 차트도 렌더해 검사한다. `root`는 클러스터 값 파일마다, `bot-slot`은 자기 values로 렌더한다(설계 C.4.6). 렌더 결과 정책 검사에 읽기 전용 Role의 verb·roleRef 검사(L30)를 넣는다. T08b가 넘긴 설계 C.8 읽기 전용 접근 줄의 CI 검사다.
- `homelab-app-template`: D-21(확정(사용자 2026-10-18, T05))대로 저장소·이름을 재사용하고 내용을 바꾼다(설계 F D-21).
  - 새 내용: Dockerfile(amd64, `ARG TARGETARCH` 기본값 없음), `/healthz`, `CODEOWNERS`(`* @<owner 계정>`), 짧은 `build.yaml`(공통 워크플로를 태그로 호출, 호출 job에 권한 상한 선언), 로컬 compose(`127.0.0.1:` 접두), `infisical run` 개발 안내, 마이그레이션 예시, Renovate 설정.
  - 지울 것: 옛 SealedSecrets 도구·인증서 사본, `.app-config.yml`, main 스키마 받기 CI.
  - 템플릿 main의 `app-main`은 결정 5 하드닝이 이미 걸었다. 그 `app-main`을 import한 뒤 교체도 PR로 한다. 템플릿 main은 모든 새 앱의 첫 main 내용이라서다(설계 C.4.7).
- GitHub App 둘. 옛 reader/writer App은 재사용하지 않는다. 권한은 설계 C.4.7 서버 쪽 장치 표를 따른다.
  - 저장소 간 쓰기용 `ukyi-homelab-deploy` (최소 권한). 이 App이 배포 갱신 주체다. homelab에만 설치하고 contents write, pull_requests write, metadata read만 준다. workflows·actions·administration 권한은 없다.
  - 병합용 `ukyi-homelab-merge`. homelab에만 설치하고 contents write, pull_requests write, checks·actions read만 준다.
- 자동 병합 범위 (D-07, 확정(사용자 2026-10-18, T05)). 배포 App이 앱 기본 브랜치 빌드에서 만든, 한 앱의 `image.yaml` digest·revision만 바뀐 PR만 자동 병합한다. 조건에 작성 주체(배포 갱신 App), 브랜치, 내용(한 앱의 digest만)을 함께 넣는다. 조건은 설계 C.4.7의 9개이고 `.github/workflows/README.md`에 같은 목록을 공개한다. GitHub auto-merge 허용은 끈다. 나머지 PR은 사람이 검토 후 병합한다.
  - 서버 쪽 강제: ruleset A `main-checks`, B `main-review`, C `deploy-branches`, D1 `release-tags-lock`, D2 `release-tags-create`, 앱 저장소와 `homelab-app-template`의 `app-main`, `workflow_run` 병합 워크플로 `deploy-merge`, App 2개와 키별 Infisical 프로젝트(설계 C.4.7).
  - 배포 PR은 앱 저장소 기본 브랜치의 빌드에서만 만든다. PR과 비기본 브랜치의 CI에는 저장소 간 쓰기 키를 주지 않는다.
  - 봇 변경 PR 신원(D-24)의 PR은 내용이 digest만 바뀌어도 자동 병합되지 않는다 (AC-P8).
  - 조건 5는 이미지 라벨과 함께 attestation 출처를 확인한다: `gh attestation verify oci://ghcr.io/ukyi-app/<app>@<digest> --repo ukyi-app/<app> --cert-identity-regex '^https://github\.com/ukyi-app/homelab/\.github/workflows/app-build\.yaml@refs/tags/app-build-v' --source-ref refs/heads/main --source-digest <revision> --deny-self-hosted-runners`. attestation은 `app-build`의 deploy-pr job이 앱 main push 실행에서 늘 만들고, 실패하면 배포 PR을 만들지 않는다(설계 C.4.7 조건 5, U30).
  - owner PR은 검토한 SHA를 고정해 관리자 bypass로 병합한다: `gh pr merge <n> --squash --admin --match-head-commit <검토한 SHA>`. bypass 모드 `exempt`는 쓰지 않고, bypass 기록은 월 1회 PR 작성자와 대조한다(설계 F D-07).
- App 키 전달 (D-04). 배포 App 키는 Infisical OIDC identity `gha-homelab-deploy`로 받는다. 병합 App 키는 원본을 Infisical 프로젝트 `homelab-ci-merge`에 두고, Secret Sync로 environment secret 사본 1개를 만든다. `gha-homelab-merge` identity는 만들지 않는다.
  - Secret Sync: 대상 GitHub, Scope Repository Environment(`ukyi-app/homelab` / `automerge`). Auto-Sync 켬, Key Schema 비움, 삭제 켬, sync 1/10.
  - App Connection: GitHub App이 아니라 `homelab` 하나로 좁힌 fine-grained PAT(Metadata read, Environments RW, Secrets RW, 만료 없음: 사용자 2026-10-21). 대가: owner 계정에 묶임, Infisical에 PAT 저장, 새면 회수할 때까지 유효함, org가 fine-grained PAT를 허용해야 함. sync 실패 알림은 프로젝트 Admin 메일로 온다.
  - environment `automerge`: 배포 브랜치 정책 main, `prevent_destroy`. 다시 만드는 일은 Terraform apply로만 하고 그 뒤에 Sync를 다시 실행한다. `prevent_destroy`는 콘솔 삭제를 막지 못하고, 지워진 뒤 `deploy-merge`가 돌면 정책 없는 `automerge`가 자동으로 다시 생긴다. 그래서 Sync 재실행·병합 키 회전·PAT 교체는 모두 `tools/tf-github.sh verify`(T12 뒤 `homelab github verify`) exit 0을 첫 단계로 한다(설계 C.4.8, C.6.5).
  - `deploy-merge`: `on`은 `workflow_run`(ci completed)만. merge job에 `environment: {name: automerge, deployment: false}`, `actions/create-github-app-token`에 `secrets.HOMELAB_MERGE_KEY`. Infisical OIDC 단계는 없다.
  - ci의 workflow-guard: YAML 별칭까지 푸는 파서로 읽는다. environment 이름은 대소문자를 무시하고 문자열형과 객체형을 모두 잡는다. environment 이름에 표현식을 쓰지 못하게 한다. `automerge`는 `deploy-merge.yaml`의 merge job만 쓴다. `deploy-merge` 트리거는 `workflow_run`만이다. `secrets: inherit`와 로컬이 아닌 reusable 호출을 금지한다. `toJSON(secrets)`와 동적 secrets 참조를 금지한다. 금지마다 음성 fixture를 둔다.
  - D-26 조건 (2)를 "environment secret을 쓰는 워크플로는 `workflow_run`만"으로 넓힌다.
  - D-07이 자동 병합을 두기로 확정돼(T05) 병합 App 키, Secret Sync, environment `automerge`는 유지된다. identity는 4/5다.
- D-26 조건 다섯 (확정(사용자 2026-10-18, T05). (5)는 2026-10-22 사용자 결정으로 더함, 설계 F D-26). Codex Connector는 유지한다.
  - (1) homelab과 앱 저장소의 어떤 ruleset bypass에도 넣지 않는다.
  - (2) 시크릿을 쓰는 `workflow_dispatch` 워크플로를 두지 않고, environment secret을 쓰는 워크플로는 트리거를 `workflow_run` 하나만 둔다. ci의 workflow-guard가 확인한다.
  - (3) 배포 키는 앱 main push의 태그 고정 `app-build`만 OIDC claim으로 꺼낸다. 병합 키는 environment `automerge`(배포 브랜치 main)의 secret이라 `deploy-merge`의 merge job만 쓴다.
  - (4) 앱 저장소는 public만 두고 그 main과 `homelab-app-template` main에 `app-main`을 건다. 자동 배포는 `app-main`이 active로 확인된 앱에서만 일어난다(조건 9).
  - (5) homelab과 앱 저장소(`homelab-app-template`, `homelab-probe`, `files`, `homelab-bot`(`infra/github/app-repos.json`의 앱 저장소), 이후 새 앱)에 Codex 클라우드 작업 환경(environment)을 두지 않는다. 리뷰(`@codex review`, 자동 리뷰)와 로컬 Codex CLI는 환경 없이 쓴다. 환경이 없으면 `@codex` 작업이 시작되지 않아 Codex가 owner 권한으로 병합 API를 부르는 길이 없다(U37). 만들게 되면 그 전에 U37을 다시 시험한다.
  - 설치 범위 축소는 확정(사용자 2026-10-18, T15): 선택 저장소로 줄이고 `homelab-bot-ops`를 뺀다. 사람 작업이고 T15에서 했다(2026-10-18 17:45 완료, spec §11, D-16). Codex 쪽 미검증 U21(Draft·배포 App PR의 자동 리뷰 건너뛰기), U37(owner 권한 병합), U38(외부인 호출)을 이 티켓에서 시험해 기록한다(설계 부록 1).
- GitHub 보호 설정 (D-28). Terraform root `infra/github`로 선언한다. 새 App ID 기준으로 필수 검사, main 보호, ruleset을 새로 정의한다. 옛 것은 T06이 지운다. org가 Free 플랜이라 브랜치 보호와 ruleset은 public 저장소에서만 동작한다(D-23, D-29).
  - 리소스는 `github_repository_ruleset`, `github_repository_environment`(+ deployment policy), `github_actions_repository_permissions`, `github_workflow_repository_permissions`만 쓴다. `github_repository`와 시크릿 리소스는 두지 않는다. 저장소 설정(`allow_auto_merge=false`, squash만, 병합 뒤 삭제 등)은 guard로 확인만 하고 값은 `gh api`로 맞춘다. fork PR 승인 정책은 provider가 지원하지 않아 `gh api` PUT + guard.
  - App ID는 숫자 리터럴로 쓴다. private App의 ID는 익명 조회가 안 되는 값이라 공개 HCL에 처음 노출된다(자격은 아님). 이 점을 기록한다.
  - 래퍼 `tools/tf-github.sh`(T12부터 `homelab github plan·apply·verify`가 감싼다). 실행은 owner 로컬만이다.
    - `GITHUB_TOKEN`은 환경변수로만 준다(기본 `gh auth token`, 또는 만료 있는 fine-grained PAT. `-var` 금지). `GITHUB_APP_ID`·`GITHUB_APP_INSTALLATION_ID`·`GITHUB_APP_PEM_FILE`, `TF_CLI_ARGS`·`TF_CLI_ARGS_*`, `TF_LOG*`은 unset한다. `TF_CLI_CONFIG_FILE`은 unset하지 않고 래퍼가 만든 설정 파일(`provider_installation { direct {} }`만)을 가리키게 한다. unset하면 `~/.terraformrc`의 `dev_overrides`가 다시 쓰인다.
    - 토큰 종류를 먼저 가른다. classic·OAuth 토큰은 `X-OAuth-Scopes`를 끝까지 읽은 뒤 비어 있거나 `delete_repo`가 있으면 거부한다(pipefail·SIGPIPE로 열린 채 실패하지 않게). fine-grained PAT는 그 머리글이 없으므로 만료 머리글을 확인한다. 이 경로에는 저장소 삭제 방어가 없다(ruleset에 필요한 Administration write가 삭제 권한도 준다). 그 밖의 토큰은 거부한다. plan 전에 `permissions.admin`이 `true`인지 본다.
    - 작업 사본에서 돌지 않는다. `git fetch origin main` 뒤 `origin/main`을 `git worktree add --detach`로 만든 임시 사본에서만 plan·apply하고 실행한 SHA를 출력한다. 임시 사본에 `*override.tf*`·`*.tfvars*`가 있으면 거부한다. plan도 코드를 실행하고, `.gitignore`가 숨기는 override 파일은 git status에도 안 보이기 때문이다.
    - `plan`과 `verify`는 `-lock=false`(R2에 잠금을 쓰지 않음, AC-P13). `apply`만 잠금을 잡는다.
    - `rm -f tfplan` 뒤 plan한다. 종료 코드는 0·2만 허용한다. plan에 delete가 있으면 `--allow-destroy` 없이는 멈춘다.
    - apply 전에 state pull로 백업한다(R2는 versioning이 없다). apply가 실패하면 그 plan의 ruleset을 `state rm` 뒤 import한다(provider v6.13.0 #3519 etag 버그 대응, 수정 #3637 미출시).
    - provider는 6.13.0 정확 핀(legacy client)이다. `.terraform.lock.hcl` 변경은 사람이 확인한다.
  - guard는 `check` 블록이 아니라 `github_rest_api` 데이터 소스 postcondition이다(실패 시 plan 오류). 관리 자원 내용을 보는 guard(ruleset 둘, environment 하나)에만 그 자원에 대한 `depends_on`을 걸고, 나머지(토큰 admin, 저장소 설정, `codeowners/errors`, 옛 보호 404, fork 정책, public 저장소 완결성)는 걸지 않아 plan 때 늘 평가한다. 그래야 admin이 아닌 토큰이 ruleset 변경 예정과 상관없이 plan 오류로 멈춘다. public 저장소 완결성의 기대 집합은 homelab + `homelab-app-template` + `app-repos.json`(봇 저장소 포함)이다. 대조 항목: 토큰 admin 여부, 저장소 설정, 저장소별 ruleset 이름 집합과 개수, ruleset별 bypass 허용 목록과 exempt 금지, `codeowners/errors` 빈 배열, 옛 브랜치 보호 404, fork PR 승인 정책, org public 저장소 완결성, environment `automerge`의 브랜치 정책 `[main]`과 secret 이름 집합(`[]` 또는 `[HOMELAB_MERGE_KEY]`. Sync 전 빈 상태는 받아들인다), repo secret 0개, org secret 0개. 병합 키 Sync는 첫 apply 1단계로 environment가 생긴 뒤, 2단계 전에 만든다. guard 실패가 모든 apply를 막을 때의 비상 경로(`-target` 재생성 뒤 전체 verify)를 런북에 둔다.
  - state: R2 `homelab-tfstate`의 `v2/github/terraform.tfstate`, `use_lockfile = true`. R2 키는 Infisical `homelab-admin`의 `/terraform/state`에서만 받는다. 동시 실행 시험(U02)은 T08a에서 하고, 이 root의 첫 apply는 그 뒤에 한다.
  - CI: `terraform fmt -check`, `terraform init -backend=false`, `terraform validate`, `terraform test`(mock_provider. run 블록은 `command = apply`. 모든 guard 인스턴스에 정상 JSON override를 준 뒤 하나만 망가뜨린다), `*override.tf*`·`*.tfvars*` 커밋 거부. CI에서 plan은 하지 않는다.
  - import: T06의 `main-interim`과 T07의 `ci` ruleset은 `gh api`로 만든 것이다. 이 티켓에서 import하고 `ci`는 제자리에서 `main-checks`로 이름을 바꾼다. 결정 5(명세 §5.1, 2026-10-18 실행)로 `files`·`homelab-app-template`에 먼저 건 `app-main`(ruleset id `files` 25327498, `homelab-app-template` 25327516), T14가 2026-10-18에 만든 봇 저장소 `homelab-bot`의 `app-main`(ruleset id 25332733)도 새로 만들지 않고 import한다(봇 저장소는 `app-repos.json`에도 넣는다).
  - `app-main`은 `app-repos.json`의 `for_each`로 `homelab-app-template`·`homelab-probe`·`files`에 적용한다(래퍼로). `files`는 남은 public 앱 저장소라 목록에 있어야 guard 8을 통과한다. 대상 저장소마다 main의 `CODEOWNERS`(`* @<owner 계정>`)와 `app-main` 규칙을 대조한다: `codeowners/errors` 빈 배열, `pull_request` 규칙의 `require_code_owner_review`·`dismiss_stale_reviews_on_push`가 `true`(설계 C.4.7 조건 9, C.8 리뷰 전용 App 줄).
  - 첫 apply는 두 단계다(설계 E5). 1단계 PR은 `main-interim`을 active 그대로 import하고 ruleset A~D를 만든다. apply 뒤 ruleset B가 active이고 main에 그 `pull_request` 규칙이 걸린 것을 확인한다. 2단계 PR에서 `main-interim`을 `disabled`로 바꾼다. 한 apply로 하면 병렬 적용이나 부분 실패(#3519) 때 main에 필수 검사만 남는 공백이 생긴다.
  - 무인 부분 감시(기본 `GITHUB_TOKEN`으로 ruleset 목록·rules·`updated_at` 비교)는 선택지로만 둔다.
- 늦게 끝난 빌드가 최신 배포를 덮지 않는 장치(설계 C.4.3).
- 리뷰 전용 App을 저장소별로 추가 설치할 수 있는 구조 (봇용 여지, AC-P12). 실제로 저장소별 추가 설치가 되는지 확인한다. 이미 org 전체 저장소에 쓰기 권한으로 설치돼 PR을 자동 리뷰하는 ChatGPT Codex Connector와의 공존은 D-26을 따른다.
- 앱 저장소는 public만 허용한다 (D-29). private 앱 경로를 두지 않는다.
  - deploy-pr job에 visibility 분기를 두지 않고 attestation을 항상 만든다. GHCR pull 자격(classic PAT, imagePullSecrets, ExternalSecret)을 두지 않는다. 자동 병합 조건 9(public + `app-main` active + `CODEOWNERS` 유효)는 fail-safe로 남긴다.
  - GHCR 패키지: `GITHUB_TOKEN`으로 만든 패키지가 저장소 가시성을 물려받는지 문서끼리 어긋난다. org Package Creation의 Public 허용을 확인한 뒤 `homelab-probe` 첫 push로 시험한다. 안 되면 앱마다 첫 push 뒤 UI에서 Public으로 바꾼다. 이 전환은 되돌릴 수 없다(public 패키지는 다시 private이 안 된다).
  - public 앱 저장소 기본 설정: org와 저장소의 fork PR 승인 `all_external_contributors`, secret scanning·push protection 켬, private vulnerability reporting 켬, 로그 보존 단축 검토. interaction limits `collaborators_only`(6개월마다 갱신)와 PR 생성 Collaborators only는 Codex 외부 호출 시험 대신 2026-10-22에 먼저 걸었다(U38, 설계 부록 1).
  - 배포 이미지 빌드(push job)는 캐시 없이 한다. D-23 금지 항목(tailnet 이름, Tailscale IP 등)을 앱 저장소의 코드·로그·이미지까지 넓히고, 템플릿 CI에 금지 패턴 검사를 둔다.
- 공개 저장소 위협 점검: fork PR, `pull_request_target`, self-hosted runner, GHCR 패키지 공개 여부를 설계에 맞춰 점검한다. 설정을 바꿀 때는 사람 승인을 받는다.
- Actions 허용 범위(`allowed_actions`)를 설계에 맞춘다. 저장소 Actions는 T07이 다시 켠다. 옛 값(`all`)으로 켜졌으면 이 티켓에서 설계 값으로 바꾼다(사람 승인).
- Renovate (D-18, 확정(사용자 2026-10-18, T05)). 호스팅형 Renovate App을 homelab과 앱 저장소에 저장소별로 설치한다. 자동 병합은 모두 끈다. Renovate PR은 자동 병합 조건 밖이라 code owner 승인 뒤 사람이 병합한다. ESO는 주 1회 묶음으로 받는다. 설치 전에 호스팅형 App의 이용 조건(U20)을 확인한다. 맞지 않으면 self-hosted Renovate를 homelab과 분리한 별도 저장소 Actions로 돌린다(설계 F D-18, 부록 1).
- 시험 자산(설계 E5).
  - 손으로 등록하는 시험 앱 저장소 `ukyi-app/homelab-probe`. 템플릿에서 `gh repo create --public --template`로 만든다. T11·T12가 이어 쓰고, T12 끝에 등록과 데이터를 지운다. T13의 `homelab-smoke`는 T13이 CLI로 새로 만든다.
  - 봇 신원 대신 쓸 시험 App `ukyi-homelab-bot-standin`. homelab과 `homelab-probe`에 설치한다. 시나리오 15 뒤 2026-10-21 App째 삭제했다(마지막 키는 따로 지울 수 없다). T13은 새 이름으로 다시 만든다.
- 외부 변경(App 생성·설치, Terraform github root apply, Actions 허용 범위, Secret Sync·App Connection, GHCR 패키지 Public 전환, Renovate 설치, `homelab-probe` 생성, 템플릿 내용 교체)은 사람 승인 뒤에 하고 [../approvals.md](../approvals.md)에 기록한다 (AC-X2).
- T07에서 넘긴 주의(2026-10-19, T07 작성 중 발견):
  - AppProject `apps`는 T07이 `platform/root/templates/project-apps.yaml`로 미리 만들었고, 설계 C.3.3 표대로 cluster-scoped kind를 모두 막는다. ApplicationSet이 `CreateNamespace`·`managedNamespaceMetadata`로 `app-*` ns를 만들면 Argo CD의 sync 권한 검사가 그 Namespace를 거부할 수 있다(추측). 이 티켓에서 확인하고 정한다.
  - 같은 허용 목록에 ReplicaSet·Pod가 없으면 Argo CD UI 트리에서 Deployment·Job의 자식이 안 보였다(옛 실측 `2d2054a:platform/argocd/root/projects.yaml:23-24`). 넣을지 이 티켓에서 정한다.
  - AppProject `apps`·`data`의 위치: 설계 C.1은 `platform/appsets/`인데 T07은 root 템플릿에 프로젝트마다 파일 하나로 두었다. 옮길지는 이 티켓(`data`는 T11)이 정한다.
  - T07의 최소 `ci`는 `kustomize build platform/argocd`가 raw.githubusercontent.com에서 install.yaml을 받고, 도구 넷을 GitHub Releases에서 받는다. 그쪽이 장애면 `ci`가 빨개지고, bypass 없는 `ci` 필수 검사가 급한 수정까지 막는다(설계 C.4.6이 외부 레지스트리 조회를 필수 검사에서 빼는 이유와 같은 종류, P27·R10). install.yaml을 sha256과 함께 벤더링할지 이 티켓에서 정한다.

## 필요한 자격

- owner의 GitHub 토큰: `infra/github` plan·apply·verify와 저장소 설정·fork PR 정책 `gh api`에 쓴다. 기본 `gh auth token`, 또는 만료 있는 fine-grained PAT다. 환경변수로만 준다. 준비: 사람(owner).
- R2 state 키(`homelab-tfstate`): Infisical `homelab-admin`의 `/terraform/state`에서만 받는다. 준비: T09.
- Infisical 프로젝트 `homelab-ci-deploy`·`homelab-ci-merge`와 배포 키 OIDC identity `gha-homelab-deploy`: 준비 T09(OIDC Free 사용 확인 U05 포함). `homelab-ci-merge`에는 machine identity가 없다.
- App `ukyi-homelab-deploy`·`ukyi-homelab-merge`의 키: 이 티켓에서 App을 만들고 키를 키별 Infisical 프로젝트에 등록한다(배포 키는 `homelab-ci-deploy`, 병합 키는 `homelab-ci-merge`).
- Infisical GitHub 연결용 fine-grained PAT(homelab만, Metadata read, Environments RW, Secrets RW, 만료 없음. 사용자 2026-10-21): 이 티켓의 사람 작업. org가 fine-grained PAT를 허용하는지 먼저 확인한다. 병합 키 sync는 1단계 apply로 environment가 생긴 뒤, 2단계 전에 만든다.
- 시험 App `ukyi-homelab-bot-standin`·`ukyi-homelab-review-probe`의 키: 이 티켓에서 쓰기 직전(`homelab-probe` 생성 때와 종단 시험 때)에 만들고, 시험이 끝나면 지운다. 키가 오래 살지 않게 하려는 것이다.
- 시나리오 7 배포 흐름 부분의 장애 주입: `eso-homelab`의 시험용 두 번째 Universal Auth client secret. T09의 "시험용 client secret 장애 주입" 방법을 따라 시험 때 발급하고 폐기한다(승인 기록). 운영 client secret은 폐기하지 않는다. `homelab-probe`의 시험 키 값은 사람이 Infisical `homelab`/`prod`에 만든다.
- 콘솔 작업: Renovate App 설치, org Package Creation의 Public 허용 확인(REST로 읽을 수 없어 화면에서).

## 완료 조건

- 아래 CLI 없는 동등 절차로 시나리오 1(첫 배포. DB·공개 URL 없이), 11(빌드 순서 역전), 15(조건 밖 PR은 승인 뒤 병합)와 시나리오 7의 배포 흐름 부분(T09가 넘긴 것)을 통과한다. 공개 URL 확인은 T13이 한다.
- 배포 갱신 주체가 아닌 신원의 digest PR이 자동 병합되지 않는다 (AC-P8).
- 리뷰 전용 App의 저장소별 설치를 확인했다(설계 C.8, AC-P12).
- 설계 C.8 읽기 전용 접근 줄의 CI 검사(L30)가 verb·roleRef를 어긴 시험 매니페스트를 거부한다(T08b가 넘긴 것).
- `tools/tf-github.sh verify`가 exit 0이다(guard 오류 없음, 변경 없음. 대상 homelab, `homelab-app-template`, `homelab-probe`, `files`).
- `infra/github`의 `terraform test`가 CI에서 통과한다.
- `main-interim`이 `disabled`이고, 그 전에 1단계 확인(ruleset B active, main에 `pull_request` 규칙)을 기록했다.
- environment `automerge`에는 Secret Sync가 만든 `HOMELAB_MERGE_KEY` 하나만 있고, repo secret과 org secret은 0개다(guard). 그 secret의 `updated_at`이 sync 생성 뒤다.
- workflow-guard가 음성 fixture를 모두 거부한다.
- `homelab-probe` 첫 push의 GHCR 패키지가 Public이고 익명 pull 토큰 응답이 200이다. 상속이 안 돼 UI에서 바꿨으면 그 기록이 approvals.md에 있고, 앱마다 같은 손 작업을 런북에 적었다(U39).
- 어느 항목도 T12의 CLI나 T08a의 공개 경로를 쓰지 않는다.

## 검증

설계 E5 표 아래 "CLI 없는 동등 절차"를 따른다. CLI는 T12에서 생기므로 G의 명령에서 `homelab-smoke`를 `homelab-probe`로, `homelab github verify`를 `tools/tf-github.sh verify`로 바꾼다. CLI 경로 재확인은 T12, CLI와 공개 URL을 포함한 전체 실행은 T13이 맡는다.

- `homelab-probe`로 시나리오 1을 실행한다: main 커밋 → `app-build` 요약이 "미등록"이고 homelab에 PR 없음 → 사람이 `apps/homelab-probe/values.yaml`(`public` 없이)과 `image.yaml`(그 빌드의 digest·revision, `hold: false`)을 손으로 써서 PR, 검토 후 관리자 bypass 병합 → G 시나리오 1의 Argo CD·imageID·tailnet 불통 확인 → 공개 URL 대신 `kubectl -n app-homelab-probe port-forward svc/homelab-probe 18080:<서비스 포트>` 뒤 `curl -sf http://127.0.0.1:18080/healthz` → 두 번째 커밋의 `deploy/homelab-probe` PR이 `ukyi-homelab-merge`로 자동 병합되고 새 revision이 배포됨.
- 시나리오 7의 배포 흐름 부분: `homelab-probe`에 시험 키 하나를 둔 상태에서 시험용 client secret 장애 주입으로 ESO 인증을 끊고 ExternalSecret Ready=False를 본 뒤, main 커밋 → `deploy/homelab-probe` PR 자동 병합 → 새 revision 파드 Ready, Application Healthy → 부트스트랩 Secret을 원래 client secret으로 되돌림 → Ready 복귀. 경보는 보지 않는다(T08b가 본다).
- 빌드 두 개의 완료 순서를 바꿔 시나리오 11을 실행한다.
- 공통 차트를 바꾸는 PR로 시나리오 15를 실행한다.
- 배포 갱신 App이 아닌 시험용 신원으로 digest만 바꾼 PR을 열고, 자동 병합되지 않는지 확인한다. 봇 쓰기 신원(D-24)은 T19에서 생기므로 다른 신원으로 시험한다.
- 리뷰 전용 App을 한 저장소에만 추가 설치할 수 있는지 확인한다.
- `terraform test`에서 guard 인스턴스를 하나씩 망가뜨릴 때마다 실패가 나는지 확인한다.
- 래퍼가 `delete_repo` 범위가 있는 토큰, 범위 머리글이 빈 classic 토큰, 만료 없는 fine-grained PAT, `--allow-destroy` 없는 delete plan을 각각 거부하는지 확인한다. 작업 사본에 미추적 `zz_override.tf`를 둬도 래퍼가 그것을 읽지 않는지(임시 worktree 실행) 확인한다.
- admin이 아닌 토큰이 래퍼의 사전 확인에서 멈추는지, 그리고 ruleset 변경이 예정된 상태에서 그 확인 없이 `terraform plan -lock=false`를 직접 돌려도 guard 1 오류로 멈추는지 확인한다.
- 병합 키 회전 절차를 한 번 실행해 environment secret의 `updated_at`이 교체 시각 이후인지 확인한다.
- `gh api orgs/ukyi-app/installations`로 App 설치 범위를 확인한다. 배포·병합 App은 homelab만, Renovate는 고른 저장소만이다. 봇 신원 대역 시험 App `ukyi-homelab-bot-standin`(homelab과 `homelab-probe`)은 2026-10-21 삭제했으므로 지금 조회하지 않고 삭제 전 증거로 본다: approvals 2026-10-21 14:57~15:02 행(설치 사용자 보고)과 15:05~15:30 행(그 App 토큰으로 두 저장소에 push·PR 시도). 리뷰 전용 App 구조도 시험 App `ukyi-homelab-review-probe`를 2026-10-21 20:26 지웠으므로 삭제 전 증거로 본다: approvals 20:12 행(`homelab-probe` 하나에만 설치)과 20:20~20:24 행(설계 C.8 리뷰 전용 App 줄의 명령으로 `repository_selection` → `selected`, 설치 토큰의 `GET /installation/repositories` → 그 저장소 하나). 다시 볼 때는 실제 리뷰 App(T17)으로 같은 명령을 쓴다.
- `homelab-probe` 첫 push 뒤 `gh api orgs/ukyi-app/packages/container/homelab-probe --jq .visibility`와 `curl -s -o /dev/null -w '%{http_code}' 'https://ghcr.io/token?scope=repository:ukyi-app/homelab-probe:pull'` → 200을 기록한다.
- 이 단계에서 확인할 항목(2026-10-22 남은 것): Renovate가 대책(PR 생성 Collaborators only) 아래에서 대시보드를 갱신하고 PR을 여는지(다음 job, 주 진행자가 본다). U37의 다른 저장소(`homelab-app-template`, `homelab-probe`, `files`, `homelab-bot`) 작업 환경 부재(사용자 확인 대기). U30의 main 밖 이미지 거부는 T13(시나리오 15-11). 결과가 틀리면 부록 1의 "틀리면" 열대로 간다.
- 확인한 항목(2026-10-21, 설계 부록 1의 결과와 같다): U39 통과(`homelab-probe` 첫 push로 만든 패키지가 `public`, 익명 토큰으로 manifest 200). U05의 배포 키 실동작(`homelab-probe` 첫 main push에서 `app-build@app-build-v1.0.0`의 deploy-pr이 배포 키를 받음. Infisical Subject를 GitHub 불변 형식으로 바꾼 뒤, 설계 B.8 E5). 시나리오 15의 U05 재확인: `homelab-probe` 시험 브랜치 워크플로의 OIDC 토큰으로 `gha-homelab-deploy` 로그인 → 403(approvals 15:05~15:30 행).
- 래퍼 음성 시험(위 두 줄): `delete_repo` 범위·`admin:org` 없는 범위·빈 범위 머리글 토큰, 만료 없는 fine-grained PAT, 모르는 토큰 종류, admin이 아닌 토큰, `--allow-destroy` 없는 delete plan, 작업 사본의 미추적 `zz_override.tf`는 ci 단계 `tf-github wrapper`(`tools/tf-github.test.sh`, 가짜 gh·infisical·terraform)가 PR마다 거부를 확인한다. 실제 토큰의 `terraform plan -lock=false` 직접 실행도 2026-10-21 통과했다: owner admin 토큰 대조 exit 2(ruleset 1 change), 익명·배포 App 설치 토큰은 exit 1 "guard 1:"(approvals 21:04~21:05 행).
- 확인한 항목(2026-10-21 시나리오 1·11·15, 근거는 approvals 같은 날 행): U09 통과(배포 App 토큰으로 `deploy/s15-wf`에 `ci.yaml`을 바꾼 push 거부, workflows 권한 없음). U25 통과(deploy-merge가 `GITHUB_TOKEN`으로 probe 저장소·`rules/branches/main`·`codeowners/errors`를 읽어 #805·#807을 병합하고, `app-main`을 끈 동안 #811을 조건 9로 멈춘 뒤 켜고 재판정해 병합). U30 정상 경로 통과((1)~(3): `app-build@app-build-v1.0.1`이 만든 attestation을 deploy-merge가 확인해 #805·#807·#811 자동 병합. main 밖 이미지 거부는 미실행, T13). U36 통과(PAT App Connection Sync, `automerge`·`AutoMerge` 선언 job이 `deployment: false`에도 배포 브랜치 정책으로 거부, probe가 homelab 워크플로를 불러 `automerge` 선언 시 키 길이 0). U08 부분 통과(관리자 `--admin`도 `ci` 실패 PR #808 거부 = 관리자 bypass에도 ruleset A 적용, 관리자 역할 bypass로 owner PR 병합 #799·#812).
- 확인한 항목(2026-10-21 U08 나머지·U21, 근거는 approvals 21:01~21:07 행과 설계 부록 1): U08 (가) 통과(병합 App bypass 병합도 `ci` 미보고 #821에서 405 "Required status check "ci" is expected."). U08 (나) 실패(owner가 연 #822에서 bypass 없는 배포 App이 승인한 뒤 같은 토큰으로 병합 200, main b25aac6, #823으로 제거). 대응은 `main-review`·`app-main`의 Restrict updates와 deploy-merge 조건 9의 `update` 확인이다. apply 뒤 재시험 통과(approvals 21:24~21:27·21:27~21:33 행): ruleset 5개 `update` false → true·verify exit 0, (1) owner가 연 #825에서 배포 App 승인 뒤 reviewDecision `APPROVED`·mergeStateStatus `BLOCKED`, 같은 토큰의 병합 405 "Cannot update this protected ref." (2) owner `--admin` 병합 됨(probe #8). (3) 배포 PR #826을 `ukyi-homelab-merge`가 자동 병합, 새 파드 Running. U21 통과(관측: 자동 리뷰가 켜진 homelab에서 배포 App PR 5건·시험 App PR 1건·Draft 2건에 Codex 반응 0).
- 확인한 항목(2026-10-21 리뷰 전용 App 구조, 설계 C.8·AC-P12, 근거는 approvals 20:12·20:20~20:24·20:26 행): 시험 App `ukyi-homelab-review-probe`를 `homelab-probe` 하나에만 설치해 설치 범위 `selected`, 설치 토큰의 저장소 목록은 `homelab-probe` 1개였다. 대상 4저장소(homelab, `homelab-app-template`, `homelab-probe`, `files`) 모두 ruleset bypass에 그 App이 없고 `codeowners/errors` 0, main `pull_request` `[true,true]`. `tools/tf-github.sh verify`(main 646b75a) exit 0. 시험 App 권한에 설계의 issues read가 빠졌지만 설치 범위 시험에는 영향이 없다(실제 리뷰 App은 T17). App과 키는 20:26 지웠다. U20 통과(조건부, 설계 부록 1·F D-18): Mend Community Cloud 무료·저장소 수 제한 없음, 쓰기 권한 위험은 저장소·org secret 0과 environment 제한으로 막는다(설계 B.8 E5 Renovate 행). Renovate 설정은 저장소 루트 `renovate.json`이고 설치는 그 PR 병합 뒤 사람이 한다.
- 확인한 항목(2026-10-21 Renovate 첫 실행, 근거는 각 저장소 Dependency Dashboard): 2026-10-21 20:57 KST(11:57Z) 첫 job. Dependency Dashboard는 homelab #820, `homelab-app-template` #43, `homelab-probe` #7. homelab 대시보드에 설정 경고·오류 절이 없고, Awaiting Schedule 9건(월요일 일정 대기), 감지 매니저는 argocd·asdf·github-actions·npm·pre-commit·regex·terraform이다. `apps/*/image.yaml`과 자기 저장소 `repoURL`(root-prod·root-vm은 의존성 0)은 잡히지 않았다(`renovate.json`의 ignorePaths와 자기 참조 비활성대로).
- 확인한 항목(2026-10-22 U35·U37, 근거는 설계 부록 1의 결과): U35 통과(guard 1이 익명·admin 아닌 토큰에서 plan 오류, guard 3이 선언 밖 ruleset에서 verify exit 1, 변경 없는 verify는 `github_rest_api` 51개를 모두 plan 때 읽고 ruleset 변경 예정이면 `rulesets_homelab`·`bypass_homelab` 7개만 미뤄짐). fine-grained PAT 만료 머리글은 미실행(운영은 classic/OAuth 토큰, 틀려도 거부 쪽). U37 통과(조건부, approvals 2026-10-22 00:17·01:48~01:5x·11:11 행): 시험 PR #828의 `@codex` 병합 요청에 Connector가 "To use Codex here, create an environment for this repo." 답글만 달고 커밋·병합 없음. 조건은 homelab과 앱 저장소에 Codex 작업 환경을 두지 않는 것(사용자 결정, 설계 F D-26 (5))이고, 만들게 되면 그 전에 다시 시험한다. 환경이 없다고 확인한 곳은 homelab뿐이고, 다른 저장소는 사용자 확인 대기다. U38은 시험 대신 대책을 먼저 걸었다(approvals 2026-10-22 11:25·11:27·11:27~11:35 행): org interaction limit `collaborators_only`(만료 2027-04-22T02:25:06Z), 저장소 다섯의 `pull_request_creation_policy` `collaborators_only`. 대책 아래 배포 PR #830 생성·자동 병합과 #829 Codex 리뷰는 정상이었다.

## 되돌리는 방법

설계 E5 "되돌리는 방법"을 따른다.

- ruleset은 HCL에서 enforcement를 `disabled`로 바꿔 apply한다. 급하면 `gh api -X PUT repos/ukyi-app/homelab/rulesets/<id> -f enforcement=disabled` 뒤 HCL을 맞춘다. 그 전에 임시 ruleset `main-interim`을 다시 active로 해 main이 열리지 않게 한다.
- App은 설치를 해제한다.
- 워크플로는 revert PR로 되돌린다.
- 템플릿 저장소의 이전 내용은 git 히스토리에 남는다.
- ruleset은 지우지 않고 `disabled`로만 끈다. 정답은 git의 HCL이다(설계 C.4.7 남는 위험).

## 진행 기록 (2026-10-20, 작성 작업)

**T07에서 넘긴 주의 네 가지의 결정**

- AppProject `apps`와 `CreateNamespace`: Argo CD v3.5.5 소스를 확인했다. `autoCreateNamespace`가 만든 Namespace 작업도 프로젝트 권한 검사를 받아, 허용이 없으면 `managedNamespaceMetadata`가 있는 앱은 매 sync가 "Namespace is not permitted"로 실패한다. `clusterResourceWhitelist`에 Namespace `app-*`(v3.5.5의 name glob)만 더했다.
- ReplicaSet·Pod: 넣었다. 목록에 없으면 리소스 트리에서 Deployment 아래가 빠지고 Argo CD의 파드 로그도 못 본다(v3.5.5 `appcontroller.go`의 트리 필터). 차트는 둘을 만들지 않는다.
- AppProject 위치: T07이 둔 `platform/root/templates/project-apps.yaml`(wave -11)에 남긴다. ApplicationSet은 클러스터 tailnet 접두를 받으려고 작은 Helm 차트 `platform/appsets/apps`로 두었다.
- Argo CD install.yaml 벤더링: 하지 않는다. ci의 `kustomize build`를 3회 재시도한다. Argo CD repo-server도 같은 URL을 받으므로 벤더링하려면 `platform/argocd` 변경이 따로 필요하다.

**설계와 다르게 한 것(설계 문서에 기록)**

- 차트(태그)와 values(main)를 source 둘(`ref: values`)로 나누는 모양은 Argo CD v3.5.5가 거부한다("cannot reference a different revision of the same repository"). ApplicationSet merge 생성기로 `values.yaml`·`image.yaml`을 `helm.valuesObject`에 넣는다(설계 C.3.3). Argo CD 소스의 템플릿 렌더 함수로 실제 렌더해 확인했다.
- 캐시 Valkey subchart(`cache:`)는 `app-chart-v1.0.0`에 없다. T11이 minor로 더한다(설계 C.4.5 표).
- `internal.name`은 Tailscale 기기 이름 규칙대로 문자로 시작·끝난다. 앱 이름은 53자 이하다(Helm 릴리스 이름 상한).
- `terraform test`는 plan 때 평가되는 guard를 `command = plan`으로, 미뤄지는 guard를 run마다 `state_key`를 달리한 `apply`로 본다(설계 C.3.9).
- 자동 병합 조건 9와 guard 5에 CODEOWNERS 규칙 내용 확인(`* @<owner>` 한 줄)을 더했다(설계 C.4.7의 [제안]).

**사람 작업 순서**는 런북 `docs/runbooks-public/github.md`와 이 티켓의 "수행"을 따른다. App ID·client ID·봇 사용자 ID는 App 생성 뒤 채우는 PR이 따로 필요하다(그 전에는 deploy-pr이 입력 확인에서 멈추고 조건 1이 늘 거짓, `infra/github` plan은 validation에서 멈춘다).

