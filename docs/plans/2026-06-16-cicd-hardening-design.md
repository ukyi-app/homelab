# CI/CD 하드닝 — 설계 (2026-06-16)

## 배경

홈랩 GitOps 모노레포의 CI/CD 전 표면(GitHub Actions 17개 워크플로 + composite action 3종 +
CI 호출 `tools/*.mjs` 16개 + Makefile 게이트, 약 4,150줄)을 멀티에이전트 적대적 감사로 분석했다.
6개 파일그룹 매핑 → 6차원(보안·동시성·실패모드·드리프트·유지보수·관측) 적대적 감사 → 발견별
독립 검증 → 종합. **41개 발견 중 39개가 검증 통과**, 8개 테마로 정리됐다.

전제: 이 레포의 CI/CD는 **이미 성숙하게 하드닝**돼 있다(fail-closed 신뢰경계, `queue:max` 직렬화,
descendant+digest 증명, `prevent_destroy`, PVC-safe purge 상태머신). 발견은 구조적 붕괴가 아니라
**남은 갭**이다. 본 설계는 owner가 선택한 **전체 스윕(P0+P1+P2) + 인접 deadmanswitch**를 다룬다.

## 스코프

39개 검증 발견 전부 + deadmanswitch-relay(인접, monitoring 백스톱) = 약 40개 항목.
**격리**: `git worktree`(`feat/cicd-hardening` @ origin/main)에서 수행 — 무관한
`feat/argocd-ui-internal` 작업을 건드리지 않는다.

## 접근법

**테마/공유인프라별 단계 PR, 라이브버그 우선.** 39개를 공유 리메디에이션 인프라(composite/lib) +
심각도로 묶어 9단계로 구성한다. 각 단계는 자체 게이트 테스트로 독립 머지 가능(레포의 PR-first +
auto-merge 모델과 정합). owner-local apply가 필요한 infra/github 변경(단계 5)만 별도로 명시.

대안 기각: "라이브 핫픽스 1 PR + 나머지 1 PR"(B, 리뷰·bisect 불가) / "순수 심각도순"(C, 공유
composite가 단계를 가로질러 쪼개져 재작업).

## 공유 리메디에이션 인프라 (중복 제거 — 먼저 구축)

1. **`tf-destroy-guard` composite** (`mode: warn|block`) — `terraform show -json | jq 'delete count'`
   단일 구현. drift-1(apply=block)·iac-plan/reconcile(warn) 공용.
2. **`tf-r2-init` composite** (inputs: root, state-key) — backend.hcl 작성 + `init -lockfile=readonly`.
   현재 5곳 중복(iac×1, tf-reconcile×3, iac-plan×1) SSOT화.
3. **`setup-toolchain`에 `kubeseal` input 추가** + **`setup-node-pnpm` composite**(node-version·pnpm
   corepack 핀 1곳). 인라인 curl(onboard/_create-app/_create-cache/_create-database)·node블록(9곳) 흡수.
4. **`tools/lib/identity.mjs`** — `APP_NAME_RE` SSOT. 현재 4종 분기 regex를 validator 정책
   `^[a-z][a-z0-9-]{0,38}[a-z0-9]$`로 6개 콜사이트 수렴.
5. **notify source-label 검증 bats** — 모든 워크플로 `.with.source` ∈ `notify.sh` enum(양방향:
   dead enum 멤버도 검출). obs-1의 근본원인 차단.

## 9단계 프로그램

### 단계 1 — 라이브 알림 + source 가드 (P0, 테마1) · auto-merge
- **obs-1**: `notify.sh:25` enum 건초더미에 `IaC드리프트` 토큰 추가(라이브 버그: github/tailscale
  드리프트 알림이 `exit 2`로 침묵 + run 빨개짐).
- **obs-2**: 위 source-label 검증 bats(공유 #5)를 `gate` 글롭에 배선.

### 단계 2 — mutator fail-closed (P0, 테마4) · auto-merge
- **dry-3**: `bump-tag.mjs`에 `ALLOWED_FLAGS` 가드(오타 `--digest`가 digest 핀을 삭제하고 exit 0 →
  공급망 핀 무력화) + `--expect-current` 옵션(races-4 TOCTOU 방어) + `bump.bats` 단언.
- **dry-4**: `teardown-app.mjs`·`teardown-resource.mjs`에 동일 가드(mutator 패밀리 균일 fail-closed).
- **dry-6**: `tools/lib/identity.mjs`(공유 #4) 도입 + 6콜사이트 수렴.

### 단계 3 — 무인 destroy 가드 + entitlement 게이트 (P0, 테마3) · auto-merge
- **drift-6**: 공유 composite 2종(`tf-destroy-guard`, `tf-r2-init`) 구축.
- **drift-1**: `iac.yaml` apply job이 `tf-destroy-guard mode=block` 사용(현재 primary apply 경로에
  destroy 가드 부재 — PR 주석은 "차단"이라 약속). iac-plan은 `mode=warn`.
- **drift-5**: `waf.tf`/`cache.tf` free-plan entitlement(rate-limit `period==10` &&
  `mitigation_timeout==10` && ruleset 식에 `matches(` 금지)를 conftest/bats 룰로 `gate`에 배선
  (현재 apply-time 400으로만 드러남).
- **drift-2**: reconcile destroy-guard가 "main에 이미 커밋된 예상 삭제"와 "드리프트 삭제"를 구분
  (또는 alert-and-skip로 비-삭제분 수렴 허용) → 합법 teardown이 30분마다 영구 차단되는 것 해소.
  경량 live-DNS 수렴 체크(apps.json active:true host CNAME→tunnel 타겟)는 destroy-guard와 분리.

### 단계 4 — secret-guard 강제 + 분기보호 불변식 (P0, 테마2 부분) · auto-merge
- **supplychain-3**: gitleaks + sops-guard를 `gate` job에 폴딩(코드 전용, 머지 즉시 발효 —
  `verify`를 required contexts에 추가하는 owner-local apply 경로보다 우선).
- **supplychain-7**: `sops-guard.sh` substring grep → 실제 `sops --decrypt` 검증(또는 구조화
  `sops.mac` 키 + data 비평문 확인).
- **supplychain-1 (부분만 채택)**: `infra/github/repo.tf`의 `required_status_checks.contexts ⊇ {gate}`
  && `strict == true`를 tf bats로 단언(게이트 무인 relaxation 차단) + `enforce_admins=false` 잔여
  위험 문서화. **기각**: `required_approving_review_count=1`(솔로 오너 auto-merge 파괴),
  `require_last_push_approval=true`(`count=0`에선 사실상 no-op).

### 단계 5 — standing 자격증명 제거 (P0, 테마2) · PR + owner-local apply
- **supplychain-2**: `infra/github/secrets.tf`의 `github_actions_secret "bot_pat"`(DEPLOY_BOT_PAT) +
  `variables.tf`의 `variable "bot_pat"` 제거(App 마이그레이션 후 워크플로 소비자 0 — grep 확인).
  `terraform.tfvars.example`/`auth.bats` 갱신.
- ⚠️ **시퀀싱**: github 루트는 신뢰앵커라 CI 무인 apply 금지(AGENTS.md). 코드 제거 머지 →
  tf-reconcile `drift-github`가 DEPLOY_BOT_PAT destroy 드리프트 알림 → owner 로컬
  `terraform -chdir=infra/github apply`로 라이브 시크릿 삭제. 런북에 절차 기록.

### 단계 6 — 동시성 직렬화 (P1, 테마6) · auto-merge
- **races-1·2**: `bump.yaml`을 `group: values-writeback` → `group: homelab-mutation` +
  `queue: max`로(문서화된 전역 직렬화 복원; 인-repo bump 유실 차단). `bump.bats`가 정확한
  group/queue 단언(현재 "group 존재"만 확인).
- **races-6**: auto-merge fallback을 already-clean 케이스로만 판별(`gh pr view --json
  mergeStateStatus == CLEAN`일 때만 직접 머지) — 6콜사이트. (contexts/strict tf 단언은 단계4.)
- **races-3 / obs-5**: stale auto-merge-pending PR 스위퍼(스케줄 — `gh pr update-branch` 또는 알림).
- **races-4**: bump-poll 루프가 `git checkout main` 후 현재 tag 재검증(`--expect-current`, 단계2).
- **races-5**: activate-app가 증명한 syncedRev/SHA를 커밋된 마커로 남기고 audit-orphans가 active:true
  행의 마커 SHA == 현재 tree hash 확인(경량 — surface 변경이 PR 게이트 재트립).
- **fm-2**: `onboard.yaml` 고정 브랜치명 → `onboard/${APP}-${RUN_ID}`(재dispatch 충돌·dangling 차단).

### 단계 7 — DRY/SSOT + 공급망 위생 (P2, 테마7) · auto-merge
- **dry-1**: onboard/_create-app/_create-cache/_create-database 인라인 curl → `setup-toolchain`
  채택(`kubeseal` input 추가 — 공유 #3).
- **dry-2**: kubeseal 핀 v0.27.3(cache) → v0.37.0(controller appVersion)로 수렴(seal/unseal 호환).
- **supplychain-5**: setup-toolchain 모든 다운로드에 SHA256 `sha256sum -c` 검증 + `age`를 고정
  버전으로 핀(현재 `latest`).
- **dry-7**: `setup-node-pnpm` composite(공유 #3) 9곳 채택.
- **drift-6 (계속)**: `tf-r2-init` composite 5콜사이트 적용.
- **supplychain-8 / dry-5**: 인라인 `create-github-app-token@<sha>` 13곳이 canonical(homelab-token)
  핀과 일치하는지 CI 단언 + homelab-token composite 삭제 또는 reference-only 문서화.
- **supplychain-6**: `.apprepo/`를 `.gitignore`에 추가 + `_teardown.yml`의 `git add -A`를 명시 경로로.

### 단계 8 — doc rot + 감사 커버리지 + 가시성 (P2, 테마8 + P1, 테마5 잔여) · auto-merge
- **dry-8**: `ci.yaml:38` 주석을 실제 BLOCKING 셋과 일치(stale-ledger-row는 미차단).
- **dry-9**: `verify.yml`·`Makefile`이 `pnpm verify:ledger`(SSOT) 호출(인라인 conftest 3중 복제 제거).
- **drift-3**: orphan-dns 블로킹을 active:true 행으로만 한정(active:false는 정보).
- **fm-3**: teardown ledger Totals 치환이 실제 발화했는지 단언(prose drift 시 silent no-op 차단) +
  Totals 포맷 헬퍼 공유(create-app/provision-cache/teardown-app).
- **fm-4**: `poll-ghcr.mjs`가 manifest 404와 transient 오류 구분(non-404는 rethrow → `refuse`).
- **fm-5**: audit-orphans에 dangling-role 체크(CR/conn 부재인데 cluster.yaml managed.roles에 잔존).
- **obs-3**: `build.yaml`에 `if: always()` telegram-notify(`source: 배포`).
- **obs-4**: dispatch-mutation `notify-failure`를 `failure() || cancelled()`로.
- **obs-6**: `_audit.yml` telegram body의 `[:20]` 캡 제거(notify.sh 4096 캡에 위임) + `|| true`
  에러삼킴 제거.

### 단계 9 — dead-man switch (인접, P1, fm-1) · auto-merge
- **fm-1**: `deadmanswitch-relay.yaml` 루프가 `nc`가 실제로 요청을 서빙했을 때만 healthchecks ping
  (실패 분기엔 floor `sleep` → bind 이상 시 self-throttle, healthchecks 폭주·dead-man switch
  무력화 차단). 문서화된 `-q` 인시던트와 동류. bats로 "nc 실패 시 wget 도달 불가" 단언.

## 테스트 전략 (TDD)

- 각 발견은 **실패하는 테스트 먼저** → 수정 → 통과. 신규 bats는 `tools/test/`·`infra/_test/` 글롭에
  자동 포함(게이트가 강제 — 하드코딩 목록 누락 버그 회피). conftest 룰은 `policy/`.
- bats `@test` 이름은 영어(한글 인코딩 깨짐 함정). 중간 단언은 `[ ]`(bash 3.2 `[[ ]]` 침묵통과 함정).
- 라이브 의존 항목(drift-2 live-DNS, races-5 activate Healthy)은 정적 단언 + 런북 절차로 분리
  (CI는 클러스터 비접촉).

## 시퀀싱 · 리스크

- 단계 1~4·6~9는 auto-merge(`gate` 통과). **단계 5만 owner-local apply**(github 루트=신뢰앵커).
- 공유 composite(단계 3·7)는 의존 단계보다 먼저 구축.
- 각 단계는 독립 PR — adversarial review·bisect 가능. 단계 간 파일 충돌 최소(대부분 직교).
- 잔여 위험: drift-2 live-DNS 체크와 races-5 activate 마커는 가장 무겁다 — 구현 중 과대해지면
  경량 정적 버전으로 축소하고 라이브 검증은 런북으로 분리(계획에서 명시).

## 감사 출처

멀티에이전트 적대적 감사(54 에이전트, 39/41 검증 통과). 최상위 라이브 항목은 owner 정독으로 교차확인:
notify.sh enum 결손·DEPLOY_BOT_PAT 무소비자·iac.yaml apply destroy 가드 부재·bump-tag digest 핀 무력화.
