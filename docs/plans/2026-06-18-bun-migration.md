# Bun + TypeScript 마이그레이션 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** homelab `tools/` CLI(19개)를 Node+pnpm에서 **Bun + TypeScript**로 full 교체한다(homelab 레포 한정, 단일 PR).

**Architecture:** bun이 deps(`bun.lock` 텍스트)+런타임+TS를 전담. homelab 전용 툴 17개는 `.ts`, 앱-공유 2개(`seal-secret`/`env-example`)는 `.mts`(무조건 ESM). `tsconfig` `erasableSyntaxOnly`로 같은 파일이 bun과 node≥22.18 strip-types 양쪽에서 실행. 유일 required check `gate`가 pnpm 계약 bats를 돌리므로 **gate-first TDD**. 테스트 계약은 bats 블랙박스 유지(`node`→`bun` 토큰 swap, exit code 1/2 단언).

**Tech Stack:** Bun 1.3.10, TypeScript ^5.8(`erasableSyntaxOnly`), `@types/bun`, `oven-sh/setup-bun`(SHA 핀), bats, yaml@^2.9.0.

**참조 설계:** `docs/plans/2026-06-18-bun-migration-design.md` (변경 인벤토리 ①~⑦ + A.5 dispositions).

**Base:** 이 플랜은 `origin/main@aa9bffa`(v1 onboarding 폐기 #62 — `onboard.yaml`·`onboard-app.mjs`·`homelab-app-schema.json`·`.homelab.yaml` 삭제; create-app/update-secrets sha 입력 제거) 위에 리베이스됨. **인벤토리는 aa9bffa 기준**(구 `dispatch-mutation.yaml`·`onboard.*`는 없음). ⚠️ **신규 게이트** `tests/gates/test_workflow-yaml.bats`가 `onboard.yaml|onboard-app|homelab-app-schema|.homelab.yaml` 추적참조 0을 단언(`docs/plans/*` 제외) — 마이그레이션은 이 식별자를 재도입하지 말 것(이미 삭제됐으니 변환 목록에서 제외하면 충족).

---

## 사전 메모 (구현자 필수 숙지)

- **워크트리**: 이미 `worktree-bun-ts-migration`에 격리됨. 새 워크트리 만들지 말 것.
- **하네스 셸 = zsh**: `declare -A`·unquoted `$var` 동작이 bash와 다름 → 복잡한 셸 단언은 `bash -c`로.
- **bats `@test` 이름은 영어만**: 한글 이름은 디렉토리 단위 실행 시 침묵 스킵(exit 0) 위장 통과.
- **bats 중간 단언은 `[ ]`만**: bash 3.2(macOS)에서 `[[ ]]` 실패가 침묵 통과.
- **커밋**: 한국어 conventional, AI 마커 금지. `Skill(commit)` 호출 금지 — 각 Commit 스텝에서 직접 `git commit`.
- **bun 버전 핀**: 전 구간 `1.3.10`(mise 보유). 다르면 `mise use bun@1.3.10` 후 진행.
- **`run-bats.sh` SSOT**: `git ls-files '*test_*.bats'` — rename된 파일은 `git add`돼야 추적.
- **🔑 grep-구동 검증**: 마이그레이션이 깰 수 있는 토큰을 매 단계 후 grep으로 잔여 0 확인(파일 열거는 stale 취약 — 명령으로 재도출):
  ```bash
  # 잔여 node/pnpm 토큰(의도된 예외만 남아야) — scripts/ 포함(teardown.sh 누락 방지, A.5 pass-2)
  git grep -nE '\bnode tools/|\.mjs|\bpnpm \b|corepack|actions/setup-node|node -e' -- \
    'tools/**' 'tests/**' '.github/**' 'scripts/**' Makefile package.json
  ```

---

## Phase 0 — Bun + TS 토대

### Task 0.1: package.json·lockfile·workspace를 bun으로 + @types/bun (A.5 F1)

**Files:** Modify `package.json`; Delete `pnpm-workspace.yaml`/`.npmrc`/`pnpm-lock.yaml`; Create `bunfig.toml`/`bun.lock`; Test `tools/tests/test_workspace.bats`

**Step 1: 계약 테스트 재작성 (failing)** — `tools/tests/test_workspace.bats` 전체 교체:
```bash
#!/usr/bin/env bats
# bun 단일 패키지 — packageManager bun 핀 + 플랫폼 게이트 스크립트 노출 + bun 타입 의존.
@test "package.json pins bun and exposes the platform gates" {
  run jq -r '.packageManager' package.json
  case "$output" in bun@*) : ;; *) false ;; esac
  run jq -r '.scripts | keys | join(",")' package.json
  case "$output" in *verify:ledger*) : ;; *) false ;; esac
  case "$output" in *verify:skeleton*) : ;; *) false ;; esac
  case "$output" in *typecheck*) : ;; *) false ;; esac
}
@test "bun type deps present (A.5 F1 — types:[bun] needs @types/bun)" {
  run jq -r '.devDependencies | keys | join(",")' package.json
  case "$output" in *@types/bun*) : ;; *) false ;; esac
  case "$output" in *typescript*) : ;; *) false ;; esac
}
@test "no pnpm workspace/lockfile remains; bun.lock is text + committed" {
  [ ! -f pnpm-workspace.yaml ]; [ ! -f pnpm-lock.yaml ]
  [ -f bun.lock ]
  run git ls-files --error-unmatch bun.lock
  [ "$status" -eq 0 ]
}
```

**Step 2: 실패 확인** — `bats tools/tests/test_workspace.bats` → FAIL

**Step 3: package.json 교체**
```json
{
  "name": "homelab",
  "private": true,
  "version": "0.0.0",
  "packageManager": "bun@1.3.10",
  "scripts": {
    "dev": "bun tools/dev.ts",
    "db:up": "bun tools/dev.ts db:up",
    "db:reset": "bun tools/dev.ts db:reset",
    "db:url": "bun tools/db-url.ts",
    "cache:url": "bun tools/cache-url.ts",
    "env:example": "bun tools/env-example.mts",
    "secret:seal": "bun tools/seal-secret.mts",
    "typecheck": "tsc --noEmit",
    "verify:ledger": "scripts/verify-ledger.sh",
    "verify:skeleton": "./scripts/check-skeleton.sh"
  },
  "devDependencies": {
    "yaml": "^2.9.0",
    "typescript": "^5.8.0",
    "@types/bun": "latest"
  }
}
```

**Step 4: pnpm 제거 + bunfig + install**
```bash
rm pnpm-workspace.yaml .npmrc pnpm-lock.yaml
printf '[install]\nfrozenLockfile = true\n' > bunfig.toml
bun install   # bun.lock(텍스트) + node_modules (@types/bun·typescript·yaml)
```
> 최초 생성이 `frozenLockfile`로 막히면 `bun install --no-frozen-lockfile` 후 커밋(이후 CI가 frozen 검증).

**Step 5: 통과 확인** — `bats tools/tests/test_workspace.bats` → PASS (3 tests)

**Step 6: Commit**
```bash
git add package.json bunfig.toml bun.lock tools/tests/test_workspace.bats
git rm pnpm-workspace.yaml .npmrc pnpm-lock.yaml
git commit -m "chore: 패키지매니저 pnpm→bun 전환 (packageManager bun@1.3.10·@types/bun·bun.lock·workspace 제거)"
```

### Task 0.2: tsconfig + typecheck 게이트

**Files:** Create `tsconfig.json`; Test `tools/tests/test_tsconfig.bats`

**Step 1: failing test** — `tools/tests/test_tsconfig.bats`:
```bash
#!/usr/bin/env bats
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }
@test "tsconfig enforces erasable-syntax + noEmit + ts-extension imports" {
  [ -f tsconfig.json ]
  run jq -r '.compilerOptions.erasableSyntaxOnly' tsconfig.json; [ "$output" = "true" ]
  run jq -r '.compilerOptions.noEmit' tsconfig.json; [ "$output" = "true" ]
  run jq -r '.compilerOptions.allowImportingTsExtensions' tsconfig.json; [ "$output" = "true" ]
}
# (typecheck 실행-통과 단언은 Task 1.1로 이동 — 지금은 TS 파일 0개라 tsc가 'No inputs' 에러, A.5 pass4 F1)
```
**Step 2:** Run → FAIL (no tsconfig)

**Step 3: tsconfig.json**
```json
{
  "compilerOptions": {
    "target": "esnext",
    "module": "preserve",
    "moduleResolution": "bundler",
    "allowImportingTsExtensions": true,
    "verbatimModuleSyntax": true,
    "erasableSyntaxOnly": true,
    "strict": true,
    "noEmit": true,
    "skipLibCheck": true,
    "types": ["bun"]
  },
  "include": ["tools/**/*.ts", "tools/**/*.mts"]
}
```
> `types:["bun"]`는 `@types/bun`(Task 0.1) 필수 — `process`/`Buffer`/node: 빌트인 타입 커버.

**Step 4:** Run → PASS (구조 단언만 — TS 파일 0개라 `bun run typecheck`는 여기서 실행 안 함; tsc는 빈 `include`에 'No inputs' 에러를 낸다. typecheck-green은 Task 1.1서. `@types/bun` 존재는 Task 0.1 `test_workspace`가 단언)
**Step 5: Commit** — `feat: TypeScript tsconfig 추가 (erasableSyntaxOnly·noEmit 타입체크 게이트)`

---

## Phase 1 — tools 변환 (.mjs → .ts / .mts)

### 변환 레시피 (반복 적용)

각 파일: ① `git mv tools/<x>.mjs tools/<x>.ts`(app-shared 2개는 `.mts`) → ② 파일 내 `from "./lib/<y>.mjs"`→`"./lib/<y>.ts"` → ③ 타입 부여(`erasableSyntaxOnly` 준수: enum·namespace·파라미터 프로퍼티 금지) → ④ **이 파일을 호출/참조하는 bats의 확장자·`node`→`bun` 갱신**(블랙박스 `run node`만; 문자열 단언 테스트는 Phase 2에서 일괄) → ⑤ `bun run typecheck` + 해당 bats green.

> bun이 런타임이라 .ts/.mts/.mjs 혼재 import 안전(점진 변환 가능).

### Task 1.1: lib/ 3개 → .ts + importer 경로 갱신
- Rename: `tools/lib/{identity,ledger-totals,surface-hash}.mjs`→`.ts`
- Importer(`./lib/*.mjs`→`./lib/*.ts`): `activate-app, validate-mutation, teardown-app, bump-tag, create-app, audit-orphans`(.mjs 상태에서 경로만; onboard-app은 #62로 삭제됨)
- bats: `test_identity.bats`(`run node tools/teardown-app.mjs`는 Task 1.4서), `test_ledger-totals.bats`(`run node -e`는 Phase 2), `test_audit-orphans.bats`(`node tools/lib/surface-hash.mjs`→`.ts`)
- TDD: lib 호출 bats를 .ts로(fail) → mv+타입+import → **`test_tsconfig.bats`에 typecheck-green @test 추가**(`@test "typecheck passes" { run bun run typecheck; [ "$status" -eq 0 ]; }` — 이제 TS 입력 존재, A.5 pass4 F1) → `bun run typecheck` green → Commit `refactor: tools/lib 3종 TS 전환 + importer 경로 갱신`

### Task 1.2~1.6: homelab-only 15개 → .ts (그룹별, 레시피 적용)
- **1.2 검증/감사:** `validate-mutation`, `audit-orphans` → `.ts` · bats: `test_validate-mutation`, `test_audit-orphans`, `test_audit-dangling-role`, `test_cli-flag-guard`, `test_tool-discoverability`(`--help`) · 커밋 `refactor: validate-mutation·audit-orphans TS 전환`
- **1.3 bump:** `bump-tag`, `poll-ghcr` → `.ts` · bats: `test_bump`, `test_poll-ghcr`(`--help`), `test_bump-poll-toctou`(블랙박스 부분) · ⚠️**라이브 스모크 #3**(bump-tag yaml 바이트, `test_bump` green) · 커밋 `refactor: bump-tag·poll-ghcr TS 전환`
- **1.4 앱 lifecycle:** `create-app`, `activate-app`, `teardown-app`, `teardown-resource` → `.ts` · bats: `test_create-app`, `test_activate-app`, `test_teardown`, `test_identity`(teardown-app 호출), `test_cli-flag-guard` · 커밋 `refactor: create/activate/teardown TS 전환` · ⚠️ `onboard-app`/`test_onboard`은 #62로 삭제 — 대상 아님(`test_reusable-app-build`가 그 계약 일부 이관, node 무관)
- **1.5 프로비저닝:** `provision-db`, `provision-cache` → `.ts` · bats: `test_provision-db`(⚠️`exec node -e` kubeseal stub → `exec bun -e`), `test_provision-cache` · ⚠️**라이브 스모크 #1**(kubeseal spawnSync) · 커밋 `refactor: provision-db·provision-cache TS 전환`
- **1.6 dev/url/dns:** `dev`, `db-url`, `cache-url`, `dns-drift-check` → `.ts` · bats: `test_dev-data`, `test_dns-drift-check`(--fixture) · ⚠️`dev.ts`: `pnpm -r --parallel dev` spawn → `bun run --filter '*' dev`(멤버0 no-op) 또는 제거; **스모크 #2** SIGINT 유지 · **스모크 #4** dns:promises(`bun tools/dns-drift-check.ts --apps ...` 1회) · 커밋 `refactor: dev·db-url·cache-url·dns-drift-check TS 전환`

### Task 1.7: app-shared 2개 → .mts
- Rename: `tools/{seal-secret,env-example}.mjs`→`.mts` (lib 미참조 — import 변경 없음, `erasableSyntaxOnly` 준수 필수)
- bats: `test_seal-secret`(`run node`→`run bun`, `.mjs`→`.mts`; kubeseal stub) · ⚠️**스모크 #1** 적용
- 커밋 `refactor: app-shared seal-secret·env-example .mts 전환 (무조건 ESM·node strip-types 양립)`

### Task 1.8: shebang-exec 정책 갱신
- `tools/tests/test_shebang-exec.bats` glob `tools/*.mjs`→`tools/*.ts`/`*.mts`/`lib/*.ts`, `@test` 이름 "via node"→"via bun"(영어)
- 커밋 `test: shebang-exec 정책 glob을 .ts/.mts로 갱신`

---

## Phase 2 — 테스트 계약 스윕 (B — grep-구동, 문자열 단언 테스트)

> ⚠️ 블랙박스 `run node`(Phase 1서 처리) 외에, **워크플로/ci/스크립트 문자열을 grep 단언**하는 테스트가 다수. 이들은 마이그레이션이 리터럴 `.mjs`/`node`/`pnpm`을 바꾸는 순간 깨진다. **현재 main 기준 권위 목록을 grep으로 재도출**해 빠짐없이 갱신.

### Task 2.1: 문자열 단언 테스트 일괄 갱신

**먼저 권위 목록 도출:**
```bash
git grep -nE '\.mjs|node tools/|node -e|\bpnpm \b|validate-mutation\.mjs' -- 'tools/tests/*.bats' 'tests/**/*.bats'
```

**갱신 대상(현재 main 확인됨 — 구현 시 위 grep으로 재검증):**
| 파일 | 현재 단언 | 변경 |
|---|---|---|
| `tools/tests/test_mutation-dispatch.bats:35` | `validate-mutation.mjs --action $d` | `validate-mutation.ts` |
| `tests/gates/test_ci-blocking-comment.bats:8,19,24` | `tools/audit-orphans.mjs`·`node tools/audit-orphans.mjs --ci` | `audit-orphans.ts`·`bun tools/audit-orphans.ts --ci` |
| `tools/tests/test_app-deploy.bats:42` | `tools/poll-ghcr.mjs` | `poll-ghcr.ts` |
| `tools/tests/test_bump-poll-toctou.bats:16` | 워크플로의 `bump-tag.mjs .*--expect-current` | `bump-tag.ts` |
| `tools/tests/test_ledger-gate.bats:8` | `run pnpm verify:ledger` (실행) | `run bun run verify:ledger` |
| `tests/gates/test_verify-ledger-ssot.bats:16` | `node -e "...require('package.json')..."` | `bun -e` |
| `tests/gates/test_workflow-yaml.bats:10` | `run node -e '...'` | `run bun -e` |
| `tools/tests/test_ledger-totals.bats:11,24` | `run node -e '...'` | `run bun -e` |

> `test_make-ci-parity.bats`는 `make ci`↔`ci.yaml` 패리티를 단언 — Phase 3·4서 양쪽을 동시 변경하면 자동 충족(이 Task에선 손대지 않되, Phase 4 후 green 재확인).

**Step:** 위 grep으로 fail 확인 → 표대로 치환 → `./scripts/run-bats.sh`(Phase 3 전이라 일부는 아직 fail 가능 — 최소 이 파일들 자체는 구문상 통과) → 커밋 `test: 문자열 단언 테스트 node/pnpm/.mjs → bun/.ts 일괄 갱신`

---

## Phase 3 — CI composite + 워크플로 (A 드리프트 반영)

### Task 3.1: setup-bun composite (gate-first TDD, 7-list, A.5 F2)

**Files:** Rename `.github/actions/setup-node-pnpm/`→`setup-bun/`; Modify `action.yml` + 7 워크플로 `uses:`; Rename test `test_setup-node-pnpm.bats`→`test_setup-bun.bats`

**Step 1: 계약 테스트 재작성 (failing)** — `tests/gates/test_setup-bun.bats`:
```bash
#!/usr/bin/env bats
# setup-bun composite — bun-version 핀 + frozen 설치 SSOT. (7 워크플로 채택; onboard.yaml은 #62로 삭제)
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; A="$ROOT/.github/actions/setup-bun/action.yml"; }

@test "setup-bun composite exists and pins bun + frozen install" {
  [ -f "$A" ]
  run grep -E "oven-sh/setup-bun@[0-9a-f]{40}" "$A"; [ "$status" -eq 0 ]
  run grep -E "bun-version: ['\"]1\.3\.10['\"]" "$A"; [ "$status" -eq 0 ]
  run grep -E 'bun install --frozen-lockfile' "$A"; [ "$status" -eq 0 ]
}

@test "all 7 install workflows adopt the setup-bun composite" {
  local wf
  for wf in ci.yaml bump.yaml bump-poll.yaml _create-app.yaml _create-database.yaml _create-cache.yaml audit.yaml; do
    run grep -F 'uses: ./.github/actions/setup-bun' "$ROOT/.github/workflows/$wf"
    [ "$status" -eq 0 ]
  done
}

@test "no workflow keeps node-setup or corepack pnpm, except the app-shared smoke (A.5 F2)" {
  run grep -rE 'corepack prepare pnpm' "$ROOT/.github/workflows/"
  [ "$status" -ne 0 ]
  # setup-node는 ci.yaml(app-shared node 스모크) 1파일에서만 — 그 외 0
  run bash -c "grep -rlE 'actions/setup-node' '$ROOT/.github/workflows/' | grep -vE '/ci\.yaml$' || true"
  [ -z "$output" ]
  # 그 예외는 SHA핀 + node 22.18
  run grep -E "actions/setup-node@[0-9a-f]{40}" "$ROOT/.github/workflows/ci.yaml"; [ "$status" -eq 0 ]
  run grep -E "node-version: ['\"]22\.18" "$ROOT/.github/workflows/ci.yaml"; [ "$status" -eq 0 ]
}
```
> ⚠️ 3번째 테스트는 Phase 3.2(인라인 5곳 제거)+Phase 5(스모크 추가) 후에야 green. 같은 PR이라 최종 게이트에서 통과.

**Step 2:** Run → FAIL · **Step 3: composite** — `.github/actions/setup-bun/action.yml`:
```yaml
name: setup-bun
description: bun 핀 + frozen 설치 (버전 SSOT).
runs:
  using: composite
  steps:
    - uses: oven-sh/setup-bun@<FULL_40CHAR_SHA>  # v2.0.x
      with:
        bun-version: "1.3.10"
    - shell: bash
      run: bun install --frozen-lockfile
```
> SHA: `gh api repos/oven-sh/setup-bun/git/refs/tags/<tag>`로 해석해 핀(Renovate gh-actions 비활성 → 수동, 버전 주석).

**Step 4:** `git mv` 디렉토리 rename + 7 워크플로 `uses: ...setup-node-pnpm`→`setup-bun`. **Step 5:** `bats tests/gates/test_setup-bun.bats`(1·2 green; 3은 후속). **Step 6: Commit** — `feat: CI composite setup-node-pnpm→setup-bun (bun-version 1.3.10·7 워크플로)`

### Task 3.2: 인라인 setup-node 디스패처 5곳 + 잔여 node 호출

**Files:** `create-app.yaml`, `create-cache.yaml`, `create-database.yaml`, `update-secrets.yaml`(validate 전용 — inline setup-node), `dns-drift.yaml`; + 잔여 `node tools/` 보유 워크플로

**Step 1 (디스패처 4종):** 각 `actions/setup-node@v4`(inline, install 없음) → `oven-sh/setup-bun@<SHA>` + `bun-version`(install 스텝 불요); `node tools/validate-mutation.mjs --action <d>` → `bun tools/validate-mutation.ts --action <d>`.
**Step 2 (dns-drift):** inline setup-node → setup-bun; `node tools/dns-drift-check.mjs`→`bun tools/dns-drift-check.ts`; `node -e '...require("fs")...'`(라인 23,30,31)→`bun -e '...'`.
**Step 3 (잔여 node tools/ + pnpm + heredoc):**
- `_create-app:98` create-app.mjs→`.ts`, `:108` `pnpm verify:ledger`→`bun run verify:ledger`
- `_create-cache:39` `node - <<EOF`→`bun - <<EOF`, `:61` provision-cache.mjs→`.ts`, `:63` pnpm→`bun run`
- `_create-database:41` validate-mutation.mjs→`.ts`, `:61/:63` provision-db.mjs→`.ts`
- `audit:24` audit-orphans.mjs→`.ts`
- `bump-poll:75` poll-ghcr.mjs→`.ts`, `:103` bump-tag.mjs→`.ts`
- `bump:97/:171` bump-tag.mjs→`.ts`
- `ci:58` pnpm→`bun run`, `:63` audit-orphans.mjs→`.ts`
- (onboard.yaml은 #62로 삭제 — 호출처 없음)
**Step 4 검증:** `git grep -nE 'node tools/|node -e|node - |corepack|\bpnpm \b' -- '.github/workflows/*.yaml' | grep -v 'secret:seal\|app 레포'` → 0(주석 제외). `bats tools/tests/test_mutation-dispatch.bats`(Phase 2서 .ts化) green.
**Step 5: Commit** — `feat: 워크플로 node→bun 일괄 (디스패처 5종 inline setup-bun·node -e·heredoc·잔여 tools)`

### Task 3.3: ci.yaml typecheck 게이트 + test_ci-gate 갱신

**Files:** `ci.yaml`, `tests/gates/test_ci-gate.bats`
**Step 1:** `test_ci-gate.bats:11-19`의 pnpm 단언 → setup-bun + bun-version:
```bash
@test "ci runs on pull_request and uses the setup-bun composite" {
  run yq '.on.pull_request' "$WF"; [ "$output" != "null" ]
  run grep -F 'uses: ./.github/actions/setup-bun' "$WF"; [ "$status" -eq 0 ]
  run grep -E 'bun-version: "1.3.10"' .github/actions/setup-bun/action.yml; [ "$status" -eq 0 ]
}
```
**Step 2:** `ci.yaml`에 typecheck 스텝 추가(`run: bun run typecheck`, composite 뒤). (node→bun은 Task 3.2서 완료)
**Step 3:** `bats tests/gates/test_ci-gate.bats` → PASS · **Commit** — `feat: ci.yaml typecheck 게이트 + ci-gate 계약 bun화`

---

## Phase 4 — Makefile (A 드리프트: teardown 타겟 공존)

### Task 4.1: m6-tools·ci·audit bun 전환 + MISE 가드 제거

**Files:** `Makefile`; Test `tools/tests/test_makefile-bun.bats`(신규)
**Step 1: failing test** —
```bash
#!/usr/bin/env bats
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }
@test "m6-tools gates the pinned bun version, not node/pnpm" {
  run grep -E 'bun --version' Makefile; [ "$status" -eq 0 ]
  run grep -F '1.3.10' Makefile; [ "$status" -eq 0 ]
  run grep -E 'node --version|pnpm --version' Makefile; [ "$status" -ne 0 ]
}
@test "MISE_SHIMS node guard removed; ci/audit use bun" {
  run grep -E 'MISE_SHIMS' Makefile; [ "$status" -ne 0 ]
  run grep -E 'node tools/|pnpm verify:ledger' Makefile; [ "$status" -ne 0 ]
}
@test "make ci runs the typecheck gate (ci.yaml parity — A.5 pass4 F2)" {
  run grep -E 'bun run typecheck' Makefile; [ "$status" -eq 0 ]
}
```
**Step 2:** Run → FAIL · **Step 3 구현:**
- 라인 4-10(MISE_SHIMS 블록) 삭제.
- m6-tools 라인 90-91(node/pnpm assert) → `@bun --version | grep -qF '1.3.10' || { echo "bun 1.3.10 required"; exit 1; }`.
- ci 타겟: `pnpm verify:ledger`→`bun run verify:ledger`; `node tools/audit-orphans.mjs --ci`→`bun tools/audit-orphans.ts --ci`; **`bun run typecheck` 스텝 추가**(ci.yaml과 패리티 — A.5 pass4 F2).
- audit 타겟(161): `node tools/audit-orphans.mjs`→`bun tools/audit-orphans.ts`.
- ⚠️ `teardown-app`/`teardown-resource` Make 타겟(cde6261 신설)은 `scripts/teardown.sh`를 호출 — **그 래퍼가 `node tools/*.mjs`를 부르므로(Task 4.2) Make 타겟 자체는 손대지 않되 래퍼를 반드시 전환**(A.5 pass-2 수정).
**Step 4:** `test_make-ci-parity.bats`가 `make -n ci`·`ci.yaml` 양쪽에 `typecheck` 존재를 단언하도록 갱신(없으면 추가) → `bats tools/tests/test_makefile-bun.bats tests/gates/test_make-ci-parity.bats` → PASS · **Commit** — `chore: Makefile bun 전환 (m6-tools 핀 일치·MISE 가드 제거·ci/audit/typecheck)`

### Task 4.2: scripts/teardown.sh owner-local 래퍼 bun 전환 (A.5 pass-2)

> ⚠️ cde6261이 추가한 `scripts/teardown.sh`(owner-local teardown 래퍼)는 `node tools/*.mjs`를 호출한다(라인 30·31·36·39). Phase 1이 그 툴을 `.ts`化하고 Phase 4가 node를 제거하면 `make teardown-app`/`teardown-resource`가 깨진다. **유일하게 node를 부르는 `scripts/*.sh`이며**(검증됨), 최종 grep이 `scripts/`를 제외했던 게 근본 누락.

**Files:** Modify `scripts/teardown.sh`; Modify `tools/tests/test_teardown-wrapper.bats`

**Step 1: failing 단언 추가** — `tools/tests/test_teardown-wrapper.bats`에:
```bash
@test "teardown wrapper carries no node/.mjs entrypoints (bun-only)" {
  run grep -nE 'node tools/|\.mjs' "$SH"
  [ "$status" -ne 0 ]
}
```
**Step 2:** Run → FAIL (현재 node tools/*.mjs 4곳)

**Step 3: 구현 `scripts/teardown.sh`:**
- 라인 30: `node tools/validate-mutation.mjs --action teardown-app ...` → `bun tools/validate-mutation.ts ...`
- 라인 31: `plan_cmd=(node tools/teardown-app.mjs ...)` → `plan_cmd=(bun tools/teardown-app.ts ...)`
- 라인 36: `node tools/validate-mutation.mjs --action teardown-resource ...` → `bun tools/validate-mutation.ts ...`
- 라인 39: `plan_cmd=(node tools/teardown-resource.mjs ...)` → `plan_cmd=(bun tools/teardown-resource.ts ...)`

**Step 4:** `bats tools/tests/test_teardown-wrapper.bats` → PASS (DRY_RUN 실행 가드 + no-node 단언). shellcheck `scripts/teardown.sh` 통과.
**Step 5: Commit** — `chore: teardown.sh owner-local 래퍼 node→bun 전환 (A.5 pass-2)`

---

## Phase 5 — app-shared node-without-bun 스모크 (A.5 F1·F2·F3)

### Task 5.1: seal-secret.mts·env-example.mts를 node strip-types로 (F3: 유효 픽스처 + 실제 실행)

**Files:** Create `tests/gates/app-shared-node-smoke.sh`(exec); Modify `ci.yaml`(required `gate` 잡에 스텝 추가); Test `tools/tests/test_app-shared-node-smoke.bats`

**Step 1: failing test (F3 — grep만이 아니라 실행)** —
```bash
#!/usr/bin/env bats
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }
@test "smoke runs inside the required gate job, not a separate job (A.5 pass3 F1)" {
  [ -x tests/gates/app-shared-node-smoke.sh ]
  run grep -E 'seal-secret\.mts' tests/gates/app-shared-node-smoke.sh; [ "$status" -eq 0 ]
  run grep -E 'env-example\.mts' tests/gates/app-shared-node-smoke.sh; [ "$status" -eq 0 ]
  # required check는 gate 잡뿐 — 스모크는 gate 안 스텝이어야(별도 잡이면 비-required라 무성 회귀)
  run grep -F 'app-shared-node-smoke.sh' .github/workflows/ci.yaml; [ "$status" -eq 0 ]
  run grep -E '^  app-shared-node-smoke:' .github/workflows/ci.yaml; [ "$status" -ne 0 ]
}
@test "smoke actually runs the .mts under node when node>=22.18 is available" {
  command -v node >/dev/null || skip "node 미설치 — CI에서 검증"
  ver=$(node -e 'process.stdout.write(process.versions.node)')
  major=${ver%%.*}; minor=$(printf '%s' "$ver" | cut -d. -f2)
  { [ "$major" -gt 22 ] || { [ "$major" -eq 22 ] && [ "$minor" -ge 18 ]; }; } || skip "node<22.18 — strip-types 미지원"
  run bash tests/gates/app-shared-node-smoke.sh
  [ "$status" -eq 0 ]
}
```
**Step 2:** Run → FAIL · **Step 3: 스모크 스크립트** (F3 유효 픽스처 + **A.5 pass3 F2: 실제 seal 경로**):
```bash
#!/usr/bin/env bash
# app-shared .mts를 bun 없이 node strip-types(>=22.18)로 실제 seal 경로까지 실행 —
# 앱 레포 `pnpm secret:seal` 경로 증명(A.5 F1 안전망). node_modules(yaml)는 bun install이 채운다.
set -euo pipefail
node --version
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# kubeseal stub — 실제 호출 없이 seal 경로(spawnSync stdin→stdout)를 node에서 검증(test_seal-secret.bats와 동일 패턴)
mkdir -p "$tmp/bin"
cat > "$tmp/bin/kubeseal" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null            # stdin(평문 Secret manifest) 소비
printf 'apiVersion: bitnami.com/v1alpha1\nkind: SealedSecret\n'
STUB
chmod +x "$tmp/bin/kubeseal"
# secret 이름은 lower-kebab → UPPER_SNAKE 매핑(app-config-schema.json 계약). 구현 시 스키마로 재확인.
cat > "$tmp/.app-config.yml" <<'EOF'
name: smoke-app
kind: service
secrets: [token]
EOF
printf 'TOKEN=x\n' > "$tmp/.env"
# 실제 seal 경로(--app/--out + kubeseal spawnSync)를 node strip-types로 — 출력 파일 단언
PATH="$tmp/bin:$PATH" node tools/seal-secret.mts --config "$tmp/.app-config.yml" --env "$tmp/.env" --app smoke-app --out "$tmp/sealed.yaml"
[ -s "$tmp/sealed.yaml" ] || { echo "sealed output missing"; exit 1; }
node tools/env-example.mts --config "$tmp/.app-config.yml" --out "$tmp/.env.example"
[ -s "$tmp/.env.example" ] || { echo "env-example output missing"; exit 1; }
echo "app-shared node smoke OK"
```
> 인자명(`--app`/`--out` 등)·secret 이름 규약은 구현 시 `tools/app-config-schema.json` + `test_seal-secret.bats`(kubeseal stub 패턴)로 확정. 핵심은 **node가 .mts를 로드 + 실제 kubeseal spawnSync seal 경로를 실행하고 봉인 출력을 쓴다**(dry-run 아님).
**Step 4: ci.yaml — 스모크를 required `gate` 잡 안 스텝으로** (A.5 pass3 F1: 별도 잡=비-required라 무성 회귀; A.5 F2: node SHA핀+22.18). `gate` 잡(이미 setup-bun composite로 `bun install` 완료)에 **append**:
```yaml
      # app-shared .mts가 node strip-types(앱 레포 경로)에서도 실행됨을 required gate가 보장 (A.5 F1·pass3)
      - uses: actions/setup-node@<FULL_40CHAR_SHA>  # v4 — node strip-types 실행용(의식적 예외)
        with: { node-version: "22.18" }
      - run: tests/gates/app-shared-node-smoke.sh
```
> ⚠️ 별도 `app-shared-node-smoke:` 잡을 만들지 말 것 — required check는 `gate` 하나뿐이라 별도 잡은 fail해도 머지됨. 반드시 `gate` 잡의 스텝.
**Step 5:** `bats tools/tests/test_app-shared-node-smoke.bats`(node≥22.18면 실제 실행) + `bats tests/gates/test_setup-bun.bats`(이제 3번째 테스트 green — 예외 1건 SHA핀·22.18). 로컬 `bash tests/gates/app-shared-node-smoke.sh` 1회.
**Step 6: Commit** — `test: app-shared .mts node-without-bun 스모크를 required gate에 (A.5 F1 안전망·실제 seal 경로·F2 예외 핀)`

---

## Phase 6 — 문서 + 최종 게이트 + 라이브 스모크

### Task 6.1: 문서 갱신
**Files:** `docs/runbooks-public/toolchain-setup.md`, `CONTRIBUTING.md`, `AGENTS.md`, `tools/README.md`, `scripts/README.md`, `docs/memory-ledger.md`, `.github/workflows/README.md`
- node≥22/pnpm 11 → **bun 1.3.10**(설치+시스템 PATH 전제). `pnpm verify:ledger`→`bun run verify:ledger`. AGENTS.md `tools/` "Node CLI"→"Bun/TS CLI"; **앱-측 `pnpm secret:seal`은 유지**(앱 레포 pnpm). app-shared `.mts`+앱 레포 node≥22.18 후속 1줄.
- ⚠️ `docs/plans/*`는 역사 기록 — **수정 금지**.
- 커밋 `docs: 툴체인 문서 bun 전환`

### Task 6.2: 최종 게이트 + 라이브 스모크 5종 (검증 전용, 커밋 없음)
**Step 1:** `make ci` green (typecheck·chart-test·run-bats·shellcheck·audit·ledger). docker 있으면 alertmanager-e2e.
**Step 2: 잔여 토큰 0 확인:**
```bash
git grep -nE '\bnode tools/|\.mjs|corepack|actions/setup-node|\bpnpm \b|node -e' -- \
  'tools/**' 'tests/**' '.github/**' 'scripts/**' Makefile package.json \
  | grep -vE 'secret:seal|app 레포|ci\.yaml.*setup-node|22\.18|node-without-bun|strip-types'
```
→ 의도된 예외(앱측 secret:seal·스모크용 node)만 남아야.
**Step 3: 라이브 스모크 5종:** ①kubeseal spawnSync(provision/seal bats) ②dev.ts SIGINT(수동 Ctrl-C) ③bump-tag 바이트(test_bump) ④dns:promises(`bun tools/dns-drift-check.ts ...`) ⑤app-shared node 스모크(`bash tests/gates/app-shared-node-smoke.sh`)
**Step 4:** `./scripts/run-bats.sh` 전량 green(신규 test_mutation-dispatch·test_audit-workflow·test_teardown-wrapper 포함 — 후자 2개는 node 무관이라 무영향 확인).

---

## 완료 기준 (Definition of Done)

- [ ] `make ci` green (typecheck·chart-test·run-bats·shellcheck·audit·ledger).
- [ ] Phase 6.2 Step 2 잔여 토큰 grep → 의도된 예외만.
- [ ] 19 tools 전부 `.ts`(17)/`.mts`(2), bun.lock(텍스트)·tsconfig·bunfig·@types/bun 존재.
- [ ] 계약/단언 테스트 전량 green: setup-bun·ci-gate·workspace·shebang-exec·mutation-dispatch·ci-blocking-comment·app-deploy·bump-poll-toctou·ledger-gate·verify-ledger-ssot·workflow-yaml·ledger-totals·make-ci-parity·teardown-wrapper.
- [ ] setup-bun 계약 3번째 테스트 green(setup-node 예외 1건=스모크, SHA핀+22.18).
- [ ] 라이브 스모크 5종 통과.
- [ ] 단일 PR — revert로 원자적 롤백.

---

## Adversarial review dispositions (Phase C)

working-tree 모드 codex 적대적 리뷰(Phase C 4패스는 base `cde6261`에서 수행). high 전부 해소·수렴(2high+1med → 1high → 1high+1med → 2med → 적용). **이후 origin/main이 `aa9bffa`(#62 v1 onboarding 폐기)로 재드리프트 → 리베이스 + 교차검증으로 플랜 축소**(툴 20→19·composite 8→7·onboard-app/onboard.yaml/test_onboard 제거·신규 v1 식별자 게이트 `test_workflow-yaml` 반영). 축소는 순수 subtractive(삭제된 onboard 제외)라 재리뷰 생략 가능.

| Pass | Finding | Sev | 처리 |
|---|---|---|---|
| 1 | tsconfig `types:[bun]`인데 `@types/bun` 누락 | high | **Accepted** — Task 0.1 devDeps에 `@types/bun` + test_workspace 단언 |
| 1 | setup-bun ban이 스모크용 setup-node와 모순 | high | **Accepted** — ban이 ci.yaml 스모크 1건 예외 허용(SHA핀+22.18) |
| 1 | 스모크 픽스처가 secret-name 계약 위반 + grep만 | med | **Accepted** — 유효 픽스처(`secrets:[token]`) + bats가 실제 실행 |
| 2 | `scripts/teardown.sh`가 삭제될 node `.mjs` 호출 | high | **Accepted** — Task 4.2 신설(래퍼 bun화) + 최종 grep에 `scripts/**` |
| 3 | 스모크가 별도 잡=비-required → 무성 회귀 | high | **Accepted** — required `gate` 잡 안 스텝으로 이동 |
| 3 | 스모크가 dry-run만 — 실제 seal 경로 미검증 | med | **Accepted** — kubeseal stub + 실제 `--app/--out` seal 경로 + 출력 단언 |
| 4 | typecheck를 TS 입력 0개 상태서 실행(tsc 'No inputs') | med | **Accepted** — typecheck-green을 Task 1.1(첫 .ts 후)로 이동 |
| 4 | `make ci`에 typecheck 누락(ci.yaml 패리티 깨짐) | med | **Accepted** — Makefile ci 타겟에 `bun run typecheck` + parity 테스트 |

**최종 패스(pass 4) verdict:** `needs-attention` (high 0, medium 2 — 둘 다 Accepted·적용). 사용자가 캡(3) 초과 confirming 1패스를 승인했고, pass 4의 medium 2건 반영 후 **사용자 결정으로 finalize**(추가 리뷰 없음; 잔여는 TDD 루프가 구현 중 자연 검출하는 단계순서 이슈).
**Summary(pass 4):** "high 전부 해소; 남은 건 typecheck 단계순서·make-ci 패리티의 기계적 medium 2건."

설계 레벨 리뷰(Phase A.5) dispositions는 `2026-06-18-bun-migration-design.md`의 동명 섹션 참조(F1 `.mts`+node 스모크, F2 bun 버전 핀).

## Execution directives
- **Skill:** implement via `executing-plans` in a **separate session, in this worktree**(`worktree-bun-ts-migration`).
- **Run continuously:** 배치 사이 루틴 리뷰로 멈추지 말 것. 진짜 블로커(의존성 부재·반복 실패하는 검증·모순된 지시·critical 플랜 갭)에서만 정지. 그 외 전 배치 완주.
- **Commits — 직접 적용, `Skill(commit)` 호출 금지**(인터랙티브 확인이 연속 실행을 깸):
  - **언어:** 한국어. **AI 마커 금지**(`🤖 Generated with`/`Co-Authored-By: Claude` 등 절대 불가).
  - **형식:** `<type>(<scope>): 한국어 설명` (필요 시 `- 상세` 본문).
  - **Type(이것만):** `feat`/`fix`/`refactor`/`docs`/`style`/`test`/`chore`. `perf`/`build`/`ci` 금지.
  - **그룹화:** ① 같은 모듈/목적 함께 ② 목적별 분리(refactor vs fix vs feat) ③ 상호 참조 파일 함께 ④ config(package.json/tsconfig)·tests·docs·style 각각 독립 커밋.
  - **위치:** 각 플랜 `Commit` 스텝에서 현재 피처 워크트리에 직접 커밋(이미 main 밖 — 새 브랜치 불요).
- **PR:** 단일 PR(gate-first). gate가 required check이므로 계약 bats 재작성을 같은 PR에. auto-merge 비활성 레포 — gate watch 후 수동 머지.
