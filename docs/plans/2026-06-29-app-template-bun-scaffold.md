# homelab-app-template Bun/Hono/React 스캐폴더 + kind 리네임 구현 계획

> **For Claude:** REQUIRED SUB-SKILL: superpowers:executing-plans 로 이 계획을 task 단위로 구현하라.

**Goal:** `kind` enum을 `web`/`worker`/`site`로 전면 리네임하고, `homelab-app-template`을 `bun run scaffold` 대화형 CLI로 Bun+Hono(서버)+React/Vite(프론트) 4-아키타입을 즉시 배포 가능하게 스캐폴드하도록 개편한다.

**Architecture:** 교차 2-레포 변경. (1) **homelab**(워크트리, 단일 PR): 스키마·공유차트·create-app·fixtures·bats·라이브 example-api·문서의 `service→web`/`static→site` 리네임. (2) **homelab-app-template**(별도 레포·브랜치/PR): `scaffold/` 머신러리(자가삭제) + 4 아키타입 + `template-ci.yaml`. 아키타입은 CLI에만 존재하고 `.app-config.yml`엔 리네임된 infra `kind`만 남는다. (3) **외부 example-api**(owner-local): `.app-config.yml` `kind: service→web`.

**Tech Stack:** Bun(런타임·번들·스캐폴더), Hono(`Bun.serve`), React+Vite, `@clack/prompts`(대화형 UI), static-web-server(site 서빙), distroless(base-debian12 / SWS scratch, arm64 nonroot), Helm(공유차트), bats, TypeScript.

---

## Phase 0 — 사실·계약·매핑 (구현 전 숙지)

**리네임 매핑(불변 — worker는 이름 유지):**

| 옛 kind | 새 kind | 의미 | 차트 토폴로지 |
|---|---|---|---|
| `service` | `web` | HTTP 서빙(Hono) | Deployment+Service+HTTPRoute :8080 |
| `static` | `site` | 정적 SPA(SWS) | 〃 (SWS, `/health`) |
| `worker` | `worker` | 백그라운드 | Deployment만 |

**아키타입 → kind 매핑(스캐폴더 CLI 전용):** `fullstack`→`web`, `api`→`web`, `site`→`site`, `worker`→`worker`.

**런타임 계약(차트가 강제, `deployment.yaml` 검증 완료):**
- 서빙 kind(web/site): http `:8080`(`ports.http`), Service+HTTPRoute. worker: 비서빙·기본 liveness 없음.
- web 프로브: 앱 선언(`probes.liveness.path`/`readiness.path`). site 프로브: 차트가 `/health` 고정(SWS `--health`). 차트 기본 probes는 `/health`(values.yaml:44-45) — web 앱은 `.app-config.yml probes`로 `/healthz`,`/readyz` 명시.
- site 이미지 **ENTRYPOINT=SWS 바이너리**(차트가 `args:`만 주입, `command:` 없음 — deployment.yaml:45-50). 에셋은 `/public`.
- metrics(:9090 포트+scrape 어노테이션)는 **kind=web + metrics.enabled** 일 때만 차트가 배선(deployment.yaml:22,55 / service.yaml:18).
- 하드닝(차트 기본): runAsNonRoot/runAsUser 65532, readOnlyRootFilesystem, drop ALL, seccomp RuntimeDefault, `/tmp` emptyDir만 쓰기. `preStopSleepSeconds:0`(distroless `/bin/sleep` 부재).

**`static` values 필드는 유지(서브결정):** `kind` 값만 `static→site`로 바꾸고, 차트의 `static: { server: sws }` **필드명은 유지**한다(= "정적 파일 서빙 메커니즘" 의미라 kind 이름과 독립; 리네임 시 bats/template 추가 churn 대비 이득 적음). deployment.yaml에 한 줄 주석으로 "kind=site가 사용"을 명시. *(Phase C 리뷰가 이의 제기 시 재판정.)*

**빌드 경로:** `reusable-app-build.yaml`은 `docker/build-push-action@v6`·`linux/arm64`·build+push만 — 언어 불문이라 Bun/SWS Dockerfile 그대로 동작(별도 변경 불필요).

**도구 핀(homelab `docs/runbooks/toolchain.md`/`tools/` 기준 확인):** bun 버전은 homelab `tools/`와 정렬(현 1.3.x). 이미지 태그(oven/bun, distroless/base-debian12, static-web-server)는 **digest 핀** 권장(Renovate가 갱신) — Phase 2에서 실제 가용 태그를 `docker manifest inspect`로 확인 후 핀.

**경로 약어:** `HL=` homelab 워크트리 루트(현 cwd), `TPL=`~/workspace/homelab-app-template`.

**리네임 시 절대 변경 금지(오탐 가드):**
- `kind: Deployment|Service|SealedSecret|Kustomization|HTTPRoute` 등 **k8s 리소스 kind** (앱 enum 아님).
- `values.yaml:47-49`의 주석 "distroless(Rust **static**/scratch) worker" — 여기 `static`은 **정적 링크 바이너리**를 뜻함(kind 아님). 변경 금지.
- `tools/tests/test_app-shared-node-smoke.bats:18`의 `db:`/`redis:` 등 다른 스테일 필드는 이 작업 범위 밖(kind만 변경).

---

## Phase 1 — homelab: kind 리네임 (web/worker/site) [워크트리·단일 PR]

> 리네임은 원자적이다(부분 변경 = 게이트 RED). 아래 Task를 한 PR로 묶고, Task 1.7의 전체 게이트로 검증·커밋한다. 작업은 현 워크트리(`HL`)에서 수행.

### Task 1.1: 스키마 enum + fail-loud(구 kind 거부) 테스트

**Files:**
- Modify: `HL/tools/app-config-schema.json:10`
- Modify: `HL/platform/charts/app/values.schema.json:20`
- Modify: `HL/tools/create-app.ts:142` (static→site)
- Modify/Add test: `HL/tools/tests/test_app-config.bats`

**Step 1: 실패 테스트 추가(RED) — 신값 수락·구값 거부**

`HL/tools/tests/test_app-config.bats`에 추가(영어 @test 이름 — CJK 침묵스킵 함정):

```bash
@test "schema accepts kind=web and kind=site" {
  for k in web worker site; do
    printf 'kind: %s\nresources:\n  requests: {cpu: 50m, memory: 64Mi}\n  limits: {cpu: 500m, memory: 128Mi}\n' "$k" > "$BATS_TEST_TMPDIR/c.yml"
    run bun tools/validate-app-config.ts "$BATS_TEST_TMPDIR/c.yml"   # 또는 기존 검증 진입점(아래 주: 없으면 create-app --dry-run 경유)
    [ "$status" -eq 0 ]
  done
}

@test "schema rejects legacy kind=service with actionable message" {
  printf 'kind: service\nresources:\n  requests: {cpu: 50m, memory: 64Mi}\n  limits: {cpu: 500m, memory: 128Mi}\n' > "$BATS_TEST_TMPDIR/c.yml"
  run bun tools/validate-app-config.ts "$BATS_TEST_TMPDIR/c.yml"
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "web"   # 안내가 신값 web을 가리켜야 함
}
```

> 주: 독립 검증 진입점이 없으면(현재 검증은 `create-app.ts` 내부 `check()`) **얇은 래퍼** `HL/tools/validate-app-config.ts`를 신설(스키마 로드 + `check()` 재사용)하거나, 기존 `test_app-config.bats`가 검증을 호출하는 방식을 그대로 따른다. 기존 `test_app-config.bats:42` "schema hides static.server..." 테스트의 호출 패턴을 참고해 동일 진입점 사용. **먼저 `test_app-config.bats`를 읽어 현재 검증 호출 방식을 확인**하고 그 방식에 맞춘다.

**Step 2: 테스트 실패 확인(RED)**

Run: `bats tools/tests/test_app-config.bats`
Expected: 신규 두 @test FAIL(구 스키마는 service 수락, web/site 거부).

**Step 3: 스키마 enum 변경(GREEN 1/2)**

- `app-config-schema.json:10`: `"kind": { "enum": ["web", "worker", "site"] }`
- `values.schema.json:20`: `"kind": { "type": "string", "enum": ["web", "worker", "site"] }`
- `app-config-schema.json` description(L5): "kind=static은…" → "kind=site는…" 으로 문구 갱신.

**Step 4: create-app fail-loud + static→site 매핑**

`create-app.ts`:
- L142: `if (kind === "static") values.static = { server: "sws" };` → `if (kind === "site") values.site = { server: "sws" };`

  ⚠️ 단, "Phase 0 서브결정"대로 **차트 values 필드는 `static` 유지**로 결정했으므로 L142는 `if (kind === "site") values.static = { server: "sws" };` (kind만 site, 필드는 static 유지). 위 두 줄 중 **필드 유지 버전** 채택.
- (선택, 안내 강화) `check()`의 enum 에러(L53)는 이미 `'${val}'은 ["web","worker","site"] 중 하나여야 함`을 출력 → 신값을 가리키므로 Step 1의 `grep web` 통과. 추가로 구값 특별 안내가 필요하면 L53 직전에:
  ```ts
  if (sch.enum && (val === "service" || val === "static")) fail(`${path}: kind '${val}'는 폐기됨 → ${val === "service" ? "web" : "site"}로 변경`);
  ```

**Step 5: 테스트 통과 확인(GREEN)**

Run: `bats tools/tests/test_app-config.bats`
Expected: PASS.

**Step 6: (커밋은 Task 1.7에서 일괄 — 부분 리네임 중간 커밋 금지)**

### Task 1.2: 공유차트 템플릿 + values.yaml

**Files:**
- Modify: `HL/platform/charts/app/templates/deployment.yaml` (L22, L45, L55, L67)
- Modify: `HL/platform/charts/app/templates/service.yaml` (L18)
- Modify: `HL/platform/charts/app/values.yaml` (L13, L31, L52-54 주석)

**Step 1: deployment.yaml kind 조건 갱신**
- L22: `(eq .Values.kind "service")` → `(eq .Values.kind "web")`
- L45: `{{- if eq .Values.kind "static" }}` → `"site"` (+ L46 `eq .Values.static.server "sws"` 유지; L47 주석에 "kind=site 정적 서빙" 명시)
- L55: `(eq .Values.kind "service")` → `"web"`
- L67: `{{- if eq .Values.kind "static" }}` → `"site"`

**Step 2: service.yaml**
- L18: `(eq .Values.kind "service")` → `"web"`

**Step 3: values.yaml 주석/기본값**
- L13: `kind: service # service | worker | static` → `kind: web # web | worker | site`
- L31: `host: "" # service|static에 필수` → `# web|site에 필수`
- L52-54: 주석 "kind=static일 때만 사용" → "kind=site일 때만 사용"(필드명 `static`은 유지).

**Step 4: 검증(차트 렌더는 Task 1.3 fixtures 갱신 후 일괄)**

### Task 1.3: fixtures 리네임 + render.sh + fixtures-bad

**Files:**
- Rename: `fixtures/service.yaml` → `fixtures/web.yaml`; `fixtures/static.yaml` → `fixtures/site.yaml` (worker.yaml 유지)
- Modify: 위 두 파일 내부 `kind:` 값
- Modify: `fixtures/site.yaml` 의 `static: { server: sws }` 유지(필드명 유지 결정) — kind만 site
- Modify: `tests/render.sh:7`
- Modify: `tests/fixtures-bad/caps-add.yaml:3`, `tests/fixtures-bad/seccomp-unconfined.yaml:3`

**Step 1: fixtures 파일 git mv + 내용 갱신**
```bash
cd "$HL/platform/charts/app/tests"
git mv fixtures/service.yaml fixtures/web.yaml
git mv fixtures/static.yaml fixtures/site.yaml
```
- `fixtures/web.yaml`: `kind: service` → `kind: web`
- `fixtures/site.yaml`: `kind: static` → `kind: site` (그 아래 `static: { server: sws }`는 유지)
- `fixtures-bad/caps-add.yaml:3` `kind: service` → `kind: web`
- `fixtures-bad/seccomp-unconfined.yaml:3` `kind: service` → `kind: web`

**Step 2: render.sh 루프**
- L7: `for k in service worker static; do` → `for k in web worker site; do`

**Step 3: 렌더 검증**

Run: `bash platform/charts/app/tests/render.sh`
Expected: web/worker/site 3 kind 렌더 성공 + kubeconform + conftest PSA PASS. (example-api values는 아직 `kind: service`라 conftest 단계에서 렌더되지만 enum과 무관하게 PSA만 검사 — 단, helm `app.validate`/스키마가 values.schema.json을 통하면 Task 1.5 전엔 example-api 렌더가 enum 위반으로 실패할 수 있음 → **Task 1.5를 1.3 직후 수행**하거나 render.sh의 app-values 루프가 values.schema를 강제하는지 확인. helm template은 values.schema.json을 강제하므로 example-api(`kind: service`)는 신스키마에서 **렌더 실패** → Task 1.5와 함께 green.)

> ⚠️ 순서 의존: values.schema.json enum을 바꾸면 `apps/example-api/.../values.yaml(kind: service)`의 helm 렌더가 실패한다(render.sh의 app 루프). 따라서 **Task 1.5(example-api values)를 Task 1.3의 렌더 검증 전에** 적용하라. 본 계획 실행 시 1.1→1.2→1.5→1.3→1.4 순으로 진행.

### Task 1.4: bats 기계적 갱신 (chart tests + tools/tests)

**Files (chart):** `test_deployment.bats`, `test_route.bats`, `test_schema_fail_closed.bats`, `test_worker_ports.bats`, `test_image-digest.bats`, `test_defense.bats`, `test_probe_override.bats`, `test_db-consume.bats`, `test_no_migrate.bats`, `test_static.bats`, `test_psa_conftest.bats`
**Files (tools):** `test_create-app.bats`, `test_bump.bats`, `test_dev-data.bats`, `test_seal-secret.bats`, `test_app-shared-node-smoke.bats`, `test_update-secrets.bats`, `test_examples.bats`, `test_app-config.bats`

**Step 1: 기계적 치환(검토 동반)**

각 파일에서:
- `--set kind=service` → `--set kind=web`
- `--set kind=static` → `--set kind=site`
- `kind: service` → `kind: web`
- `kind: static` → `kind: site`
- (`static.server`/`--set static.server=` 는 **유지** — 필드명 유지 결정)
- `@test` 이름·주석의 "service"/"static" 단어 → "web"/"site" (예: `test_deployment.bats:8` "service Deployment…" → "web Deployment…"; `test_static.bats` 파일명은 유지하되 @test 문구의 kind는 site)

`worker`는 변경 없음. 치환 후 **각 파일을 눈으로 확인**(k8s `kind: Service` 등 오탐 없는지 — bats엔 보통 없음).

권장 접근(파일별, 안전):
```bash
cd "$HL"
for f in platform/charts/app/tests/*.bats tools/tests/*.bats; do
  # service/static은 kind 컨텍스트(--set kind= / kind:)에서만 — 안전 위해 패턴 한정
  perl -0pi -e 's/--set kind=service\b/--set kind=web/g; s/--set kind=static\b/--set kind=site/g; s/\bkind: service\b/kind: web/g; s/\bkind: static\b/kind: site/g' "$f"
done
```
그 후 남은 문구(@test 이름의 "service"/"static" 영단어)는 수동 갱신. `git diff`로 전수 확인.

**Step 2: 테스트 실행(RED→GREEN 확인)**

Run(영향 파일만, 빠른 피드백):
```bash
bash scripts/run-bats.sh platform/charts/app/tests tools/tests   # 또는 프로젝트 표준 러너
```
Expected: 전부 PASS. (치환 누락 시 특정 @test가 enum 위반/렌더 실패로 잡힘.)

> 함정 주의: bats 디렉토리 단위 실행 시 한글 @test 이름은 인코딩 깨짐 → 신규/수정 @test 이름은 **영어**. `run` 단언은 마지막 명령만 평가됨.

### Task 1.5: 라이브 example-api 인레포 values

**Files:** Modify `HL/apps/example-api/deploy/prod/values.yaml:5`

**Step 1:** `kind: service` → `kind: web`

**Step 2: 렌더 무변화(no-op) 확인**
```bash
# 리네임 전후 렌더가 selector/포트/프로브 등 기능상 동일한지 — 라벨 app.homelab/kind만 변함
helm template example-api platform/charts/app -f apps/example-api/deploy/prod/values.yaml | grep -E 'app.homelab/kind|kind: (Deployment|Service|HTTPRoute)'
```
Expected: `app.homelab/kind: web`(라벨만 변경), Deployment/Service/HTTPRoute 동일 생성. selector(name+instance)는 불변 → immutable selector 충돌 없음(라이브에선 pod 라벨 변경분 1회 롤만).

### Task 1.6: 문서 (PR 포함분만)

**Files:**
- Modify: `HL/README.md:102` ("3 kind(service/worker/static)" → "3 kind(web/worker/site)")
- Modify: `HL/AGENTS.md:26` (동일)
- (owner-local·gitignored) `docs/runbooks/app-onboarding.md:35` — 런북은 git에 없음 → PR 밖, owner가 로컬에서 별도 갱신(이 줄은 폐기된 v1 `pnpm gen:app`도 참조하므로 별도 정리).

**Step 1:** 위 두 줄 갱신.

### Task 1.7: 재검증 경로 확인 + 전체 게이트 + 커밋

**Step 1: 외부 `.app-config.yml` 재검증 경로 식별(Phase A.5 finding 대응)**

bump-poll/update-* 가 외부 `.app-config.yml`을 스키마로 재검증·재소비하는지 코드로 확인:
```bash
cd "$HL"
grep -rn "app-config" tools/ .github/workflows/ | grep -vi schema   # .app-config.yml 읽는 흐름
grep -rln "app-config-schema" tools/ .github/workflows/             # 스키마 재검증 흐름
```
- 결과를 PR 설명에 문서화: **어떤 흐름이 기존 앱의 외부 config를 재검증하는가**.
- 재검증 흐름이 **create-app(신규 온보딩 전용)뿐**이면 → 실행 중 example-api는 재검증 안 됨 → 스키마 컷오버가 라이브 example-api를 깨지 않음(외부 마이그레이션은 "재온보딩·일관성 대비"로 Phase 3에서).
- 만약 bump-poll/update-*가 외부 config를 재검증하면 → Phase 3(외부 마이그레이션)을 **이 PR 머지 전/동시에** 수행해야 함을 PR에 명시.

**Step 2: 전체 게이트**
```bash
cd "$HL"
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
set -e                 # fail-closed: 어떤 게이트든 RED면 즉시 중단(F2 — `|| true` 금지)
make verify            # skeleton + 원장(conftest) + sops
make chart-test        # web/worker/site 렌더 + kubeconform + bats
make ci                # gate 미러(tsc/run-bats/shellcheck/ledger/audit) — 타입오류·bats·shellcheck 실패를 잡음
bats tools/tests/      # tools bats 전수
# 라이브 의존(KUBECONFIG 없으면 자체 skip — masking 아님, 별도 실행):
make verify-posture    # internal-by-default·netpol·e2e (KUBECONFIG 부재 시 skip)
```
Expected: 전부 GREEN. **`|| true` 절대 사용 금지** — RED면 누락된 kind 참조·타입오류를 추적해 해결(게이트가 권위). `make ci`/`make verify`가 리네임 누락·타입오류·bats·shellcheck 실패를 fail-closed로 잡는다.

**Step 3: 커밋(executing-plans 커밋 규칙 — Phase D 디렉티브 따름)**

논리 그룹별 커밋(예시):
```bash
git add tools/app-config-schema.json platform/charts/app/values.schema.json tools/create-app.ts
git commit -m "refactor: kind enum을 web/worker/site로 리네임(스키마·create-app)"

git add platform/charts/app/templates platform/charts/app/values.yaml
git commit -m "refactor: 공유차트 kind 조건을 web/site로 갱신"

git add platform/charts/app/tests
git commit -m "test: 차트 fixtures·bats를 web/worker/site로 갱신"

git add tools/tests
git commit -m "test: tools bats의 kind 값을 web으로 갱신"

git add apps/example-api/deploy/prod/values.yaml
git commit -m "refactor: example-api kind를 web으로 리네임"

git add README.md AGENTS.md
git commit -m "docs: kind 어휘를 web/worker/site로 갱신"
```

---

## Phase 2 — homelab-app-template: 대화형 스캐폴더 + 4 아키타입 [별도 레포·브랜치]

> 작업 위치: `TPL=~/workspace/homelab-app-template`. 별도 git 레포 → 자체 feature 브랜치 + PR. 먼저 `cd "$TPL" && git checkout -b feat/bun-scaffold`(main 직접 금지).

### Task 2.0: 레포 구조 + 루트 package.json + common/

**Files (create under `$TPL`):**
- `package.json`(루트 — 스캐폴더용), `scaffold/scaffold.ts`(2.1), `scaffold/common/*`, `scaffold/archetypes/*`(2.2~2.5), `.github/workflows/template-ci.yaml`(2.7)
- Remove(이전 스텁): 루트 `Dockerfile`, `src/.gitkeep`, 기존 `.app-config.yml`(스테일 — db/redis 포함), 루트 `README.md`(2.8서 재작성), 기존 `.github/workflows/release.yaml`(→ `scaffold/common/.github/workflows/release.yaml`로 이동)

**Step 1: 루트 `package.json`**
```json
{
  "name": "homelab-app-template",
  "private": true,
  "type": "module",
  "scripts": { "scaffold": "bun run scaffold/scaffold.ts" },
  "devDependencies": { "@clack/prompts": "^0.x", "yaml": "^2.x" }
}
```
(버전은 `bun add -d @clack/prompts yaml` 후 lockfile 핀.)

**Step 2: `scaffold/common/` 공통 파일**
- `scaffold/common/.gitignore`(node_modules, dist, web/dist, *.local, .env*)
- `scaffold/common/.dockerignore`(.git, node_modules, **/dist, .github)
- `scaffold/common/tsconfig.json`(bun 호환 base: `"moduleResolution":"bundler"`, `"types":["bun-types"]` 등)
- `scaffold/common/.github/workflows/release.yaml` ← 기존 release.yaml 이동(아래). 단 `if: github.repository != ...template` 가드는 제거(앱 전용이라 불필요).
  ```yaml
  name: release
  on: { push: { branches: [main] } }
  permissions: { contents: read, packages: write }
  jobs:
    release:
      uses: ukyi-app/homelab/.github/workflows/reusable-app-build.yaml@main
      with: { app: ${{ github.event.repository.name }} }
  ```
- `scaffold/common/README.app.md`(스캐폴드 후 앱 README로 치환될 본문 템플릿 — 플레이스홀더 `{{APP}}`,`{{ARCHETYPE}}`)

**Step 3: 검증**
```bash
cd "$TPL" && bun install && test -f scaffold/common/.github/workflows/release.yaml && echo ok
```

### Task 2.1: scaffold.ts (대화형 + 비대화형)

**Files:** Create `$TPL/scaffold/scaffold.ts`

**동작 사양:**
1. 인자 파싱(**strict, F1**): `--archetype <fullstack|api|site|worker>` `--name <app>` `--public` `--metrics` `--no-autodeploy` `--yes`(비대화형). **allowlist 외 flag·누락/flag-형 값은 exit 2로 거부**(homelab parseFlags 규약). flag 미지정 + TTY면 `@clack/prompts`로 질의.
2. 기본 app 이름 = `path.basename(process.cwd())`. **homelab `tools/lib/identity.ts`의 `APP_NAME_RE`(`/^[a-z][a-z0-9-]{0,38}[a-z0-9]$/` — 소문자 시작·trailing hyphen 금지·길이 2..40)와 동일 정규식**을 대화형·비대화형 두 경로 모두 적용(F1·#2 — 느슨하면 빌드 후 create-app서 거부). 실행 시 homelab 정규식을 복제·동기, 네거티브 케이스(선행숫자·trailing hyphen·1자·대문자·언더스코어·40자초과).
3. 멱등/안전 가드: 루트에 `src/` 또는 `web/`가 이미 있고 `scaffold/`가 없으면(=이미 스캐폴드됨) 거부. `scaffold/` 부재 시 실행 거부.
4. 전개: `scaffold/archetypes/<a>/**` + `scaffold/common/**` → 레포 루트 복사(common의 `README.app.md`는 `README.md`로, 플레이스홀더 치환).
5. `.app-config.yml` 렌더(아래 Task 2.6 매핑) → 루트.
6. 루트 `package.json` 재작성: name=app, archetype의 deps/scripts 병합, `scaffold` 스크립트·`@clack/prompts` 제거.
7. **lockfile 재생성(F1) — 자가삭제 前(F4)**: package.json을 신 deps(hono/react/vite·clack 제거)로 재작성했으므로 `bun install`을 재실행해 `bun.lock`을 갱신한다. 빠뜨리면 **stale 템플릿 lock**(clack/yaml)이 커밋돼 Dockerfile `bun install --frozen-lockfile`이 첫 GHCR 빌드에서 실패. **실패 시 생성 파일 롤백(#3 — 전개 前 스냅샷 기준 새 엔트리 제거)+scaffold/ 보존+비0 종료**(부분 생성·success 위장 방지; src/web 제거로 멱등 가드 재통과 → 재시도 가능).
8. **자가삭제(lock 성공 후에만)**: `rm -rf scaffold/`, `rm -f .github/workflows/template-ci.yaml`(템플릿 전용 — 앱에 누출 금지).
9. 안내 출력: 다음 단계(`git add -A && git commit && git push` → owner가 homelab `create-app` 디스패치).

**Step 1: scaffold.ts 작성(골격)**
```ts
#!/usr/bin/env bun
import { intro, outro, select, text, confirm, isCancel, cancel } from "@clack/prompts";
import { stringify as toYaml } from "yaml";
import { cpSync, rmSync, existsSync, writeFileSync, readFileSync, readdirSync } from "node:fs";
import { basename, join } from "node:path";

const ROOT = process.cwd();
const SCAFFOLD = join(ROOT, "scaffold");
if (!existsSync(SCAFFOLD)) { console.error("scaffold/ 부재 — 이미 스캐폴드된 레포로 보임"); process.exit(1); }
if (existsSync(join(ROOT, "src")) || existsSync(join(ROOT, "web"))) { console.error("src/ 또는 web/ 이미 존재 — 중복 스캐폴드 방지"); process.exit(1); }

// --- 인자 (strict: allowlist 외 flag·누락/flag-형 값 거부 — homelab parseFlags fail-closed 규약 모사, F1) ---
const argv = process.argv.slice(2);
const ARCHES = ["fullstack", "api", "site", "worker"] as const;
type Arch = typeof ARCHES[number];
const KIND: Record<Arch, "web" | "site" | "worker"> = { fullstack: "web", api: "web", site: "site", worker: "worker" };
const BOOL = new Set(["--public", "--metrics", "--no-autodeploy", "--yes"]);
const VAL = new Set(["--archetype", "--name"]);
const ALLOWED = "--archetype --name --public --metrics --no-autodeploy --yes";
const flags: Record<string, string | boolean> = {};
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (BOOL.has(a)) flags[a] = true;
  else if (VAL.has(a)) {
    const v = argv[++i];
    if (v === undefined || v.startsWith("--")) { console.error(`${a}: 값 필요`); process.exit(2); }
    flags[a] = v;
  } else { console.error(`알 수 없는 옵션: '${a}' (허용: ${ALLOWED})`); process.exit(2); }
}
const NONINT = flags["--yes"] === true || !process.stdin.isTTY;
// homelab tools/lib/identity.ts의 APP_NAME_RE와 **동일**(소문자 시작·소문자/숫자/하이픈·trailing hyphen 금지·길이 2..40).
// 느슨하면 빌드·push는 되나 create-app/onboarding에서 거부됨(#2). 실행 시 homelab 정규식을 복제·동기.
const NAME_RE = /^[a-z][a-z0-9-]{0,38}[a-z0-9]$/;
const validName = (n: string): string => { if (!NAME_RE.test(n)) { console.error(`앱 이름 불량(소문자 시작, 소문자/숫자/하이픈, trailing hyphen 금지, 2..40자): '${n}'`); process.exit(2); } return n; };

async function ask() {
  if (NONINT) {
    const a = ((flags["--archetype"] as string) ?? "fullstack") as Arch;
    if (!ARCHES.includes(a)) { console.error(`--archetype은 ${ARCHES.join("|")} 중 하나`); process.exit(2); }
    // 비대화형 경로도 --name을 검증(대화형 text validate와 동일 규칙) — F1
    return { archetype: a, name: validName((flags["--name"] as string) ?? basename(ROOT)), pub: flags["--public"] === true, metrics: flags["--metrics"] === true, autoDeploy: flags["--no-autodeploy"] !== true };
  }
  intro("homelab 앱 스캐폴드");
  const archetype = await select({ message: "아키타입", options: [
    { value: "fullstack", label: "🌐 Full-stack (Hono + React)" },
    { value: "api", label: "🔌 API (Hono)" },
    { value: "site", label: "📄 Static site (React SPA)" },
    { value: "worker", label: "⚙️ Worker (백그라운드)" },
  ], initialValue: "fullstack" }) as Arch;
  if (isCancel(archetype)) { cancel("취소"); process.exit(0); }
  const name = await text({ message: "앱 이름", initialValue: basename(ROOT), validate: v => NAME_RE.test(v) ? undefined : "소문자 시작·소문자/숫자/하이픈·trailing hyphen 금지·2..40자" }) as string;
  if (isCancel(name)) { cancel("취소"); process.exit(0); }
  const served = KIND[archetype] !== "worker";
  const pub = served ? await confirm({ message: "공개 노출(ukyi.app)? (아니오=home.ukyi.app 내부)", initialValue: false }) as boolean : false;
  const metrics = KIND[archetype] === "web" ? await confirm({ message: "metrics(:9090) 활성?", initialValue: false }) as boolean : false;
  const autoDeploy = await confirm({ message: "autoDeploy?", initialValue: true }) as boolean;
  return { archetype, name, pub, metrics, autoDeploy };
}

const { archetype, name, pub, metrics, autoDeploy } = await ask();
const kind = KIND[archetype];

// --- 트랜잭션 롤백(#3): 전개 前 루트 엔트리 스냅샷 → 실패 시 새로 생성된 것만 제거해
//     pre-scaffold 상태 복원(src/web 제거 → 멱등 가드 재통과 → 재시도 가능). ---
const before = new Set(readdirSync(ROOT));
const rollback = () => { for (const e of readdirSync(ROOT)) if (!before.has(e) && e !== ".git") rmSync(join(ROOT, e), { recursive: true, force: true }); };

// --- 전개 ---
cpSync(join(SCAFFOLD, "common"), ROOT, { recursive: true });
cpSync(join(SCAFFOLD, "archetypes", archetype), ROOT, { recursive: true });
// README.app.md → README.md(치환)
const readme = readFileSync(join(ROOT, "README.app.md"), "utf8").replaceAll("{{APP}}", name).replaceAll("{{ARCHETYPE}}", archetype);
writeFileSync(join(ROOT, "README.md"), readme); rmSync(join(ROOT, "README.app.md"));

// --- .app-config.yml 렌더 (Task 2.6 매핑) ---
const RES: Record<string, any> = kind === "site"
  ? { requests: { cpu: "10m", memory: "16Mi" }, limits: { cpu: "100m", memory: "32Mi" } }
  : { requests: { cpu: "50m", memory: "64Mi" }, limits: { cpu: "500m", memory: "128Mi" } };
const cfg: any = { kind, resources: RES };
if (kind !== "worker") cfg.route = { public: pub };
if (kind === "web") cfg.probes = { liveness: { path: "/healthz" }, readiness: { path: "/readyz" } };
if (kind === "web" && metrics) cfg.metrics = { enabled: true };
cfg.deploy = { autoDeploy };
writeFileSync(join(ROOT, ".app-config.yml"), toYaml(cfg));

// --- package.json 재작성 ---
const pkg = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8"));
pkg.name = name; delete pkg.private;
delete pkg.scripts?.scaffold; delete pkg.devDependencies?.["@clack/prompts"];
// archetype package 조각(아키타입 디렉토리의 package.partial.json)을 병합
const partial = JSON.parse(readFileSync(join(ROOT, "package.partial.json"), "utf8"));
pkg.scripts = { ...pkg.scripts, ...partial.scripts };
pkg.dependencies = { ...pkg.dependencies, ...partial.dependencies };
pkg.devDependencies = { ...pkg.devDependencies, ...partial.devDependencies };
writeFileSync(join(ROOT, "package.json"), JSON.stringify(pkg, null, 2) + "\n");
rmSync(join(ROOT, "package.partial.json"));

// --- lockfile 재생성(F1) — 파괴적 자가삭제 前에 수행(F4) ---
// package.json을 hono/react/vite로 재작성하고 @clack/prompts를 제거했으므로 bun.lock도 갱신해야
// 한다. 안 하면 stale 템플릿 lock(clack/yaml 핀)이 커밋돼 Dockerfile `bun install --frozen-lockfile`이
// 첫 GHCR 빌드에서 실패한다. **실패 시 scaffold/를 보존하고 비0 종료**(부분 생성·success 위장 방지, 재시도 가능).
const inst = Bun.spawnSync(["bun", "install"], { cwd: ROOT, stdout: "inherit", stderr: "inherit" });
if (inst.exitCode !== 0) { console.error("❌ bun install(lock 재생성) 실패 — 생성 파일 롤백(#3), scaffold/ 보존(재시도 가능)"); rollback(); process.exit(1); }

// --- 자가삭제 (lock 재생성 성공 후에만) ---
rmSync(SCAFFOLD, { recursive: true, force: true });
rmSync(join(ROOT, ".github/workflows/template-ci.yaml"), { force: true });

outro(`✅ ${name} (${archetype}/${kind}) 스캐폴드 완료 — git add -A && git commit && git push → owner가 homelab create-app 디스패치`);
```

**Step 2: 비대화형 스모크**
```bash
cd "$TPL"
cp -r . /tmp/sc-test && cd /tmp/sc-test && rm -rf .git
bun install && bun run scaffold --archetype api --name smoke-api --yes
test -f .app-config.yml && ! test -d scaffold && ! test -f .github/workflows/template-ci.yaml
# F1 회귀 방지: lock이 신 deps와 정합(frozen 통과) + clack 미잔존
bun install --frozen-lockfile && ! grep -q '@clack/prompts' bun.lock && echo ok

# F1 strict-parse 네거티브(fresh 사본 — 파싱은 파일변경 前 실행): 오타 flag·불량 name 거부
cp -r "$TPL" /tmp/sc-neg1 && (cd /tmp/sc-neg1 && rm -rf .git && bun install >/dev/null && ! bun run scaffold --no-autodeplpy --yes) && echo "neg1 ok(unknown flag 거부)"
cp -r "$TPL" /tmp/sc-neg2 && (cd /tmp/sc-neg2 && rm -rf .git && bun install >/dev/null && ! bun run scaffold --name Bad_Name --yes) && echo "neg2 ok(불량 name 거부)"
# 추가 name 네거티브(#2 APP_NAME_RE): 선행숫자·trailing hyphen·1자·40자초과 거부
for bad in 1app bad- a "$(printf 'a%.0s' {1..41})"; do
  cp -r "$TPL" /tmp/sc-n && (cd /tmp/sc-n && rm -rf .git && bun install >/dev/null && ! bun run scaffold --name "$bad" --yes) || { echo "name '$bad' 미거부"; exit 1; }; rm -rf /tmp/sc-n
done
echo "name 네거티브 ok"
```
Expected: `.app-config.yml` 생성, `scaffold/`·`template-ci.yaml` 제거, **frozen install 통과**(lock 재생성됨)·lock에 clack 없음. 네거티브 모두 **비0 종료**(오타 flag·불량 name 거부).

**Step 3: 롤백/재시도 테스트(#3)**

```bash
# bun install(lock 재생성) 실패를 모사 → 롤백으로 pre-scaffold 복원 → 재시도 성공
cp -r "$TPL" /tmp/sc-retry && cd /tmp/sc-retry && rm -rf .git && bun install >/dev/null
# 실패 주입(구현 택1): ① BUN 레지스트리를 잘못 가리키게 env override, ② 아키타입 partial에 존재하지 않는 dep 임시 주입.
# 기대: scaffold가 lock 재생성에서 실패 → rollback()이 src/·web/·.app-config.yml 등 새 엔트리 제거 → scaffold/ 잔존.
#   → ! test -d src && ! test -f .app-config.yml && test -d scaffold   (pre-scaffold 상태 복원)
# 실패 주입 해제 후 재실행:
bun run scaffold --archetype api --name retry-api --yes   # 멱등 가드 재통과 → 성공
test -f .app-config.yml && ! test -d scaffold && echo "retry ok"
```
Expected: 실패 시 롤백으로 멱등 가드 재통과 → 재시도 성공(부분 앱 잔존으로 막히지 않음).

> 위 스모크는 임시 사본에서(자가삭제가 원본 파괴 방지). 실제 검증은 Task 2.7 CI가 매트릭스로 수행.

### Task 2.2: fullstack 아키타입 (Hono + React, 한 컨테이너)

**Files (create under `$TPL/scaffold/archetypes/fullstack/`):**
- `src/index.ts`(Hono+Bun.serve), `web/index.html`, `web/src/main.tsx`, `web/src/App.tsx`, `web/vite.config.ts`, `package.partial.json`, `Dockerfile`, `app-config 기본은 scaffold.ts가 렌더`

**Step 1: `src/index.ts`**
```ts
import { Hono } from "hono";
import { serveStatic } from "hono/bun";

const app = new Hono();
app.get("/healthz", (c) => c.text("ok"));
app.get("/readyz", (c) => c.text("ready"));
app.get("/api/hello", (c) => c.json({ message: "Hello from Hono" }));
// 정적 React(빌드 산출물) + SPA fallback
app.use("/*", serveStatic({ root: "./web/dist" }));
app.get("/*", serveStatic({ path: "./web/dist/index.html" }));

const port = Number(process.env.PORT ?? 8080);
Bun.serve({ port, fetch: app.fetch });
console.log(`listening :${port}`);

// metrics(:9090) — 차트 metrics.enabled=true 시 scrape. 항상 떠도 무해(경량).
const metricsPort = Number(process.env.METRICS_PORT ?? 9090);
const started = Date.now();
Bun.serve({ port: metricsPort, fetch: () => new Response(
  `# HELP app_uptime_seconds\n# TYPE app_uptime_seconds gauge\napp_uptime_seconds ${(Date.now()-started)/1000}\n`,
  { headers: { "content-type": "text/plain" } }) });
```

**Step 2: React (`web/`)**
- `web/index.html`: 표준 vite + `<div id="root">` + `<script type="module" src="/src/main.tsx">`.
- `web/src/main.tsx`: `createRoot(...).render(<App/>)`.
- `web/src/App.tsx`: `fetch("/api/hello")` 호출해 메시지 표시(풀스택 연동 데모).
- `web/vite.config.ts`: `import react from "@vitejs/plugin-react"; export default { plugins:[react()], build:{ outDir:"dist" }, server:{ proxy:{ "/api":"http://localhost:8080" } } }`.

**Step 3: `package.partial.json`**
```json
{
  "scripts": {
    "dev:web": "vite web",
    "dev:server": "bun --watch src/index.ts",
    "build:web": "vite build web",
    "build": "bun run build:web && bun build --compile --target=bun-linux-arm64 src/index.ts --outfile app",
    "typecheck": "tsc --noEmit"
  },
  "dependencies": { "hono": "^4.x", "react": "^19.x", "react-dom": "^19.x" },
  "devDependencies": { "vite": "^7.x", "@vitejs/plugin-react": "^5.x", "typescript": "^5.x", "@types/react": "^19.x", "@types/react-dom": "^19.x", "bun-types": "latest" }
}
```

**Step 4: `Dockerfile`(멀티스테이지, arm64 distroless)**
```dockerfile
# syntax=docker/dockerfile:1
FROM oven/bun:1 AS build
WORKDIR /app
COPY package.json bun.lock* ./
RUN bun install --frozen-lockfile
COPY . .
RUN bun run build:web \
 && bun build --compile --target=bun-linux-arm64 src/index.ts --outfile app

FROM gcr.io/distroless/base-debian12:nonroot
WORKDIR /app
COPY --from=build /app/app /app/app
COPY --from=build /app/web/dist /app/web/dist
USER nonroot
EXPOSE 8080
ENTRYPOINT ["/app/app"]
```

**Step 5: 빌드·런 검증(경험적 — 런타임 전제 확정)**
```bash
cd /tmp/sc-fullstack   # scaffold 사본
bun install && bun run build && ls app web/dist/index.html
docker build --platform linux/arm64 -t fs-test .
docker run --rm -d -p 8080:8080 --name fs fs-test && sleep 1
curl -fsS localhost:8080/healthz && curl -fsS localhost:8080/api/hello && curl -fsS localhost:8080/ | grep -q '<div id="root"'
docker rm -f fs
```
Expected: `/healthz`=ok, `/api/hello`=json, `/`=React HTML. **실패 시**(Bun --compile arm64/serveStatic 경로/distroless glibc) 여기서 드러남 → Dockerfile/경로 조정. *(이 단계가 Phase 0의 Bun/distroless 전제를 실증한다.)*

### Task 2.3: api 아키타입 (Hono only)

**Files:** `scaffold/archetypes/api/{src/index.ts, package.partial.json, Dockerfile}`

- `src/index.ts`: fullstack에서 serveStatic 제거, `/healthz`,`/readyz`,`/api/*` + metrics 서버 유지.
- `package.partial.json`: react/vite 제거, hono + bun build:compile만.
- `Dockerfile`: fullstack에서 `bun run build:web`·`COPY web/dist` 제거.
- 검증: `docker run` 후 `/healthz`,`/api/hello` curl.

### Task 2.4: worker 아키타입 (백그라운드)

**Files:** `scaffold/archetypes/worker/{src/index.ts, package.partial.json, Dockerfile}`

**Step 1: `src/index.ts`**
```ts
let running = true;
process.on("SIGTERM", () => { running = false; });
console.log("worker started");
while (running) {
  // TODO: 작업 단위(큐 소비 등)
  await new Promise((r) => setTimeout(r, 5000));
  console.log("tick", new Date().toISOString());
}
console.log("worker stopped");
```
- `package.partial.json`: hono 불필요(순수 Bun) — bun build:compile만.
- `Dockerfile`: api와 동일(서버 없음, 동일 distroless/base 바이너리), `EXPOSE` 없음.
- 검증: `docker run` 후 로그 "tick" 확인, `docker stop`에 정상 종료(SIGTERM).

### Task 2.5: site 아키타입 (React SPA → SWS)

**Files:** `scaffold/archetypes/site/{web/*, vite.config.ts, package.partial.json, Dockerfile}`

**Step 1: `web/`**: fullstack의 web/과 동일(단 `/api` 프록시·호출 없는 순수 정적 데모).

**Step 2: `package.partial.json`**
```json
{ "scripts": { "dev": "vite web", "build": "vite build web", "typecheck": "tsc --noEmit" },
  "dependencies": { "react": "^19.x", "react-dom": "^19.x" },
  "devDependencies": { "vite": "^7.x", "@vitejs/plugin-react": "^5.x", "typescript": "^5.x", "@types/react": "^19.x", "@types/react-dom": "^19.x" } }
```

**Step 3: `Dockerfile`(SWS scratch, ENTRYPOINT=SWS)**
```dockerfile
# syntax=docker/dockerfile:1
FROM oven/bun:1 AS build
WORKDIR /app
COPY package.json bun.lock* ./
RUN bun install --frozen-lockfile
COPY . .
RUN bun run build   # → web/dist

FROM ghcr.io/static-web-server/static-web-server:2-scratch
COPY --from=build /app/web/dist /public
# ENTRYPOINT는 베이스(SWS 바이너리) — 차트가 args(--port/--root /public/--page-fallback/--health) 주입
```

**Step 4: 검증(차트 args를 모사해 SWS 직접 실행 — nonroot/scratch 양립 확인)**
```bash
cd /tmp/sc-site && bun install && bun run build
docker build --platform linux/arm64 -t site-test .
# 차트가 주는 args를 모사 + nonroot UID 강제(차트 podSecurityContext)
docker run --rm -d -p 8080:8080 --user 65532:65532 --read-only --name st site-test \
  --port 8080 --root /public --page-fallback /public/index.html --health
sleep 1
curl -fsS localhost:8080/health && curl -fsS localhost:8080/ | grep -q '<div id="root"' && \
curl -fsS localhost:8080/nonexistent | grep -q '<div id="root"'   # SPA fallback
docker rm -f st
```
Expected: `/health`=ok, `/`·임의경로=index.html. **실패 시**(scratch가 nonroot+read-only에서 SWS 미동작, 또는 `:2-scratch` 태그 부재) → SWS 이미지 변종(`:2`, `:2-debian`) 재선택. *(Phase 0 SWS 전제 실증.)*

### Task 2.6: .app-config.yml 매핑 검증 + 자가삭제 통합 테스트

**Step 1:** scaffold.ts가 아키타입별로 낸 `.app-config.yml`이 homelab 스키마(현 워크트리의 신 스키마 또는 `@main` 머지 후)에 유효한지 — Task 2.7 CI가 강제. 로컬 선검증:
```bash
# 각 아키타입 비대화형 스캐폴드 후 산출 .app-config.yml을 homelab 신스키마로 검증
```
**Step 2:** 자가삭제·멱등 가드 단위 테스트(임시 사본 4종).

### Task 2.7: template-ci.yaml (드리프트 가드)

**Files:** Create `$TPL/.github/workflows/template-ci.yaml`

**Step 1: 매트릭스 CI**
```yaml
name: template-ci
on: { push: { branches: [main] }, pull_request: {} }
permissions: { contents: read }
jobs:
  scaffold-build:
    runs-on: ubuntu-24.04-arm
    strategy: { matrix: { archetype: [fullstack, api, site, worker] } }
    steps:
      - uses: actions/checkout@<핀>
      - uses: oven-sh/setup-bun@<핀>
        with: { bun-version: <핀> }
      - name: scaffold(비대화형) → 앱 생성 + lock 재생성(scaffold 자체가 마지막에 bun install)
        run: |
          cp -r . /tmp/app && cd /tmp/app && rm -rf .git
          bun install                 # 템플릿 deps(clack) — scaffold 실행용
          bun run scaffold --archetype ${{ matrix.archetype }} --name ci-${{ matrix.archetype }} --yes
          test ! -d scaffold && test ! -f .github/workflows/template-ci.yaml
      - name: docker build(frozen-lockfile — 첫 검증, lock 변형 前 — F1·#1)
        # scaffold가 재생성한 lock을 이후 어떤 install/add가 '수리'해 stale을 가리기 前에 frozen 빌드로 검증(#1).
        run: docker build --platform linux/arm64 -t ci-${{ matrix.archetype }} /tmp/app
      - name: 타입검사(필수 — F3)
        working-directory: /tmp/app
        run: |
          test -f tsconfig.json || { echo "::error::tsconfig.json 누락(모든 아키타입 필수)"; exit 1; }
          bun run build           # vite/bun 빌드(install/add 없음 → lock 무변형)
          bunx tsc --noEmit       # `|| true` 금지 — 타입오류 시 CI fail(vite/bun 빌드는 타입오류로도 성공)
      - name: .app-config.yml 계약 검증(별도 디렉토리 — 앱 lock 미오염, F2·#1)
        run: |
          curl -fsSL https://raw.githubusercontent.com/ukyi-app/homelab/main/tools/app-config-schema.json -o /tmp/schema.json \
            || { echo "::error::homelab app-config-schema fetch 실패(경로/브랜치 확인)"; exit 1; }
          mkdir -p /tmp/validate && cp /tmp/app/.app-config.yml /tmp/validate/cfg.yml && cd /tmp/validate
          bun add ajv js-yaml >/dev/null   # /tmp/app이 아닌 별도 디렉토리(#1 — 앱 lock 미오염)
          # 결정적 YAML→JSON + full ajv 검증. enum-only fallback 없음(fail-closed).
          bun -e '
            import Ajv from "ajv"; import yaml from "js-yaml"; import fs from "node:fs";
            const schema = JSON.parse(fs.readFileSync("/tmp/schema.json","utf8"));
            const cfg = yaml.load(fs.readFileSync("cfg.yml","utf8"));
            const v = new Ajv({allErrors:true});
            if (!v.validate(schema, cfg)) { console.error("::error::.app-config.yml 스키마 위반:", JSON.stringify(v.errors)); process.exit(1); }
          '
      - name: 네거티브 — 무효 config는 검증 실패해야(가드 fail-closed 증명 — F2)
        run: |
          cd /tmp/validate
          printf 'kind: web\n' > bad.yml   # resources 누락 = 스키마 위반
          if bun -e '
            import Ajv from "ajv"; import yaml from "js-yaml"; import fs from "node:fs";
            const schema = JSON.parse(fs.readFileSync("/tmp/schema.json","utf8"));
            process.exit(new Ajv().validate(schema, yaml.load(fs.readFileSync("bad.yml","utf8"))) ? 0 : 1)
          '; then echo "::error::무효 config가 통과함 — 가드 구멍"; exit 1; else echo "negative OK(무효 config 거부)"; fi
      - name: Dockerfile lint(선택)
        working-directory: /tmp/app
        run: docker run --rm -i hadolint/hadolint < Dockerfile || true
  scaffold-args:
    runs-on: ubuntu-24.04-arm
    steps:
      - uses: actions/checkout@<핀>
      - uses: oven-sh/setup-bun@<핀>
        with: { bun-version: <핀> }
      - run: bun install
      - name: strict-parse 네거티브(F1) — 오타 flag·불량 name 거부
        run: |
          cp -r . /tmp/n1 && (cd /tmp/n1 && rm -rf .git && bun install >/dev/null && ! bun run scaffold --no-autodeplpy --yes) || { echo "::error::unknown flag 미거부"; exit 1; }
          cp -r . /tmp/n2 && (cd /tmp/n2 && rm -rf .git && bun install >/dev/null && ! bun run scaffold --name Bad_Name --yes) || { echo "::error::불량 name 미거부"; exit 1; }
```
> 스키마 fetch는 homelab `main`의 `tools/app-config-schema.json` 경로에 핀 의존 — 경로/브랜치 변경 시 깨짐(위 step이 fetch 실패를 fail-closed로 처리). homelab 신스키마 머지 전까지 `@main`은 구 enum이라 신값(web/site)이 통과 못 함 → **homelab PR(Phase 1) 머지 후** 이 CI가 통과(Phase 4 순서 준수). `docker build` step은 커밋될 산출물의 `--frozen-lockfile` 경로를 실제로 빌드해 F1(stale lock)을 CI에서 직접 잡는다.

**Step 2:** 핀(`oven-sh/setup-bun`·`actions/checkout`·이미지 digest)은 homelab Renovate 정책과 정렬되도록 SHA/digest 핀.

### Task 2.8: README + 커밋

**Files:** Modify `$TPL/README.md`

**Step 1: README**
```markdown
# homelab 앱 템플릿 (Bun + Hono + React)

## 시작
1. 이 템플릿으로 레포 생성(레포 이름 = 앱 이름, 소문자/숫자/하이픈)
2. clone 후: `bun install && bun run scaffold`
3. 아키타입 선택(🌐 풀스택 / 🔌 API / 📄 정적 / ⚙️ 워커) → 코드·`.app-config.yml` 자동 생성, 스캐폴더 자가삭제, `bun.lock` 재생성
4. `git add -A && git commit && git push` (재생성된 lock 포함)
5. owner가 homelab에서 create-app 디스패치 → 첫 배포 🚀

## 런타임 계약
:8080 http(web/site), web=`/healthz`·`/readyz`, site=SWS `/health`, metrics :9090(web·opt-in), arm64 distroless non-root.
```

**Step 2: 커밋(논리 그룹)**
```bash
cd "$TPL"
git add scaffold/scaffold.ts package.json scaffold/common
git commit -m "feat: 대화형 bun run scaffold + 공통 파일"
git add scaffold/archetypes
git commit -m "feat: fullstack/api/site/worker 아키타입 추가"
git add .github/workflows/template-ci.yaml
git commit -m "chore: 아키타입 스캐폴드·빌드 검증 CI 추가"
git add README.md && git rm --cached Dockerfile src/.gitkeep .app-config.yml 2>/dev/null
git commit -m "docs: 템플릿 README를 스캐폴더 흐름으로 갱신"
```

---

## Phase 3 — 외부 example-api 마이그레이션 [owner-local·GitHub]

> 외부 `ukyi-app/example-api`는 로컬 미체크아웃 → GitHub에서 별도 수행. **순서는 Phase 1 Task 1.7 Step1 결과에 따름**: 재검증 흐름이 create-app 전용이면 Phase 1 머지 후 여유 있게; bump-poll/update-*가 재검증하면 Phase 1과 동시/선행.

**Step 1:** `ukyi-app/example-api`의 `.app-config.yml` `kind: service` → `kind: web` (브랜치·PR 또는 직접).
**Step 2:** 변경 후 다음 bump-poll/배포 사이클에서 검증 통과 확인.
**Step 3:** (Phase 1 Step1에서 다른 외부 앱이 발견됐다면) 각 앱 동일 마이그레이션.

---

## Phase 4 — 교차 레포 검증 + E2E [owner-local]

**Step 1:** Phase 1 PR(homelab) 머지 → ArgoCD example-api **no-op 싱크** 라이브 확인(`kubectl get application example-api`, pod 라벨 `app.homelab/kind=web`, restart 1회 후 Healthy).
**Step 2:** Phase 2 PR(template) 머지 → `template-ci` 4 아키타입 GREEN 확인(homelab 신스키마 머지 후라 계약 검증 통과).
**Step 3 (E2E):** fullstack 아키타입으로 실제 신규 앱 레포 생성 → `bun run scaffold` → push → reusable-app-build로 GHCR 이미지 → owner가 homelab `create-app` 디스패치 → 배포 Healthy + `curl https://<app>.home.ukyi.app/healthz` 확인.

---

## 리스크·미해결 (Phase C 리뷰가 검증)

1. **Bun `--compile --target=bun-linux-arm64`** 단일바이너리 + `distroless/base-debian12`(glibc) 실행, `serveStatic` 상대경로(`./web/dist`) — Task 2.2 Step5가 실증. 실패 시 Dockerfile/경로 조정.
2. **SWS `:2-scratch`** + nonroot(65532) + readOnlyRootFilesystem 양립, 태그 실재 — Task 2.5 Step4가 실증. 실패 시 이미지 변종 재선택.
3. **외부 config 재검증 경로**(Phase A.5 finding) — Task 1.7 Step1이 식별·문서화, Phase 3가 마이그레이션, fail-loud(Task 1.1)가 침묵 방지.
4. **bats 리네임 누락** — 기계적 치환 + `git diff` 전수 확인 + 전체 게이트(Task 1.7)로 잡음.
5. **`static` values 필드 유지**(서브결정) — 일관성 vs churn 트레이드오프. 리뷰가 이의 시 재판정.
6. **template-ci 스키마 fetch 핀**(`@main` 경로) — 경로/브랜치 변경 취약, 실패 메시지 명시. homelab 신스키마 머지 전엔 신값이 구 `@main` 스키마와 불일치 → Phase 4 순서(homelab 먼저) 준수.
7. **metrics 항상-on 리스너(:9090)** — web 아키타입이 metrics.enabled와 무관히 :9090을 띄움(경량). readOnlyRootFs/nonroot에서 바인딩 무해 확인(Task 2.2 검증에 포함 권장).
8. **이미지 태그 핀**(oven/bun·distroless·SWS·setup-bun·checkout) — digest/SHA 핀 + Renovate 정렬.

---

## Adversarial review dispositions

> 사후 감사 추적(post-approval). codex 적대적 리뷰 — 설계 1패스(A.5) + 계획 3패스(C, 캡 도달). 총 발견 10건, **전부 ACCEPTED**(0 rejected).

**Phase A.5 — 설계 리뷰 (`--kind design`, 1패스):**
- (high) Rename-everywhere가 외부 앱 레포 호환성 제거 — **ACCEPTED** → 설계 §7.1(외부 example-api 마이그레이션·재검증 경로 식별·actionable fail-loud) 추가.

**Phase C Pass 1 (verdict: needs-attention):**
- (high) Scaffold rewrites deps without regenerating lockfile — **ACCEPTED** → scaffold가 자가삭제 前 `bun install`로 lock 재생성(F4와 결합), template-ci에 frozen docker build.
- (high) Template CI falls back from schema validation to enum-only — **ACCEPTED** → `|| enum fallback` 제거, full ajv fail-closed + 네거티브 fixture.

**Phase C Pass 2 (verdict: needs-attention):**
- (high) Scaffold CLI silently ignores bad flags/typos — **ACCEPTED** → strict allowlist 파서(unknown/누락값 exit 2), `--name` 양 경로 검증, 네거티브 테스트.
- (high) Primary homelab gate explicitly allowed to fail (`make ci || true`) — **ACCEPTED** → `|| true` 제거, `set -e` fail-closed, 라이브 의존만 명시 분리.
- (medium) Template CI doesn't gate TypeScript (`tsc --noEmit || true`) — **ACCEPTED** → tsc 필수(tsconfig 필수, `|| true` 제거).
- (medium) Scaffold self-deletes before proving recoverable — **ACCEPTED** → lock 재생성을 자가삭제 前으로, 실패 시 비0 종료.

**Phase C Pass 3 (verdict: needs-attention — 캡 도달):**
- (high) CI mutates scaffolded app before frozen-lockfile build — **ACCEPTED** → template-ci 재배치: scaffold → frozen docker build(첫) → 타입검사 → 스키마검증은 **별도 디렉토리**(앱 lock 미오염).
- (medium) Scaffold name validation looser than homelab — **ACCEPTED** → homelab `APP_NAME_RE`(`/^[a-z][a-z0-9-]{0,38}[a-z0-9]$/`) 복제 + 네거티브 케이스.
- (medium) Partial scaffold failures not retryable — **ACCEPTED** → 전개 前 스냅샷 기반 rollback(실패 시 생성 파일 제거 → 멱등 가드 재통과 → 재시도 가능).

**최종 판정:** Pass 3 verdict=`needs-attention`, summary="No ship: the plan can still produce broken scaffolded repos and its CI can mask the exact failure it claims to guard." → 그 3건을 **모두 ACCEPTED·반영**했고, 3패스 캡 도달 후 사용자가 **"반영 후 확정(추가 패스 없음)"** 을 정보 기반으로 승인. 미반영 high/critical 잔여 0.

---

## Execution directives

- **Skill:** 이 계획은 **별도 세션**에서 `executing-plans`로 구현한다. homelab 변경은 **이 워크트리**(`/Users/ukyi/workspace/homelab/.claude/worktrees/feat+app-template-bun-scaffold`, 브랜치 `worktree-feat+app-template-bun-scaffold`)에서, 템플릿 변경은 `~/workspace/homelab-app-template`(자체 브랜치)에서 수행한다.
- **교차 레포 순서:** Phase 1(homelab, 워크트리) → Phase 2(template repo) → Phase 3·4(owner-local). template-ci의 `@main` 스키마 검증은 homelab 신스키마 머지 후 통과하므로 Phase 1을 먼저 머지한다.
- **연속 실행:** 배치 사이에 일상 리뷰로 멈추지 말 것. **진짜 블로커일 때만** 멈춤 — 누락 의존, 반복 실패하는 검증(예: Bun `--compile`/SWS 전제 실패 시 Dockerfile 조정 후에도 안 되면), 불명확/모순 지시, 치명적 계획 갭. 그 외엔 전 배치를 끝까지.
- **커밋 — 아래 규칙을 직접 적용; `Skill(commit)` 호출 금지**(대화형 확인이 연속 실행을 깸):
  - **언어:** 한국어. **AI 마커 금지**(`🤖 Generated with`·`Co-Authored-By: Claude` 등 금지).
  - **형식:** `<type>(<scope>): 한국어 설명` (필요 시 `- 상세` body).
  - **type(이 7개만):** `feat`/`fix`/`refactor`/`docs`/`style`/`test`/`chore`. `perf`/`build`/`ci` 금지(→ `refactor`/`chore`).
  - **그룹화(우선순위):** ① 같은 기능/모듈 디렉토리 함께; ② 목적별 분리(refactor vs fix vs feature); ③ 서로 참조하는 파일 함께; ④ config(`package.json`/`tsconfig`)·테스트·문서·standalone style 각각 별도 커밋.
  - **판단:** 같은 디렉토리+같은 목적 → 한 커밋; 다른 파일 없이는 무의미한 변경 → 같은 커밋; 독립 설명 가능 → 별도 커밋.
  - **위치:** 각 `Commit` step에서 현재 feature 워크트리(homelab) 또는 template 브랜치에 직접 커밋(이미 main 밖이라 새 브랜치 불요). homelab은 PR-first·auto-merge(gate 통과 시), template은 자체 PR.
- **게이트 fail-closed:** `|| true` 절대 금지. `make verify`/`make chart-test`/`make ci`/bats가 RED면 해결(누락 추적). 라이브 의존(`make verify-posture`)은 KUBECONFIG 없으면 자체 skip.
