# 데이터 연결=secret 미니멀화 구현 계획

> **For Claude:** REQUIRED SUB-SKILL: superpowers:executing-plans 로 이 계획을 task 단위로 구현한다.

**Goal:** `.app-config.yml`에서 `db`/`redis`/`migrate` 필드를 제거(연결=앱 SealedSecret의 `DATABASE_URL`/`REDIS_URL`)하고, 로컬·GUI 접속을 tailscale + admin superuser + `db:url`/`cache:url`로 1급 지원한다.

**Architecture:** 3개 PR — (A) migrate 제거, (B) db/redis 제거 + refcount 축소 + A.5 완화(F1/F2/F3), (C) 접속 계층(tailscale pg 노출 + admin superuser + URL 도구 재작성). 설계 SSOT: `docs/plans/2026-06-25-data-connection-as-secret-design.md`.

**Tech Stack:** Bun/TS 툴(`tools/*.ts`), Helm 공유차트(`platform/charts/app`), CNPG(`platform/cnpg/prod`), tailscale operator, Terraform(`infra/tailscale`). 테스트=bats(tools/charts/cnpg), kustomize+kubeconform, `make verify`/`make tf-validate`.

---

## 공통 규약 (모든 Task에 적용)

- **커밋 메시지: 한국어 conventional `<type>(<scope>): 설명`. AI 마커 절대 금지**(`🤖`, `Co-Authored-By`, `Claude-Session` 등 어떤 형태도 X). type은 `feat|fix|refactor|docs|style|test|chore`만.
- **라인 번호는 근사치** — 편집 전 반드시 `grep -n`으로 현재 위치 확인(특히 PR-A가 먼저 라인을 바꾸므로 PR-B/C는 재확인).
- **bats `@test` 이름은 영어**(CJK 침묵 스킵 — 검증된 버그). 중간 단언은 `[ ]`(`[[ ]]` bash3.2 함정).
- 작업 디렉토리: 이 워크트리. 명령은 워크트리 루트 기준 상대경로.
- **선행**: env 평문 제거(PR #113)는 별도로 main에 먼저 머지. 이 계획은 env를 다루지 않는다(스키마/차트에 env가 보여도 무시).
- 인-레포 앱 0개 → 라이브 마이그레이션 비용 0.

---

## PR-A: `migrate` 제거

앱이 부팅 시 self-migrate(expand/contract + 멱등 강제, 문서). migrate Job/필드/values 제거.

### Task A0: 외부 템플릿 cross-repo cutover (선행 — F2 수정)

> ★ create-app은 **외부 앱 레포의 `.app-config.yml`을 직접 read**하고, schema는 `additionalProperties:false`(fail-closed)다. PR-A/B가 homelab schema에서 migrate/db/redis를 제거하면, **구계약(db/redis/migrate)을 쓰는 외부 앱은 create-app/변이에서 거부**된다. 따라서 homelab schema 제거 **이전에** 외부 계약을 정렬해야 한다.

**Files:** (별도 레포) `ukyi-app/homelab-app-template/.app-config.yml`·`README.md` · (homelab) 검증만

**Step 1 (인벤토리):** 기존 외부 앱 레포 목록 확인 — `apps/*/deploy/prod/source-repo`로 바인딩된 레포 + `infra/cloudflare/apps.json` 교차. db/redis/migrate를 쓰는 레포 식별(`gh api`로 각 레포 `.app-config.yml` 조회). 0개면 cutover 비용 0(기대: 인-레포 앱 0, 외부도 템플릿뿐).
**Step 2 (템플릿 PR):** `homelab-app-template`의 `.app-config.yml`에서 db/redis/migrate 라인·예시 제거(env는 PR #3에서 이미) + README 갱신. 별도 레포 PR(`homelab-app-template-sync` 패턴).
**Step 3 (스모크):** 갱신된 템플릿 `.app-config.yml`을 homelab create-app schema 검증(또는 `create-app --dry-run --config <템플릿 사본>`)에 통과시켜 fail-closed 거부 안 됨 확인.
**Step 4 (순서 게이트):** 템플릿 PR 머지 + 외부 앱 인벤토리 0(또는 전부 갱신) 확인 **후에만** PR-A/B의 homelab schema 제거를 머지. 이 순서를 PR-A/B 설명·체크리스트에 명시.
**Step 5 (커밋/기록):** homelab 측은 코드 변경 없음(검증·문서). 인벤토리 결과를 PR 설명에 기록.

### Task A1: app-config-schema.json에서 `migrate` 제거

**Files:** Modify `tools/app-config-schema.json` · `tools/tests/test_app-config.bats`

**Step 1 (실패 테스트):** `test_app-config.bats`의 기존 `@test "migrate command moved out of db..."`(migrate 존재 단언)를 부재 단언으로 교체:
```bash
@test "schema no longer has migrate property (app self-migrates at boot)" {
  run jq -e '.properties | has("migrate") | not' "$S"
  [ "$status" -eq 0 ]
}
```
**Step 2 (RED 실행):** `bats tools/tests/test_app-config.bats` → 위 테스트 FAIL(아직 migrate 존재).
**Step 3 (구현):** `tools/app-config-schema.json`에서 `"migrate": { ... }` property 블록 삭제(`grep -n '"migrate"'로 위치 확인).
**Step 4 (GREEN):** `bats tools/tests/test_app-config.bats` → 전부 통과.
**Step 5 (커밋):**
```bash
git add tools/app-config-schema.json tools/tests/test_app-config.bats
git commit -m "refactor(schema): app-config에서 migrate 필드 제거 — 앱 self-migrate

- additionalProperties:false라 migrate 선언 .app-config.yml은 이제 fail-closed
- self-migrate(expand/contract+멱등)는 문서로 강제(Task A6)"
```

### Task A2: 공유차트 `migrate-job.yaml` 삭제 + db.* 제거

**Files:** Delete `platform/charts/app/templates/migrate-job.yaml` · Modify `platform/charts/app/values.yaml`,`values.schema.json` · Delete `platform/charts/app/tests/test_migrate.bats`

**Step 1 (실패 테스트):** 새 가드 `platform/charts/app/tests/test_no_migrate.bats`:
```bash
#!/usr/bin/env bats
CHART="${BATS_TEST_DIRNAME}/.."
@test "no migrate-job template exists (app self-migrates)" {
  [ ! -f "$CHART/templates/migrate-job.yaml" ]
}
@test "values.schema.json no longer defines db object" {
  run jq -e '.properties | has("db") | not' "$CHART/values.schema.json"
  [ "$status" -eq 0 ]
}
```
**Step 2 (RED):** `bats platform/charts/app/tests/test_no_migrate.bats` → FAIL(파일·db 존재).
**Step 3 (구현):**
```bash
rm platform/charts/app/templates/migrate-job.yaml
rm platform/charts/app/tests/test_migrate.bats
```
- `values.yaml`에서 `# --- 데이터베이스 / migration ---` + `db:` 블록(enabled/migrateCmd/migrateMemory) 삭제.
- `values.schema.json`에서 `"db": { ... }` property 삭제.
**Step 4 (GREEN):** `bats platform/charts/app/tests/test_no_migrate.bats` 통과 + `make chart-test`(전 차트 렌더+kubeconform+bats) 통과.
**Step 5 (커밋):**
```bash
git add -A platform/charts/app
git commit -m "refactor(chart): migrate Job 템플릿·db values 제거

- migrate-job.yaml 삭제(앱 self-migrate)
- values.yaml/values.schema.json의 db.* 제거
- test_migrate.bats 삭제, test_no_migrate.bats 가드 추가"
```

### Task A2b: 잔여 db/migrate 참조 일괄 정리 (F3 수정 — rg 기반 완전성)

> ★ A2가 `db`를 values/schema에서 지우면, **차트 전반의 `.Values.db.*` 참조가 깨진다**. A3(테스트)만으로 부족 — 템플릿/헬퍼/fixtures의 db 참조를 전수 정리해야 `make chart-test`가 녹색이 된다.

**Files:** `platform/charts/app/templates/_helpers.tpl`·`deployment.yaml` 등 · `platform/charts/app/tests/fixtures/{service,worker}.yaml` · 차트 테스트(`test_image-digest.bats`·`test_schema_fail_closed.bats` 등)

**Step 1 (전수 탐색):**
```bash
cd platform/charts/app
rg -n '\.Values\.db|db\.enabled|db\.host|db\.migrate|migrate' templates/ tests/ values.yaml values.schema.json
```
→ 나오는 모든 참조가 정리 대상(이미지 digest 테스트가 db 켜고 렌더하는 경우, `_helpers.tpl`의 `.Values.db.enabled` 분기, fixtures의 `db:` 블록, schema-fail-closed의 `db.host` 케이스 포함).
**Step 2 (RED):** `make chart-test` → A2 적용 상태에서 위 참조들로 인해 red/렌더 오류 확인.
**Step 3 (구현):** 각 참조 제거 — `_helpers.tpl`에서 db 분기 삭제, `deployment.yaml`의 db 잔재 제거, fixtures `service.yaml`/`worker.yaml`의 `db:` 블록 제거, `test_image-digest.bats`가 db.enabled로 Job 렌더 가정하면 그 부분 제거, `test_schema_fail_closed.bats`의 `db.host` 케이스 제거. 제거 후 필요한 대체 단언(예: "no Job kind rendered")만 남김.
**Step 4 (GREEN):** `rg '\.Values\.db|migrate' platform/charts/app/templates platform/charts/app/tests` → 0 매치(테스트 이름의 "migrate" 산문 제외) + `make chart-test` 전부 통과.
**Step 5 (커밋):** `git commit -m "refactor(chart): db/migrate 잔여 참조 일괄 제거(_helpers·fixtures·tests)"`

### Task A3: 차트 테스트 정리 (test_db-consume / test_defense의 migrate Job 가정 제거)

**Files:** Modify `platform/charts/app/tests/test_db-consume.bats` · `platform/charts/app/tests/test_defense.bats`

**Step 1 (RED):** `make chart-test` → `test_db-consume.bats`의 "migrate job inherits envFrom..." 와 `test_defense.bats`의 "migration Job ... SA token" 2개가 FAIL(Job 미렌더).
**Step 2 (구현):** 두 파일에서 migrate Job 관련 `@test` 블록 삭제(`db.enabled=true`·`select(.kind=="Job")` 참조하는 것). envFrom/secretRef 일반 테스트(db conn 아닌)는 PR-B에서 별도 처리.
**Step 3 (GREEN):** `make chart-test` 통과.
**Step 4 (커밋):**
```bash
git add platform/charts/app/tests/test_db-consume.bats platform/charts/app/tests/test_defense.bats
git commit -m "test(chart): migrate Job 가정 테스트 제거(템플릿 삭제 반영)"
```

### Task A4: create-app.ts에서 migrate 분기 제거

**Files:** Modify `tools/create-app.ts`

**Step 1 (RED):** 새 단언 — create-app 산출 values에 `migrate`/`migrateCmd`/`db.enabled` 없음. `tools/tests/test_create-app.bats`에 추가:
```bash
@test "create-app values.yaml has no migrate/db.enabled (migrate removed)" {
  # (기존 헬퍼로 orders 앱 생성한 뒤)
  run grep -E "migrateCmd|enabled:" "$FR/apps/orders/deploy/prod/values.yaml"
  [ "$status" -ne 0 ]   # 매치 없어야 함
}
```
**Step 2 (RED 실행):** `bats tools/tests/test_create-app.bats` → FAIL(values.db 출력됨).
**Step 3 (구현):** `tools/create-app.ts`에서:
- `values.db = config.migrate ? { enabled: true, migrateCmd: config.migrate.cmd } : { enabled: false };` 삭제(`grep -n 'values.db' 확인).
- 라인 76 static 가드의 `config.migrate` 항을 제거: `if (kind === "static" && config.db?.length) fail("kind=static은 db를 가질 수 없다(정적 서빙)");` (db 자체는 PR-B에서 제거되므로 PR-B에서 이 줄도 정리).
> 주: migrate는 Task A1에서 schema 제거됨 → `config.migrate`는 항상 undefined이고, additionalProperties:false라 migrate 선언 config는 schema 검증에서 거부된다. 따라서 분기는 dead code → 안전 제거.
**Step 4 (GREEN):** `bats tools/tests/test_create-app.bats` 통과.
**Step 5 (커밋):**
```bash
git add tools/create-app.ts tools/tests/test_create-app.bats
git commit -m "refactor(create-app): migrate 분기 제거(values.db 미생성)"
```

### Task A5: 문서 — self-migrate expand/contract + 멱등 명문화 (F3)

**Files:** Modify `tools/README.md` (+ 템플릿 README는 별도 레포 — 본 PR 범위 밖, 후속 동기화)

**Step 1 (RED):** `grep -q "self-migrat" tools/README.md` → 실패.
**Step 2 (구현):** `tools/README.md`에 "App 계약: self-migration" 절 추가 — 앱은 부팅 시 직결 URL로 expand/contract + 멱등 마이그레이션 실행 필수, 검증은 앱 레포 CI, homelab은 수동(설계 §5.8 F3).
**Step 3 (GREEN):** `grep -q "expand.*contract\|멱등" tools/README.md`.
**Step 4 (커밋):** `git commit -m "docs(tools): self-migrate expand/contract+멱등 계약 명문화(F3)"`

### Task A6: PR-A 게이트 검증
`make verify` + `make chart-test` + `bats tools/tests/` 영향분 전부 GREEN 확인(커밋 불필요).

---

## PR-B: `db`/`redis` 제거 + refcount 축소 + F1/F2/F3 완화

연결을 앱 SealedSecret(`DATABASE_URL`/`REDIS_URL`)으로. **purge 안전(`--backup-verified`)은 유지.**

### Task B1: app-config-schema.json에서 `db`/`redis` 제거

**Files:** Modify `tools/app-config-schema.json` · `tools/tests/test_app-config.bats`

**Step 1 (RED):** test_app-config.bats의 "schema allows db and redis as arrays..."를 부재 단언으로 교체:
```bash
@test "schema no longer has db/redis fields (connection is a sealed secret)" {
  run jq -e '(.properties | has("db") | not) and (.properties | has("redis") | not)' "$S"
  [ "$status" -eq 0 ]
}
```
**Step 2 (RED 실행):** FAIL.
**Step 3 (구현):** `tools/app-config-schema.json`에서 `"db"`,`"redis"` property 삭제(`grep -n` 확인).
**Step 4 (GREEN):** `bats tools/tests/test_app-config.bats` 통과(스키마는 여전히 valid draft-07).
**Step 5 (커밋):** `git commit -m "refactor(schema): app-config에서 db/redis 필드 제거 — 연결=SealedSecret"`

### Task B2: create-app.ts에서 db/redis 배선·가드·bindings 제거

**Files:** Modify `tools/create-app.ts` · `tools/tests/test_create-app.bats`

**Step 1 (RED):** test_create-app.bats:
- `@test "create-app wires db/redis SealedSecret conn handles into envFrom"` 삭제(더 이상 유효 X).
- `.bindings.json` 단언을 `{autoDeploy}`만 검사로 교체:
```bash
@test "bindings.json records only autoDeploy (no db/redis)" {
  run jq -e '(has("db")|not) and (has("redis")|not) and has("autoDeploy")' "$FR/apps/orders/deploy/prod/.bindings.json"
  [ "$status" -eq 0 ]
}
```
- "create-app rejects an unprovisioned db reference" 테스트 삭제(가드 제거됨).
**Step 2 (RED 실행):** FAIL.
**Step 3 (구현):** `tools/create-app.ts`에서:
- db/redis 미생성·tombstone 가드 블록 제거(`const dbs`/`const caches` 사용처 전부, `grep -n 'config.db\|config.redis\|tombstone\|dbs\|caches'`).
- envFrom 구성에서 `...dbs.map(...secretRef db-${n}-conn)` / `...caches.map(...cache-${n}-conn)` 제거(secrets 배선만 남김).
- static 가드 `config.db?.length` 항 제거(Task A4에서 migrate 제거했으니 이제 줄 전체 삭제 가능).
- `const bindings = { db: dbs, redis: caches, autoDeploy: ... }` → `const bindings = { autoDeploy: config.deploy?.autoDeploy ?? true }`.
**Step 4 (GREEN):** `bats tools/tests/test_create-app.bats` 통과.
**Step 5 (커밋):** `git commit -m "refactor(create-app): db/redis 배선·가드 제거, bindings는 autoDeploy만"`

### Task B3: app-deploy-schema.json 갱신 (.bindings.json 계약)

**Files:** Modify `tools/app-deploy-schema.json` · `tools/tests/test_app-deploy.bats`(있으면)

**Step 1 (RED):** `.bindings.json` 계약에서 db/redis required/description 제거 단언. (현재 계약 확인: `grep -n "bindings\|db\|redis" tools/app-deploy-schema.json`.)
**Step 2 (구현):** `.bindings.json` 스키마를 `autoDeploy`(boolean) 중심으로 갱신, db/redis 제거. `check-app-deploy.sh`가 참조하면 동반 갱신.
**Step 3 (GREEN):** `make verify`(check-app-deploy 포함) 통과.
**Step 4 (커밋):** `git commit -m "refactor(schema): app-deploy의 .bindings.json 계약에서 db/redis 제거"`

### Task B4: env-example.mts에서 db/redis 스캐폴딩 제거

**Files:** Modify `tools/env-example.mts` · `tools/tests/test_app-shared-node-smoke.bats`(영향 시)

**Step 1 (RED):** 새 단언 — env-example 출력에 `_DATABASE_URL`/`_REDIS_URL` 스캐폴드 없음(secrets만). (`bun tools/env-example.mts --config <fixture> --out -` 형태 또는 임시파일.)
**Step 2 (구현):** `tools/env-example.mts`에서 `for (const d of config.db ...)` / `for (const r of config.redis ...)` 두 줄 삭제(헤더 주석의 "db+redis"도 정리). secrets 루프만 남김.
**Step 3 (GREEN):** smoke bats 통과.
**Step 4 (커밋):** `git commit -m "refactor(env-example): db/redis 스캐폴딩 제거(연결은 secrets로)"`

### Task B5: teardown-resource — 자동 refcount → `--refs-verified` attestation 게이트 (F1 강화)

**Files:** Modify `tools/teardown-resource.ts` · `tools/tests/test_teardown.bats`

> F1(패스2): db: 제거로 자동 refcount는 불가하지만, **db: 복원 없이도 enforceable 파괴-작업 가드를 복원**한다 — 모든 teardown(retain/purge)이 `--refs-verified <evidence-id>` 없이는 **거부**. owner가 "사용 앱 수동 확인 완료"를 명시 attest해야 진행(증거 id는 런북 체크리스트 수행 기록). 자동 검사는 아니지만 "그냥 실행"을 막는 강제 게이트.

**Step 1 (RED):** test_teardown.bats:
- `@test "teardown-resource refuses while any bindings still reference..."`(자동 refcount) 삭제.
- 신규 단언:
```bash
@test "any teardown is refused without --refs-verified attestation (F1 enforceable guard)" {
  run bun "$ROOT/tools/teardown-resource.ts" --db shared --repo-root "$FR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "refs-verified"
}
@test "retain proceeds with --refs-verified <id>" {
  run bun "$ROOT/tools/teardown-resource.ts" --db shared --refs-verified manual-2026-06-25 --repo-root "$FR"
  [ "$status" -eq 0 ]
}
@test "purge without --backup-verified is still refused (data-loss guard kept)" {
  run bun "$ROOT/tools/teardown-resource.ts" --db shared --delete-data --step tombstone --refs-verified manual-2026-06-25 --repo-root "$FR"
  [ "$status" -ne 0 ]   # backup-verified 별도 필수
}
```
**Step 2 (RED 실행):** `bats tools/tests/test_teardown.bats` → 신규 단언 FAIL.
**Step 3 (구현):**
- `tools/teardown-resource.ts`에서 `.bindings.json` 참조 집계 블록(`referrers`)과 `if (referrers.length>0) fail(...)` 제거.
- `--refs-verified <id>` 플래그 추가(parseFlags value). **누락 시 retain/purge 모두 즉시 `fail("--refs-verified <evidence-id> 필수 — 런북 수동 확인 후 증거 id 전달")`.** id 형식은 비어있지 않은 토큰(검증).
- plan 객체에 `refsVerified: <id>` 기록(감사 추적). **purge 상태머신 + `--backup-verified`는 비접촉(별도 가드).**
**Step 4 (GREEN):** `bats tools/tests/test_teardown.bats` 통과(refs-verified 강제 + backup-verified 유지).
**Step 5 (커밋):** `git commit -m "feat(teardown): 자동 refcount → --refs-verified attestation 게이트(F1 강화)"`

### Task B6: audit-orphans.ts에서 dangling-binding(db/redis) 제거

**Files:** Modify `tools/audit-orphans.ts` · `tools/tests/test_audit-orphans.bats`

**Step 1 (RED):** test_audit-orphans.bats의 dangling-binding(db/redis) + unreferenced-resource(db/redis) 테스트 삭제.
**Step 2 (구현):** `tools/audit-orphans.ts`에서 `.bindings.json` db/redis 순회·`dangling-binding` 추가·미참조 리소스 탐지 블록 제거(`grep -n 'dangling-binding\|bindings\|referenced'`). 다른 유형(orphan-dns 등)·`BLOCKING` 세트에서 dangling-binding 제거.
**Step 3 (GREEN):** `bats tools/tests/test_audit-orphans.bats` + `make audit`(있으면) 통과.
**Step 4 (커밋):** `git commit -m "refactor(audit): db/redis dangling-binding 탐지 제거(정적 사실만)"`

### Task B7: seal-secret.mts에 F2 완화 — seal-time superuser-host 거부

**Files:** Modify `tools/seal-secret.mts` · `tools/tests/test_seal-secret.bats`

> F2는 **앱 봉인 경로**(=`seal-secret.mts`, `pnpm secret:seal`)에만 둔다. 관리형 secret용 `lib/seal.ts`(provision-db)는 대상 아님.

**Step 1 (RED):** test_seal-secret.bats에 추가:
```bash
@test "seal-secret rejects a value pointing at the admin superuser host (F2, best-effort)" {
  printf 'kind: service\nsecrets: [db-url]\n' > "$TMP/.app-config.yml"
  printf 'DB_URL=postgres://app_admin@pg-rw-tailscale:5432/app\n' > "$TMP/.env"   # C1의 superuser 롤(SSOT=app_admin)
  run bun "$ROOT/tools/seal-secret.mts" --config "$TMP/.app-config.yml" --env "$TMP/.env" --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "superuser\|app_admin"
}
```
> 거부 규칙(F1 수정): **C1이 만드는 실제 superuser 롤명 `app_admin`**(SSOT) 또는 backup superuser `postgres`가 URL userinfo(user)에 있을 때 거부. host 매칭이 아니라 **user 매칭**(host는 공유라 false-positive 위험). 롤명이 C1과 어긋나면 가드가 무력화되므로 동일 SSOT를 참조한다. SEAL_FORCE=1로 우회 가능(informed) — 단 평문 값은 절대 출력 안 함.
**Step 2 (RED 실행):** FAIL(아직 체크 없음).
**Step 3 (구현):** `tools/seal-secret.mts`의 envMap 파싱 후, 각 대상 값에 대해 `postgres(ql)?://(app_admin|postgres)[:@]` / `redis://(default)[:@]`(per-instance admin) 매칭 시 키 이름만 출력하고 `die(...)`(SEAL_FORCE!=1). **값은 출력 금지.** 거부 user 목록(`app_admin`,`postgres`)은 C1 롤명 SSOT와 일치시킨다(상수로 두고 주석에 "C1 cluster.yaml managed.roles와 동기" 명시).
**Step 4 (GREEN):** `bats tools/tests/test_seal-secret.bats` 통과(기존 + 신규).
**Step 5 (커밋):** `git commit -m "feat(seal-secret): F2 완화 — seal-time admin/superuser 자격 거부(best-effort, SEAL_FORCE 우회)"`

### Task B8: F1/F3 런북 명문화

**Files:** Create `docs/runbooks/teardown-resource.md`(로컬 전용 — gitignored 여부 확인; AGENTS.md상 런북은 로컬) · 또는 `docs/traps-detail.md`에 항목 추가

**Step 1:** teardown 런북에 "삭제 전 수동 확인" 체크리스트(사용 앱 grep `apps/*/deploy/prod` + 실행 워크로드 `kubectl` + 백업 검증) + purge 3단계 절차.
**Step 2:** §7 잔여 위험(자동 refcount 제거·rotation drift) 기록 위치 확인(설계 문서에 이미 있음).
**Step 3 (커밋):** `git commit -m "docs(runbook): teardown 수동 확인 절차(F1)·F3 expand/contract"`
> 런북이 gitignored면 커밋 대상 아님 — 로컬 작성만 + 설계 문서 §7로 추적.

### Task B9: PR-B 게이트 검증
`make verify` + `bats tools/tests/`(app-config·create-app·teardown·audit·seal-secret·app-deploy) + bats accounting(`scripts/check-bats-accounting.sh`) 전부 GREEN.

---

## PR-C: 접속 계층 (tailscale pg 노출 + admin superuser + URL 도구 재작성)

### Task C1: cluster.yaml admin superuser 롤 + 비번 SealedSecret

**Files:** Modify `platform/cnpg/prod/cluster.yaml` · KSOPS 시크릿(기존 `app-credentials.enc.yaml` 패턴 따름) · `platform/cnpg/prod/kustomization.yaml`

> ★ 비번 시크릿은 **기존 `pg-app-credentials`(=`app-credentials.enc.yaml`, KSOPS, sync-wave -2) 패턴을 그대로** 복제: `pg-admin-credentials.enc.yaml`(SOPS 암호화) 신설 + kustomization KSOPS generator 등록. `*.enc.yaml`은 평문 직접편집 금지 — `sops`로 생성.
>
> ★★ **admin 롤명 SSOT = `app_admin`** (F1 수정). 이 이름은 C1에서 한 번 정의되고 **B7의 seal-time 거부 체크가 동일 이름을 거부**해야 한다(아래 B7 참조). 롤명을 바꾸면 B7도 동반 수정. 가능하면 plan 실행 시 단일 상수/주석으로 못박을 것.

**Step 1 (RED):** `platform/cnpg/prod/tests/`에 보안 단언 추가:
```bash
@test "cluster.yaml defines app_admin with full SSA-explicit fields" {
  out=$(kustomize build --enable-helm --enable-alpha-plugins --enable-exec platform/cnpg/prod)
  echo "$out" | yq -e 'select(.kind=="Cluster").spec.managed.roles[] | select(.name=="app_admin") | .superuser==true and .login==true and .ensure=="present" and .inherit==true and .connectionLimit==-1' >/dev/null
}
@test "adding app_admin preserves existing managed roles (SSA-atomic list not clobbered)" {
  out=$(kustomize build --enable-helm --enable-alpha-plugins --enable-exec platform/cnpg/prod)
  # 기존 provision-db owner/ro 롤이 있으면 함께 보존돼야 함(예시: 최소 1개 비-admin 롤 존재 시 카운트 유지)
  echo "$out" | yq -e 'select(.kind=="Cluster").spec.managed.roles | length >= 1' >/dev/null
}
```
> ★ 알려진 트랩(AGENTS.md: SSA atomic 리스트 영구 OutOfSync) — `managed.roles`는 SSA-atomic이라 **defaulted 필드를 명시**해야 ArgoCD가 OutOfSync 플립을 안 한다. 기존 롤(provision-db owner/ro)이 있으면 **그 리스트에 append**(전체 교체 금지).
**Step 2 (RED 실행):** 렌더 후 FAIL(롤 없음/필드 누락).
**Step 3 (구현):** `cluster.yaml` `spec.managed.roles`에 **full 객체** append:
```yaml
      - name: app_admin
        ensure: present
        login: true
        superuser: true
        inherit: true
        connectionLimit: -1
        passwordSecret:
          name: pg-admin-credentials
```
`pg-admin-credentials.enc.yaml`(database NS, `kubernetes.io/basic-auth` username=app_admin/password, CNPG passwordSecret 계약 — §11 #3 확인) `sops`로 생성 + kustomization KSOPS generator 등록(wave -2, app-credentials 패턴 동일).
**Step 4 (GREEN):** `kustomize build ... platform/cnpg/prod | kubeconform -summary` 통과 + 위 bats 통과.
**Step 5 (커밋):** `git commit -m "feat(cnpg): GUI 전용 admin superuser 롤 추가(백업 pg-superuser와 분리)"`

### Task C2: networkpolicy.yaml — tailscale→pg(5432) ingress 허용

**Files:** Modify `platform/cnpg/prod/networkpolicy.yaml`

**Step 1 (RED):** bats 단언 — tailscale NS에서 5432 ingress 허용 + 기존 default-deny 유지:
```bash
@test "netpol allows ingress from tailscale ns on 5432" {
  out=$(kustomize build --enable-helm --enable-alpha-plugins --enable-exec platform/cnpg/prod)
  echo "$out" | yq -e 'select(.kind=="NetworkPolicy" and (.metadata.name=="cnpg-allow-tailscale")) | .spec.ingress[0].ports[] | select(.port==5432)' >/dev/null
}
```
**Step 2 (구현):** netpol 추가 — `from: namespaceSelector{kubernetes.io/metadata.name: tailscale (또는 edge — tailscale operator NS 확인)} ports: 5432`. tailscale operator proxy가 실제로 어느 NS/라벨인지 `kubectl get ns --show-labels`로 확인 후 정확히.
**Step 3 (GREEN):** 렌더 + kubeconform + bats 통과.
**Step 4 (커밋):** `git commit -m "feat(cnpg): tailscale proxy→pg(5432) ingress netpol(default-deny 유지)"`

### Task C3: pg-rw tailscale LoadBalancer Service

**Files:** Create `platform/cnpg/prod/pg-rw-tailscale-service.yaml` · Modify `kustomization.yaml`

> ★ tailscale 노출 메커니즘은 레포 기존 방식 확인: `platform/tailscale/prod/traefik-ingress.yaml`이 `loadBalancerClass: tailscale` + `tailscale.com/hostname` annotation 사용. 동일 패턴 적용. selector는 CNPG primary(`cnpg.io/cluster: pg, role: primary` — 실제 라벨 `kubectl -n database get svc pg-rw -o yaml`로 확인).

**Step 1 (RED):** bats — Service가 `loadBalancerClass: tailscale` + hostname annotation + port 5432.
**Step 2 (구현):** Service 생성(type LoadBalancer, loadBalancerClass tailscale, `tailscale.com/hostname: pg-rw`, selector=pg primary, port 5432). kustomization resources 등록.
**Step 3 (GREEN):** 렌더 + kubeconform + bats 통과.
**Step 4 (커밋):** `git commit -m "feat(cnpg): pg-rw tailscale LoadBalancer Service(GUI/로컬 직결)"`

### Task C4: infra/tailscale ACL — owner 기기→pg(5432)

**Files:** Modify `infra/tailscale/*.tf` (ACL 정의 파일 — `grep -rn "acls\|tailscale_acl" infra/tailscale`)

**Step 1 (RED):** `grep -q "5432" infra/tailscale/*.tf` → 없음. + 단언 테스트(아래)도 RED.
**Step 2 (구현, F2 수정):** ACL에 5432 규칙을 **owner-only**로 추가 — `src`는 **`autogroup:member` 금지**(전 tailnet 멤버 노출). 대신 owner 특정 신원: tailnet 단독 운영이면 `autogroup:admin`(tailnet 관리자=owner), 또는 owner user email(`["ukyi.js@gmail.com"]`)/전용 device 태그. 예:
```hcl
# GUI(TablePlus)+로컬 CLI: owner(tailnet admin)만 CNPG pg(5432) — autogroup:member 금지(crown-jewel 보호)
{ action = "accept", src = ["autogroup:admin"], dst = ["tag:k8s:5432"] },
```
(dst 태그명은 기존 ACL의 k8s 노출 태그 확인 후 일치.)
**Step 2b (단언 — F2 회귀 가드):** 5432가 일반 멤버에 안 열렸는지 검사. `infra/tailscale/tests/` 또는 jq/grep 게이트:
```bash
# acl.json 렌더(또는 jsonencode 입력)에서 5432 규칙의 src에 autogroup:member 없음
! grep -E 'autogroup:member.*5432|5432.*autogroup:member' infra/tailscale/*.tf
```
**Step 3 (GREEN):** `terraform -chdir=infra/tailscale fmt` + `make tf-validate` 통과 + 위 단언 통과(plan-only; apply는 owner-local, AGENTS.md상 신뢰앵커 무인 apply 금지).
**Step 4 (커밋):** `git commit -m "feat(tailscale): owner 기기→pg(5432) ACL 규칙(최소권한)"`

### Task C5: db-url.ts 재작성 — `--rw`/`--admin` + canonical `DATABASE_URL`

**Files:** Modify `tools/db-url.ts` · `tools/tests/test_db-url.bats`(신규)

> ★ 자격 출처 정정: `--rw`는 **owner conn `db-<name>-conn`**(키 `<NAME>_DATABASE_URL`)을 읽는다(provision-db는 `-rw-conn`을 만들지 않음 — owner=RW). 기본(no flag)=RO(`db-<name>-ro-conn`).
> RO/RW 출력 키는 **`DATABASE_URL`**(canonical) → **`.env.local`**(앱 런타임 채널).
>
> ★★ **F2 채널 분리(패스2)**: `--admin`은 `pg-admin-credentials`(database NS) superuser를 읽되, **절대 `DATABASE_URL`/`.env.local`에 쓰지 않는다**. 대신 키 `DATABASE_ADMIN_URL` → 별도 파일 `.env.admin.local`(gitignore 필수, **secret:seal 대상 제외** — 앱 봉인 경로와 분리). 이유: superuser URL이 앱 런타임 키에 들어가면 로컬 앱이 실수로 app_admin으로 구동 + 봉인 사고 위험. 평문 stdout 금지(모든 모드).

**Step 1 (RED):** test_db-url.bats:
```bash
@test "db-url --dry-run uses canonical DATABASE_URL and forbids stdout plaintext" {
  run bun "$ROOT/tools/db-url.ts" --name orders --host 100.0.0.1 --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "DATABASE_URL"
  echo "$output" | grep -q "출력하지 않음\|stdout"
}
@test "db-url --rw reads owner conn db-<name>-conn (not a -rw-conn)" {
  run bun "$ROOT/tools/db-url.ts" --name orders --host 100.0.0.1 --rw --dry-run
  echo "$output" | grep -q "db-orders-conn"
}
@test "db-url --admin and --rw are mutually exclusive" {
  run bun "$ROOT/tools/db-url.ts" --name orders --host 100.0.0.1 --rw --admin --dry-run
  [ "$status" -eq 2 ]
}
@test "db-url --admin uses DATABASE_ADMIN_URL + .env.admin.local, never DATABASE_URL (F2)" {
  run bun "$ROOT/tools/db-url.ts" --name orders --host 100.0.0.1 --admin --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "DATABASE_ADMIN_URL"
  echo "$output" | grep -q "env.admin.local"
  run bash -c "bun \"$ROOT/tools/db-url.ts\" --name orders --host 100.0.0.1 --admin --dry-run | grep -ow DATABASE_URL"
  [ "$status" -ne 0 ]   # admin은 앱 런타임 키(DATABASE_URL)를 쓰지 않음
}
```
**Step 2 (RED 실행):** FAIL.
**Step 3 (구현):** `tools/db-url.ts` 재작성 — `--rw`/`--admin` bool 플래그(상호배타). mode별 secret: RO=`db-<name>-ro-conn`, RW=`db-<name>-conn`(owner), admin=`pg-admin-credentials`. host를 tailscale로 치환. **RO/RW → 키 `DATABASE_URL` → `.env.local`. admin → 키 `DATABASE_ADMIN_URL` → `.env.admin.local`(앱 런타임 채널·봉인 경로와 분리).** 평문 stdout 금지(전 모드). dry-run은 mode/secretRef/키/대상파일만(값 없음).
**Step 4 (GREEN):** `bats tools/tests/test_db-url.bats` 통과.
**Step 5 (커밋):** `git commit -m "feat(db-url): --rw/--admin 모드 + canonical DATABASE_URL(평문 stdout 금지)"`

### Task C6: cache-url.ts 재작성 — `--rw` + canonical `REDIS_URL`

**Files:** Modify `tools/cache-url.ts` · `tools/tests/test_cache-url.bats`(신규)

> `--rw`=`cache-<name>-conn`(default 유저), 기본=RO(`cache-<name>-ro-conn`). admin 없음(Valkey는 per-instance — `--rw`가 default 유저=관리). 출력 키 `REDIS_URL`. db-url과 대칭.
>
> ★★ **F3 노출 정합(패스2)**: PR-C는 Postgres만 tailscale 노출(5432). **Valkey tailscale 상시 노출은 deferred**(설계 §11 #4 — 캐시별 Service/netpol/ACL 추가 비용). 따라서 cache-url은 **port-forward 기본** — tailscale host 불요. 도구는 RO/RW 자격을 conn secret에서 읽고 host를 **`127.0.0.1`(port-forward 타깃)**으로 치환해 `.env.local`에 `REDIS_URL` 기록. 런북에 `kubectl -n cache port-forward svc/<name> 6379:6379` 선행 안내. (tailscale 상시 노출이 필요해지면 별도 PR.)

**Step 1 (RED):** test_cache-url.bats:
```bash
@test "cache-url --dry-run uses canonical REDIS_URL, port-forward localhost, no tailscale required" {
  run bun "$ROOT/tools/cache-url.ts" --name sessions --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "REDIS_URL"
  echo "$output" | grep -q "127.0.0.1\|port-forward"
  echo "$output" | grep -q "출력하지 않음\|stdout"
}
@test "cache-url --rw reads cache-<name>-conn (default user)" {
  run bun "$ROOT/tools/cache-url.ts" --name sessions --rw --dry-run
  echo "$output" | grep -q "cache-sessions-conn"
}
```
**Step 2 (구현):** db-url 대칭으로 재작성(port 6379) — **단 host는 tailscale가 아닌 `127.0.0.1`(port-forward)**. `--host` 옵션은 받되 기본 localhost. 평문 stdout 금지 → `.env.local`만.
**Step 3 (GREEN):** `bats tools/tests/test_cache-url.bats` 통과.
**Step 4 (커밋):** `git commit -m "feat(cache-url): --rw + canonical REDIS_URL(port-forward 기본, Valkey tailscale 노출 deferred)"`

### Task C7: 보안 통합 테스트 + 신규 런북

**Files:** `platform/cnpg/prod/tests/test_security-gates.bats`(C1~C3 단언 통합) · `docs/runbooks/db-cache-access.md`(로컬 전용일 수 있음 — gitignore 확인)

**Step 1 (구현):** C1(admin role superuser/login + 비번 SealedSecret 평문 0), C2(tailscale ingress 5432 + default-deny 유지), C3(LB class tailscale + hostname) 단언 + kubeconform 통과를 한 파일로. bats accounting에 chart-test가 아닌 cnpg test 도메인 배정 확인(`scripts/check-bats-accounting.sh`).
**Step 2 (런북):** TablePlus(Postgres admin)·RedisInsight(per-instance)·tailscale LB IP 조회·port-forward 대안·트러블슈팅·`.env.local` `.gitignore` 주의.
**Step 3 (GREEN):** `bats platform/cnpg/prod/tests/` + `make verify` 통과.
**Step 4 (커밋):** `git commit -m "test(cnpg): admin/netpol/tailscale 보안 게이트 + 접속 런북"`

### Task C8: PR-C 게이트 검증
`make verify` + `make tf-validate` + `make chart-test`(영향 없음 확인) + `bats tools/tests/test_db-url.bats test_cache-url.bats` + `bats platform/cnpg/prod/tests/` + `kustomize build platform/cnpg/prod | kubeconform`. 라이브 적용(tailscale apply·admin 비번 봉인 cert)은 owner-local.

### Task C9: PR-C 롤백/자격 회수 절차 (F3 — 문서, owner-local 런북)

PR-C는 superuser 자격 + tailscale LB + netpol ingress + ACL 노출을 한 번에 추가한다. **노출이 잘못됐거나 admin 자격이 유출되면 아래 순서로 즉시 되돌린다**(노출을 먼저 닫고, 자격을 회수하고, 검증). 런북 `docs/runbooks/db-cache-access.md`에 명문화(gitignore면 로컬 + 설계 문서 추적).

**순서화된 롤백 (노출 차단 → 자격 회수 → 검증):**
1. **ACL 닫기** — `infra/tailscale`에서 5432 규칙 제거 → `terraform apply`(owner-local). tailnet에서 5432 도달 즉시 차단.
2. **LB/netpol 제거** — `pg-rw-tailscale-service.yaml`·tailscale ingress netpol을 kustomization에서 제거 → ArgoCD 싱크(또는 즉시 `kubectl delete svc pg-rw-tailscale`).
3. **admin 자격 회전/삭제** — `pg-admin-credentials` 재봉인(새 비번)으로 회전, 또는 cluster.yaml `managed.roles`에서 `app_admin` 제거 → CNPG가 롤 DROP. (롤 제거 시 ensure absent 확인.)
4. **검증** — tailnet 클라이언트에서 `nc -zv <pg-rw-tailscale-host> 5432`가 **실패**(닫힘) + `psql`로 `app_admin` 로그인 거부 확인.

**부분 롤백 가이드**: admin 자격만 유출 → 3·4만(노출은 유지 가능). 과노출만 문제 → 1·2·4. 전체 철회 → 1→2→3→4 순.

**Step (커밋):** `git commit -m "docs(runbook): PR-C 롤백/자격 회수 순서 절차(F3)"` (런북이 gitignore면 설계 문서 §7 옆에 요약 추가).

---

## 시퀀싱 & 머지
- 순서: **PR-A → PR-B → PR-C** (각 PR-first + gate GREEN 후 수동 머지; 이 레포 auto-merge 비활성 → gate watch).
- env 제거(PR #113)는 선행 머지 후 각 PR을 origin/main에 리베이스.
- 라이브 검증(PR-C): tailscale LB IP 발급·admin 자격 GUI 접속·netpol 차단 확인은 머지 후 owner-local.

## 미해결 (실행 중 결정)
1. F2 거부 규칙: user 매칭(`admin`/`postgres`) 정밀화 — false-positive 최소화.
2. tailscale operator NS/라벨 실측(netpol namespaceSelector·ACL 태그).
3. admin 비번 SealedSecret을 basic-auth vs generic — CNPG managed role passwordSecret 계약 확인.
4. 런북 gitignore 여부(로컬 전용이면 커밋 제외, 설계 문서로 추적).

---

## Adversarial review dispositions (Phase C 감사 추적)

codex `--scope working-tree`, 3패스. (post-approval 기록 — 재검증 안 함.)

**패스 1** (verdict: needs-attention, 3 findings):
- F1 (HIGH) F2 가드가 app_admin 롤 누락 → **Accepted**: 롤명 SSOT(`app_admin`) + B7이 실제 롤 거부.
- F2 (HIGH) ACL `autogroup:member` 과노출 → **Accepted**: owner-only(`autogroup:admin`/특정 신원) + 회귀 단언.
- F3 (MED) PR-C 롤백 부재 → **Accepted**: Task C9 순서 롤백/회수 추가.

**패스 2** (needs-attention, 4 findings):
- F1 (HIGH) teardown 강제 가드 상실 → **Accepted(강화)**: B5에 `--refs-verified` attestation 게이트(design 불변).
- F2 (HIGH) `--admin`이 앱 `DATABASE_URL` 채널 오염 → **Accepted**: `DATABASE_ADMIN_URL`+`.env.admin.local` 분리(C5).
- F3 (MED) cache 노출 부재 → **Accepted**: cache-url port-forward 기본, Valkey tailscale deferred(C6).
- F4 (MED) managed role SSA default 누락 → **Accepted**: full role 객체+보존 단언(C1).

**패스 3 (캡, needs-attention, 3 findings)** — 최종 verdict=needs-attention:
- F1 (HIGH) teardown `--refs-verified`가 검증 불가 토큰 → **Open / 감수(informed)**: db: 제거로 기계검증 가능 registry는 불가(=`db:` 복원 = 핵심 결정 reversal). owner가 A.5·패스2·패스3에서 반복 확인 후 `--refs-verified` 최대 완화로 감수(설계 §7). codex 권고(non-secret registry)는 설계 reversal이라 미채택.
- F2 (MED) 외부 계약 cross-repo cutover 누락 → **Accepted**: Task A0(템플릿 cutover+인벤토리+순서 게이트).
- F3 (MED) 차트 db/migrate 잔여 참조 → **Accepted**: Task A2b(rg 기반 일괄 정리).

> 캡 초과로 F2/F3 보강은 codex 재검증 없이 반영(owner 승인). **잔여 HIGH(F1)는 owner informed 감수** — 자동 finalize 아님, 캡 게이트에서 명시 결정.

## Execution directives
- **Skill:** `executing-plans`로 **별도 세션, 이 워크트리에서** 구현.
- **연속 실행:** 배치 사이 멈추지 말 것. 진짜 블로커(의존성 부재·반복 실패하는 검증·모순된 지시·치명적 계획 갭)에서만 정지. 그 외엔 전 배치 완주.
- **커밋 — 아래 규칙 직접 적용, `Skill(commit)` 호출 금지**(대화형 확인이 연속 실행을 깸):
  - **언어:** 한국어. **AI 마커 절대 금지**(`🤖 Generated with`, `Co-Authored-By: Claude`, `Claude-Session` 등 어떤 형태도 X).
  - **형식:** `<type>(<scope>): 한국어 설명` (+ 필요 시 `- 상세` 본문).
  - **type — 이것만:** `feat`·`fix`·`refactor`·`docs`·`style`·`test`·`chore`. (`perf`/`build`/`ci` 등 금지.)
  - **그룹:** ① 같은 모듈/디렉토리 함께 ② 목적별 분리(refactor↔fix↔feat) ③ 서로 import/참조하면 함께 ④ config·tests·docs·standalone style은 각자 커밋.
  - **위치:** 각 plan `Commit`/`커밋` 스텝에서 현재 feature-branch 워크트리에 직접 커밋(이미 main 밖이라 새 브랜치 불요).
- **순서:** PR-A(Task A0 cutover 선행) → PR-B → PR-C. env 제거(PR #113) 선행 머지 후 origin/main 리베이스.
- **검증:** 각 PR 끝 `make verify`/`make chart-test`/`make tf-validate`/관련 bats GREEN. 라이브(tailscale apply·admin 봉인 cert·라이브 접속/롤백 검증)는 owner-local.
