# 설계: homelab tools/ — Node+pnpm → Bun + TypeScript 마이그레이션

- **날짜**: 2026-06-18
- **상태**: 승인됨 (brainstorming Phase A — 사용자 승인 완료)
- **브랜치**: `worktree-bun-ts-migration`
- **후속**: writing-plans(Phase B) → 적대적 리뷰 루프(Phase C) → finalize(Phase D) → 별도 executing-plans 세션

## 배경 & 동기

`tools/`는 ESM `.mjs` ~20개로 된 글루/오케스트레이션 CLI다(`kubectl`/`git`/`gh`/`kubeseal`/`docker` 셸아웃 + 코멘트 보존 YAML 편집 + 계약 검증). CI(`gate` required check)와 로컬에서 돌고 bats로 블랙박스 테스트된다. 의존성은 순수 JS `yaml` 1개뿐.

사용자의 원래 동기는 **TypeScript로 관리**하는 것이고, bun을 그 수단으로 택했다. (Node도 22.18+/24에서 type stripping을 네이티브 지원하지만, 사용자는 bun 런타임 통일을 명시 선택.)

## 결정 요약 (잠금)

1. **스코프 = Full 교체.** node·pnpm를 homelab에서 제거하고 **bun이 deps(`bun.lock`)+런타임+TS**를 전담.
2. **도달 범위 = homelab 레포만.** `homelab-app-template`·앱 레포(별도 레포, CI sync 미강제)는 이 계획 밖.
3. **TS 동시 전환.** homelab 전용 툴(~18개) `tools/*.mjs`·`tools/lib/*.mjs` → **`.ts`**.
4. **app-shared 툴은 `.mts`.** `seal-secret`·`env-example`(앱 레포에서도 실행되는 2개)은 **`.mts`**(무조건 ESM)로 전환. (A.5 리뷰 반영 — 아래.)

### 핵심 화해: erasable-syntax-only + `.mts`

결정 2(homelab-only, 앱 측 node 유지)와 결정 4(app-shared 툴 TS화)의 긴장은 **`tsconfig` `erasableSyntaxOnly` + 확장자 `.mts`로 해소**한다:

> - `erasableSyntaxOnly`(enum·런타임 namespace·생성자 파라미터 프로퍼티·레거시 데코레이터 금지) → 같은 TS 파일이 bun과 node strip-types 양쪽에서 실행 가능(문법 차원).
> - **`.mts`는 package.json `type`과 무관하게 무조건 ESM** → `.mjs`가 갖던 "무조건-ESM" 속성을 보존한다. (일반 `.ts`는 모듈 모드가 app-repo package.json `type`에 의존 → app 레포에서 CJS로 오인돼 깨질 수 있음. **A.5 Finding 1이 잡은 함정.**)

이로써 app-shared 2개는 bun(homelab)과 node≥22.18 strip-types(앱 레포) 양쪽에서 단일 소스로 실행된다. **단, 문법 호환만으론 부족**하므로(A.5 Finding 1) homelab CI에 **node-without-bun 스모크**(이 2개를 node strip-types로 실행)를 *인-스코프 안전망*으로 추가한다. template sync(별도 레포)는 "앱 레포 node≥22.18 핀 + 스크립트 경로 `.mts` 갱신" 후속 의무를 남긴다(범위 밖, 문서화).

## 엔드스테이트 (성공 기준)

- homelab CI/Makefile/bats에서 `node`/`pnpm` 토큰 소멸, bun으로 대체.
- 모든 tools `.ts`(erasable-syntax), `bun.lock`(텍스트) 커밋, 신규 `tsc --noEmit` 타입체크 게이트.
- 기존 게이트(`gate` required check: `make chart-test`·run-bats.sh·shellcheck·gitleaks·sops-guard·alertmanager-e2e·ledger·audit) 전부 GREEN.
- 라이브 스모크 4종 통과(아래).
- 단일 PR로 원자적 머지·롤백 가능.

## 변경 인벤토리

### ① deps / lockfile / 매니페스트
- `pnpm-lock.yaml` + `pnpm-workspace.yaml` 삭제(워크스페이스는 nominal — JS 멤버 0, `platform/charts/*`는 Helm, `tools`는 package.json 없음).
- `bun install`로 `bun.lock`(**텍스트**, GitOps 리뷰 가능성) 생성·커밋. CI는 `bun install --frozen-lockfile`.
- `.npmrc`(engine-strict / prefer-frozen-lockfile) → `bunfig.toml`(`[install] frozenLockfile=true`) 또는 제거.
- `package.json`: `engines.node`·`engines.pnpm` 제거; **`packageManager: "bun@<x.y.z>"`로 교체**(레포 가시 버전 SSOT — A.5 Finding 2); `devDependencies`에 `yaml` 유지 + `typescript` 추가; scripts `node`→`bun`(app-shared 2개 스크립트는 `.mts` 경로).

### ② TypeScript
- 신규 `tsconfig.json`: `strict`, **`erasableSyntaxOnly`**(앱 측 node strip-types 양립 강제), `verbatimModuleSyntax`, `allowImportingTsExtensions`, `noEmit`, bun용 `moduleResolution`(bundler).
- 확장자: homelab 전용 → `.ts`; **app-shared 2개(`seal-secret`·`env-example`) → `.mts`**(무조건 ESM, A.5 Finding 1).
- 상대 import 확장자 `./lib/x.mjs` → `./lib/x.ts`(현재 explicit `.mjs`라 일괄 치환 — bump-tag/create-app/onboard-app/teardown-app/activate-app/validate-mutation/audit-orphans 등). app-shared 2개는 `lib/` 미참조라 영향 없음.
- 신규 타입체크 게이트: `tsc --noEmit`(`bunx tsc`) → `make ci` + `ci.yaml`(`.ts`+`.mts` 모두 커버).

### ③ CI 워크플로 / composite
- composite `.github/actions/setup-node-pnpm` → **`setup-bun`**(`oven-sh/setup-bun@<SHA>` + **`bun-version: "<x.y.z>"`** 명시 핀(A.5 Finding 2 — 액션 SHA는 바이너리 버전을 핀하지 않음) + `bun install --frozen-lockfile`). 참조 9개 워크플로 경로 갱신.
- inline setup-node 2곳(`dispatch-mutation.yaml`·`dns-drift.yaml`) → setup-bun.
- `node -e` → `bun -e`(dns-drift, 4곳, CJS `require("fs")` 포함), `node - <<EOF` heredoc → `bun -`(`_create-cache.yaml`).
- 모든 `node tools/x.mjs` → `bun tools/x.ts` 스텝(ci/bump/bump-poll/onboard/_audit/_create-*/_teardown/dispatch-mutation/dns-drift).
- **SHA 핀 수동**: Renovate github-actions 매니저 비활성 → `oven-sh/setup-bun@<SHA>`에 버전 주석 병기, 자동 bump 없음.

### ④ 호출처 (~42)
- bats 27개: `run node "$X.mjs"` → `run bun "$X.ts"`(kubeseal stub의 `exec node -e` 포함), 확장자 갱신.
- package.json scripts 6개(dev/db:url/cache:url/env:example/secret:seal/db:reset 등).

### ⑤ Makefile (수정 반영)
- `m6-tools` 게이트: `node --version | grep v2[2-9]` + `pnpm --version ^11` → **`bun --version`이 `packageManager`의 핀 버전과 일치**하는지 grep(존재만이 아니라 일치 — A.5 Finding 2).
- `make ci`/`audit`의 `node`/`pnpm` → `bun`.
- **MISE_SHIMS 가드(Makefile:4-10) 통째 제거** — node 이탈로 `ifneq($(wildcard .../node))` 프로브가 어차피 false가 되어 무의미.
- **레포 mise.toml 미신설** — 레포 관례("커밋된 tool-versions 없음") 유지. bun 버전 SSOT = `package.json` `packageManager: "bun@x.y.z"`(레포 가시) + CI `setup-bun` `bun-version` 핀(머신 강제) + Makefile 게이트 일치 검사 + `toolchain-setup.md` 동일 핀 참조.
- **전제**: `make ci`가 비대화형 셸에서 부르는 도구(`bun`, `conftest`/`kubeconform` 등)는 시스템 PATH에 존재해야 함(mise-only면 exit-127 재발). 사용자 로컬 셋업으로 충족 간주.

### ⑥ dev 툴
- `dev.ts`의 `pnpm -r --parallel --if-present dev` spawn → `bun run --filter '*' dev`(멤버 0이라 no-op) 또는 제거. docker compose 경로 유지.

### ⑦ 계약 bats 재작성 (gate 내)
- `tests/gates/test_setup-node-pnpm.bats` → `test_setup-bun.bats`(setup-bun + `bun install --frozen-lockfile` 단언; "9 워크플로 채택" 유지).
- `tests/gates/test_ci-gate.bats`: `pnpm@11` grep → bun composite 단언.
- `tools/tests/test_workspace.bats`: `packageManager == pnpm@11*` + pnpm-workspace 단언 제거/대체.
- `tools/tests/test_shebang-exec.bats`: glob `*.mjs` → `*.ts`(+ shebang 금지 불변 유지).

## 테스트 전략 & 라이브 스모크

- **테스트 계약은 bats 유지**(블랙박스 — 런타임 토큰만 swap). API "지원"만으론 불충분 → 다음 **라이브 스모크** 필수:
  1. **kubeseal `spawnSync` stdin 파이프** — `seal-secret`/`provision-db`/`provision-cache`(JSON manifest를 `input:`으로 전달 + stdout 수신).
  2. **`dev.ts` SIGINT 포워딩** — `process.on('SIGINT')` → 자식 프로세스 kill.
  3. **`bump-tag` yaml 코멘트 보존 바이트 동일** — `parseDocument` 라운드트립, `test_bump.bats`가 출력 바이트 단언.
  4. **`dns-drift-check` `node:dns` promises** — bun 호환 확인(워크플로에서 실행).
  5. **app-shared node-without-bun 스모크** (A.5 Finding 1 안전망) — `seal-secret.mts`·`env-example.mts`를 **node≥22.18 strip-types로**(bun 없이) `--dry-run` 실행해 앱 레포 실행 경로를 인-스코프로 증명. homelab CI에 `setup-node`(≥22.18) 1스텝 한정 재도입(node 제거 취지의 의식적 예외).
- exit code 1/2 일치 필수(bats가 `$status` 단언 — 검증기/게이트는 계약 위반 시 1/2로 exit).

## 롤아웃 & 롤백

- **단일 PR · gate-first.** 유일 required check `gate`가 pnpm 계약 bats(⑦)를 돌리므로, 계약 재작성+composite+lockfile+호출처+TS를 **한 PR에** 안 묶으면 레포가 머지 불능(App 토큰은 branch protection 우회 불가). 따라서 ⑦(계약 bats)을 가장 먼저 새 계약으로 바꾸고 나머지를 같은 PR에 적층.
- **롤백** = PR revert(단일 PR이라 원자적). 라이브 영향 없음(ArgoCD는 platform/ 싱크 — tools/는 CI/로컬 전용).

## 리스크 & 완화

| 리스크 | 완화 |
|---|---|
| bun node-API 미묘한 차이(spawnSync stdin·SIGINT·dns) | 라이브 스모크 5종 + exit code 단언 |
| `gate` red로 머지 불능 | 단일 PR + ⑦ 계약 bats 먼저 |
| setup-bun SHA 자동 bump 부재 | 수동 핀 + 버전 주석(레포 관례) |
| **bun 바이너리 버전 드리프트**(A.5 F2) | `packageManager: bun@x` + setup-bun `bun-version` 핀 + Makefile 일치 게이트 |
| bun.lock 바이너리화로 리뷰 불가 | **텍스트** bun.lock 강제(bun≥1.1) |
| 비대화형 PATH에서 bun 부재(exit-127) | bun을 시스템 PATH 전제(brew 등) 문서화 |
| 앱 측 .ts가 app-repo서 CJS 오인(A.5 F1) | app-shared 2개 **`.mts`**(무조건 ESM) + node-without-bun CI 스모크 |
| 앱 측 SSOT 분기 | `.mts` 단일소스 + CI 스모크로 node 경로 증명; 앱 레포 node≥22.18 + 스크립트 경로 후속(범위 밖) |

## 범위 밖 / 후속

- **template/app-repo sync(별도 레포)**: `seal-secret.mts`/`env-example.mts`를 앱 레포에서 node strip-types로 돌리려면 앱 레포 **node≥22.18 핀 + 스크립트 경로 `.mjs`→`.mts` 갱신**. 별도 작업, CI 미강제 — 문서화만(homelab CI 스모크가 node 실행 가능성은 사전 증명).
- bun-version Renovate customManager(원하면 후속).

## 설계 적대적 리뷰 (Phase A.5) — dispositions

codex 1패스(branch diff `HEAD~1`, `--kind design`), `ok:true`·`planInDiff:true`·`verdict:needs-attention`·high 2건:

- **F1 (high) app-shared TS 안전성 미보장** → **수용.** `.mjs`→`.ts`가 무조건-ESM 상실(모듈 모드가 app-repo `type` 의존). 해소: app-shared 2개 **`.mts`** + homelab CI **node-without-bun 스모크**(인-스코프 안전망). 앱 레포 node≥22.18 + 스크립트 경로는 문서화 후속.
- **F2 (high) bun 바이너리 버전 미핀** → **수용.** `setup-bun@SHA`는 액션만 핀. 해소: `packageManager: "bun@x.y.z"`(레포 가시) + setup-bun `bun-version`(머신 강제) + Makefile 일치 게이트. (mise.toml은 사용자 요청대로 미신설.)

## 미해결 질문

- 없음(설계 + A.5 합의 완료). 세부 구현 순서·테스트 케이스는 writing-plans(Phase B)에서 확정.
