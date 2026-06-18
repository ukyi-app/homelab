# v1 onboarding 폐기 + 템플릿 v2 이행 — 구현 플랜

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 죽은(deprecated+orphaned) v1 onboarding 경로를 homelab에서 전면 제거하고 외부 템플릿을 v2(`.app-config.yml`)로 이행해, 권위 온보딩 경로를 `✨ create-app` 단일로 만든다.

**Architecture:** 두 개의 독립 레포 변경 — **A**(외부 `ukyi-app/homelab-app-template`: `.homelab.yaml`→`.app-config.yml` + README + secret flow)와 **B**(homelab: `onboard.yaml`/`onboard-app.mjs`/`homelab-app-schema.json`/`test_onboard.bats` 삭제 + 참조 테스트·문서·워크플로 정리 + 영구 stale-ref 가드). **A→B 머지 순서 필수**(A.5 F1): A가 먼저 머지·검증돼야 템플릿산 앱이 온보딩 경로를 잃지 않는다.

**Tech Stack:** GitHub Actions(reusable workflow), Node 22 tools(create-app.mjs/validate-mutation.mjs), JSON Schema(app-config-schema.json), bats(`scripts/run-bats.sh` 수집), shellcheck, terraform(github 루트 — owner-local apply).

**설계 SSOT:** `docs/plans/2026-06-18-retire-v1-onboarding-design.md` (A.5 F1 반영본).

---

## 작업 전 필독 (함정)

- **bats `@test` 이름 영어**; 중간 단언 `[ ]`/`run`+`[ "$status" ]`(bash 3.2 `[[ ]]` 침묵통과); `declare -A` 금지.
- **KSOPS 오삭제 금지**: 제거 대상은 `onboard-app.mjs`의 v1 app-secret KSOPS 분기뿐. 플랫폼 KSOPS(`kustomize --enable-exec`, cnpg 등)는 불변.
- **공유 lib 유지**: `tools/lib/identity.mjs`·`tools/lib/ledger-totals.mjs`(create-app 등 공유) 삭제 금지.
- **A→B 머지 순서**: B의 PR은 만들되 **A PR 머지 + 템플릿 dry-run 통과 후에만 머지**(finishing 단계에서 강제).
- **full `run-bats`/`make ci`는 마지막에**; 중간은 타겟 bats. 피처 브랜치 중간 red 허용.
- 하네스 셸=zsh(URL의 `?`는 인용), node는 mise, 워크트리는 이미 생성됨.

---

# Phase A — 템플릿 v2 이행 (외부 레포, B보다 먼저 머지)

> 외부 `ukyi-app/homelab-app-template`. 임시 clone에서 작업 → PR. homelab 워크트리와 무관.

## Task A1: 템플릿 clone + 브랜치

```bash
rm -rf /tmp/halt && gh repo clone ukyi-app/homelab-app-template /tmp/halt -- --quiet
git -C /tmp/halt checkout -b feat/v2-app-config
```

## Task A2: `.app-config.yml` 작성 (v1 `.homelab.yaml` 대체)

**Files:** Create `/tmp/halt/.app-config.yml`, Delete `/tmp/halt/.homelab.yaml`

`.app-config.yml` (v2 — `app-config-schema.json`, required `kind`·`resources`):
```yaml
# 이 앱의 자기선언(v2) — homelab create-app이 main HEAD에서 read해 배포 설정을 생성한다.
# 계약(전체 필드/규칙): ukyi-app/homelab → tools/app-config-schema.json
kind: service              # service | worker | static
resources:                 # 필수 — 메모리 예산 원장 게이트 대상
  requests: { cpu: 50m, memory: 64Mi }
  limits: { cpu: 500m, memory: 128Mi }
route:
  public: false            # true=<앱>.ukyi.app(공개) / false=<앱>.home.ukyi.app(내부). host:로 오버라이드
db: []                     # 선프로비전 DB 이름 배열. 예: [orders] — 먼저 ✨ create-database로 생성
redis: []                  # 선프로비전 캐시 이름 배열. 예: [sessions] — 먼저 ✨ create-cache로 생성
# migrate: { cmd: ["node", "migrate.js"] }   # db 사용 + 마이그레이션 시 주석 해제(wave-1 Job)
env: []                    # 평문 설정만 — 비밀은 secrets:로 선언
secrets: []                # 예: [my-app-secrets] → pnpm secret:seal로 봉인, create-app/update-secrets가 배선
deploy:
  autoDeploy: true         # false면 .bindings.json autoDeploy=false → bump 승인 PR
```

```bash
git -C /tmp/halt rm .homelab.yaml
```

## Task A3: README 갱신 (v1 표현 → v2)

**Files:** Modify `/tmp/halt/README.md`

- step 2: `.homelab.yaml 수정` → `.app-config.yml 수정 (kind/resources/route/db/redis/env/secrets)`.
- "## 비밀 값" 절: `.homelab.yaml의 secrets:` → `.app-config.yml의 secrets:`, 안내를 **`pnpm secret:seal`(SealedSecret)** 로(KSOPS/SOPS 언급 제거).
- (이미 PR #1에서 온보딩 흐름은 정정됨 — push=빌드, 온보딩=owner create-app. 유지.)

## Task A4: 검증 — create-app dry-run (권위 검증기)

homelab 워크트리에서(create-app.mjs가 거기 있음) 템플릿 config를 검증:
```bash
cd "$(git -C /tmp/halt rev-parse --show-toplevel)" >/dev/null  # (참고용; 실제론 homelab 워크트리에서 실행)
cd /Users/ukyi/workspace/homelab/.claude/worktrees/refactor+retire-v1-onboarding
node tools/create-app.mjs --config /tmp/halt/.app-config.yml --app demo \
  --repo ukyi-app/demo --domain ukyi.app --tag sha-deadbeef --digest sha256:0000000000000000000000000000000000000000000000000000000000000000 --dry-run
```
Expected: 스키마+비즈니스 규칙 통과(plan JSON 출력). db/redis/secrets 빈 배열이라 리소스 참조 검사 무통과 없음. 실패 시 메시지대로 `.app-config.yml` 수정.

## Task A5: 커밋 + PR

```bash
git -C /tmp/halt config user.name ukkiee; git -C /tmp/halt config user.email ukyi.js@gmail.com
git -C /tmp/halt add -A
git -C /tmp/halt commit -m "feat: v2 .app-config.yml로 이행 (.homelab.yaml 폐기)"
git -C /tmp/halt push -u origin feat/v2-app-config
gh pr create -R ukyi-app/homelab-app-template --base main --head feat/v2-app-config \
  --title "feat: v2 .app-config.yml 이행" --body "v1 .homelab.yaml → v2 .app-config.yml(create-app 경로). README 시크릿 안내 pnpm secret:seal로. create-app --dry-run 통과 검증."
```
> **이 PR(A)을 먼저 머지**해야 B로 진행 안전(A.5 F1). 머지는 owner 확인.

---

# Phase B — homelab v1 폐기 (이 워크트리, A 머지 후)

## Task B0: cutover 감사 — v1 소비자 인벤토리 0 확인 (B 선행 차단 게이트, C-F3)

v1 경로 삭제 전, 아직 v1에 의존하는 소비자가 없는지 확인. **하나라도 있으면 먼저 migrate/close 후 진행.**

**fail-closed 게이트(C-F5)** — gh 실패·비-0 히트는 전부 STOP(통과 못하면 B 착수 금지):
```bash
set -euo pipefail
echo "=== (a) A 머지 검증: 템플릿 main이 v2 (.app-config.yml 有 ∧ .homelab.yaml 無) ==="
gh api repos/ukyi-app/homelab-app-template/contents/.app-config.yml -H "Accept: application/vnd.github.raw" >/dev/null \
  || { echo "STOP: 템플릿 main에 .app-config.yml 없음 — A PR 먼저 머지"; exit 1; }
if gh api repos/ukyi-app/homelab-app-template/contents/.homelab.yaml >/dev/null 2>&1; then
  echo "STOP: 템플릿 main에 .homelab.yaml 잔존 — A 미완료"; exit 1
fi
echo "=== (b) 외부 ukyi-app/* .homelab.yaml 히트 0 (템플릿 포함 — A 후엔 0) ==="
hits=$(gh search code --owner ukyi-app --filename .homelab.yaml --json repository --jq '.[].repository.nameWithOwner' | sort -u)
[ -z "$hits" ] || { echo "STOP: .homelab.yaml 잔존 소비자: $hits — v2 이행 후 재감사"; exit 1; }
echo "=== (c) 열린 onboard/* PR 0 ==="
prs=$(gh pr list -R ukyi-app/homelab --state open --json headRefName \
  --jq '.[]|select(.headRefName|startswith("onboard/"))|.headRefName')
[ -z "$prs" ] || { echo "STOP: 열린 onboard PR: $prs"; exit 1; }
echo "=== (d) 큐/진행중 onboard run 0 (C-F6) ==="
runs=$(gh run list -R ukyi-app/homelab --workflow onboard.yaml --json status \
  --jq '[.[]|select(.status=="queued" or .status=="in_progress" or .status=="waiting")]|length')
[ "$runs" = "0" ] || { echo "STOP: 진행중 onboard run ${runs}건 — 완료 대기 후 재감사"; exit 1; }
echo "B0 통과 (fail-closed) — B 진행 가능 ✅"
```
**판정:** 위 스크립트가 **exit 0(전 게이트 통과)** 일 때만 B1~B7 진행. gh 실패·`.homelab.yaml` 히트(템플릿 포함 — A가 제거하므로 히트=A미완료)·열린 onboard PR·진행중 onboard run이면 **STOP** 후 처리·재감사. **또한 스냅샷 이후 in-flight 방지를 위해 B 머지 직전 B0를 1회 더 실행한다(C-F6).** (코드 변경 없는 감사 게이트 — 결과를 PR/로그에 기록.)

## Task B1: 영구 stale-ref 가드 (fail-first)

삭제 전, v1 식별자 잔존 참조 0을 강제할 가드를 먼저 추가(아직 v1 파일 존재라 실패).

**Files:** Modify `tests/gates/test_workflow-yaml.bats` (PR #59에서 추가한 "deleted dispatch workflows" 가드 옆)

**Step 1:** `test_workflow-yaml.bats`에 @test 추가:
```bash
@test "deleted v1 onboarding identifiers have no tracked references" {
  # v1 onboarding 경로(onboard.yaml·onboard-app·homelab-app-schema·.homelab.yaml) 전면 폐기 후 잔존 0.
  # 제외: docs/plans(역사)·docs/runbooks(로컬 런북, 별도 수동)·자기 가드 파일.
  run bash -c "git -C \"$ROOT\" grep -lE 'onboard\.yaml|onboard-app|homelab-app-schema|\.homelab\.yaml' -- ':!docs/plans/*' ':!docs/runbooks/*' ':!tests/gates/test_workflow-yaml.bats' || true"
  [ -z "$output" ]
}
```
**Step 2:** Run `bats tests/gates/test_workflow-yaml.bats` → FAIL(v1 파일·참조 존재).
**Step 3:** 커밋: `test: v1 onboarding 잔존-참조 영구 가드 (fail-first)`

## Task B1.7: test_onboard.bats의 생존 경로 가드 이관 (삭제 전 — C-F2)

test_onboard.bats는 v1-onboard 외에 **생존 워크플로 가드 3개**(bump.yaml·reusable-app-build.yaml)를 품는다 — 삭제 전 반드시 이관.

**Files:** Read `tools/tests/test_onboard.bats`; Modify `tools/tests/test_bump.bats`; Create `tools/tests/test_reusable-app-build.bats`

**Step 1:** test_onboard.bats Read → 이관 대상 3 @test 식별(셋 다 `run_onboard`·fixture 미사용, `$ROOT`만 사용 → 그대로 이식 가능):
- `bump: dispatch path shares serial group; legacy job scoped to workflow_run` (bump.yaml)
- `bump dispatch: untrusted payload env-only + source-repo binding + digest verify` (bump.yaml)
- `reusable-app-build v1: build-only, dispatch jobs gone, dispatch-pat optional-compat` (reusable-app-build.yaml 외부계약)

**Step 2:** bump 2 @test를 `tools/tests/test_bump.bats`에 추가(그 파일 setup의 ROOT 변수명에 정합). reusable-app-build @test는 신규 `tools/tests/test_reusable-app-build.bats`로:
```bash
#!/usr/bin/env bats
# reusable-app-build.yaml 외부 cross-repo 계약 가드(test_onboard.bats에서 이관 — v1 폐기).
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "reusable-app-build v1: build-only, dispatch jobs gone, dispatch-pat optional-compat" {
  f="$ROOT/.github/workflows/reusable-app-build.yaml"
  grep -q 'workflow_call' "$f"
  grep -q 'linux/arm64' "$f"
  run grep -E "repos/.*/dispatches|app-onboard|app-image|environment: production" "$f"
  [ "$status" -ne 0 ]
  grep -q 'dispatch-pat' "$f"
  # 구조 검사(C-F4·C-F7): dispatch-pat과 required 사이에 description 줄이 끼어 grep -A1 인접성이 깨진다.
  # yq로 required==false 직접 확인(yq는 GHA on: 키를 문자열로 정상 파싱 — on→true 함정 없음, 실측 확인).
  command -v yq >/dev/null || skip "yq required"
  [ "$(yq -r '.on.workflow_call.secrets.dispatch-pat.required' "$f")" = "false" ]
}
```

**Step 3:** Run `bats tools/tests/test_bump.bats tools/tests/test_reusable-app-build.bats` → PASS.
**Step 4:** 커밋: `test: bump·reusable-app-build 가드를 test_onboard에서 분리 이관 (v1 폐기 전 보존)`

## Task B2: v1 파일 4개 삭제

**Files:** Delete `onboard.yaml`·`tools/onboard-app.mjs`·`tools/homelab-app-schema.json`·`tools/tests/test_onboard.bats`

```bash
git rm .github/workflows/onboard.yaml tools/onboard-app.mjs tools/homelab-app-schema.json tools/tests/test_onboard.bats
```
**검증:** `ls` 부재 확인. test_onboard.bats는 **B1.7에서 생존 가드 이관 후라 v1-onboard 전용만 남음** — 안전 삭제. (이 시점 다른 테스트가 onboard 참조로 깨짐 — B3에서 정리.)
**커밋:** `refactor: v1 onboarding 경로 파일 삭제 (onboard.yaml·onboard-app·homelab-app-schema·test_onboard)`

## Task B3: 삭제 파일을 참조하던 테스트 마이그레이션

각 파일 Read 후 onboard 참조 제거. **타겟 검증**만(full suite는 B6).

- `tests/gates/test_setup-node-pnpm.bats`: node-workflow 루프서 `onboard.yaml` 제거, `@test "all 8 …"` → `"all 7 …"`.
- `tests/gates/test_setup-toolchain-kubeseal.bats`: `@test "onboard and _create-app use the composite"` → `"_create-app uses the composite"`, 루프 `for wf in onboard.yaml _create-app.yaml` → `for wf in _create-app.yaml`.
- `tests/gates/test_ci-toolchain-pin.bats`: 루프 `for wf in ci.yaml onboard.yaml _create-app.yaml` → `for wf in ci.yaml _create-app.yaml`(주석의 onboard도).
- `tests/gates/test_telegram-callsites.bats`: EXPECTED here-doc서 `onboard.yaml 1` 줄 삭제.
- `tools/tests/test_cli-flag-guard.bats`: `@test "onboard-app rejects an unknown flag"` 블록 삭제, 상단 주석의 onboard-app 정리.
- `tools/tests/test_identity.bats`: arg-guard 대상 목록(`tools/...mjs` 줄 + `for f in …` 루프)서 `onboard-app` 제거.
- `tests/gates/test_pr-sweeper.bats`: 브랜치 prefix regex/주석서 `onboard` 제거(B4의 pr-sweeper.yaml과 동기).

**검증:** `bats tests/gates/test_setup-node-pnpm.bats tests/gates/test_setup-toolchain-kubeseal.bats tests/gates/test_ci-toolchain-pin.bats tests/gates/test_telegram-callsites.bats tools/tests/test_cli-flag-guard.bats tools/tests/test_identity.bats tests/gates/test_pr-sweeper.bats` → PASS.
**커밋:** `test: v1 삭제에 맞춰 게이트 테스트 정리 (onboard 참조 제거)`

## Task B4: 워크플로/코드 참조 정리

**Files:** Modify
- `.github/workflows/pr-sweeper.yaml:46` — sweep regex `^(bump|bump-poll|create-database|create-cache|create-app|onboard|update-secrets)/` → `onboard` 제거.
- `.github/workflows/bump.yaml:162` — 에러 `미온보딩 앱 '$APP' — onboard PR부터 머지하라` → `미온보딩 앱 '$APP' — ✨ create-app 먼저 실행하라`.
- `tools/provision-cache.mjs:332` 주석 `(onboard-app.mjs와 동일 규약)` → `(create-app.mjs와 동일 규약)`.
- `tools/create-app.mjs:3` 주석의 `onboard-app.mjs(v1, .homelab.yaml)의 후속` → v1 참조 제거(예: `v2 앱 생성기 — db/redis 리소스 참조·SealedSecret·digest 핀.`).
- `platform/argocd/root/appset.yaml:83` legacy 주석의 `onboard-app v1은 KSOPS …` → 간결화(예: `(앱 시크릿 표준=SealedSecret)`).
- `tools/app-config-schema.json:5` description의 `구계약(.homelab.yaml) 대비 …` → `.homelab.yaml` 언급 제거(설명만 정리, 스키마 구조 불변).

**검증:** `node -e "require('yaml').parse(...)"` (pr-sweeper·bump YAML 유효) + `node --check tools/provision-cache.mjs tools/create-app.mjs` + `node -e "require('./tools/app-config-schema.json')"` + shellcheck 무관(.sh 아님).
**커밋:** `refactor: v1 onboard 참조 정리 (워크플로 에러·주석·스키마 설명)`

## Task B5: 문서 정리

**Files:** Modify
- `tools/README.md` — 계약 스키마 표서 `homelab-app-schema.json` 행 삭제, `v1(...)→v2(...)` 마이그레이션 문단 삭제, "App Platform 변이 도구"서 `onboard-app.mjs` 항목 삭제, `onboard.yaml` 언급 정리.
- `AGENTS.md` — `tools/` 설명(`onboard-app` 제거), 멀티레포 플로우의 v1/onboard 서술 정리, 런북 인덱스의 `app-onboarding.md` 행(유지하되 "외부 레포 v2" 반영 or 그대로 — 런북은 로컬). naming 컨벤션은 무변경.
- `.github/workflows/README.md` — 🤖 자동 표서 `onboard | repo_dispatch | 앱 온보딩` 행 삭제.

**검증:** `git grep -nE "onboard-app|homelab-app-schema" -- AGENTS.md tools/README.md` → 0(또는 의도적 히스토리만).
**커밋:** `docs: v1 onboarding 폐기 문서 정리 (README·AGENTS)`

## Task B6: repo.tf (owner-local apply 명시)

**Files:** Modify `infra/github/repo.tf`
- line ~30 template description `homelab 앱 템플릿: .homelab.yaml 채우고 push하면 온보딩 PR이 자동 생성된다` → `homelab 앱 템플릿: .app-config.yml 채우고 push(빌드) → owner가 create-app으로 온보딩`.
- line ~20 주석 `자동화(bump/onboard 등)` → `자동화(bump/create-app 등)`.
- line ~27 `런북 app-onboarding 참고` 유지(런북명 그대로).

**검증:** `make tf-validate`(github 루트 fmt+validate). ⚠️ **apply는 CI 무관 — owner 로컬 `terraform apply` 필요**(description은 GitHub 메타데이터; PR 머지만으론 미반영). 플랜 핸드오프에 명시.
**커밋:** `chore: repo.tf 템플릿 description v2 반영 (owner-local apply 필요)`

## Task B7: 최종 게이트 + 잔존 참조 0

```bash
cd "$(git rev-parse --show-toplevel)"
bats tests/gates/test_workflow-yaml.bats        # 신규 v1 가드 PASS(이제 참조 0)
./scripts/run-bats.sh                            # 전체 수집 PASS
shellcheck $(git ls-files '*.sh')
make verify                                      # skeleton·bats-accounting·app-deploy·ledger·sops
make tf-validate                                 # github 루트 포함
# 잔존 참조 0 (docs/plans·runbooks·자기가드 제외)
git grep -lE 'onboard\.yaml|onboard-app|homelab-app-schema|\.homelab\.yaml' -- ':!docs/plans/*' ':!docs/runbooks/*' ':!tests/gates/test_workflow-yaml.bats' && echo "잔존!" || echo "잔존 0 ✅"
# 공유 lib·플랫폼 KSOPS 무삭제 확인
test -f tools/lib/identity.mjs && test -f tools/lib/ledger-totals.mjs && echo "공유 lib 유지 ✅"
```
Expected: 전부 PASS, 잔존 0, 공유 lib 유지.

---

## 완료 기준 (DoD)

- [ ] B0 cutover 감사(C-F3): 외부 `.homelab.yaml`(템플릿 자신 외)·열린 onboard/* PR·onboard run = 0 확인 후 삭제 착수.
- [ ] A: 템플릿 `.app-config.yml`(v2) + README + create-app --dry-run 통과, PR 머지(B보다 먼저).
- [ ] B: v1 4파일 삭제 + 참조 테스트 7종·워크플로·코드·문서 정리 + 영구 stale-ref 가드.
- [ ] 생존 가드 보존(C-F2): bump 2 @test → test_bump.bats, reusable-app-build @test → 신규 test_reusable-app-build.bats(삭제 전 이관).
- [ ] `onboard.yaml`/`onboard-app`/`homelab-app-schema`/`.homelab.yaml` 추적 참조 0(docs/plans·runbooks 제외).
- [ ] 공유 lib·플랫폼 KSOPS·create-app(v2) 불변.
- [ ] `run-bats`·shellcheck·`make verify`·`make tf-validate` PASS.
- [ ] repo.tf description = owner-local terraform apply 안내(핸드오프).
- [ ] 런북(app-onboarding/app-platform) v1 서술 갱신 = owner 수동(PR 밖).

---

## Adversarial review dispositions (감사 추적 — post-finalize)

설계 1패스(A.5) + 플랜 4패스. **전 발견 수용·반영, reject 0.**

| 출처 | 발견 | 심각도 | 반영 |
|---|---|---|---|
| A.5 | F1 A/B "순서 무관" 오류 — A(템플릿 v2)가 B(v1 삭제) 선행 필수 | high | §3.B 선행조건·§5 + Task B0 게이트 |
| 플랜 P1 | F2 test_onboard 전체삭제가 생존 가드(bump·reusable-app-build) 상실 | high | Task B1.7 분리 이관(test_bump·신규 test_reusable-app-build) |
| 플랜 P2 | F3 v1 삭제 전 소비자 인벤토리 부재 | high | Task B0 cutover 감사 |
| 플랜 P2 | F4 dispatch-pat 가드 false-positive(`grep -vq`) | med | positive 단언으로 |
| 플랜 P3 | F5 B0 감사 fail-open(`\|\| true`·템플릿 히트 허용) | high | B0 fail-closed(set -e·템플릿 main v2 검증·히트0) |
| 플랜 P4 | F6 B0가 큐/진행중 run 미확인 + 머지직전 재감사 없음 | high | B0 (d) run-list 추가 + 머지직전 재감사 |
| 플랜 P4 | F7 가드 `grep -A1 \| grep -q 'required: false'` false-negative(description 줄) | med | yq 구조검사(`.on...required`==false, 실측 확인) |

**최종 상태(정직 기록):** 3패스 캡을 사용자 인가 확인 패스 1회 초과(총 4패스). 패스 4 verdict=`needs-attention`(F6·F7) — clean `approve` 아님. 사용자가 "수정 반영 후 확정" 선택. F6·F7은 기계적 수정(직전 패스에서 내가 드롭한 run-list 체크 복원 + grep→yq, yq 동작 실측)이라 재리뷰 없이 수용. 핵심 설계(A+B·삭제 스윕·테스트 이관)는 견고, 발견은 전부 B0 안전 게이트 정밀화 + 가드 단언에 수렴.

## Execution directives

- **Skill:** 별도 세션, 이 worktree에서 `executing-plans`로 구현.
- **연속 실행:** 배치 사이 루틴 정지 없음. 진짜 블로커만 정지(의존성 누락·반복 실패 검증·모순 지시·치명 갭).
- **cross-repo 순서(필수):** **Phase A(템플릿 PR) 먼저 머지** → **B0 cutover 감사 통과**(fail-closed) → B1~B7 구현/PR. **B PR 머지 직전 B0 1회 더 실행**(C-F6). B0가 STOP이면 처리·재감사 전 진행 금지.
- **중간 게이트:** B는 토폴로지 전환 중이라 cross-cutting 게이트 일시 red 가능 — full `run-bats`/`make ci`는 마지막(B7). 중간은 타겟 bats.
- **owner-local(자동 아님):** `infra/github/repo.tf` description은 PR 머지만으론 GitHub 미반영 → owner 로컬 `terraform apply`(github 루트, 신뢰앵커). 런북(app-onboarding/app-platform) v1 서술은 PR 밖 수동.
- **커밋 — 규칙 직접 적용, `Skill(commit)` 미사용:**
  - 한국어, **AI 마커 금지**. `<type>(<scope>): 설명`. type=feat/fix/refactor/docs/style/test/chore만.
  - 그룹화: 같은 목적·디렉토리 함께; config·테스트·문서 분리. 각 Task 커밋 스텝이 기본 단위.
  - 현재 피처 워크트리 브랜치에 직접 커밋(이미 main 밖).
