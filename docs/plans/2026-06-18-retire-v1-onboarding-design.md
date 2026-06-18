# v1 onboarding 경로 폐기 + 템플릿 v2 이행 — 설계

- 날짜: 2026-06-18
- 상태: 설계 확정 (hardened-planning Phase A)
- 브랜치: `refactor/retire-v1-onboarding`

## 1. 배경 / 문제

앱 온보딩 경로가 **v1/v2 이중**으로 갈라져 있고 v1이 사실상 죽어 있다:

- **v2 (권위)**: `✨ create-app`(owner workflow_dispatch) → `_create-app.yaml` → 앱 레포 `.app-config.yml`(`app-config-schema.json`) read → SealedSecret. reusable-app-build 주석도 "온보딩은 owner의 create-app"이라 명시.
- **v1 (deprecated + orphaned)**: `onboard.yaml`(repository_dispatch `app-onboard`) → `onboard-app.mjs` → 앱 레포 `.homelab.yaml`(`homelab-app-schema.json`) + **KSOPS**(코드에 `[deprecated]` 명시). **트리거 발신자 없음** — reusable-app-build가 "homelab dispatch 전부 제거"라 `app-onboard`를 쏘는 곳이 0. 즉 onboard.yaml은 고아.

**드리프트 본질**: 외부 템플릿 레포가 v1 `.homelab.yaml`을 쓴다 → 템플릿으로 만든 앱은 (a) create-app(v2)이 `.app-config.yml` 부재로 못 받고 (b) onboard(v1)는 트리거가 없어 못 돈다 → **다음 온보딩이 양쪽 다 불가**. (현재 인-레포 앱 0개라 라이브 영향은 없음 — 다음 온보딩 때 터지는 지뢰.)

## 2. 목표 / 비목표

**목표**: 권위 경로를 **v2 create-app 단일**로. 죽은 v1 경로를 homelab에서 전면 제거하고, 템플릿을 v2로 이행해 온보딩이 실제로 동작하게.

**비목표**: create-app(v2) 로직 변경 / 공유 lib(`identity`·`ledger-totals`) 변경 / 플랫폼 KSOPS(cnpg 등 SOPS 경로 — v1 app-secret KSOPS와 무관) 변경 / bump의 `app-image` repository_dispatch(별개 과도기 경로) 처리.

## 3. 설계

### A. 템플릿 레포 v2 이행 (외부 `ukyi-app/homelab-app-template`, 별도 PR)

`.homelab.yaml` → **`.app-config.yml`** (v2 `app-config-schema.json`; required `kind`·`resources`):

| v1 `.homelab.yaml` | v2 `.app-config.yml` |
|---|---|
| `kind`(service\|worker\|static) · `resources` · `route` · `env` · `deploy` | 동일 |
| `db: {enabled: false}` (객체) | `db: []` (선프로비전 리소스 **이름 배열**; 빈=없음) + 필요시 `migrate: {cmd: [...]}` |
| `secrets: []` (KSOPS 관리) | `secrets: []` (이름 배열 → SealedSecret) |
| (없음) | `redis: []` 추가(주석으로 설명) |

- README: step 2 `.homelab.yaml`→`.app-config.yml`, 시크릿 절 KSOPS/SOPS → **`pnpm secret:seal`**.
- 검증: 템플릿 `.app-config.yml`을 `node tools/create-app.mjs --dry-run`(스키마+비즈니스 규칙)으로 통과 확인(권위 검증기).

### B. homelab v1 전면 폐기 (별도 PR)

**삭제(4):** `.github/workflows/onboard.yaml` · `tools/onboard-app.mjs` · `tools/homelab-app-schema.json` · `tools/tests/test_onboard.bats`

**테스트 갱신(삭제 파일 참조 — 안 고치면 `run-bats`/gate red):**
- `tests/gates/test_setup-node-pnpm.bats` — node-workflow 목록서 `onboard.yaml` 제거(현 8 → 7).
- `tests/gates/test_setup-toolchain-kubeseal.bats` — `onboard.yaml` 루프서 제거(`_create-app`만).
- `tests/gates/test_ci-toolchain-pin.bats` — helm-composite 루프서 `onboard.yaml` 제거.
- `tests/gates/test_telegram-callsites.bats` — EXPECTED 맵서 `onboard.yaml 1` 줄 제거.
- `tools/tests/test_cli-flag-guard.bats` — `onboard-app rejects unknown flag` @test 제거.
- `tools/tests/test_identity.bats` — arg-guard 목록서 `onboard-app` 제거.
- `tests/gates/test_pr-sweeper.bats` — 브랜치 prefix regex서 `onboard` 제거(아래 워크플로와 동기).

**코드/워크플로 갱신:**
- `.github/workflows/pr-sweeper.yaml:46` — sweep regex `^(bump|…|onboard|update-secrets)/`서 `onboard` 제거(더는 onboard/ 브랜치 없음).
- `.github/workflows/bump.yaml:162` — 에러 "미온보딩 앱 … onboard PR부터 머지" → "create-app 먼저".
- `tools/provision-cache.mjs:332` 주석(`onboard-app.mjs와 동일 규약` → `create-app.mjs`), `tools/create-app.mjs:3` 주석(onboard-app 참조 제거), `platform/argocd/root/appset.yaml:83` legacy onboard-app 주석 정리, `tools/app-config-schema.json:5` 설명의 `.homelab.yaml` 구계약 언급 정리(선택).

**문서 갱신:**
- `tools/README.md` — `homelab-app-schema.json` 행·v1→v2 마이그레이션 노트·`onboard-app.mjs` 항목 제거.
- `AGENTS.md` — 멀티레포 플로우 v1 서술·런북 인덱스(`app-onboarding.md`)·관련 표현 정리.
- `.github/workflows/README.md` — 🤖 자동 표의 `onboard` 행 제거.

**가드 신설(영구):** 삭제 v1 식별자(`onboard\.yaml`·`onboard-app`·`homelab-app-schema`·`\.homelab\.yaml`) 잔존 추적 참조 0 — `test_workflow-yaml.bats`의 deleted-workflow 가드 확장(docs/plans·런북·자기파일 제외).

**유지(공유·무관):** `tools/lib/identity.mjs`·`tools/lib/ledger-totals.mjs` · 플랫폼 KSOPS · `ci.yaml`의 "memory ledger onboarding"(무관).

### C. owner-local / 외부 (PR 밖 수동)

- `infra/github/repo.tf` — 템플릿 description(".homelab.yaml 채우고 push→온보딩 PR 자동")·주석(`bump/onboard`) 갱신. **github tf 루트는 owner-local apply**(CI 미적용, 신뢰앵커) → 코드 PR에 포함하되 **반영은 owner의 로컬 `terraform apply`** 필요(명시).
- 런북 `app-onboarding.md`·`app-platform.md`(gitignored) — v1 서술 갱신, PR 밖 수동.

## 4. 안전성 / 검증

- **참조맵 기반 삭제**: §3 B의 삭제·갱신 목록은 `git grep`(onboard/homelab-app-schema/.homelab.yaml/app-onboard) 전수에서 도출. 플랜 실행 시 **discovery 스윕 재실행**으로 누락 0 보장.
- 게이트: `make verify` · `run-bats`(신규 가드 포함) · shellcheck · chart-test.
- **KSOPS 오삭제 방지**: v1 KSOPS는 `onboard-app.mjs` 분기에만 — 삭제는 그 파일 제거로 한정. 플랫폼 KSOPS(`kustomize --enable-exec`)는 불변.
- 외부 계약 불변: `reusable-app-build.yaml`(byte-stable) — 단 그 주석의 stale `dispatch-mutation(create-app)`은 별개(외부계약 제외 정책 유지).

## 5. 리스크 & 오픈

- repo.tf description = owner-local terraform apply(수동) — PR 머지만으론 GitHub 메타데이터 미반영.
- pr-sweeper regex서 onboard 제거 = 동작 변경(onboard/ 브랜치 미스윕 — 존재 0이라 무해).
- 템플릿(A)·homelab(B)는 독립 PR, 의존 없음(v1 이미 orphaned). 순서 무관.
- 런북(로컬)은 PR 게이트 밖 — 수동 갱신 필요.
