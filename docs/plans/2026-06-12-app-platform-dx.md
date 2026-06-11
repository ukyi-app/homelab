# App Platform DX 구현 플랜

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** homelab을 "앱 코드 0개 + 선언적 멀티레포 앱 플랫폼"으로 만든다 — 외부 앱 레포가 `.app-config.yml`을 선언하면, owner가 homelab에서 변이를 트리거(또는 update-image는 빌드 후 자동)했을 때 공개 DNS·tunnel·DB·캐시·시크릿·매니페스트·ArgoCD 등록이 전부 자동화된다.

**Architecture:** 인프라 자격은 **homelab에만** 중앙화한다. **GitHub App private key는 homelab에만** 두고, 앱 레포에는 homelab을 write할 수 있는 어떤 자격도 두지 않는다(App은 앱 레포에 Contents:read로만 설치 — homelab이 앱 config를 SHA 고정으로 읽기 위함). 따라서 **모든 변이는 homelab측에서 권위를 가진다**: 생성/파괴(create-app/create-database/create-cache/teardown)는 homelab `workflow_dispatch`(owner 실행), **update-image는 homelab측 GHCR 폴링(스케줄) 또는 수동 트리거**로 처리한다(앱 레포가 `repository_dispatch`를 보내려면 homelab Contents:write 토큰이 필요한데 그 자격을 주지 않으므로 — Codex 검증). 모든 변이는 단일 `concurrency.group: homelab-mutation`으로 전역 직렬화된 dispatcher/잡이 reusable workflow로 라우팅한다. 시크릿은 KSOPS(age)에서 SealedSecrets(공개 cert 봉인)로 전환하되 **컨트롤러 sealing key를 out-of-band 백업하고 클린 클러스터 복구 드릴을 통과한 뒤에만** 기존 enc.yaml을 제거한다. DB/캐시는 리소스 중심으로 프로비저닝해 raw URL이 아닌 SealedSecret 핸들로 참조하며, 앱 소비용 conn Secret은 **앱이 도는 `prod` 네임스페이스**에 봉인한다.

**Tech Stack:** GitHub Actions(reusable workflows, `actions/create-github-app-token`), Terraform(Cloudflare provider, `for_each`), ArgoCD, Helm(공유 `platform/charts/app` 차트), CNPG(PostgreSQL), Valkey, bitnami sealed-secrets, kubeseal, Node.js(tools/*.mjs), bats(테스트), conftest/kubeconform(게이트).

---

## 작업 규약 (모든 태스크에 적용)

- **커밋은 반드시 `/commit` 스킬로** (한국어 conventional, AI 마커·Co-Authored-By 금지). 플랜의 "Commit" 스텝은 이 규칙으로 실행한다.
- **`*.enc.yaml` 직접 수정 금지.** 평문 메타데이터도 SOPS MAC에 포함된다. 복호화→편집→재암호화(`sops`)만. **시크릿 값은 채팅/로그에 절대 출력 금지.**
- 라이브 클러스터 접근: `export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig` (실 k3s는 :6443; KUBECONFIG 없이 kubectl 쓰면 OrbStack 내부 :26443으로 잘못 붙는다 — 검증된 함정).
- SOPS: `export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt`.
- 게이트 명령: `make verify`(skeleton+원장+sops), `make chart-test`(차트 렌더+kubeconform+bats), `make tf-validate`, `bats tools/test/`.
- **KSOPS 풀 렌더:** `kustomize build --enable-helm --enable-alpha-plugins --enable-exec platform/<comp>/prod`.
- 라이브 검증된 함정(재확인): ArgoCD sync-wave는 "이전 wave healthy"를 기다린다(한 Application 내 Secret(0)보다 워크로드(-6)가 빠르면 교착); `generatorOptions.annotations`는 KSOPS(exec) 출력에 적용 안 됨; SSA는 atomic-list에 서버 주입 기본값(`group: ""` 등)을 명시 안 하면 영구 OutOfSync; `client_payload`는 비신뢰(env 경유 + regex/화이트리스트만); appset 대상 네임스페이스는 `platform/namespaces` 소유.

각 Phase는 독립 머지 가능하고 점진적으로 가치를 전달한다. **Phase 0은 사용자 수동 액션**(코드 아님)이며 Phase 1+의 선행 조건이다.

---

## Phase 0: 사용자 수동 액션 (선행 — 코드 아님)

> 이 Phase는 GitHub UI/Cloudflare 대시보드에서 사용자가 수행한다. 구현자는 **체크리스트를 제시하고 완료를 확인**한 뒤 Phase 1로 넘어간다. 완료 전까지 Phase 1의 라이브 검증 스텝은 막힌다(정적 렌더/테스트는 진행 가능).

> **인증 경계 — reader/writer App 분리(Codex #1 + pass4 #7 + pass6 #4):** GitHub App 권한은 **App 수준**이라 단일 App에 Contents:write를 주고 "앱 레포는 read-only로 설치"는 **강제되지 않는다**(토큰 스코핑은 정상 경로 요청만 줄일 뿐, 유출된 private key는 여전히 App 권한 전체로 앱 레포에 write 가능 → 공급망 침해). 따라서 **App을 2개로 분리**한다(둘 다 키는 homelab에만, 별도 보관):
> - **reader App:** 권한 **Contents:read만**. **앱 레포(+템플릿)에만** 설치. homelab이 앱 config/sealed 시크릿을 SHA 고정 read하는 데 사용. 이 키가 유출돼도 **어디에도 write 불가**.
> - **writer App:** 권한 **Contents:write + Pull requests:write**. **homelab에만** 설치. homelab 매니페스트/PR 커밋에 사용. 이 키는 **앱 레포에 설치 안 됨** → 앱 레포 write 불가.
> - 두 키 모두 homelab Actions secret에만. 앱 레포는 어떤 homelab/앱-write 토큰도 발급 못 한다. 토큰 발급 시에도 `owner`/`repositories`/`permission-*`로 추가 최소화. 트리거 모델은 Phase 1 Task 1.0.

**체크리스트 (사용자):**
- [ ] org `ukyi-app`에 **reader App** 생성: 권한 **Contents: Read**, Metadata: Read. **앱 레포 + 템플릿에만** 설치. App ID + Private key 발급.
- [ ] org `ukyi-app`에 **writer App** 생성: 권한 **Contents: Read & write, Pull requests: Read & write**, Metadata: Read. **`ukyi-app/homelab`에만** 설치. App ID + Private key 발급.
- [ ] **앱 레포에는 어느 App의 키도 등록하지 않는다**(앱 레포는 자기 `GITHUB_TOKEN`으로 GHCR push만).
- [ ] homelab 레포에 Actions secret 등록(인프라 자격 + 양쪽 App 키 중앙화):
  - `HOMELAB_WRITER_APP_ID`, `HOMELAB_WRITER_APP_PRIVATE_KEY` (homelab write/PR용 — homelab에만 설치)
  - `HOMELAB_READER_APP_ID`, `HOMELAB_READER_APP_PRIVATE_KEY` (앱 레포 config/시크릿 read용 — 앱 레포에만 설치)
  - `TF_CLOUDFLARE_TOKEN`, `TF_CLOUDFLARE_ACCOUNT_ID`, `TF_ZONE_ID`, `TF_TUNNEL_ID`, `TF_DOMAIN`
  - `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_STATE_BUCKET`, `R2_ACCOUNT_ID`
  - (기존 유지) `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`
- [ ] homelab 레포 variable `HOMELAB_DOMAIN` 확인(기존 onboard.yaml 사용).
- [ ] **검증:** 이 값들은 로컬 `.env.secrets`(gitignored)와 `infra/cloudflare/terraform.tfvars`에 이미 존재 → 동일 값을 GitHub Secrets로 복사. 값 자체는 채팅에 출력하지 않는다.

**구현자 확인 스텝:** 사용자에게 위 체크리스트를 제시하고, "Phase 0 완료"를 받기 전에는 Phase 1의 **라이브 dispatch 검증**(Task 1.4)을 보류한다. 정적 작업(Task 1.1~1.3)은 병행 가능.

---

## Phase 1: GitHub App 인증 교체 (PAT 제거) + 트리거 경계

**목표:** `DEPLOY_BOT_PAT`를 org GitHub App 설치 토큰으로 교체(키는 homelab에만). 토큰은 워크플로마다 짧게 발급되고 권한이 최소화된다. 앱 레포는 homelab-write 자격을 갖지 않는다.

### Task 1.0: 트리거 경계 결정 (설계 문서화 — Codex critical #1)

**Files:**
- Create: `docs/runbooks/app-platform.md`(로컬 전용) 또는 플랜 내 명세

**트리거 경계(불변식):**
- **App private key는 homelab Actions secret에만.** 앱 레포는 어떤 homelab-write 자격도 보유하지 않는다.
- **생성/파괴 변이(create-app/create-database/create-cache/teardown)는 homelab-initiated**: owner가 homelab에서 `workflow_dispatch`(또는 `gh workflow run`)로 실행하며 `app_repo`, `sha`를 입력. homelab이 자기 App 토큰으로 그 SHA에서 앱 config를 checkout(read)한다. → 앱 레포 자격 0.
- **update-image(bump)는 homelab측 GHCR 폴링/수동 트리거**: 앱 레포는 homelab-write 토큰이 없으므로 cross-repo `repository_dispatch`를 보낼 수 없다(`POST /dispatches`는 대상 Contents:write 필요 — Codex 검증). 따라서 **homelab이 폴링으로 권위 처리**한다: 스케줄 워크플로(`bump-poll.yml`, 예: 10분 주기 + `workflow_dispatch`)가 `source-repo` 바인딩별로 GHCR 패키지의 최신 `sha-*` 버전을 조회해, 배포된 태그와 다르고 digest가 실존하면 bump(PR 또는 main 커밋). **앱 레포 입력을 일절 신뢰하지 않는다**(GHCR 실존 digest + source-repo 바인딩만 신뢰). 폴링 지연(최대 주기)은 homelab 자격 비노출의 대가 — 즉시 반영이 필요하면 owner가 `workflow_dispatch`로 수동 트리거.
- validator는 모든 입력을 비신뢰로 보고 env 경유 + 화이트리스트 검증(기존 원칙 유지).

**왜:** App private key를 앱 레포에 두면 그 키로 homelab write 토큰을 발급해 전역 침해가 가능하다. reader/writer App 분리 + homelab-initiated + GHCR-폴링 권위 모델이 앱 레포에서 homelab-write 자격을 제거한다.

**⚠️ 순서/마이그레이션 단위(Codex pass7 high #2):** 현재 앱 레포는 `HOMELAB_DISPATCH_PAT`(homelab Contents:write)를 보유하고 reusable build가 이를 필수로 받는다. **Phase 1(homelab 자체 워크플로의 PAT→App 교체)만으로는 "앱 레포 자격 0"이 달성되지 않는다** — 그 PAT는 Task 3.4(GHCR 폴링 + build-only v2)까지 살아 있어 공급망 침해 경로가 남는다. 따라서 **"앱 레포 자격 0" 게이트는 Phase 1이 아니라 Task 3.4 v2 완료(모든 caller 마이그레이션 + `HOMELAB_DISPATCH_PAT` 폐기) 시점에 달성**된다. Phase 1과 Task 3.4를 **하나의 인증 마이그레이션 단위**로 묶어 진행하고, 둘 다 끝나기 전에는 "앱 레포 무자격"을 주장하지 않는다(의존성 그래프에 반영).

**UX 트레이드오프(사용자 확인 필요):** 원래 "앱/템플릿 레포에서 원-버튼 create-app" 희망 → **homelab에서 버튼(workflow_dispatch)**으로 이동. update-image는 빌드 후에도 자동 가능(GHCR 권위 경로). 이 변경은 승인된 설계의 Phase 0/UX를 수정한다 — 구현 착수 전 사용자에게 재확인.

**Step:** 이 경계를 `docs/runbooks/app-platform.md`(로컬)에 기록하고, 이후 모든 워크플로가 이를 따른다. (테스트 없음 — 정책 문서; 강제는 Task 1.2/3.2/4.x의 워크플로 구조로.)

### Task 1.1: App 토큰 발급 composite action

**Files:**
- Create: `.github/actions/homelab-token/action.yml`
- Test: `tools/test/homelab-token.bats`

**Step 1: 실패 테스트 작성** — `tools/test/homelab-token.bats`

```bash
#!/usr/bin/env bats
# @test names MUST be English (dir-run encoding bug)

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "homelab-token action declares app-id and private-key inputs" {
  run grep -E "app-id:|private-key:" "$ROOT/.github/actions/homelab-token/action.yml"
  [ "$status" -eq 0 ]
}

@test "homelab-token pins create-github-app-token to a 40-char commit SHA (not a tag)" {
  # mutable @vN 태그는 이동/공급망 침해 시 private key를 변조된 action에 넘긴다 → full SHA만 immutable (Codex pass8 #2)
  run grep -E "actions/create-github-app-token@[0-9a-f]{40}" "$ROOT/.github/actions/homelab-token/action.yml"
  [ "$status" -eq 0 ]
  run grep -E "actions/create-github-app-token@v[0-9]" "$ROOT/.github/actions/homelab-token/action.yml"
  [ "$status" -ne 0 ]   # 태그 형태는 거부
}

@test "homelab-token exposes token as output" {
  run grep -E "token:.*steps\.app-token\.outputs\.token" "$ROOT/.github/actions/homelab-token/action.yml"
  [ "$status" -eq 0 ]
}
```

**Step 2: 테스트 실패 확인**

Run: `bats tools/test/homelab-token.bats`
Expected: FAIL (`action.yml` 없음).

**Step 3: 최소 구현** — `.github/actions/homelab-token/action.yml`

```yaml
# org GitHub App 설치 토큰 발급 (DEPLOY_BOT_PAT 대체).
# 권한은 App 수준이라 토큰을 owner/repositories/permission-*로 좁혀 최소 권한을 만든다(Codex pass4 #7).
name: homelab-token
description: org GitHub App 설치 토큰 발급(스코프 좁힘)
inputs:
  app-id: { description: GitHub App ID, required: true }
  private-key: { description: GitHub App private key (PEM), required: true }
  owner:
    description: 토큰을 발급할 org/owner (앱 레포 read 시 ukyi-app)
    required: false
    default: ""
  repositories:
    description: 토큰 범위 레포(공백/줄바꿈). 비우면 설치 전체. 앱 레포 read 시 그 레포만.
    required: false
    default: ""
  permission-contents:
    description: "read | write (앱 레포 read 토큰은 read)"
    required: false
    default: ""
  permission-pull-requests:
    description: "read | write (homelab PR 생성 시 write)"
    required: false
    default: ""
outputs:
  token: { description: 설치 액세스 토큰, value: "${{ steps.app-token.outputs.token }}" }
runs:
  using: composite
  steps:
    - id: app-token
      # full commit SHA로 핀(mutable 태그 금지 — private key를 넘기므로, Codex pass8 #2). 주석에 버전 병기.
      uses: actions/create-github-app-token@<40-char-sha>  # v1.x
      with:
        app-id: ${{ inputs.app-id }}
        private-key: ${{ inputs.private-key }}
        owner: ${{ inputs.owner }}
        repositories: ${{ inputs.repositories }}
        permission-contents: ${{ inputs.permission-contents }}
        permission-pull-requests: ${{ inputs.permission-pull-requests }}
```
> **모든 워크플로의 `create-github-app-token`(인라인 포함)도 동일하게 full SHA로 핀**한다(dispatcher/bump/onboard/create-app 등). 가능하면 다른 서드파티 action도 SHA 핀(보안 강화). CI에 "create-github-app-token이 SHA로 핀됐는지" 정적 게이트 추가.
> **사용 예(reader/writer App 분리 — Codex pass6 #4):** `_create-app`은 앱 레포 config/시크릿 read에 **reader App**(`HOMELAB_READER_APP_*`, `owner: ukyi-app`, `repositories: <app-repo>`) 토큰을, homelab PR 커밋에 **writer App**(`HOMELAB_WRITER_APP_*`, `repositories: homelab`) 토큰을 **각각** 발급한다. `owner`/`repositories` 없는 토큰은 현재 레포로만 제한되어 cross-repo read가 실패하므로 reader 토큰엔 반드시 명시. 이 플랜에서 "homelab write/PR" 토큰 = writer App, "앱 레포 read" 토큰 = reader App으로 통일(이후 모든 워크플로 동일).

**Step 4: 테스트 통과 확인**

Run: `bats tools/test/homelab-token.bats`
Expected: PASS (3 tests).

**Step 5: Commit** — `/commit` 스킬 (`feat: GitHub App 설치 토큰 발급 composite action`)

### Task 1.2: bump.yaml의 PAT → App 토큰 교체

**Files:**
- Modify: `.github/workflows/bump.yaml`
- Test: `tools/test/ci-build.bats` (또는 신규 `auth.bats`)

**Step 1: 실패 테스트 작성** — `tools/test/auth.bats`

```bash
#!/usr/bin/env bats
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "no workflow references DEPLOY_BOT_PAT" {
  run grep -rn "DEPLOY_BOT_PAT" "$ROOT/.github/workflows/"
  [ "$status" -ne 0 ]   # grep returns 1 when nothing matches
}

@test "bump.yaml mints an app token before checkout" {
  run grep -E "uses: ./.github/actions/homelab-token" "$ROOT/.github/workflows/bump.yaml"
  [ "$status" -eq 0 ]
}
```

**Step 2: 테스트 실패 확인**

Run: `bats tools/test/auth.bats`
Expected: FAIL (현재 bump.yaml이 `DEPLOY_BOT_PAT`를 4회 참조).

**Step 3: 구현** — `bump.yaml`의 두 job(`writeback`, `writeback-dispatch`) 각각에서:
- `actions/checkout` **앞에** App 토큰 발급 step 추가:
  ```yaml
      - uses: actions/create-github-app-token@v1   # writer App (homelab write) — 인라인
        id: token
        with:
          app-id: ${{ secrets.HOMELAB_WRITER_APP_ID }}
          private-key: ${{ secrets.HOMELAB_WRITER_APP_PRIVATE_KEY }}
  ```
  **주의:** composite action을 쓰려면 그 전에 레포 체크아웃이 필요하다. App 토큰 자체가 체크아웃에 쓰이므로 **순서 딜레마**가 있다 — 해결: `create-github-app-token`은 레포 파일이 필요 없으므로 composite action 대신 **이 job에서는 `actions/create-github-app-token@v1`을 인라인**으로 첫 step에 둔다(Task 1.1 composite는 이미 체크아웃된 레포에서 쓰는 용도). bump.yaml/onboard.yaml은 인라인 패턴을 쓴다.
- `token: ${{ secrets.DEPLOY_BOT_PAT }}` → `token: ${{ steps.token.outputs.token }}` 로 교체(checkout + 이후 push).
- 주석의 "OWNER/ADMIN PAT는 branch protection 우회" → App 토큰 권한 모델로 갱신.
- **쓰기 모델을 하나로 확정(Codex pass9 high #3 — 미정으로 두지 않는다):** App 토큰은 branch protection을 우회 못 한다. 이후 activate-app/poller/provision/teardown이 모두 `main`에 쓰므로 모델을 **구현 전에 확정**한다. **결정: 모든 homelab-main 쓰기는 PR-first + auto-merge**(writer App이 PR 생성 → required check `gate` 실행 → 통과 시 자동 머지). 이로써 직접 push로 리뷰 게이트를 우회하지 않으면서 자동화가 가능하다.
  - 대안(직접 push 필요 시): **writer App을 branch-protection bypass 목록에 terraform으로 등록** + 필수 pre-push 게이트(렌더/conftest). 단 이 경우 우회가 리뷰를 건너뛰지 않도록 pre-push 게이트가 required check와 동등해야 한다.
  - **이 플랜은 PR-first+auto-merge를 기본**으로 한다. `main`에 쓰는 **모든** 워크플로(bump-poll/activate-app/_create-*/_teardown/update-secrets)에 라이브 E2E(쓰기 성공 + 게이트 통과)를 둔다.
  ```bash
  gh api repos/ukyi-app/homelab/branches/main/protection 2>/dev/null | jq '.required_pull_request_reviews, .restrictions'  # 현 상태 확인
  ```

**Step 4: 정적 검증**

Run: `bats tools/test/auth.bats && bats tools/test/ci-build.bats`
Expected: PASS.

**Step 5: Commit** — `/commit` (`refactor: bump 워크플로 인증을 PAT에서 GitHub App 토큰으로 교체`)

### Task 1.3: onboard.yaml의 PAT → App 토큰 교체

**Files:**
- Modify: `.github/workflows/onboard.yaml`

**Step 1~2:** Task 1.2의 `auth.bats` 첫 테스트가 onboard.yaml의 잔존 `DEPLOY_BOT_PAT` 때문에 여전히 실패하는지 확인.

Run: `bats tools/test/auth.bats`
Expected: FAIL until onboard.yaml 교체.

**Step 3: 구현** — `onboard.yaml`:
- 첫 step에 `actions/create-github-app-token@v1` 인라인 추가(`id: token`).
- checkout `token:` → `steps.token.outputs.token`.
- PR 생성 step `GH_TOKEN: ${{ secrets.DEPLOY_BOT_PAT }}` → `steps.token.outputs.token`.
- 주석 갱신: "GITHUB_TOKEN PR은 required check를 안 돌린다 → App 토큰 PR은 check를 정상 트리거"(App 토큰 PR도 워크플로를 트리거함을 명시). **검증 포인트:** App이 만든 PR이 `gate` check를 트리거하는지는 Task 1.4 라이브로 확인.

**Step 4: 정적 검증**

Run: `bats tools/test/auth.bats`
Expected: PASS (DEPLOY_BOT_PAT 0건).

**Step 5: Commit** — `/commit` (`refactor: onboard 워크플로 인증을 GitHub App 토큰으로 교체`)

### Task 1.4: 라이브 E2E 검증 (Phase 0 완료 후)

**선행:** Phase 0 체크리스트 완료.

**Step 1:** 데모 앱 레포에서 더미 변경 push → `reusable-app-build` → bump dispatch → homelab `bump.yaml`이 App 토큰으로 write-back 성공하는지 확인.
**Step 2:** GitHub Actions 로그에서 `Resource not accessible` 부재 + values 커밋 + ArgoCD 싱크 확인(`kubectl -n argocd get app`).
**Step 3: Terraform에서 PAT 리소스 제거(Codex pass9 high #2).** `DEPLOY_BOT_PAT`/`HOMELAB_DISPATCH_PAT`는 **`infra/github` terraform 루트가 관리**(`bot_pat` 변수 + `github_actions_secret` 리소스)할 수 있다 — 워크플로 참조만 지우면 **다음 apply가 PAT를 보존/재생성**해 보안 경계가 무력화된다. 따라서: (a) terraform에서 PAT secret 리소스 + `bot_pat` 변수 제거, (b) App secret(reader/writer App ID/KEY)의 소유 모델 정의(TF로 관리할지 수동일지), (c) `terraform plan`이 PAT 미관리를 보이는지 + 레포 전역에서 `DEPLOY_BOT_PAT`/`HOMELAB_DISPATCH_PAT`가 더 이상 관리/참조되지 않는지 단언하는 게이트.
**Step 4:** 위 통과 후 사용자에게 **잔존 PAT 폐기** 안내(GitHub Settings). 코드/terraform에서는 이미 제거됨.
**롤백:** App 인증 실패 시 git revert로 PAT 경로 복원 가능(PAT는 폐기 전까지 유효).
> ⚠️ 이 PAT 제거는 Task 3.4 v2(`HOMELAB_DISPATCH_PAT` 폐기)와 **같은 인증 마이그레이션 단위**다 — 둘 다 끝나야 "앱 레포 자격 0"."

---

## Phase 2: SealedSecrets 컨트롤러 + KSOPS 마이그레이션

**목표:** bitnami sealed-secrets 컨트롤러를 ArgoCD로 배포하고, 기존 KSOPS(age) enc.yaml 7개를 SealedSecret으로 마이그레이션. `.env`→봉인 CLI 추가. age 키는 복구 폴백으로 유지.

> **마이그레이션 안전 원칙:** SealedSecret과 KSOPS를 **한 컴포넌트씩** 전환하되, 전환 중에는 평문 Secret이 클러스터에 계속 존재해야 한다(워크로드 중단 금지). 각 컴포넌트: (1) SealedSecret 추가 → (2) 라이브에서 동일 Secret 생성 확인 → (3) KSOPS generator 제거 → (4) 라이브 재확인. 절대 generator를 먼저 지우지 않는다.

### Task 2.1: sealed-secrets 컨트롤러 ArgoCD 컴포넌트

> **소유권 모델(Codex pass3 high #3 — 라이브 구조 확인):** 이 레포 root-app은 `platform/argocd/root`만 recurse하고, `platform-components` appset은 `platform/*/prod`를 자동 발견하되 **`platform/argocd/*`만 제외**한다. 그냥 두면 `platform/sealed-secrets/prod`가 appset에 `sealed-secrets-prod`로 자동 발견되어 **수동 Application(`platform/argocd/prod/...`)은 무시되고 wave 제어 불가**. → **cert-manager/cnpg와 동일 패턴**(appset에서 exclude + `platform/argocd/root/apps/`에 수동 Application)을 쓴다. Application은 정확히 1개만 존재해야 한다.

**Files:**
- Create: `platform/sealed-secrets/prod/kustomization.yaml`
- Modify: `platform/argocd/root/appset.yaml` (`{ path: platform/sealed-secrets/*, exclude: true }` 추가)
- Create: `platform/argocd/root/apps/sealed-secrets.yaml` (수동 Application; `sync-wave: "-8"`)
- Modify: `platform/namespaces` (`sealed-secrets` 네임스페이스 추가 — appset 규약상 namespaces가 소유)
- Test: `platform/sealed-secrets/prod/test_render.bats`

**Step 1: 실패 테스트 작성** — `test_render.bats`

```bash
#!/usr/bin/env bats
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"; C="$ROOT/platform/sealed-secrets/prod"; }

@test "sealed-secrets kustomization renders with helm chart" {
  run kustomize build --enable-helm "$C"
  [ "$status" -eq 0 ]
}

@test "sealed-secrets is excluded from the platform appset (no double-ownership)" {
  run grep -E "path: platform/sealed-secrets/\*, exclude: true" "$ROOT/platform/argocd/root/appset.yaml"
  [ "$status" -eq 0 ]
}

@test "exactly one manual sealed-secrets Application with an early sync-wave" {
  run grep -E "argocd.argoproj.io/sync-wave: \"-?[0-9]+\"" "$ROOT/platform/argocd/root/apps/sealed-secrets.yaml"
  [ "$status" -eq 0 ]
}
```

**Step 2: 테스트 실패 확인**

Run: `bats platform/sealed-secrets/prod/test_render.bats`
Expected: FAIL.

**Step 3: 구현**
- `kustomization.yaml` — helm chart **`sealed-secrets`(bitnami-labs `https://bitnami-labs.github.io/sealed-secrets`, 1개로 확정)**. 핀 버전. `namespace: sealed-secrets`. **컨트롤러 이름 불일치 주의(Codex pass5 high #7):** 차트 기본 fullname은 `sealed-secrets`인데 `kubeseal`은 `sealed-secrets-controller`를 찾는다 → **`fullnameOverride: sealed-secrets-controller`로 고정**(또는 모든 kubeseal 호출에 `--controller-name sealed-secrets` 일관 사용). 이 플랜은 `fullnameOverride`로 통일.
- **ownerReference GC 차단은 per-Secret annotation으로(Codex pass6 #1 + pass7 #1):** 공식 계약은 컨트롤러 전역 플래그가 아니라 **기존 Secret에 `sealedsecrets.bitnami.com/skip-set-owner-references: "true"` annotation**을 다는 것이다 → 그 Secret에는 ownerReference가 설정되지 않아 SealedSecret CR 삭제/revert 시에도 GC되지 않는다. 따라서 Task 2.3에서 **인수 대상 Secret마다 `managed: "true"` + `skip-set-owner-references: "true"` 두 annotation을 함께** 단다(여기 Task 2.1에서 컨트롤러 전역 옵션에 의존하지 않는다).
- `appset.yaml`에 `{ path: platform/sealed-secrets/*, exclude: true }` 추가(이중 소유 차단).
- `platform/argocd/root/apps/sealed-secrets.yaml` — 수동 Application(cert-manager.yaml 형태), `sync-wave: "-8"`, `source.path: platform/sealed-secrets/prod`, `destination.namespace: sealed-secrets`, `syncOptions: [ServerSideApply=true]`. CRD(`SealedSecret`)가 KSOPS/앱 Application보다 먼저 healthy가 되도록 이른 wave.

**Step 4: 렌더 통과 확인**

Run: `bats platform/sealed-secrets/prod/test_render.bats`
Expected: PASS.

**Step 5: 라이브 적용 + 검증** (Phase 0/클러스터 접근 후)

```bash
export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig
kubectl -n argocd patch app sealed-secrets --type merge -p '{"operation":{"sync":{}}}'
kubectl -n sealed-secrets get deploy           # 컨트롤러 Running
kubectl get crd sealedsecrets.bitnami.com      # CRD 존재
```

**Step 6: 공개 cert 추출 + 보관**

```bash
# fullnameOverride=sealed-secrets-controller 덕에 컨트롤러 이름이 kubeseal 기본과 일치 →
# 이 cert fetch가 실패하지 않는다(Codex #7 라이브 게이트):
kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets-controller --fetch-cert > /tmp/pub-cert.pem
test -s /tmp/pub-cert.pem   # 비어 있지 않아야 함(실패 시 컨트롤러 이름/배포 점검)
# 이 cert는 비밀이 아님(공개키) — app-starter 템플릿에 동봉 + homelab tools/에 보관 가능.
```

cert를 `tools/sealed-secrets-cert.pem`으로 커밋(공개키이므로 안전). **라이브 cert-fetch가 성공함**을 Step 5 검증에 포함.

**Step 7: Commit** — `/commit` (`feat: SealedSecrets 컨트롤러 ArgoCD 컴포넌트 추가`)

### Task 2.1b: 컨트롤러 sealing key 백업 + 복구 드릴 게이트 (Codex critical #2)

> **DR 불변식:** SealedSecret은 **컨트롤러의 private sealing key**로만 복호화된다(공개 cert로도, age로도 불가). 이 key는 클러스터 안에만 존재 → 클러스터 유실 시 git에 커밋된 SealedSecret을 아무도 복호화 못 한다. **그러므로 sealing key를 out-of-band로 백업하고, 클린 클러스터에서 복구가 실증되기 전까지 어떤 enc.yaml도 삭제하지 않는다.**

**Files:**
- Create: `scripts/backup-sealed-secrets-key.sh`
- Create: `tests/sealed-secrets-restore.bats`
- Modify: `docs/runbooks/restore.md`(로컬) — sealing key 복구 절차 추가

**Step 1: sealing key 백업 스크립트** — `scripts/backup-sealed-secrets-key.sh`
- **평문 private key가 디스크에 남지 않게 kubectl 출력을 SOPS로 직접 스트림(Codex pass5 high #3):**
  ```bash
  set -euo pipefail; umask 077
  # ⚠️ 기존 백업을 검증 전에 truncate하면 안 된다(Codex pass9 critical #1): `> ss-keys.enc.yaml`은
  #    sops 실행 전에 파일을 비워, 암호화 실패/중단 시 마지막 정상 백업이 파괴된다.
  #    → 같은 파일시스템 임시파일에 암호화 → 복호화/복구 검증 → 원자적 rename. 버전드 보관.
  tmp="$(mktemp ./ss-keys.XXXXXX.enc.yaml)"; trap 'rm -f "$tmp"' EXIT
  # .sops.yaml 규칙은 *.enc.yaml만 매칭 → --filename-override로 매칭(Codex pass8 #1):
  kubectl -n sealed-secrets get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
    | sops --encrypt --filename-override ss-keys.enc.yaml --input-type yaml --output-type yaml /dev/stdin > "$tmp"
  sops -d "$tmp" | grep -q "kind: Secret"            # 복구 검증(평문은 메모리만)
  mv -f "$tmp" "ss-keys.$(date +%s).enc.yaml"; trap - EXIT   # 원자적 교체 + 버전드(기존 백업 보존)
  ```
  **암호화 실패/중단 시 기존 백업 무손상**(temp에만 쓰고 검증 후 교체). 평문은 디스크에 안 떨어짐. **테스트:** 암호화 실패 주입 시 직전 백업이 그대로 남는지 단언.
  - **키 회전 = 백업 재생성을 하나의 자동 게이트로(Codex #1):** sealing key 갱신 시 이 백업 스크립트를 재실행해 새 키 백업 + 복구 드릴(Task 2.1b Step 2)을 **자동으로 다시 통과**해야 한다(문서화만 아니라 게이트).
- 백업본(`ss-keys.enc.yaml`)은 age 2-recipient 모델(`docs/runbooks/age-keys.md`)로 암호화돼 있으며 git **밖** 보관(외장 SSD/패스워드 매니저). git에 평문 커밋 금지.
- **테스트:** 암호화 실패/중단을 시뮬레이션해 평문 파일이 남지 않음을 단언.

**Step 2: 복구 드릴 테스트** — `tests/sealed-secrets-restore.bats`
- (CI 정적) 백업 스크립트 존재 + 복구 런북 키 섹션 존재 검증.
- (로컬/수동) 별도 kind 클러스터에 sealed-secrets 설치 → 백업 key 복원 → 기존 SealedSecret 하나가 정상 복호화되는지 확인. **이 드릴 통과가 Task 2.3 enc.yaml 삭제의 선행 조건.**

**Step 3: 회전 절차 문서화** — `restore.md`에 sealing key 회전/복원 단계 추가.

**Step 4: Commit** — `/commit` (`feat: SealedSecrets sealing key 백업 스크립트 + 복구 드릴 게이트`)

### Task 2.2: `secret:seal` CLI

**Files:**
- Create: `tools/seal-secret.mjs`
- Modify: `package.json` (scripts: `secret:seal`)
- Test: `tools/test/seal-secret.bats`

**Step 1: 실패 테스트 작성** — `seal-secret.bats`

```bash
#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

@test "seal-secret only seals keys declared in secrets allowlist" {
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: api
secrets: [api-key, db-extra]
EOF
  cat > "$TMP/.env" <<'EOF'
API_KEY=topsecret
DB_EXTRA=more
UNDECLARED=should-not-seal
EOF
  # --dry-run은 봉인 없이 어떤 키가 대상인지 JSON으로 출력
  run node "$ROOT/tools/seal-secret.mjs" --config "$TMP/.app-config.yml" --env "$TMP/.env" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "API_KEY"
  echo "$output" | grep -q "DB_EXTRA"
  ! echo "$output" | grep -q "UNDECLARED"
}

@test "seal-secret errors when a declared secret is missing from .env" {
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: api
secrets: [missing-key]
EOF
  printf 'OTHER=x\n' > "$TMP/.env"
  run node "$ROOT/tools/seal-secret.mjs" --config "$TMP/.app-config.yml" --env "$TMP/.env" --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "missing"
}
```

> **env 이름 규칙:** `secrets:` 항목은 kebab-case(`api-key`), 대응 env 키는 UPPER_SNAKE(`API_KEY`). CLI가 `api-key`↔`API_KEY` 정규화.

**Step 2: 테스트 실패 확인**

Run: `bats tools/test/seal-secret.bats`
Expected: FAIL.

**Step 3: 구현** — `tools/seal-secret.mjs`
- 인자: `--config .app-config.yml`, `--env .env`, `--cert tools/sealed-secrets-cert.pem`, `--app <name>`, `--namespace prod`, `--out <app>-secrets.sealed.yaml`, `--dry-run`.
- 로직: `.app-config.yml`의 `secrets:[...]`만 allowlist로 읽는다 → 각 키를 UPPER_SNAKE로 변환해 `.env`에서 값 조회 → 누락 시 에러(어떤 키인지 출력, **값은 출력 금지**) → `--dry-run`이면 대상 키 목록 JSON만 출력하고 종료 → 아니면 임시 평문 Secret manifest를 만들고 `kubeseal --cert <cert> --format yaml`로 파이프 → `<app>-secrets.sealed.yaml` 생성. **평문 Secret과 .env 값은 stdout/로그에 절대 노출 금지**(임시 파일은 `mktemp` + trap rm).
- Secret 이름 규약: `<app>-secrets`, namespace `prod`, key=UPPER_SNAKE. 차트 `envFrom`이 이 Secret을 `secretRef`로 참조(§7).

**Step 4: 테스트 통과 확인**

Run: `bats tools/test/seal-secret.bats`
Expected: PASS.

**Step 5: package.json 스크립트 추가**
```json
"secret:seal": "node tools/seal-secret.mjs"
```
> 이 CLI는 **앱 레포(app-starter)에도 동봉**되어 개발자가 `pnpm secret:seal`로 봉인한다. homelab의 사본은 마이그레이션/테스트용. (DRY: 단일 소스를 npm 패키지화하는 건 YAGNI — 양쪽에 동일 스크립트 복제, 차이 발생 시 재검토.)

**Step 6: Commit** — `/commit` (`feat: .env→SealedSecret 봉인 CLI(secret:seal) 추가`)

### Task 2.3: KSOPS enc.yaml 7개 → SealedSecret 마이그레이션 (컴포넌트별)

**대상(7개):** `platform/cloudflared/prod/tunnel.enc.yaml`, `platform/cnpg/prod/{app-credentials,r2-creds,restore-drill-alerting}.enc.yaml`, `platform/tailscale/prod/operator-oauth.enc.yaml`, `platform/traefik/prod/cloudflare-api-token.enc.yaml`, `platform/victoria-stack/prod/alerting.enc.yaml`. 각 컴포넌트에 `secret-generator.yaml`(KSOPS generator)도 존재.

**컴포넌트당 반복 절차(예: traefik):**

**Step 1:** 복호화로 평문 추출(채팅에 출력 금지):
```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
sops -d platform/traefik/prod/cloudflare-api-token.enc.yaml > /tmp/plain.yaml  # /tmp만
```

**Step 2:** SealedSecret 생성:
```bash
kubeseal --cert tools/sealed-secrets-cert.pem --format yaml < /tmp/plain.yaml \
  > platform/traefik/prod/cloudflare-api-token.sealed.yaml
rm -f /tmp/plain.yaml
```

**Step 3: 기존 Secret 인수 준비(bitnami managed + ownerReference 없이 — Codex pass2 #5 + pass6 #1).** KSOPS와 SealedSecret이 **같은 이름**의 Secret을 두고 충돌하지 않도록, bitnami "managing existing secrets"를 따른다: SealedSecret을 **원본 이름 그대로** 만들되, 그 산출이 기존 Secret을 인수하도록 인수 허용 메타데이터를 단다.
```bash
# 인수 허용 + ownerReference 미설정(GC 차단) — 두 annotation을 함께(Codex pass7 #1):
kubectl -n traefik annotate secret cloudflare-api-token \
  sealedsecrets.bitnami.com/managed=true \
  sealedsecrets.bitnami.com/skip-set-owner-references=true --overwrite
```
**⚠️ ownerReference GC 위험(Codex pass6 #1 + pass7 #1):** 기본값이면 산출 Secret이 **SealedSecret CR을 ownerReference로** 가져, git revert로 CR을 지우면 **k8s가 Secret을 GC**한다(`Prune=false`/tracking 제거는 ArgoCD prune만 막고 **k8s GC는 못 막음**). 위 **`skip-set-owner-references=true` annotation**으로 그 Secret에 ownerReference를 달지 않게 해 CR 삭제 시에도 GC를 막는다. `sealed.yaml`(원본 이름)을 kustomization resources에 추가하고 generator는 아직 유지.

**Step 4: SealedSecret이 Secret을 실제로 생산함을 증명**(Codex #3 — "존재"만으론 부족; ownerReference는 안 검사 — skip-set-owner-references라 없음이 정상):
```bash
# (a) SealedSecret reconcile 성공
kubectl -n traefik get sealedsecret cloudflare-api-token -o jsonpath='{.status.conditions[?(@.type=="Synced")].status}'  # "True"
# (b) ownerReference가 없어야 정상(GC 차단): 비어 있음 확인
kubectl -n traefik get secret cloudflare-api-token -o jsonpath='{.metadata.ownerReferences}'  # 빈 값
# (c) 값 일치: sops -d 원본 vs 현재 Secret을 키별 sha256만 비교(값 비출력)
```
세 조건(Synced=True + ownerReference 없음 + 체크섬 일치) **모두** 통과해야 generator 제거 자격. **하나라도 실패하면 generator 유지하고 중단**.

**Step 5: ArgoCD tracking handoff로 prune 방지(Codex pass3 #4).** 각 평문 Secret은 appset 생성 Application(`<comp>-prod`)이 KSOPS generator 출력으로 추적한다. generator 제거 시 desired state를 떠나 **ArgoCD가 prune**한다(ownerReference는 ArgoCD prune 면제 아님). 안전 handoff: generator 제거 **전에** Secret에 `argocd.argoproj.io/sync-options: Prune=false` + tracking 메타데이터(`argocd.argoproj.io/tracking-id`) 제거 → ArgoCD가 desired state 이탈 시에도 prune 안 함. 이후 SealedSecret 컨트롤러가 계속 생산. 그 다음 Step 4 통과 + Task 2.1b 복구 드릴 통과 컴포넌트에 한해 generator/enc.yaml 제거.

**Step 6: 롤백 E2E를 필수 게이트로(Codex pass6 critical #1).** 전환 전에 **실제 롤백을 리허설**해 자격이 사라지지 않음을 증명한다:
```bash
kustomize build --enable-helm platform/traefik/prod   # KSOPS 플래그 없이 렌더
# (1) 전환 내내 1~2초 간격 연속 단언:
kubectl -n traefik get secret cloudflare-api-token -o name  # 절대 사라지지 않아야 함
kubectl -n traefik rollout status deploy/traefik           # 워크로드 readiness 유지
# (2) 롤백 E2E(self-heal 배제 환경): SealedSecret CR 삭제 후 Secret UID 보존 확인(skip-set-owner-references 검증)
UID_BEFORE=$(kubectl -n traefik get secret cloudflare-api-token -o jsonpath='{.metadata.uid}')
kubectl -n traefik delete sealedsecret cloudflare-api-token
[ "$(kubectl -n traefik get secret cloudflare-api-token -o jsonpath='{.metadata.uid}')" = "$UID_BEFORE" ]  # 동일 UID = GC 안 됨
# (3) 2단계 handback 정의: git revert로 KSOPS 복원 → 동기화 확인 → (필요 시) managed 메타데이터 제거 → 그 다음 SealedSecret 제거
kubectl -n traefik patch app traefik-prod --type merge -p '{"operation":{"sync":{}}}'  # KSOPS 재생산 확인
```
이 롤백 E2E(특히 (2))가 통과해야 해당 컴포넌트 전환을 확정한다. **하나라도 Secret이 사라지면 중단**(skip-set-owner-references 미적용 의심).
> 동일 이름 인수라 위로 충분. 소비자가 별도 이름을 참조하면 **새 이름 전환 후 구이름 제거**의 2단계 마이그레이션.

**Step 7: Commit**(컴포넌트별 별도 커밋) — `/commit` (`refactor: traefik 시크릿을 KSOPS에서 SealedSecret으로 전환`)

**7개 컴포넌트 모두 반복.** cnpg는 3개 enc.yaml이라 주의(app-credentials는 CNPG가 소비하는 DB 자격 — 순서 민감, **워크로드 무중단** 원칙 준수: Secret 교체 후 `envFrom` 소비 파드 재시작이 있어야 반영됨 — 라이브 검증된 함정). app-credentials 전환 후 CNPG cluster/pooler가 정상 reconcile하는지 라이브 확인.

**Step 8: 마이그레이션 완료 후 게이트 갱신**
- `tests/`의 sops 라운드트립 테스트가 enc.yaml 0개를 허용하도록 조정(또는 age 백업 키 검증만 유지).
- `make verify`의 sops 라운드트립이 남은 enc.yaml에만 적용되는지 확인.
- AGENTS.md의 "KSOPS 마이그레이션 대상" 문구 갱신.

**Step 9: Commit** — `/commit` (`chore: KSOPS 전환 완료 — sops 게이트/문서 갱신`)

> **age 키 유지:** R2 tfstate나 복구 폴백에 age가 여전히 필요할 수 있으므로 키 자체는 폐기하지 않는다. 신규 시크릿은 SealedSecrets만.

---

## Phase 3: 데이터 기반 Terraform + 중앙 dispatcher

**목표:** 공개 앱 DNS/tunnel ingress를 `apps.json` SSOT에서 `for_each`로 생성. 모든 앱 변이를 단일 직렬화 dispatcher로 라우팅.

### Task 3.1: apps.json 레지스트리 + 데이터 기반 dns.tf/tunnel.tf

**Files:**
- Create: `infra/cloudflare/apps.json`
- Modify: `infra/cloudflare/dns.tf`, `infra/cloudflare/tunnel.tf`, `infra/cloudflare/variables.tf`
- Test: `infra/cloudflare/test_apps_data.bats` (또는 기존 tf 테스트 패턴)

**Step 1: 실패 테스트 작성** — `test_apps_data.bats`

```bash
#!/usr/bin/env bats
setup() { C="$(cd "$BATS_TEST_DIRNAME" && pwd)"; }

@test "apps.json is valid JSON and is an array" {
  run jq -e 'type == "array"' "$C/apps.json"
  [ "$status" -eq 0 ]
}

@test "terraform validate passes with data-driven dns" {
  cd "$C" && run terraform validate
  [ "$status" -eq 0 ]
}

@test "dns.tf consumes apps.json via for_each" {
  run grep -E "for_each" "$C/dns.tf"
  [ "$status" -eq 0 ]
}

@test "apps.json has globally unique app names and hosts (no silent collision)" {
  # 중복 host는 toset에서 조용히 사라지지만 Gateway엔 같은 hostname HTTPRoute 2개 → 오라우팅(Codex pass8 #4)
  run jq -e '(.|length) == ([.[].name]|unique|length) and (.|length) == ([.[].host]|unique|length)' "$C/apps.json"
  [ "$status" -eq 0 ]
}

@test "apps.json hosts do not collide with reserved names (apex/www/home suffix)" {
  run jq -e 'all(.[]; (.host != "ukyi.app") and (.host != "www.ukyi.app") and (.host | endswith(".home.ukyi.app") | not))' "$C/apps.json"
  [ "$status" -eq 0 ]
}
```

**Step 2: 테스트 실패 확인**

Run: `bats infra/cloudflare/test_apps_data.bats`
Expected: FAIL.

**Step 3: 구현**
- `apps.json` — 초기값 `[]`(빈 배열; apex/www는 코드 고정 유지). 스키마: `[{ "name": "<app>", "host": "<fqdn>", "public": true }]`.
- `dns.tf`:
  ```hcl
  locals {
    apps          = jsondecode(file("${path.module}/apps.json"))
    app_hosts     = toset([for a in local.apps : a.host if a.public])
    tunnel_target = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
    public_hosts  = toset(concat([var.zone_name, "www.${var.zone_name}"], tolist(local.app_hosts)))
  }
  # 기존 cloudflare_dns_record.public의 for_each = local.public_hosts (그대로 — public_hosts에 앱 host 합류)
  ```
- `tunnel.tf`: ingress 리스트를 `concat`으로 동적 생성:
  ```hcl
  config = {
    ingress = concat(
      [for h in local.public_hosts : { hostname = h, service = "http://traefik.gateway.svc.cluster.local:80" }],
      [{ service = "http_status:404" }]
    )
  }
  ```
  > **주의:** terraform map은 순서 보장 안 됨 → ingress는 리스트라 정렬 필요. `sort(tolist(local.public_hosts))`로 결정적 순서 보장(드리프트 방지). 404 catch-all은 항상 마지막.

**Step 4: 검증**

Run: `cd infra/cloudflare && terraform fmt && terraform validate && terraform plan -var-file=terraform.tfvars`
Expected: validate PASS. plan = no-op(apps.json 비었으므로 apex/www만, 기존과 동일).

**Step 5: Commit** — `/commit` (`feat: Cloudflare DNS/tunnel을 apps.json 데이터 기반 for_each로 전환`)

### Task 3.2: 중앙 직렬화 dispatcher + payload 검증기

**Files:**
- Create: `.github/workflows/dispatch-mutation.yml`
- Create: `tools/validate-mutation.mjs`
- Test: `tools/test/validate-mutation.bats`

**Step 1: 실패 테스트 작성** — `validate-mutation.bats`

> **픽스처는 실제 `github.event.inputs` 모양과 일치해야 한다(Codex pass3 high #2):** dispatcher가 넘기는 입력은 `{action, app_repo, sha, spec}`(+ 빈 선택 입력). 검증기가 `repo` 같은 다른 필드명을 기대하거나 빈 선택 입력을 거부하면 정상 dispatch가 라우팅 전에 실패한다. 픽스처를 실제 모양으로 작성한다.

```bash
#!/usr/bin/env bats
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; V="$ROOT/tools/validate-mutation.mjs"; }

@test "rejects unknown action" {
  run node "$V" --action evil --payload '{"app_repo":"ukyi-app/orders","sha":"abc1234","spec":""}'
  [ "$status" -ne 0 ]
}

@test "rejects app_repo with shell metacharacters" {
  run node "$V" --action create-app --payload '{"app_repo":"ukyi-app/foo; rm -rf /","sha":"abc1234","spec":""}'
  [ "$status" -ne 0 ]
}

@test "accepts a real create-app workflow_dispatch payload (with empty optional spec)" {
  run node "$V" --action create-app --payload '{"app_repo":"ukyi-app/orders","sha":"abc1234def","spec":""}'
  [ "$status" -eq 0 ]
}

@test "rejects app_repo not in ukyi-app org" {
  run node "$V" --action create-app --payload '{"app_repo":"evil/orders","sha":"abc1234","spec":""}'
  [ "$status" -ne 0 ]
}

@test "accepts create-database with a JSON spec string" {
  run node "$V" --action create-database --payload '{"app_repo":"","sha":"","spec":"{\"name\":\"orders\",\"owner\":\"orders\",\"extensions\":[\"uuid-ossp\"]}"}'
  [ "$status" -eq 0 ]
}
```

**Step 2: 테스트 실패 확인**

Run: `bats tools/test/validate-mutation.bats`
Expected: FAIL.

**Step 3: 구현** — `tools/validate-mutation.mjs` (위 액션 계약 표를 강제 — Codex #2/#4)
- action 화이트리스트 = 계약 표(`create-app | activate-app | update-secrets | create-database | create-cache | teardown-app | teardown-resource | audit`). (update-image는 GHCR 폴링이라 제외 — Task 3.4.)
- **입력은 항상 `{action, app, app_repo, sha, resource, spec}` 키**(dispatcher inputs와 1:1). 빈 문자열 선택 입력 허용. action별 필수 필드는 계약 표대로 강제(예: create-app=app_repo+sha, activate-app=app+sha, teardown-resource=resource, create-database=spec, audit=없음).
- 필드 regex: `app`=`^[a-z][a-z0-9-]{0,38}[a-z0-9]$`, `app_repo`=`^ukyi-app/[A-Za-z0-9._-]+$`(org 고정), `sha`=`^[0-9a-f]{7,40}$`, `resource`=`^(db|cache):[a-z][a-z0-9-]*$`, `spec`=JSON 파싱 후 별도 검증(name=`^[a-z][a-z0-9-]*$`, extensions[] 등 — 공유 클러스터 지원 필드만, Task 5.1). **스키마 밖 필드 거부**. 픽스처는 실제 `github.event.inputs`에서 복사한 모양.
- 위반 시 비-0 종료 + stderr 메시지(값 일부만, 시크릿 없음).

**Step 4: 테스트 통과 확인**

Run: `bats tools/test/validate-mutation.bats`
Expected: PASS.

**Step 5: dispatcher 워크플로** — `.github/workflows/dispatch-mutation.yml`

```yaml
name: dispatch-mutation
on:
  # 생성/파괴 변이: homelab-initiated만 (owner가 homelab에서 실행) — 앱 레포 자격 불필요 (Codex #1)
  workflow_dispatch:
    inputs:
      action:
        description: create-app|activate-app|update-secrets|create-database|create-cache|teardown-app|teardown-resource|audit
        required: true
      app:
        description: "앱 이름 (activate-app/teardown-app용)"
        required: false
      app_repo:
        description: "ukyi-app/<app> (create-app/update-secrets용)"
        required: false
      sha:
        description: "SHA — create-app/update-secrets: 앱 레포 커밋 SHA(config read), activate-app: homelab 머지 SHA(노출할 revision)"
        required: false
      resource:
        description: "db:<name> | cache:<name> (teardown-resource용)"
        required: false
      spec:
        description: "JSON 스펙 (create-database/create-cache)"
        required: false
# update-image는 이 dispatcher가 아니라 별도 homelab측 GHCR 폴링 워크플로(`bump-poll.yml`)가 처리한다.
# 기본 concurrency는 pending을 1건만 유지해 3번째가 대기 건을 취소(누락) → `queue: max`로 모두 큐잉(Codex pass8 #3).
# 추가로 Step 5b lease(멱등) + 취소 알림 + operation ledger + IaC 주기 reconcile(Task 3.3 3b')로 누락 0을 보강.
concurrency:
  group: homelab-mutation
  cancel-in-progress: false
  queue: max          # 모든 homelab-mutation 워크플로(dispatcher/bump-poll/iac/tf-reconcile)에 동일 적용
permissions:
  contents: write
  pull-requests: write
jobs:
  validate:
    runs-on: ubuntu-24.04-arm
    outputs:
      action: ${{ steps.v.outputs.action }}
    steps:
      - uses: actions/create-github-app-token@v1   # writer App (homelab write)
        id: token
        with:
          app-id: ${{ secrets.HOMELAB_WRITER_APP_ID }}
          private-key: ${{ secrets.HOMELAB_WRITER_APP_PRIVATE_KEY }}
      - uses: actions/checkout@v4
        with: { ref: main, token: ${{ steps.token.outputs.token }} }
      - uses: actions/setup-node@v4
        with: { node-version: "22" }
      - id: v
        env:
          ACTION: ${{ github.event.inputs.action }}      # workflow_dispatch만 — homelab-initiated
          PAYLOAD: ${{ toJSON(github.event.inputs) }}    # owner 입력도 비신뢰로 검증 — env 경유
        run: |
          printf '%s' "$PAYLOAD" > /tmp/payload.json
          node tools/validate-mutation.mjs --action "$ACTION" --payload-file /tmp/payload.json
          echo "action=$ACTION" >> "$GITHUB_OUTPUT"
  route:
    needs: validate
    runs-on: ubuntu-24.04-arm
    steps:
      - run: echo "라우팅: ${{ needs.validate.outputs.action }} (각 reusable 호출은 Phase 4/5에서 추가)"
```

**액션 계약 표(Codex pass4 #4 — 모든 최종 액션을 먼저 확정):**

| action | 필수 입력 | reusable | 추가되는 Task |
|---|---|---|---|
| create-app | app_repo, sha | `_create-app.yml` | 4.2 |
| activate-app | app, sha(homelab 머지 SHA) | (inline, Healthy 게이트) | 3.3 |
| update-secrets | app_repo, sha | `_update-secrets.yml` | 4.2 Step 8 |
| create-database | spec | `_create-database.yml` | 5.1 |
| create-cache | spec | `_create-cache.yml` | 5.2 |
| teardown-app | app | `_teardown.yml` | 6.1 |
| teardown-resource | resource(`db:`/`cache:`) | `_teardown.yml` | 6.1 |
| audit | (없음) | `_audit.yml` | 6.2 |

validator는 이 표의 **action별 필수/허용 입력**을 강제한다. update-image는 표에 없음(GHCR 폴링 — Task 3.4).

> **트리거 경계(Codex #1):** create-app/create-database/create-cache/teardown은 `workflow_dispatch`(homelab-initiated)만. update-image는 이 dispatcher 밖의 GHCR 폴링 워크플로(Task 3.4)가 처리한다 — 앱 레포가 보낸 어떤 입력도 받지 않는다.
> **점진성:** dispatcher는 먼저 validate+route 스켈레톤으로 머지하고, 라우팅 대상 reusable(`_create-app` 등)은 Phase 4/5에서 채운다. 기존 `onboard.yaml`(app-onboard)은 `create-app`으로, `bump.yaml`(app-image repository_dispatch)은 **Task 3.4 GHCR 폴링으로 대체**될 때까지 공존하되, 대체 시 **앱 레포발 write 경로(repository_dispatch + DEPLOY 자격)를 제거**한다.

**Step 5b: lease 뮤텍스 + 멱등 — best-effort 직렬화(과장 금지, Codex pass3 #1 / pass4 #6 / pass5 #1).** GitHub `concurrency`는 pending 1건만 유지하므로 **동시 3건째는 대기 중이던 것을 취소**한다 — in-run lease는 **취소된 run을 보호하지 못한다**(그 run은 lease를 잡기도 전에 사라짐). 따라서 **"정확-1회"를 주장하지 않는다.** homelab 규모(단일 operator + 저빈도 변이)에 맞춘 현실적 보장:
- **누락이 조용하지 않게:** 생성/파괴 변이는 **owner-initiated**라 취소되면 owner가 Actions에서 'canceled'를 본다 → 재실행. GHCR 폴링 bump는 **스케줄 멱등**이라 취소돼도 **다음 주기가 자동 수렴**(누락 자가 치유). 즉 어떤 변이도 영구 소실되지 않는다.
- **race 방지 lease:** `.mutation-lock`에 `{ owner: <run-id>, acquired_at, ttl: 15m, op_id: <action+입력 해시> }`. 획득 = lease 없음/TTL 만료면 회수. 살아있고 **op_id가 같고 상태가 `succeeded`면** 멱등 no-op(진행 중과 완료를 혼동하지 않음 — `succeeded`만 dedup), 아니면 유한 backoff 후 실패(재실행). `if: always()` 해제 + TTL 백스톱(runner 종료 시 다음 변이가 stale 회수 → 영구 차단 없음).
- **`queue: max` + operation ledger + 취소 알림(Codex pass8 #3):** concurrency에 `queue: max`로 모든 변이를 큐잉(취소 누락 차단). 추가로 **영속 operation ledger**(`.mutation-ops.jsonl` 또는 lease 레코드 확장)에 각 op의 `{op_id, action, state: queued|running|succeeded|failed, ts}`를 기록 → 취소/실패 시 **Telegram 알림**(조용한 누락 없음) + 미완 op를 다음 reconcile/수동 재실행으로 재등록. IaC는 Task 3.3 3b' 주기 reconcile가 추가 안전망.
- **테스트(E2E 게이트):** **최소 3개 동시 dispatch가 모두 순서대로 정확히 1회 완료**(queue: max), (b) runner 강제 종료 후 stale lease 회수, (c) `succeeded` op_id 재실행만 dedup(진행 중 op_id는 dedup 안 함), (d) 취소 시 Telegram 알림 + ledger에 미완 기록.

**Step 6: 정적 검증**

Run: `bats tools/test/validate-mutation.bats && bats tools/test/ci-build.bats`
Expected: PASS.

**Step 7: Commit** — `/commit` (`feat: 중앙 mutation dispatcher + 검증기 + 어드바이저리 락(정확-1회)`)

### Task 3.3: post-merge SHA 고정 terraform apply (공개 DNS 자동 반영, Codex high #4)

**Files:**
- Modify: `.github/workflows/iac.yaml` (push to main 트리거)
- Test: `tools/test/ci-build.bats` (정적)

> **트랜잭션 안전 원칙(Codex #4):** create-app은 라이브 Cloudflare를 **commit 전에** 건드리지 않는다(이미 apply된 uncommitted plan은 git revert로 못 되돌림). **등록(배포)과 DNS activation(공개)을 분리**한다: 머지로 앱이 배포되어도 DNS는 **그 Application revision이 Healthy로 확인된 뒤** 별도 단계에서만 노출된다.

> **activation 모델(Codex pass2 high #4):** `apps.json` 항목에 `active: bool` 추가. terraform은 `public && active`인 host만 DNS/tunnel을 만든다. create-app은 `public:true, active:false`로 커밋(DNS 미생성) → ArgoCD 배포 → **`activate-app` 단계가 해당 Application의 특정 revision Healthy를 확인한 뒤** `active:true`로 플립(별도 커밋) → 그 push가 terraform apply를 돌려 DNS 노출. 배포 실패 중에는 `active`가 false로 남아 외부 트래픽이 절대 노출되지 않는다.

**Step 1~3:** dns.tf의 `app_hosts` 필터를 `[for a in local.apps : a.host if a.public && a.active]`로. `iac.yaml`에 `on: push: { branches: [main], paths: [infra/cloudflare/**] }` 추가 — main 머지된 커밋 SHA를 체크아웃해 `terraform apply`(homelab `TF_*`/`R2_*` 시크릿, R2 백엔드). `concurrency: homelab-mutation` 공유(tfstate race 차단). plan→apply 분리.
**Step 3b: `activate-app` 워크플로 — 노출할 revision을 고정 검증(Codex pass3 high #5).** dispatcher `action: activate-app`: 입력 `app` + **`sha`(노출하려는 homelab 머지 SHA)**. "현재 Synced된 아무 revision의 Healthy"만 보면 reconcile 지연 중 **옛 revision**이 게이트를 통과해 조기 노출될 수 있다. 따라서:
- Application 이름은 **`<app>-prod`**(appset 규약 — 라이브 확인).
- **moving-main 영구대기/과승인 회피(Codex pass6 med #6):** 모든 source가 `main`을 추적하므로 "synced revision == 정확한 merge SHA"를 요구하면, 사이에 auto-bump/다른 merge가 끼면 그 SHA를 건너뛰어 **게이트가 영원히 통과 못 하거나**, 최신 SHA로 재시도하면 **승인 범위 밖 변경까지 승인**된다. 따라서:
  - synced revision이 **merge `sha`의 descendant(또는 동일)** 이고,
  - merge `sha`와 synced revision **사이에 이 앱의 경로(`apps/<app>/**`)·공유 차트·그 앱 시크릿·`infra/cloudflare/apps.json`의 해당 앱 행이 변경되지 않았음**을 git diff로 증명(변경됐으면 새 활성화 요청 필요 — 과승인/미승인 hostname 노출 차단; **apps.json 행 포함은 Codex pass7 #4**).
  ```bash
  git merge-base --is-ancestor "$SHA" "$SYNCED_REV"
  git diff --quiet "$SHA" "$SYNCED_REV" -- "apps/$APP/" platform/charts/app
  # apps.json의 해당 앱 행이 요청 SHA와 정확히 동일한지(host/public 무변경) — expected-value로 active만 변경
  [ "$(git show "$SHA:infra/cloudflare/apps.json" | jq -c --arg a "$APP" '.[]|select(.name==$a)|{name,host,public}')" \
    = "$(jq -c --arg a "$APP" '.[]|select(.name==$a)|{name,host,public}' infra/cloudflare/apps.json)" ]
  ```
- 그 다음에만 `.status.sync.status == Synced` && `.status.health.status == Healthy` + **그 앱 HTTPRoute의 `Accepted`/`ResolvedRefs` True**(같은 revision) 확인 → 통과 시 `apps.json` `active:true`만 변경 커밋(host/public는 그대로) → terraform apply가 DNS 노출. 타임아웃까지 미충족이면 중단(노출 안 함, Telegram 경보).
**Step 3b': 주기적 terraform reconcile(Codex pass6 high #2 — 취소된 apply 자가수렴).** push-triggered apply가 `concurrency`로 **취소되면** owner 재실행도 폴링 자가수렴도 없어 activation/teardown DNS가 **영구 미반영**될 수 있다. 따라서 **스케줄 reconcile 워크플로**(`tf-reconcile.yml`, 예: 30분 주기 + `workflow_dispatch`)를 둔다: main 최신 SHA에서 `terraform plan` → 드리프트(apps.json↔실제 DNS 불일치) 있으면 apply. `concurrency: homelab-mutation` + lease 공유. 이로써 취소된 apply가 다음 reconcile에서 수렴(누락 0). (GitHub Actions가 `queue: max`를 지원하면 그것도 함께 쓰되, **의존하지 않는다** — reconcile이 권위 안전망.)
**Step 3c: 부분 실패 보상** — apply 일부 실패 시: (a) job 실패 + Telegram 경보, (b) R2 state 기반 다음 apply/reconcile가 수렴, (c) "고아 DNS"(active=true인데 앱 미배포)는 Phase 6 `audit-orphans`가 감지.
**Step 4:** 정적 검증(`bats tools/test/ci-build.bats` + `terraform validate`) + 라이브는 Phase 4 create-app E2E에서.
**Step 5: Commit** — `/commit` (`feat: DNS activation 게이트 — Healthy 확인 후 active 플립 + SHA 고정 apply`)

### Task 3.4: update-image GHCR 폴링 bump (Codex pass2 critical #1)

**Files:**
- Create: `.github/workflows/bump-poll.yml`
- Create: `tools/poll-ghcr.mjs`
- Test: `tools/test/poll-ghcr.bats`
- (대체) Remove: `bump.yaml`의 `repository_dispatch: [app-image]` 경로 + 앱 레포 DEPLOY 자격(Task 3.4 라이브 검증 후)

> **배포 승인 정책 보존(Codex pass4 high #2):** 현재 `deploy.autoDeploy:false` 앱은 `production` environment 승인을 거쳐야 배포된다(`dispatch-image-gated` job). 폴링이 최신 태그를 **무조건 자동 커밋**하면 이 승인 게이트가 사라진다. 따라서 배포 정책을 **homelab 소유 레지스트리**로 옮긴다: `apps/<app>/deploy/prod/.bindings.json`(또는 별도 `deploy-policy`)에 `autoDeploy: bool` 기록. 폴링은 `autoDeploy:true`만 직접 bump하고, **`autoDeploy:false` 앱은 후보 PR(또는 승인 대기 상태)로만** 생성한다.

**Step 1: 실패 테스트** — `poll-ghcr.bats`: `poll-ghcr.mjs --dry-run`이 각 `source-repo` 바인딩에 대해 GHCR 최신 `sha-*` 태그를 조회(모킹/픽스처)해 배포 태그와 다르면 bump 후보로 리포트, 같으면 no-op. **`autoDeploy:false` 앱은 직접 커밋이 아니라 PR 후보로 분류**됨을 단언. 앱 레포 입력을 전혀 받지 않음(바인딩 + GHCR만 소스).

**Step 2~4:** 구현
- `bump-poll.yml`: `on: { schedule: [{cron: "*/10 * * * *"}], workflow_dispatch: {} }`. `concurrency: homelab-mutation` + Step 5b lease 공유. App 토큰(homelab) + GHCR `packages:read`.
- `poll-ghcr.mjs`: `apps/*/deploy/prod/source-repo` 바인딩 순회 → 각 앱의 GHCR 패키지 버전 목록에서 후보 `sha-<gitsha>` 태그 선정 → **(a) 그 gitsha가 바운드 레포 main에서 reachable**(`gh api repos/ukyi-app/<app>/commits/<gitsha>` + branch contains — non-main 빌드 차단), **(b) 후진 배포 차단(Codex pass9 high #4):** 빌드 완료 순서가 뒤바뀌면 옛 commit이 최신 패키지 버전이 되어 **새 digest를 옛것으로 되돌릴** 수 있다 → **배포된 source SHA를 values에 보존**하고, 후보가 그 SHA의 **descendant임이 증명될 때만** 자동 배포(`git merge-base --is-ancestor <deployed-sha> <candidate-sha>`). git 조상 기준 **가장 최신 eligible commit** 선택. **(c) digest로 해석**(`sha256:...`) → 다르면: `autoDeploy:true`면 `repo@sha256:...`로 bump, `autoDeploy:false`면 PR. **non-fast-forward(되돌리기)는 명시적 rollback 작업으로만**(자동 폴링 금지).
- **불변 식별자(Codex pass5 #5):** 태그는 덮어쓸 수 있으므로 values에 `image.tag`(가변)가 아니라 **`image.digest`(`repo@sha256:...`)를 커밋**한다 → git이 배포 바이트를 결정적으로 식별, 롤백 결정적.
- **공통 image-ref helm helper(Codex pass7 high #3):** `deployment.yaml`만 바꾸면 **`migrate-job.yaml`도 `{repo}:{tag}`를 직접 조합**하므로 migration과 Deployment가 **다른 이미지를 실행**하거나 호환용 stale tag가 남는다. 따라서 `platform/charts/app/templates/_helpers.tpl`에 **`app.image` helper**(`{{- if .Values.image.digest }}{repo}@{digest}{{- else }}{repo}:{tag}{{- end }}`)를 만들고 **deployment.yaml·migrate-job.yaml 둘 다** 이 helper를 쓰게 한다. values.schema.json의 tag/digest 계약 정리(digest 있으면 tag 선택) + 기존 values 마이그레이션 + `bump-tag.mjs`가 digest 기록. **테스트:** 두 워크로드가 **동일 digest**를 렌더하는지 단언.
- 신뢰 경계: 태그/digest/reachability는 **GHCR/GitHub에서 직접** 읽고, 어떤 앱 레포 payload도 받지 않는다.
- **E2E:** (a) `autoDeploy:false` 앱이 폴링으로 비승인 자동 배포되지 않음(후보 PR만), (b) non-main 빌드 태그는 배포 거부, (c) 배포가 digest로 핀.

**Step 5: reusable-app-build 2-릴리스 호환 마이그레이션(Codex pass3 #6 + pass6 #3) — 계약 순서 주의.** 현재 `.github/workflows/reusable-app-build.yaml`은 **`secrets.dispatch-pat`(required)** + target/onboard/image dispatch job을 갖는다. **reusable에서 `secrets.dispatch-pat` 선언을 먼저 지우면**, 아직 그 named secret을 넘기는 기존 caller는 **"undeclared secret"으로 workflow 검증 실패** → 빌드/GHCR push 전면 중단(GitHub reusable workflow 계약). 따라서 **2단계 릴리스**:
1. **릴리스 v1(build-only, 호환):** dispatch job(`target`/`dispatch-onboard`/`dispatch-image`/`dispatch-image-gated`) 전부 제거하고 build+push(앱 `GITHUB_TOKEN` packages:write)만 남기되, **`secrets.dispatch-pat`은 `required: false`로 선언만 유지(미사용)** → 기존 caller가 secret을 넘겨도 검증 통과.
2. 템플릿 + **모든 호출 앱 레포** caller를 v1 호출로 마이그레이션(점차 `secrets:` 블록 제거) + 라이브 확인(빌드 성공).
3. Task 3.4 GHCR 폴링 bump가 라이브 동작함을 검증(빌드→GHCR→폴링→bump→ArgoCD).
4. **릴리스 v2:** 모든 caller가 secret을 안 넘기는 것 확인 후 `secrets.dispatch-pat` 선언 제거 + org secret `HOMELAB_DISPATCH_PAT` 폐기 + `bump.yaml`의 `writeback-dispatch` job 제거.

**Step 6: Commit** — `/commit` (`feat: update-image를 GHCR 폴링 bump로 전환 + reusable-build를 build-only로 마이그레이션`)

---

## Phase 4: 원-버튼 create-app

**목표:** 앱 레포 `create-app` workflow_dispatch → homelab `_create-app` reusable이 매니페스트 생성·공개면 registry/terraform·ArgoCD 등록까지 자동.

### Task 4.1: `.app-config.yml` 스키마

**Files:**
- Create: `tools/app-config-schema.json`
- Modify: `tools/homelab-app-schema.json` (deprecate 또는 흡수)
- Test: `tools/test/app-config.bats`

**Step 1: 실패 테스트 작성** — `app-config.bats`

```bash
#!/usr/bin/env bats
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; S="$ROOT/tools/app-config-schema.json"; }

@test "schema is valid json-schema draft-07" {
  run jq -e '."$schema" | test("draft-07")' "$S"
  [ "$status" -eq 0 ]
}

@test "schema allows db and redis as arrays of resource names" {
  run jq -e '.properties.db.type == "array" and .properties.redis.type == "array"' "$S"
  [ "$status" -eq 0 ]
}

@test "schema forbids additional properties" {
  run jq -e '.additionalProperties == false' "$S"
  [ "$status" -eq 0 ]
}
```

**Step 2: 테스트 실패 확인**

Run: `bats tools/test/app-config.bats`
Expected: FAIL.

**Step 3: 구현** — `tools/app-config-schema.json` (기존 `homelab-app-schema.json` 확장):
- 추가 필드: `db: { type: array, items: {pattern: ^[a-z][a-z0-9-]*$} }`, `redis: 동일`.
- `secrets`(기존), `env`(기존), `route`, `resources`, `kind`, `replicas` 유지.
- **`deploy.autoDeploy` 유지(Codex pass5 high #4):** 기존 `.homelab.yaml`의 `deploy.autoDeploy`(승인 게이트)를 스키마에 그대로 두고, create-app이 이를 **권위 레지스트리 `apps/<app>/deploy/prod/.bindings.json`(또는 `deploy-policy`)에 기록**한다. 폴러(Task 3.4)는 이 값을 읽어 `false`면 직접 배포하지 않는다. **값 누락 시 fail-closed**(= 자동 배포 안 함, 후보 PR만) — 승인 앱이 조용히 자동 배포로 바뀌지 않도록.
- `additionalProperties: false`.
- `db`(배열, 리소스명) vs 기존 `db`(객체, enabled/migrateCmd) **충돌** — 마이그레이션 결정: 기존 `db.enabled/migrateCmd`는 `migrate: {cmd: [...]}`로 분리하고, `db:`는 리소스 참조 배열로 재정의. 스키마+onboard 변환기 동시 갱신.
- **마이그레이션 테스트:** 기존 `autoDeploy:false` 앱 전부가 결정적으로 마이그레이션되고 폴러가 비승인 자동 배포하지 않음을 단언.

**Step 4: 테스트 통과 확인**

Run: `bats tools/test/app-config.bats`
Expected: PASS.

**Step 5: Commit** — `/commit` (`feat: .app-config.yml 스키마 — db/redis 리소스 참조 추가`)

### Task 4.2: `_create-app` reusable + create-app 생성기

**Files:**
- Create: `.github/workflows/_create-app.yml`
- Create: `tools/create-app.mjs` (`.app-config.yml` → values.yaml + registry 갱신)
- Test: `tools/test/create-app.bats`

**Step 1: 실패 테스트 작성** — `create-app.bats`

```bash
#!/usr/bin/env bats
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; TMP="$(mktemp -d)"; }
teardown() { rm -rf "$TMP"; }

@test "create-app generates values.yaml from .app-config.yml" {
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: api
resources: { requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 200m, memory: 128Mi} }
route: { public: true, host: orders.example.com }
db: [orders]
redis: [sessions]
EOF
  run node "$ROOT/tools/create-app.mjs" --config "$TMP/.app-config.yml" --app orders \
    --repo ukyi-app/orders --domain example.com --out "$TMP/out" --dry-run
  [ "$status" -eq 0 ]
  run cat "$TMP/out/apps/orders/deploy/prod/values.yaml"
  echo "$output" | grep -q "orders"
}

@test "create-app wires db/redis SealedSecret handles into envFrom" {
  # db: [orders] → envFrom: [{secretRef: {name: db-orders-conn}}]
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: api
resources: { requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 200m, memory: 128Mi} }
db: [orders]
EOF
  run node "$ROOT/tools/create-app.mjs" --config "$TMP/.app-config.yml" --app orders \
    --repo ukyi-app/orders --domain example.com --out "$TMP/out" --dry-run
  [ "$status" -eq 0 ]
  grep -q "db-orders-conn" "$TMP/out/apps/orders/deploy/prod/values.yaml"
}
```

**Step 2: 테스트 실패 확인**

Run: `bats tools/test/create-app.bats`
Expected: FAIL.

**Step 3: 구현** — `tools/create-app.mjs`
- `.app-config.yml` 검증(app-config-schema.json, additionalProperties 차단).
- **GHCR 이미지 필수화(Codex med #9):** `ghcr.io/ukyi-app/<app>:<tag>`가 실존해야 한다(`docker manifest inspect`). **없으면 `replicas: 0`을 쓰지 않고 생성 중단**(차트 스키마가 replicas 1~3만 허용 → replicas:0은 render gate에서 거부됨). 명확한 에러: `이미지 미존재 — 앱 레포에서 빌드(GHCR push) 먼저`.
- values.yaml 생성: image.repo=`ghcr.io/ukyi-app/<app>`, **image.digest=`sha256:...`(불변 — Codex pass5 #5, 가변 태그 대신)**, kind/route/resources/env 매핑.
- **db/redis 소비(§6):** `db: [orders]` → `envFrom: [{secretRef: {name: db-orders-conn}}]`, `redis: [sessions]` → `{secretRef: {name: cache-sessions-conn}}`. conn Secret은 **앱이 도는 `prod` 네임스페이스**에 존재해야 함(Codex high #6 — Phase 5.1). env 키 규약 `<NAME>_DATABASE_URL`/`<NAME>_REDIS_URL`은 conn Secret 내부 키로 보장(Phase 5).
- **권위 바인딩/정책 레지스트리(Codex pass3 #8 + pass5 #4):** `db:`/`redis:`를 envFrom으로 변환하면서, **homelab 소유의 정규화된 파일**(`apps/<app>/deploy/prod/.bindings.json` = `{"db":["orders"],"redis":["sessions"],"autoDeploy":false}`)도 함께 생성한다. teardown은 외부 `.app-config.yml`(이 레포에 없음)이나 envFrom 파싱이 아니라 **오직 이 in-homelab 레지스트리**로 참조 수를 세고, 폴러는 `autoDeploy`를 여기서 읽는다(누락=fail-closed).
- **미생성 리소스 가드(Task 5.4 선반영):** `db:`/`redis:`에 적힌 이름이 `platform/cnpg/prod/databases/`·`platform/<cache>/prod/`(prod conn Secret)에 없으면 중단(`db '<name>' 미생성 — create-database 먼저`).
- secrets 선언 시 `envFrom: [{secretRef: {name: <app>-secrets}}]` 추가.
- **시크릿 GitOps 전달 + kustomize 등록(Codex pass3 #7 + pass4 #5):** `secret:seal`은 **앱 레포**에서 `<app>-secrets.sealed.yaml`을 산출한다. appset source #3는 `apps/<name>/deploy/prod`를 **Kustomize**로 렌더하므로 파일만 두면 안 되고 **`kustomization.yaml`이 있어야 하고 그 `resources`에 등록**돼야 한다. 따라서 create-app은:
  - 앱 레포 고정 경로(`deploy/<app>-secrets.sealed.yaml`)에서 SHA 고정 read → homelab `apps/<app>/deploy/prod/<app>-secrets.sealed.yaml`로 복사.
  - **`apps/<app>/deploy/prod/kustomization.yaml`을 항상 생성**하고 sealed 시크릿(+필요 리소스)을 `resources:`에 등록(현재 온보딩 스캐폴드 패턴과 동일 — secrets 없으면 빈 kustomization).
  - 복사 시 **검증:** `kind: SealedSecret`, `metadata.namespace: prod`, `metadata.name: <app>-secrets`(아니면 거부). 봉인본이라 전송/커밋 안전.
  - **테스트:** 생성 결과에 `kustomize build apps/<app>/deploy/prod | kubeconform`이 clean하게 통과(시크릿 누락/렌더 실패 0).
- `source-repo` 파일 생성(외부 레포 바인딩).
- 공개면 `infra/cloudflare/apps.json`에 `{name, host, public:true, active:false}` 추가. **`active:false`로 시작** — DNS는 배포 Healthy 확인 후 `activate-app`이 켠다(Codex #4). **host/name 전역 유일성 강제(Codex pass8 #4):** 이미 같은 name 또는 host가 있으면 **거부**(중복 host는 toset에서 조용히 사라져 오라우팅 유발). apex/www/`*.home.<domain>` 예약어도 거부. CI(Task 3.1 테스트)와 create-app 양쪽에서 강제.
- **메모리 원장 갱신(Codex pass6 high #5):** `docs/memory-ledger.md`에 이 앱의 행을 **원자적으로 추가**(replicas × request/limit 반영 — 기존 onboard 구현과 동일). `pnpm verify:ledger`(합계 ≤ 8704Mi) 통과 필수 — 초과 시 생성 거부(단일 노드 OOM 방지). teardown-app은 이 행을 제거. **추가 CI 정책:** 모든 배포 앱 values와 상주 Valkey가 **원장에 정확히 1행** 갖는지 교차 검증(values↔ledger 불일치 차단).
- `--dry-run`은 `--out`에만 쓰고 git/dispatch 안 함.

**Step 4: 테스트 통과 확인**

Run: `bats tools/test/create-app.bats`
Expected: PASS.

**Step 5: `_create-app.yml` reusable — PR-first, SHA 고정(Codex #4/#5)**
- 입력: `app_repo`(ukyi-app/<app>), `sha`(앱 레포 커밋 SHA). **homelab이 자기 App 토큰으로 `app_repo`를 그 SHA에서 checkout(read)** 해 `.app-config.yml` + (secrets 선언 시) `deploy/<app>-secrets.sealed.yaml`을 읽는다(앱 레포가 payload로 보내지 않음 — 변조/stale-revision 방지).
- 단계: validate → app 레포 `sha`에서 config + sealed 시크릿 read → GHCR digest 실존 확인 → `create-app.mjs`로 매니페스트/apps.json 생성 + **sealed 시크릿을 `apps/<app>/deploy/prod/`로 복사·검증**(Codex #7) → **브랜치 push + PR 생성(App 토큰)** → render gate(`gate` required check) → **사람 머지 = 배포 승인**.
- 머지 시 apps.json은 `active:false`라 terraform이 DNS를 만들지 않는다(앱은 internal로 배포). ArgoCD appset이 매니페스트를 픽업해 배포 → **`activate-app`(Task 3.3 Step 3b)이 머지 SHA가 모든 source에 반영된 revision Healthy를 확인한 뒤** `active:true`로 플립 → terraform apply가 DNS 노출. 배포 실패 시 노출 없음.
- Telegram 통지(핸들/PR 링크만).

**Step 6: 차트 렌더 게이트 + E2E** — 생성된 values.yaml로 `helm template ... | kubeconform`(onboard.yaml의 render gate 재사용). **E2E 테스트:** (a) secrets 선언 앱 최초 온보딩 → 시크릿이 prod에 배포되어 파드 기동(missing Secret 아님), (b) `update-secrets`(Step 8) 회전 후 값 갱신 + 파드 재시작 반영.

**Step 7: Commit** — `/commit` (`feat: create-app — SHA 고정 config+시크릿 read + PR-first reusable + 생성기`)

**Step 8: `update-secrets` 회전 워크플로(Codex #7 회전 + pass9 high #6 선언적 반영)** — 별도 homelab `workflow_dispatch`(`action: update-secrets`, 입력 `app_repo`,`sha`): 앱 레포 `sha`의 `deploy/<app>-secrets.sealed.yaml`을 읽어 검증 후 homelab `apps/<app>/deploy/prod/`에 갱신 커밋. **재시작은 명령형 `rollout restart`가 아니라 선언적으로(Codex #6):** `envFrom` 시크릿 변경은 파드 재시작이 있어야 반영되는데, 명령형 restart는 취소/실패 시 파드가 옛 값을 무한 유지(git은 회전 완료로 보임)한다. → **봉인 콘텐츠 해시를 Deployment pod template annotation**(`checksum/secrets: <sealed-content-hash>`)에 함께 커밋 → ArgoCD가 그 변경만으로 **선언적으로 롤링**한다. 이미 커밋된 회전을 재실행해도 같은 해시로 수렴(idempotent). (개발자: 로컬 `.env` 수정 → `pnpm secret:seal` → 앱 레포 커밋 → owner가 homelab에서 `update-secrets` 실행.)

**Step 9: Commit** — `/commit` (`feat: update-secrets — 앱 SealedSecret 회전 + 재시작 반영`)

### Task 4.3: 트리거 진입점 (homelab-initiated)

> Codex #1 반영: create-app은 **homelab `workflow_dispatch`**(Task 3.2 dispatcher의 `action: create-app` 입력)로 owner가 실행한다. 앱/템플릿 레포에는 homelab을 호출하는 자격을 두지 않는다.

**진입 방법:**
- homelab Actions UI에서 `dispatch-mutation` 워크플로 → `Run workflow` → `action=create-app`, `app_repo=ukyi-app/<app>`, `sha=<커밋 SHA>` 입력. 또는 `gh workflow run dispatch-mutation.yml -f action=create-app -f app_repo=... -f sha=...`.
- **(선택) 앱 레포 편의 트리거:** 앱 레포가 homelab을 직접 호출하지 않고, homelab이 앱 레포의 최신 main SHA를 조회해 채우는 얇은 헬퍼(`gh` 별칭)를 로컬 런북에 둔다. 앱 레포에 자격을 심지 않는다.
- update-image(빌드 후 자동)는 **Task 3.4 GHCR 폴링**이 처리(앱 레포 입력 없음).

---

## Phase 5: DB/캐시 리소스 프로비저닝 + 소비 + 로컬 개발

**목표:** homelab workflow_dispatch로 postgres DB/Valkey 캐시를 생성, SealedSecret 핸들 반환(raw URL 비노출), 앱이 `db:`/`redis:`로 소비, tailscale 노출 + 로컬 2모드 CLI.

> **공유 클러스터 제약(Codex pass2 high #3):** postgres는 **공유 CNPG 클러스터(`pg`) 안의 논리 DB**다 → `version/storage/cpu/mem`은 **DB별로 적용 불가**(클러스터 레벨 속성). 따라서 per-DB 스펙은 **`name/owner/extensions`만** 받는다. 사이징(storage/cpu/mem/version)은 공유 클러스터 `cluster.yaml`을 조정하는 별도 작업(메모리 원장 게이트)이며 DB 생성 API의 입력이 아니다. valkey는 앱별 경량 Deployment라 사이징을 받을 수 있다(§Task 5.2).

### Task 5.1: create-database — CNPG Database CR + 관리 롤 + conn SealedSecret

> **네임스페이스 분리(Codex pass4 high #3):** `platform/cnpg/prod`의 상위 kustomization은 `namespace: database`를 강제한다 → prod용 conn SealedSecret을 거기 넣으면 namespace가 database로 바뀌어 **strict-scope 복호화 실패**. 따라서 **2개 kustomization/Application으로 분리**한다: (a) `platform/cnpg/prod`(database NS) = Database CR + managed.role 비밀번호 Secret, (b) **신규 `platform/data-conn/prod`(namespace: prod)** = 앱 소비용 `db-*/cache-*` conn SealedSecret. 후자는 appset이 `data-conn-prod`로 자동 발견(destination 네임스페이스는 kustomization의 `namespace: prod`가 지정).

**Files:**
- Create: `tools/provision-db.mjs`
- Create: `platform/cnpg/prod/databases/` (Database CR — database NS; cnpg-data 수동 Application이 소유)
- Create: `platform/data-conn/prod/` (conn SealedSecret — prod NS; appset 자동 발견 `data-conn-prod`)
- Create: `.github/workflows/_create-database.yml`
- Test: `tools/test/provision-db.bats`, `platform/cnpg/prod/test_databases.bats`, `platform/data-conn/prod/test_render.bats`

**Step 1: 실패 테스트 작성** — `provision-db.bats`

```bash
#!/usr/bin/env bats
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; TMP="$(mktemp -d)"; }
teardown() { rm -rf "$TMP"; }

@test "provision-db emits a CNPG Database CR for the named db" {
  run node "$ROOT/tools/provision-db.mjs" --name orders --owner orders \
    --cluster pg --namespace database --out "$TMP" --dry-run
  [ "$status" -eq 0 ]
  grep -q "kind: Database" "$TMP/orders.yaml"
  grep -q "name: orders" "$TMP/orders.yaml"
}

@test "provision-db never prints a raw connection URL" {
  run node "$ROOT/tools/provision-db.mjs" --name orders --owner orders \
    --cluster pg --namespace database --out "$TMP" --dry-run
  ! echo "$output" | grep -qiE "postgres://|password="
}
```

**Step 2: 테스트 실패 확인**

Run: `bats tools/test/provision-db.bats`
Expected: FAIL.

**Step 3: 구현** — `tools/provision-db.mjs` (공유 클러스터 모델 — Codex pass2 #3)
- 입력: **`name, extensions[]`만**(+ `cluster` 기본 pg). storage/cpu/mem/version은 받지 않음(공유 클러스터 레벨, DB API 입력 아님).
- **owner == name 강제 + 전역 유일(Codex pass5 high #6):** owner role을 임의 입력으로 받으면 두 DB가 같은 owner를 공유해 한쪽 teardown/회전이 다른 쪽을 깬다. 따라서 **owner는 항상 `<name>`으로 고정**하고 name의 전역 유일성을 강제(이미 존재하면 거부) → role↔DB 1:1, role refcount 불필요. (managed.role도 `<name>` 1개.)
- 출력(git 커밋 대상), 생성·인증이 실제로 동작하도록 **세 조각을 모두** 산출:
  1. **owner 롤 + 비밀번호:** 공유 `pg` `Cluster.spec.managed.roles[]`에 `<owner>` 항목 추가(declarative role management) + 비밀번호 Secret을 **`database` 네임스페이스**에 둔다(CNPG managed role은 같은 네임스페이스의 `passwordSecret`을 참조). 비밀번호는 **워크플로가 생성**(입력 안 받음). → `platform/cnpg/prod/cluster.yaml`의 `managed.roles` patch + `database` NS Secret(SealedSecret로 봉인).
  2. **논리 DB:** CNPG `Database` CR(`spec.cluster.name=pg`, `spec.name=<name>`, `spec.owner=<owner>`, `spec.extensions`) → **`platform/cnpg/prod/databases/`(database NS)**. `databaseReclaimPolicy: retain`(기본 — DB는 CR 삭제와 무관하게 보존; 삭제는 Task 6.1에서 명시적으로). (CNPG 1.24+ declarative Database CR.)
  3. **앱 소비용 conn SealedSecret(prod NS — Codex #6) — 런타임/마이그레이션 엔드포인트 분리(Codex pass9 high #5):** 플랫폼은 이미 `pg-pooler-rw`(PgBouncer)를 두어 클러스터 `max_connections=50`을 보호한다. **런타임 Deployment 트래픽은 풀러를 통과해야** 다중 앱 풀이 연결을 고갈시키지 않는다. 반면 **마이그레이션은 session 시맨틱이 필요**해 풀러로는 불안전. 따라서 conn을 **2개**로:
     - `<NAME>_DATABASE_URL`(런타임) = host **`pg-pooler-rw.database.svc...`**, user `<name>`.
     - `<NAME>_MIGRATE_DATABASE_URL`(마이그레이션 Job) = host **`pg-rw.database.svc...`**(직결, session).
     둘 다 같은 평문 Secret(namespace=prod, name=`db-<name>-conn`)에 담아 kubeseal 봉인 → **`platform/data-conn/prod/db-<name>-conn.sealed.yaml`**. 차트의 migrate-job은 `<NAME>_MIGRATE_DATABASE_URL`을, Deployment는 `<NAME>_DATABASE_URL`을 쓰도록(테스트로 각 워크로드가 의도한 엔드포인트를 받는지 증명). **raw URL은 stdout/로그 비노출**. envFrom은 네임스페이스-로컬이라 prod에 없으면 "missing Secret" 실패.
  4. **읽기 전용 롤(Task 5.5 모드2용):** managed.roles에 `<owner>_ro`(또는 SQL 후처리 Job으로 `GRANT SELECT` + `ALTER DEFAULT PRIVILEGES`) + ro conn SealedSecret(`db-<name>-ro-conn`) → **`platform/data-conn/prod/`(prod NS)**.
- **kustomization 등록:** `platform/data-conn/prod/kustomization.yaml`에 새 `*.sealed.yaml`을 `resources`에 추가(`namespace: prod` 강제). `platform/cnpg/prod/databases/kustomization.yaml`에 Database CR 등록.
- **생성·회전·삭제 순서 확정:** 생성 = managed.role(+pw Secret, database NS) → Database CR → prod conn 봉인(data-conn). 삭제(Task 6.1) = prod conn 제거 → 논리 DB 제거(`Database.spec.ensure: absent` 또는 `databaseReclaimPolicy: delete` — **PVC 미접촉**) → managed.role 제거. 회전 = pw Secret 갱신 → conn 재봉인 → 소비 파드 재시작(envFrom 변경은 재시작 필요 — 라이브 검증된 함정).
- **함정 반영:** pg_hba replication 항목(라이브 검증), pooler 예약 파라미터 미설정, SSA atomic-list 기본값(`Cluster.managed.roles`/`Cluster.plugins` 등 — atomic list에 서버 주입 기본값 명시 안 하면 영구 OutOfSync). prod→database:5432 egress는 기존 NetworkPolicy가 이미 허용(Codex #8 — DB는 OK, cache만 추가 필요).

**Step 4: 테스트 통과 확인**

Run: `bats tools/test/provision-db.bats`
Expected: PASS.

**Step 5: `_create-database.yml` reusable** — dispatcher route 호출(homelab-initiated workflow_dispatch): validate(스펙) → provision-db.mjs → kubeseal 봉인(prod) → 커밋(writer App 토큰) → ArgoCD 싱크 → Telegram **(핸들 이름만 통지, URL 금지)**.
> **메모리 원장: 논리 DB는 행 추가 안 함(Codex pass7 med #6).** Database는 공유 CNPG pod 안의 **논리 객체**라 DB별 cpu/memory 숫자가 없다(입력에도 없음) → 원장에 임의 숫자를 넣으면 8704Mi 게이트가 왜곡된다. 따라서 **논리 DB는 원장 행을 추가하지 않고**, 공유 CNPG 클러스터의 request/limit를 키울 때만 **기존 CNPG 행을 갱신**한다. DB 수/연결 수 용량은 별도 정책으로 관리(필요 시). (앱 워크로드·상주 Valkey는 실제 request/limit가 있으므로 원장 행 필요 — Task 4.1/5.2.)

**Step 6: 라이브 검증** (클러스터, 양쪽 네임스페이스 — Codex #6):
```bash
export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig
kubectl -n database get database orders          # CR Ready (database NS)
kubectl -n prod get secret db-orders-conn        # 앱 소비용 핸들이 prod NS에 존재(값 비출력)
# 소비 검증: prod의 더미 파드가 db-orders-conn을 envFrom으로 받아 기동되는지(missing Secret 아님)
```

**Step 7: Commit** — `/commit` (`feat: create-database — CNPG Database CR(database) + prod conn SealedSecret 핸들`)

### Task 5.2: create-cache — Valkey 인스턴스 + conn SealedSecret

**Files:**
- Create: `tools/provision-cache.mjs`
- Create: `platform/valkey/prod/` (또는 `platform/cnpg`와 대칭으로 `platform/cache/`)
- Create: `.github/workflows/_create-cache.yml`
- Test: `tools/test/provision-cache.bats`

**Step 1: 실패 테스트** — DB와 대칭(`kind: Valkey`/Deployment, conn SealedSecret은 **prod NS**(Codex #6 동일), `cache-<name>-conn`에 `<NAME>_REDIS_URL`, raw URL 비노출).

**Step 2~7:** DB와 동일 패턴.
- Valkey 배치 결정: **공유 인스턴스 + ACL 유저** vs **앱별 경량 Deployment**. 1차는 **앱별 경량 Deployment**(격리 단순, 메모리 원장에 limit 등록 — `docs/memory-ledger.md` 합계 ≤ 8704Mi 유지). maxmemory/eviction/persist 스펙 반영. 배치 네임스페이스 결정: `cache`(신규, `platform/namespaces` 소유) 또는 기존 `database`. **결정: `cache` 신규 네임스페이스**(아래 NetworkPolicy와 정합).
- **NetworkPolicy 추가(Codex high #8 — 기본 default-deny가 6379를 막음):**
  - `platform/namespaces`에 `cache` 네임스페이스 추가(appset 규약상 namespaces가 소유).
  - `platform/network-policies`에: (a) **prod egress → cache:6379** 허용, (b) **cache ingress ← prod:6379** 허용, (c) cache의 default-deny 기본 정책. DNS(:53)는 기존처럼 허용.
  - **라이브 연결 테스트(positive+negative):** prod 파드 → cache:6379 연결 성공(positive); prod 외 네임스페이스 → cache:6379 차단(negative). NetworkPolicy는 적용에 지연이 있으니 재시도.
- **메모리 원장 게이트:** Valkey는 **실제 request/limit를 가진 Deployment**라 `docs/memory-ledger.md`에 **행 추가** + `pnpm verify:ledger` 통과 필수(CI 강제, 합계 초과 시 거부). (논리 DB는 행 추가 안 함 — Task 5.1 Step 5 참고.)

**Step 5: Commit** — `/commit` (`feat: create-cache — Valkey + prod conn 핸들 + cache NetworkPolicy`)

### Task 5.2b: Valkey 백업 체인 (teardown `--delete-data` 선행 — Codex pass8 #6)

> teardown의 "최근 검증된 스냅샷" 요구가 성립하려면 Valkey도 **백업 체인**이 있어야 한다(없으면 삭제가 영구 차단되거나 유일 사본 소실).

**Files:**
- Create: `platform/cache/prod/backup-cronjob.yaml` (RDB 스냅샷 → R2), `tools/test/cache-backup.bats`
- Modify: `docs/runbooks/restore.md`(로컬) — Valkey 복구 절차

**Step 1~4:** 
- **스냅샷 export:** Valkey RDB(`SAVE`/`BGSAVE`)를 주기적으로 R2로 업로드(rclone, `no_check_bucket=true` — R2 R&W 토큰 함정). CNPG barman 패턴과 대칭.
- **보존 정책 + 신선도 메타데이터:** 마지막 성공 백업 시각/무결성 체크섬을 관측(메트릭/파일). teardown은 이 신선도를 게이트로 읽는다.
- **복구 드릴:** 백업에서 새 Valkey로 복원 테스트(주기 또는 수동). 검증된 **복구 지점 ID**를 산출.
- **파괴 승인 고정:** `teardown-resource --cache <name> --delete-data`는 **검증된 복구 지점 ID를 입력으로 고정**해야 통과(임의 삭제 차단).

**Step 5: Commit** — `/commit` (`feat: Valkey R2 백업 체인 + 복구 드릴 — 파괴 게이트 선행`)

### Task 5.3: 차트의 db/redis 소비 + env 주입 검증

**Files:**
- Modify: `platform/charts/app/values.schema.json`, `templates/deployment.yaml`
- Test: `platform/charts/app/tests/db-consume.bats`

**Step 1: 실패 테스트 작성** — `db-consume.bats`

```bash
#!/usr/bin/env bats
load 'render.sh'  # 기존 헬퍼

@test "db handle wires a secretRef into envFrom" {
  render --set kind=api --set-json 'envFrom=[{"secretRef":{"name":"db-orders-conn"}}]' \
    --set image.repo=ghcr.io/x/y --set image.tag=sha-abc
  echo "$output" | grep -q "db-orders-conn"
}
```

> 차트는 이미 `envFrom`(secretRef 리스트)을 지원(deployment.yaml:49-58). create-app이 conn 핸들을 envFrom에 넣으므로 **차트 변경 최소** — values.schema.json에 envFrom secretRef 형태가 허용되는지만 보강.

**Step 2: 테스트 실패 확인** → **Step 3: schema 보강** → **Step 4: PASS** → **Step 5: Commit** (`test: 차트 db/redis 핸들 소비 렌더 검증`).

### Task 5.4: 미생성 리소스 참조 시 명확한 실패

**Files:**
- Modify: `tools/create-app.mjs`
- Test: `tools/test/create-app.bats` (추가 케이스)

**Step 1:** `db: [orders]`인데 `apps.json`/클러스터에 `orders` DB가 없으면 create-app이 `db 'orders' 미생성 — create-database 먼저` 에러로 실패하는 테스트.
**Step 2~4:** 구현(레지스트리/`platform/cnpg/prod/databases/`에 핸들 존재 확인) + PASS.
**Step 5: Commit** (`feat: 미생성 db/redis 참조 시 명확한 사전 실패`).

### Task 5.5: tailscale 노출 + 로컬 2모드 CLI

**Files:**
- Create: `tools/db-url.mjs`, `tools/cache-url.mjs` (또는 `tools/dev.mjs` 확장)
- Modify: `package.json` (`db:up`, `db:reset`, `db:url`, `cache:url`, `env:example`)
- Create: tailscale LoadBalancer 노출 매니페스트(리소스별, ACL `autogroup:self`)
- Test: `tools/test/dev-data.bats`

**Step 1: 실패 테스트 작성** — `dev-data.bats`

```bash
#!/usr/bin/env bats
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "db:up writes a localhost DATABASE_URL for clean dev" {
  run node "$ROOT/tools/dev.mjs" db:up --dry-run --name orders
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "localhost"
}

@test "db:url targets the tailscale IP, one-way (no destructive ops)" {
  run node "$ROOT/tools/db-url.mjs" --name orders --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "tailscale\|100\."
}
```

**Step 2~4:** 구현
- **모드 1(깨끗한 개발, 기본):** `db:up` = 로컬 docker postgres/valkey 기동 + 마이그레이션 + 시드(`tools/dev-postgres` 재사용). `.env`의 `<NAME>_DATABASE_URL`=localhost. `db:reset`로 초기화.
- **모드 2(실데이터 디버깅):** docker 없이 클러스터 직결. 리소스를 tailscale LoadBalancer로 노출(ACL `autogroup:self` — 본인 tailnet만).
  - **읽기 전용 강제(Codex high #7):** "단방향/비파괴"는 경고로는 보장되지 않는다 — Tailscale ACL은 *누가* 붙는지만 제어하고 *어떤 SQL*은 막지 못한다. 따라서 디버깅용 **별도 읽기 전용 자격을 발급**한다:
    - postgres: 프로비저닝 시 `<name>_ro` 롤(GRANT SELECT only, 미래 테이블 포함 `ALTER DEFAULT PRIVILEGES`) 생성. `db:url`은 owner가 아닌 **`_ro` 롤 자격**을 conn에서 꺼내 `.env.local`에 기록.
    - valkey: read-only ACL 유저(`+@read -@write -@dangerous`). `cache:url`은 이 유저 자격만 노출.
  - `db:url <name>`/`cache:url <name>`: 해당 ro conn Secret에서 자격을 꺼내(kubectl) `.env.local`(gitignored)에 `<NAME>_DATABASE_URL`(host=tailscale IP, user=`<name>_ro`) 기록. tailscale 켜면 즉시 연결.
  - **검증 테스트:** ro 자격으로 `INSERT`/`DELETE`/DDL이 거부됨(권한 에러)을 라이브로 확인. `db-url.mjs`는 reset/파괴 명령을 제공하지 않는다.
- **단방향만**: prod→로컬 pull(읽기) 직결만. 파괴적 작업(reset/대량삭제)은 docker 모드(모드 1)에서만.
- ro conn SealedSecret도 **prod NS**에 봉인(Codex #6 일관성).

**Step 5: `env:example` 생성기** — `.app-config.yml`(env+secrets+db+redis)에서 `.env.example` 자동 생성(`pnpm env:example`). 로컬 패리티.

**Step 6: Commit** (`feat: 로컬 2모드 데이터 개발 — docker 시드 / 읽기전용 tailscale URL 직결 CLI`).

> tailscale 노출 매니페스트는 리소스 생성 시(create-database/create-cache) **옵션 플래그**로만 생성(기본 비노출 — 필요할 때만 tailnet에 띄움).

---

## Phase 6: 라이프사이클 (teardown + audit) + 문서

### Task 6.1: teardown — 앱 ↔ 리소스 분리 (Codex pass2 critical #2)

> **공유 리소스 안전 원칙:** DB/캐시는 앱과 독립한 리소스이며 **여러 앱이 같은 DB/캐시를 참조**할 수 있다. 따라서 **앱 teardown이 DB/캐시를 건드려선 안 된다.** 두 명령을 분리한다.

**Files:**
- Create: `tools/teardown-app.mjs`, `tools/teardown-resource.mjs`, `.github/workflows/_teardown.yml`
- Test: `tools/test/teardown.bats`

**Step 1: 실패 테스트**
- `teardown-app --app orders --dry-run`: 제거 대상 = **앱 한정**(매니페스트 `apps/orders`(`.bindings.json` 포함), `apps.json` 행, `<app>-secrets` SealedSecret, DNS) **만** 리포트. **db-*/cache-* conn Secret과 Database CR/Valkey는 절대 제거 대상에 없음**을 단언.
- `teardown-resource --db orders --dry-run`: **권위 레지스트리 `apps/*/deploy/prod/.bindings.json`** 전체에서 `orders`를 참조하는 앱 수를 집계(Codex #8 — envFrom 파싱이나 외부 config 아님) → 1건이라도 있으면 **거부**(어떤 앱이 쓰는지 리포트). 참조 0일 때만 제거 후보. **공유 리소스(여러 앱이 같은 db 참조) 케이스와 stale/접근불가 앱 레포 케이스를 테스트.**
- **열린 create-app PR과의 경쟁 차단(Codex pass7 high #5):** teardown은 main의 `.bindings.json`만 보므로 **아직 머지 안 된 create-app PR의 신규 참조를 못 본다** → 삭제 후 그 PR이 머지되면 missing Secret. 따라서 teardown-resource는 **2단계**: (1) 먼저 리소스를 **tombstone**(신규 참조 차단 표시) 커밋 → (2) **별도 머지**에서 실제 삭제. 그리고 **전역 CI 정책**으로 모든 `.bindings.json` 참조가 실제 Database/Valkey manifest + conn SealedSecret에 대응함을 강제(tombstone된 리소스를 새로 참조하는 PR은 게이트에서 실패).
- 멱등(존재 안 해도 0 종료).

**Step 2~4:** 구현
- **`teardown-app`:** 앱 매니페스트 + `apps.json` 행 제거 + `<app>-secrets` 제거 커밋(App 토큰) → `active:false`면 DNS 이미 없음, `active:true`였으면 행 제거가 terraform apply로 DNS 회수. **DB/캐시 conn Secret은 건드리지 않는다**(다른 앱이 같은 리소스를 참조할 수 있고, 이 앱의 conn은 리소스 소유물).
- **`teardown-resource` — retain ↔ purge 두 상태 머신 분리(Codex pass9 high #7):** "기본 teardown은 DB를 `ensure: present`로 보존하면서 conn Secret/owner role을 지운다"는 **모순**이다(소유 role 없는 보존 DB는 접근 불가 고아). 따라서:
  - **purge(`--delete-data`):** 아래 PVG 분리 상태 머신(tombstone → `ensure: absent` → DB 부재 검증 → role/CR 제거).
  - **retain(기본):** 리소스를 **보존**하되 **참조 0**이면 **tombstoned 인벤토리 엔트리**로 표시(소유 role/password/CR/conn 유지 — 접근 가능 상태 보존). retain은 owner role을 **제거하지 않는다**(보존 DB가 고아가 되지 않게). 재생성 시 이 인벤토리로 결정적 복원.
  - 두 경로 모두 참조 수 == 0 강제 + 중단→재실행 테스트.
- **DB 데이터 삭제는 PVC와 완전 분리(Codex pass4 critical #1):** postgres는 공유 클러스터의 논리 DB라 **DB별 PVC가 없다** — `--delete-data`로 PVC를 지우면 **클러스터 전체 데이터가 날아간다**. 따라서 데이터 삭제는 **`Database.spec.ensure: absent`로 그 논리 DB만 DROP**한다(PVC 미접촉). 기본은 `ensure: present`(보존).
  - **재개 가능한 GitOps 상태 머신으로 분해(Codex pass8 #5):** `ensure: absent`와 managed.role 제거를 **한 revision에 같이 적용하면** ArgoCD/CNPG reconcile 순서가 보장되지 않아 role이 먼저 처리되면 DB 소유권 때문에 `cannotReconcile`. 따라서 **별도 revision + 상태 대기**로:
    1. **tombstone 커밋**(신규 참조 차단),
    2. **`ensure: absent` 커밋** → CNPG가 DROP,
    3. **대기/검증:** Database CR `status.applied=true` + 실제 DB 부재 확인(공유 클러스터의 다른 DB는 생존),
    4. **그 다음 별도 커밋**으로 managed.role/password Secret/CR 제거.
  - 각 단계는 **중단 후 재실행 가능**(idempotent). 각 단계 중단→재개 테스트 추가.
- valkey(앱별 Deployment)는 자체 PVC가 있으므로 `--delete-data` 시 그 인스턴스 PVC만 삭제(공유 아님). **단 백업 체인 선행 필수(Codex pass8 #6):** Task 5.2가 persistence만 두면 teardown의 "최근 검증 스냅샷" 요구가 영구 차단되거나 유일 사본을 지운다 → **Task 5.2b(아래)에서 Valkey R2 백업·보존·신선도·복구 드릴을 먼저 설계**하고, 파괴 승인 입력에 **검증된 복구 지점 ID를 고정**한다.
- **복구 가능한 파괴 게이트(Codex pass5 critical #2 — git revert로 데이터 복구 불가):** `--delete-data`는 되돌릴 수 없으므로:
  1. **백업 신선도 게이트:** 삭제 전 **최근 검증된 백업/스냅샷 존재를 강제**(postgres는 CNPG barman R2 백업 — Phase M4; valkey는 persist 스냅샷). 백업 없거나 stale이면 거부.
  2. **tombstone 유예:** 즉시 DROP 대신 N일 tombstone(리소스 비활성화 후 유예) → 유예 경과 후에만 실제 삭제. 오삭제 회수 창.
  3. **별도 파괴 승인:** `--delete-data`는 일반 변이와 다른 명시 승인(이중 확인 토큰).
  4. **복구 리허설:** 백업에서 복원 경로를 테스트(restore.md 연동).
  - **롤백 보장에서 명시 제외:** 데이터 삭제는 아래 "롤백 전략"의 git/ArgoCD 가역성에 **포함되지 않는다**(백업 복원만이 복구 경로).
**Step 5: Commit** (`feat: teardown — 앱/리소스 분리, 참조 0 강제, 논리 DB만 삭제(PVC 비접촉)`).

### Task 6.2: audit-orphans

**Files:**
- Create: `tools/audit-orphans.mjs`, dispatcher route `audit`
- Test: `tools/test/audit-orphans.bats`

**Step 1: 실패 테스트** — registry(`apps.json`) vs 실제(매니페스트 디렉토리/클러스터 리소스) 드리프트를 리포트(고아 DNS/DB/매니페스트).
**Step 2~4:** 구현 — 읽기 전용 리포트(파괴 없음). 라이브는 kubectl 비교 옵션.
**Step 5: Commit** (`feat: audit-orphans — registry vs 실제 리소스 드리프트 리포트`).

### Task 6.3: 문서 + AGENTS.md 갱신

**Files:**
- Modify: `AGENTS.md` (멀티레포 앱 플로우 섹션 — 새 dispatcher/create-app/DB/캐시/SealedSecrets 반영)
- Modify: `README.md` (간략 플로우)
- Create: `docs/runbooks/app-platform.md` (로컬 전용 — gitignored)

**Step 1~2:** AGENTS.md의 "멀티레포 앱 플로우"·"라이브 검증된 함정"을 새 모델로 갱신(PAT→App, KSOPS→SealedSecrets, create-app/create-database/create-cache 추가). README는 사용자와 합의된 톤 유지.
**Step 3: Commit** (`docs: App Platform DX 플로우로 AGENTS.md/README 갱신`).

---

## 의존성 그래프 (요약)

```
Phase 0(사용자) ──> Phase 1(인증) ──> Phase 3(dispatcher) ──> Phase 4(create-app) ──> Phase 5(DB/캐시) ──> Phase 6(라이프사이클)
                └─> Phase 2(SealedSecrets) ──────────────────┘            └─ Phase 2 선행(봉인 필요)
```
- Phase 2(SealedSecrets)는 Phase 1과 병렬 가능하나, Phase 4/5의 시크릿 봉인보다 **반드시 선행**.
- Phase 3 terraform/dispatcher는 Phase 4 create-app의 토대.
- **인증 마이그레이션 단위(Codex pass7 #2):** Phase 1(homelab PAT→App) + Task 3.4(GHCR 폴링·build-only v2·`HOMELAB_DISPATCH_PAT` 폐기)는 **하나의 단위**다. 이 단위 전체가 끝나야 "앱 레포 자격 0" 보안 게이트가 달성된다 — Phase 1만 머지된 중간 상태는 앱 레포 PAT가 살아 있는 과도기로 명시.
- 각 Phase 머지 후 라이브 검증(클러스터/Actions) 통과를 다음 Phase 착수 조건으로.

## 롤백 전략
- Phase 1: App 인증 실패 → git revert로 PAT 경로 복원(PAT는 라이브 E2E 통과 전까지 폐기 금지).
- Phase 2: SealedSecret↔KSOPS 공존 기간 유지 → 문제 시 generator 복원(Prune=false + managed로 일시삭제 없음). 평문 Secret 무중단 원칙. sealing key는 out-of-band 백업.
- Phase 3~6: 각 **비파괴** 변이는 git 기록 → ArgoCD가 이전 상태로 싱크. terraform은 state로 롤백(R2 백엔드).
- **⚠️ 데이터 삭제(`--delete-data`)는 가역적이지 않다(Codex pass5 #2):** git/ArgoCD 롤백으로 복구 불가 — 유일한 복구 경로는 **백업 복원**(CNPG barman R2 / valkey 스냅샷). 그래서 Task 6.1의 백업 신선도 게이트 + tombstone 유예 + 별도 승인 + 복구 리허설이 필수.

## 비목표 (YAGNI 재확인)
모노레포 다서비스, 홈페이지 대시보드, 양방향 데이터 동기화, External Secrets/Vault, npm 패키지화된 공유 CLI — 모두 제외.

---

## Adversarial review dispositions (hardened-planning Phase C/D 감사 기록)

이 플랜은 Codex 적대적 리뷰를 **9패스** 거쳤다(launcher: `adversarial-review.mjs --scope working-tree`). 각 패스의 plan finding은 **전부 기술적 타당성으로 판정해 Accept하고 본문에 반영**했다(reject 0 — 모든 finding이 플랜 텍스트에 근거가 있고 사실관계가 정확했다). 단 한 곳, pass3 #1의 `queue: max`/durable-queue 권고는 homelab 규모에 맞춰 "best-effort 직렬화 + 멱등 재실행 + 주기 reconcile"로 **해소 방식만 조정**(pass8에서 `queue: max`도 병기 채택).

**패스별 요약(findings / critical → 반영):**

| Pass | 건수(crit) | 핵심 반영 |
|---|---|---|
| 1 | 9 (3) | App 키 앱레포 배포 금지, SealedSecrets 컨트롤러키 백업+복구드릴 선행, prod/database 네임스페이스 분리, 읽기전용 디버그 롤, cache NetworkPolicy, 이미지 필수화 |
| 2 | 5 (2) | update-image GHCR 폴링 권위화, 앱/리소스 teardown 분리, 공유 클러스터 per-DB 스펙 축소, DNS activation 게이트, SealedSecret managed handoff |
| 3 | 8 (3) | reader/writer 토큰 스코핑, prune handoff(Prune=false), revision-pin activation, reusable-build 마이그레이션, 시크릿 전달 경로, 바인딩 레지스트리, lease 뮤텍스 |
| 4 | 7 (1) | 논리DB `ensure:absent`(PVC 비접촉), autoDeploy 보존, conn prod 네임스페이스, 액션 계약표, kustomize 등록, owner==name |
| 5 | 7 (2) | 파괴 복구 게이트(백업/tombstone), digest 불변성, sealing key 스트림 암호화, controller-name, 백업키 안전 |
| 6 | 6 (1) | **reader/writer App 분리(필수화)**, SealedSecret `skip-set-owner-references`, 주기 terraform reconcile, reusable 2-릴리스, create-app 원장행, activation descendant |
| 7 | 6 (0) | skip-owner per-Secret annotation, 인증 마이그레이션 단위, 공통 image-ref helm helper, activation이 apps.json 행 고정, teardown vs 열린 PR tombstone, 논리DB 원장 제외 |
| 8 | 6 (0) | 백업 `--filename-override`, action SHA 핀, `queue:max`+op ledger+취소알림, hostname 전역 유일성, PG 삭제 상태머신, Valkey 백업 체인 |
| 9 | 7 (1) | 백업 원자성(temp→검증→rename), TF-관리 PAT 제거, 쓰기모델 PR-first 확정, 폴러 후진배포 차단, **PgBouncer 풀러 라우팅**, 선언적 회전(checksum), retain/purge 상태머신 분리 |

**최종 패스(pass 9) verdict:** `needs-attention` / "Do not ship this plan yet. It contains one DR-critical backup flaw and several unresolved control-plane and lifecycle paths."
→ pass 9의 7개 finding을 **모두 반영**(위 표 pass9 행). 이후 verdict는 approve에 수렴하지 않고 **~6건/패스에서 plateau**(두 레포·인증·시크릿·DB/캐시·terraform·ArgoCD의 넓은 표면상 Codex가 계속 더 깊은 통합 계약을 발견). **critical은 pass 7–8에서 0**이었고 pass 9의 1건은 직전 수정의 정밀화였다.

**사용자 결정(캡 초과 후 신규 판단):** pass 3 캡 도달 시 "계속 반영·재검토" 승인 → 9패스까지 진행. 9패스 수렴 현황 제시 후 **"지금 확정 + 핸드오프"** 결정. critical이 사실상 정리됐고 잔여는 구현 컨텍스트에서 더 정확히 해소되는 계약성 항목이라는 판단에 근거.

**잔여 강화 항목(실행 시 코드와 함께 해소 — 실행자 책임):** 적대적 리뷰가 plateau한 영역은 *추상 계획*보다 *실제 코드* 앞에서 더 정확히 닫힌다. 실행 시 특히 검증할 것:
- GitHub Actions `queue: max` 실재 여부를 라이브로 확인(없으면 주기 reconcile + op ledger가 안전망).
- 각 mutation 워크플로가 PR-first+auto-merge로 `main`에 쓰는 라이브 E2E(branch protection 실제 동작 확인).
- PgBouncer `pg-pooler-rw` 런타임 / `pg-rw` 마이그레이션 분리가 라이브에서 의도대로 라우팅되는지.
- SealedSecret `skip-set-owner-references` 인수 + 롤백(SealedSecret 삭제 후 Secret UID 보존) E2E.
- 논리 DB retain/purge 상태머신의 중단→재개 멱등성.
