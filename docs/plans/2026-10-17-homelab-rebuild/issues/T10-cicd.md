# T10 CI/CD

- 단계: P2 플랫폼 구축 (재분해 T05 2026-10-18)
- 상태: 대기
- 명세: [../spec.md](../spec.md)
- Blocked by: T07(착수), T09(완료), T08a(`infra/github` 첫 apply만. R2 잠금 시험 U02 뒤)
  - 착수: T07 뒤 바로 시작한다. 차트, 워크플로, `infra/github` HCL 같은 작성 작업은 T09와 병행한다.
  - 완료: T09 뒤. Infisical 프로젝트 `homelab-ci-deploy`·`homelab-ci-merge`와 배포 키 OIDC identity `gha-homelab-deploy`가 있어야 배포 PR이 생기고, 종단 시험(아래 CLI 없는 동등 절차)을 할 수 있다(설계 C.4.8 "T09 → T10 간선의 답").
  - `infra/github` 첫 apply: T08a의 첫 Terraform apply와 R2 잠금 동시 실행 시험(U02) 뒤에 한다. R2 state를 처음 쓰는 단계를 하나로 둔다(설계 E.0).
- 선행 결정: D-04 (확정(사용자 2026-10-18): 배포 키 OIDC, 병합 키 Secret Sync), D-07 (확정(사용자 2026-10-18, T05): 배포 digest PR만 자동 병합, 서버 강제), D-18 (확정(사용자 2026-10-18, T05): 호스팅형 Renovate App 저장소별 설치, 자동 병합 모두 끔), D-21 (확정(사용자 2026-10-18, T05): `homelab-app-template` 재사용, 내용 교체), D-23 (확정: public 유지), D-26 (확정(사용자 2026-10-18, T05): Codex Connector 유지 + 조건 넷), D-28 (확정(사용자 2026-10-18): GitHub 보호 설정 Terraform), D-29 (확정(사용자 2026-10-18): 앱 저장소 public만)
- 참조 결정: D-24 (봇 쓰기 신원, T15에서 결정). T10은 이 신원이 없어도 자동 병합 차단 조건을 설계하고, 시험용 다른 신원으로 검증한다. D-16 (봇 PR 리뷰, T15에서 결정). Codex Connector 설치 범위 축소는 D-16과 함께 본다(D-26).
- 연결 AC: AC-P7, AC-P8, AC-P12
- 수행: 에이전트 + 사람 (GitHub App 2개와 시험 App 생성·설치, Terraform github root apply(owner 로컬), Actions 허용 범위, Infisical Secret Sync와 App Connection용 PAT, GHCR 패키지 Public 전환, Renovate 설치, `homelab-probe` 저장소 생성, 템플릿 내용 교체 승인)

## 목표

앱 저장소 push부터 digest 기반 배포 PR과 병합까지의 흐름을 만든다.

## 범위

- 공통 워크플로와 공유 Helm 차트. 만들 것(설계 E5): `platform/charts/app`과 태그 `app-chart-v1.0.0`, ApplicationSet `apps`와 AppProject `apps`, `.github/workflows/app-build.yaml`과 태그 `app-build-v1.0.0`, 전체 `ci.yaml`, `deploy-merge.yaml`, `.github/workflows/README.md`(자동 병합 조건 공개, AC-P8).
  - 공유 차트는 설계 C.4.5 표의 항목을 낸다. 선택 항목 `serviceAccountName`을 더한다(봇의 `bot-reader`, 설계 C.8). 차트는 SA·바인딩을 만들지 않는다. DB·캐시 연결 env와 마이그레이션 Sync hook Job(`migration.command`, D-22)도 이 차트의 항목이고 T11이 쓴다.
  - 차트 NetworkPolicy의 인터넷 443은 ipBlock `0.0.0.0/0`에 except `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10`(tailnet)을 명시한다. IPv6 허용 줄은 두지 않아 tailnet IPv6 `fd7a:115c:a1e0::/48`도 막힌다. IPv6 허용을 더할 때는 except에 `fd7a:115c:a1e0::/48`을 함께 넣는다(설계 C.4.5 네트워크 행과 "tailnet 차단"). D-11 (a)의 self 규칙이 NUC에서 운영자 기기로 가는 모든 포트를 열어, 빼지 않으면 앱 파드가 NUC 주소로 운영자 기기에 닿을 수 있다(추측, U28). 확인은 시나리오 1의 tailnet 불통이다(앱 라벨을 단 시험 파드에서 운영자 기기의 tailnet 주소 연결 실패, U28).
  - 앱 저장소 쪽 읽기(compare, 기본 브랜치 확인)는 App 토큰이 아니라 deploy-pr job의 `GITHUB_TOKEN`으로 한다. App 설치 토큰은 homelab 쪽(`image.yaml` 읽기, `deploy/<app>` push, PR 생성)에만 쓴다(설계 C.4.8).
  - 전체 `ci`는 platform의 로컬 Helm 차트도 렌더해 검사한다. `root`는 클러스터 값 파일마다, `bot-slot`은 자기 values로 렌더한다(설계 C.4.6). 렌더 결과 정책 검사에 읽기 전용 Role의 verb·roleRef 검사(L30)를 넣는다. T08b가 넘긴 설계 C.8 읽기 전용 접근 줄의 CI 검사다.
- `homelab-app-template`: D-21(확정(사용자 2026-10-18, T05))대로 저장소·이름을 재사용하고 내용을 바꾼다(설계 F D-21).
  - 새 내용: Dockerfile(amd64, `ARG TARGETARCH` 기본값 없음), `/healthz`, `CODEOWNERS`(`* @<owner 계정>`), 짧은 `build.yaml`(공통 워크플로를 태그로 호출, 호출 job에 권한 상한 선언), 로컬 compose(`127.0.0.1:` 접두), `infisical run` 개발 안내, 마이그레이션 예시, Renovate 설정.
  - 지울 것: 옛 SealedSecrets 도구·인증서 사본, `.app-config.yml`, main 스키마 받기 CI.
  - 템플릿 main의 `app-main`은 결정 5 하드닝이 이미 걸었다. 그 `app-main`을 import한 뒤 교체도 PR로 한다. 템플릿 main은 모든 새 앱의 첫 main 내용이라서다(설계 C.4.7).
- GitHub App 둘. 옛 reader/writer App은 재사용하지 않는다. 권한은 설계 C.4.7 서버 쪽 장치 표를 따른다.
  - 저장소 간 쓰기용 `homelab-deploy` (최소 권한). 이 App이 배포 갱신 주체다. homelab에만 설치하고 contents write, pull_requests write, metadata read만 준다. workflows·actions·administration 권한은 없다.
  - 병합용 `homelab-merge`. homelab에만 설치하고 contents write, pull_requests write, checks·actions read만 준다.
- 자동 병합 범위 (D-07, 확정(사용자 2026-10-18, T05)). 배포 App이 앱 기본 브랜치 빌드에서 만든, 한 앱의 `image.yaml` digest·revision만 바뀐 PR만 자동 병합한다. 조건에 작성 주체(배포 갱신 App), 브랜치, 내용(한 앱의 digest만)을 함께 넣는다. 조건은 설계 C.4.7의 9개이고 `.github/workflows/README.md`에 같은 목록을 공개한다. GitHub auto-merge 허용은 끈다. 나머지 PR은 사람이 검토 후 병합한다.
  - 서버 쪽 강제: ruleset A `main-checks`, B `main-review`, C `deploy-branches`, D1 `release-tags-lock`, D2 `release-tags-create`, 앱 저장소와 `homelab-app-template`의 `app-main`, `workflow_run` 병합 워크플로 `deploy-merge`, App 2개와 키별 Infisical 프로젝트(설계 C.4.7).
  - 배포 PR은 앱 저장소 기본 브랜치의 빌드에서만 만든다. PR과 비기본 브랜치의 CI에는 저장소 간 쓰기 키를 주지 않는다.
  - 봇 변경 PR 신원(D-24)의 PR은 내용이 digest만 바뀌어도 자동 병합되지 않는다 (AC-P8).
  - 조건 5는 이미지 라벨과 함께 attestation 출처를 확인한다: `gh attestation verify oci://ghcr.io/ukyi-app/<app>@<digest> --repo ukyi-app/<app> --cert-identity-regex '^https://github\.com/ukyi-app/homelab/\.github/workflows/app-build\.yaml@refs/tags/app-build-v' --source-ref refs/heads/main --source-digest <revision> --deny-self-hosted-runners`. attestation은 `app-build`의 deploy-pr job이 앱 main push 실행에서 늘 만들고, 실패하면 배포 PR을 만들지 않는다(설계 C.4.7 조건 5, U30).
  - owner PR은 검토한 SHA를 고정해 관리자 bypass로 병합한다: `gh pr merge <n> --squash --admin --match-head-commit <검토한 SHA>`. bypass 모드 `exempt`는 쓰지 않고, bypass 기록은 월 1회 PR 작성자와 대조한다(설계 F D-07).
- App 키 전달 (D-04). 배포 App 키는 Infisical OIDC identity `gha-homelab-deploy`로 받는다. 병합 App 키는 원본을 Infisical 프로젝트 `homelab-ci-merge`에 두고, Secret Sync로 environment secret 사본 1개를 만든다. `gha-homelab-merge` identity는 만들지 않는다.
  - Secret Sync: 대상 GitHub, Scope Repository Environment(`ukyi-app/homelab` / `automerge`). Auto-Sync 켬, Key Schema 비움, 삭제 켬, sync 1/10.
  - App Connection: GitHub App이 아니라 `homelab` 하나로 좁힌 fine-grained PAT(Metadata read, Environments RW, Secrets RW, 만료 지정). 대가: owner 계정에 묶임, Infisical에 PAT 저장, 만료 관리, org가 fine-grained PAT를 허용해야 함. sync 실패 알림은 프로젝트 Admin 메일로 온다.
  - environment `automerge`: 배포 브랜치 정책 main, `prevent_destroy`. 다시 만드는 일은 Terraform apply로만 하고 그 뒤에 Sync를 다시 실행한다. `prevent_destroy`는 콘솔 삭제를 막지 못하고, 지워진 뒤 `deploy-merge`가 돌면 정책 없는 `automerge`가 자동으로 다시 생긴다. 그래서 Sync 재실행·병합 키 회전·PAT 교체는 모두 `tools/tf-github.sh verify`(T12 뒤 `homelab github verify`) exit 0을 첫 단계로 한다(설계 C.4.8, C.6.5).
  - `deploy-merge`: `on`은 `workflow_run`(ci completed)만. merge job에 `environment: {name: automerge, deployment: false}`, `actions/create-github-app-token`에 `secrets.HOMELAB_MERGE_KEY`. Infisical OIDC 단계는 없다.
  - ci의 workflow-guard: YAML 별칭까지 푸는 파서로 읽는다. environment 이름은 대소문자를 무시하고 문자열형과 객체형을 모두 잡는다. environment 이름에 표현식을 쓰지 못하게 한다. `automerge`는 `deploy-merge.yaml`의 merge job만 쓴다. `deploy-merge` 트리거는 `workflow_run`만이다. `secrets: inherit`와 로컬이 아닌 reusable 호출을 금지한다. `toJSON(secrets)`와 동적 secrets 참조를 금지한다. 금지마다 음성 fixture를 둔다.
  - D-26 조건 (2)를 "environment secret을 쓰는 워크플로는 `workflow_run`만"으로 넓힌다.
  - D-07이 자동 병합을 두기로 확정돼(T05) 병합 App 키, Secret Sync, environment `automerge`는 유지된다. identity는 4/5다.
- D-26 조건 넷 (확정(사용자 2026-10-18, T05), 설계 F D-26). Codex Connector는 유지한다.
  - (1) homelab과 앱 저장소의 어떤 ruleset bypass에도 넣지 않는다.
  - (2) 시크릿을 쓰는 `workflow_dispatch` 워크플로를 두지 않고, environment secret을 쓰는 워크플로는 트리거를 `workflow_run` 하나만 둔다. ci의 workflow-guard가 확인한다.
  - (3) 배포 키는 앱 main push의 태그 고정 `app-build`만 OIDC claim으로 꺼낸다. 병합 키는 environment `automerge`(배포 브랜치 main)의 secret이라 `deploy-merge`의 merge job만 쓴다.
  - (4) 앱 저장소는 public만 두고 그 main과 `homelab-app-template` main에 `app-main`을 건다. 자동 배포는 `app-main`이 active로 확인된 앱에서만 일어난다(조건 9).
  - 설치 범위 축소는 D-16(T15)과 함께 본다. Codex 쪽 미검증 U21(Draft·배포 App PR의 자동 리뷰 건너뛰기), U37(owner 권한 병합), U38(외부인 호출)을 이 티켓에서 시험해 기록한다(설계 부록 1).
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
  - import: T06의 `main-interim`과 T07의 `ci` ruleset은 `gh api`로 만든 것이다. 이 티켓에서 import하고 `ci`는 제자리에서 `main-checks`로 이름을 바꾼다. 결정 5(명세 §5.1, 2026-10-18 실행)로 `files`·`homelab-app-template`에 먼저 건 `app-main`(ruleset id `files` 25327498, `homelab-app-template` 25327516), T14가 봇 저장소를 이미 만들었으면 그 저장소의 `app-main`도 새로 만들지 않고 import한다(봇 저장소는 `app-repos.json`에도 넣는다).
  - `app-main`은 `app-repos.json`의 `for_each`로 `homelab-app-template`·`homelab-probe`·`files`에 적용한다(래퍼로). `files`는 남은 public 앱 저장소라 목록에 있어야 guard 8을 통과한다. 대상 저장소마다 main의 `CODEOWNERS`(`* @<owner 계정>`)와 `app-main` 규칙을 대조한다: `codeowners/errors` 빈 배열, `pull_request` 규칙의 `require_code_owner_review`·`dismiss_stale_reviews_on_push`가 `true`(설계 C.4.7 조건 9, C.8 리뷰 전용 App 줄).
  - 첫 apply는 두 단계다(설계 E5). 1단계 PR은 `main-interim`을 active 그대로 import하고 ruleset A~D를 만든다. apply 뒤 ruleset B가 active이고 main에 그 `pull_request` 규칙이 걸린 것을 확인한다. 2단계 PR에서 `main-interim`을 `disabled`로 바꾼다. 한 apply로 하면 병렬 적용이나 부분 실패(#3519) 때 main에 필수 검사만 남는 공백이 생긴다.
  - 무인 부분 감시(기본 `GITHUB_TOKEN`으로 ruleset 목록·rules·`updated_at` 비교)는 선택지로만 둔다.
- 늦게 끝난 빌드가 최신 배포를 덮지 않는 장치(설계 C.4.3).
- 리뷰 전용 App을 저장소별로 추가 설치할 수 있는 구조 (봇용 여지, AC-P12). 실제로 저장소별 추가 설치가 되는지 확인한다. 이미 org 전체 저장소에 쓰기 권한으로 설치돼 PR을 자동 리뷰하는 ChatGPT Codex Connector와의 공존은 D-26을 따른다.
- 앱 저장소는 public만 허용한다 (D-29). private 앱 경로를 두지 않는다.
  - deploy-pr job에 visibility 분기를 두지 않고 attestation을 항상 만든다. GHCR pull 자격(classic PAT, imagePullSecrets, ExternalSecret)을 두지 않는다. 자동 병합 조건 9(public + `app-main` active + `CODEOWNERS` 유효)는 fail-safe로 남긴다.
  - GHCR 패키지: `GITHUB_TOKEN`으로 만든 패키지가 저장소 가시성을 물려받는지 문서끼리 어긋난다. org Package Creation의 Public 허용을 확인한 뒤 `homelab-probe` 첫 push로 시험한다. 안 되면 앱마다 첫 push 뒤 UI에서 Public으로 바꾼다. 이 전환은 되돌릴 수 없다(public 패키지는 다시 private이 안 된다).
  - public 앱 저장소 기본 설정: org와 저장소의 fork PR 승인 `all_external_contributors`, secret scanning·push protection 켬, private vulnerability reporting 켬, 로그 보존 단축 검토. interaction limits `collaborators_only`(6개월마다 갱신)와 PR 생성 Collaborators only는 Codex 외부 호출 시험 결과에 따라 정한다.
  - 배포 이미지 빌드(push job)는 캐시 없이 한다. D-23 금지 항목(tailnet 이름, Tailscale IP 등)을 앱 저장소의 코드·로그·이미지까지 넓히고, 템플릿 CI에 금지 패턴 검사를 둔다.
- 공개 저장소 위협 점검: fork PR, `pull_request_target`, self-hosted runner, GHCR 패키지 공개 여부를 설계에 맞춰 점검한다. 설정을 바꿀 때는 사람 승인을 받는다.
- Actions 허용 범위(`allowed_actions`)를 설계에 맞춘다. 저장소 Actions는 T07이 다시 켠다. 옛 값(`all`)으로 켜졌으면 이 티켓에서 설계 값으로 바꾼다(사람 승인).
- Renovate (D-18, 확정(사용자 2026-10-18, T05)). 호스팅형 Renovate App을 homelab과 앱 저장소에 저장소별로 설치한다. 자동 병합은 모두 끈다. Renovate PR은 자동 병합 조건 밖이라 code owner 승인 뒤 사람이 병합한다. ESO는 주 1회 묶음으로 받는다. 설치 전에 호스팅형 App의 이용 조건(U20)을 확인한다. 맞지 않으면 self-hosted Renovate를 homelab과 분리한 별도 저장소 Actions로 돌린다(설계 F D-18, 부록 1).
- 시험 자산(설계 E5).
  - 손으로 등록하는 시험 앱 저장소 `ukyi-app/homelab-probe`. 템플릿에서 `gh repo create --public --template`로 만든다. T11·T12가 이어 쓰고, T12 끝에 등록과 데이터를 지운다. T13의 `homelab-smoke`는 T13이 CLI로 새로 만든다.
  - 봇 신원 대신 쓸 시험 App. homelab과 `homelab-probe`에 설치한다. T13은 `homelab-smoke`에도 설치한다.
- 외부 변경(App 생성·설치, Terraform github root apply, Actions 허용 범위, Secret Sync·App Connection, GHCR 패키지 Public 전환, Renovate 설치, `homelab-probe` 생성, 템플릿 내용 교체)은 사람 승인 뒤에 하고 [../approvals.md](../approvals.md)에 기록한다 (AC-X2).

## 필요한 자격

- owner의 GitHub 토큰: `infra/github` plan·apply·verify와 저장소 설정·fork PR 정책 `gh api`에 쓴다. 기본 `gh auth token`, 또는 만료 있는 fine-grained PAT다. 환경변수로만 준다. 준비: 사람(owner).
- R2 state 키(`homelab-tfstate`): Infisical `homelab-admin`의 `/terraform/state`에서만 받는다. 준비: T09.
- Infisical 프로젝트 `homelab-ci-deploy`·`homelab-ci-merge`와 배포 키 OIDC identity `gha-homelab-deploy`: 준비 T09(OIDC Free 사용 확인 U05 포함). `homelab-ci-merge`에는 machine identity가 없다.
- App `homelab-deploy`·`homelab-merge`의 키: 이 티켓에서 App을 만들고 키를 키별 Infisical 프로젝트에 등록한다(배포 키는 `homelab-ci-deploy`, 병합 키는 `homelab-ci-merge`).
- Infisical GitHub 연결용 fine-grained PAT(homelab만, Metadata read, Environments RW, Secrets RW, 만료 지정): 이 티켓의 사람 작업. org가 fine-grained PAT를 허용하는지 먼저 확인한다. 병합 키 sync는 1단계 apply로 environment가 생긴 뒤, 2단계 전에 만든다.
- 시험 App의 키: 이 티켓에서 만든다.
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

- `homelab-probe`로 시나리오 1을 실행한다: main 커밋 → `app-build` 요약이 "미등록"이고 homelab에 PR 없음 → 사람이 `apps/homelab-probe/values.yaml`(`public` 없이)과 `image.yaml`(그 빌드의 digest·revision, `hold: false`)을 손으로 써서 PR, 검토 후 관리자 bypass 병합 → G 시나리오 1의 Argo CD·imageID·tailnet 불통 확인 → 공개 URL 대신 `kubectl -n app-homelab-probe port-forward svc/homelab-probe 18080:<서비스 포트>` 뒤 `curl -sf http://127.0.0.1:18080/healthz` → 두 번째 커밋의 `deploy/homelab-probe` PR이 `homelab-merge`로 자동 병합되고 새 revision이 배포됨.
- 시나리오 7의 배포 흐름 부분: `homelab-probe`에 시험 키 하나를 둔 상태에서 시험용 client secret 장애 주입으로 ESO 인증을 끊고 ExternalSecret Ready=False를 본 뒤, main 커밋 → `deploy/homelab-probe` PR 자동 병합 → 새 revision 파드 Ready, Application Healthy → 부트스트랩 Secret을 원래 client secret으로 되돌림 → Ready 복귀. 경보는 보지 않는다(T08b가 본다).
- 빌드 두 개의 완료 순서를 바꿔 시나리오 11을 실행한다.
- 공통 차트를 바꾸는 PR로 시나리오 15를 실행한다.
- 배포 갱신 App이 아닌 시험용 신원으로 digest만 바꾼 PR을 열고, 자동 병합되지 않는지 확인한다. 봇 쓰기 신원(D-24)은 T15 뒤에 생기므로 다른 신원으로 시험한다.
- 리뷰 전용 App을 한 저장소에만 추가 설치할 수 있는지 확인한다.
- `terraform test`에서 guard 인스턴스를 하나씩 망가뜨릴 때마다 실패가 나는지 확인한다.
- 래퍼가 `delete_repo` 범위가 있는 토큰, 범위 머리글이 빈 classic 토큰, 만료 없는 fine-grained PAT, `--allow-destroy` 없는 delete plan을 각각 거부하는지 확인한다. 작업 사본에 미추적 `zz_override.tf`를 둬도 래퍼가 그것을 읽지 않는지(임시 worktree 실행) 확인한다.
- admin이 아닌 토큰이 래퍼의 사전 확인에서 멈추는지, 그리고 ruleset 변경이 예정된 상태에서 그 확인 없이 `terraform plan -lock=false`를 직접 돌려도 guard 1 오류로 멈추는지 확인한다.
- 병합 키 회전 절차를 한 번 실행해 environment secret의 `updated_at`이 교체 시각 이후인지 확인한다.
- `gh api orgs/ukyi-app/installations`로 App 설치 범위를 확인한다. 배포·병합 App은 homelab만, 봇 신원 대역 시험 App은 homelab과 `homelab-probe`, Renovate는 고른 저장소만이다. 리뷰 전용 App 구조는 설계 C.8 리뷰 전용 App 줄의 명령으로 본다(한 저장소에만 설치한 시험 App의 `repository_selection` → `selected`, 설치 토큰의 `GET /installation/repositories` → 그 저장소 하나).
- `homelab-probe` 첫 push 뒤 `gh api orgs/ukyi-app/packages/container/homelab-probe --jq .visibility`와 `curl -s -o /dev/null -w '%{http_code}' 'https://ghcr.io/token?scope=repository:ukyi-app/homelab-probe:pull'` → 200을 기록한다.
- 이 단계에서 확인할 미검증 항목: U08의 나머지(bypass 병합 때 ruleset A 필수 검사 적용, App 승인이 code owner 승인을 대신하지 못함), U09, U20, U21, U25, U30, U35, U36, U37, U38, U39, 그리고 시나리오 15에서 U05를 다시 본다(설계 부록 1). 결과가 틀리면 부록 1의 "틀리면" 열대로 간다.

## 되돌리는 방법

설계 E5 "되돌리는 방법"을 따른다.

- ruleset은 HCL에서 enforcement를 `disabled`로 바꿔 apply한다. 급하면 `gh api -X PUT repos/ukyi-app/homelab/rulesets/<id> -f enforcement=disabled` 뒤 HCL을 맞춘다. 그 전에 임시 ruleset `main-interim`을 다시 active로 해 main이 열리지 않게 한다.
- App은 설치를 해제한다.
- 워크플로는 revert PR로 되돌린다.
- 템플릿 저장소의 이전 내용은 git 히스토리에 남는다.
- ruleset은 지우지 않고 `disabled`로만 끈다. 정답은 git의 HCL이다(설계 C.4.7 남는 위험).
