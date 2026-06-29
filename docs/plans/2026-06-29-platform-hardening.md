# 플랫폼 하드닝 구현 계획 — 프로비저닝·풀러 재발방지

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 첫 실앱 page가 드러낸 프로비저닝/풀러 결함(#3 CNPG 롤 비번 미적용)이 신규 앱에서 재발하지 않게 하고, 인클러스터 카나리로 골든패스를 상시 검증하며, 템플릿을 풀러-안전 정설계로 만든다.

**Architecture:** 세 워크스트림. WS1은 `provision-db.ts`가 만드는 owner/ro 비번 SealedSecret에 Cluster(-1)보다 앞선 ArgoCD sync-wave를 부여해 CNPG 롤 reconcile 전에 비번 Secret이 존재하도록 한다(원인: Cluster wave -1 < SealedSecret 기본 wave 0). WS2는 example-api를 DB 백업 카나리로 전환해 풀러 경로를 상시 검증한다. WS3은 homelab-app-template에 풀러-안전 DB 클라이언트·DB readiness·현행 kind를 넣는다.

**Tech Stack:** CNPG(CloudNativePG) Cluster/Database/Pooler, SealedSecrets, ArgoCD(sync-wave), kustomize, bats, Bun + Hono(앱/카나리/템플릿), node-postgres(pg).

**Repos:** homelab(주), ukyi-app/example-api(카나리), ukyi-app/homelab-app-template(템플릿). homelab main은 보호됨 — 전부 PR.

**검증 제약(설계서 참조):** CI(GitHub 러너)는 인클러스터 풀러에 도달 불가 → 라이브 conn 검증은 카나리(인클러스터)로만. CI 게이트는 정적(bats/render)만.

---

## WS1 — CNPG managed role 비밀번호 적용 보장 (sync-wave 순서)

### Task 1: owner/ro 비번 SealedSecret에 Cluster보다 앞선 sync-wave 부여

**원인(라이브 확정):** `platform/cnpg/prod/cluster.yaml`의 Cluster CR은 `argocd.argoproj.io/sync-wave: "-1"`. `provision-db.ts`가 만드는 `db-<app>-owner`/`db-<app>-ro` SealedSecret엔 wave 어노테이션이 없어 기본 wave **0**. ArgoCD는 낮은 wave 먼저 적용 → Cluster(-1, managed-role 포함)가 비번 SealedSecret(0)보다 먼저 reconcile → CNPG가 비번 Secret 부재 상태로 롤 생성 → `passwordStatus.<role>`에 resourceVersion 미기록, secret 변경 전 재적용 안 함 = 인증 실패.

**Files:**
- Modify: `tools/provision-db.ts` (seal 호출의 owner/ro Secret manifest — 현재 145-156행)
- Test: `tools/provision-db.test.ts` (있으면 확장; 없으면 신설) + `platform/cnpg/prod/test_sync_wave_ordering.bats`

**Step 1: 실패 테스트 작성 (provision-db 산출물에 wave 어노테이션)**

`tools/provision-db.test.ts`에, `--dry-run`이 아닌 임시 `--repo-root`로 provision-db를 실행한 뒤 `db-<name>-owner.sealed.yaml`/`db-<name>-ro.sealed.yaml`을 파싱해 `metadata.annotations["argocd.argoproj.io/sync-wave"]`가 Cluster wave(-1)보다 작은지(예: `"-2"`) 단언. (기존 provision-db 테스트 파일의 픽스처/헬퍼 패턴을 먼저 읽고 동일 스타일로.)

```ts
// 예시 골자 (실제 헬퍼는 기존 테스트 파일 관례를 따른다)
test("owner/ro 비번 SealedSecret은 Cluster(-1)보다 앞선 sync-wave를 가진다", () => {
  // provision-db를 임시 repo-root에서 실행 후
  const owner = parseSealed(`${tmp}/platform/cnpg/prod/databases/db-foo-owner.sealed.yaml`);
  const wave = Number(owner.metadata.annotations["argocd.argoproj.io/sync-wave"]);
  expect(wave).toBeLessThan(-1); // Cluster CR이 -1
});
```

**Step 2: 실패 확인**

Run: `bun test tools/provision-db.test.ts` → 어노테이션 없음으로 FAIL.

**Step 3: 최소 구현**

`tools/provision-db.ts`의 owner/ro `seal({...})` manifest `metadata`에 annotations 추가. (SealedSecret은 `spec.template.metadata.annotations`로 평문 Secret에 전파되지만, CNPG가 보는 것은 평문 Secret이 아니라 ArgoCD가 보는 **SealedSecret 리소스의 wave**다 — 따라서 SealedSecret 자체의 `metadata.annotations`에 wave를 둔다. `sealManifest`가 SealedSecret의 metadata.annotations를 보존하는지 `tools/lib/seal.ts`를 먼저 읽어 확인하고, 보존 안 하면 seal 후 결과 YAML에 주입.)

```ts
// owner/ro Secret manifest에 (seal 입력이 SealedSecret metadata로 전파되지 않으면 seal 결과에 주입)
metadata: {
  name: `db-${name}-owner`, namespace: "database",
  annotations: { "argocd.argoproj.io/sync-wave": "-2" }, // Cluster(-1)보다 먼저 → CNPG 롤 reconcile 전 비번 Secret 존재
},
```

**Step 4: 통과 확인** — `bun test tools/provision-db.test.ts` PASS.

**Step 5: Commit**
```bash
git add tools/provision-db.ts tools/provision-db.test.ts
git commit -m "fix: provision-db가 비번 SealedSecret에 Cluster보다 앞선 sync-wave 부여 (CNPG 롤 비번 적용 보장)"
```

### Task 2: sync-wave 순서 게이트 + sealed-secrets health 게이팅 검증

**Files:**
- Modify: `platform/cnpg/prod/test_sync_wave_ordering.bats`
- Read/검증: ArgoCD가 SealedSecret을 Secret 생성 후에만 Healthy로 판정하는지(잔여 레이스).

**Step 1: bats 단언 추가 (실패)**
```bash
@test "db owner/ro 비번 SealedSecret은 Cluster(-1)보다 앞선 wave" {
  for f in platform/cnpg/prod/databases/db-*-owner.sealed.yaml platform/cnpg/prod/databases/db-*-ro.sealed.yaml; do
    [ -e "$f" ] || continue
    w=$(yq '.metadata.annotations."argocd.argoproj.io/sync-wave"' "$f")
    [ "$w" -lt -1 ]
  done
}
```
Run: `bats platform/cnpg/prod/test_sync_wave_ordering.bats` → 기존 page 시크릿(wave 없음)으로 FAIL.

**Step 2: 기존 page 비번 SealedSecret 레트로핏 (필수 — 게이트 활성화 전 마이그레이션, adversarial pass2-F2)**
게이트(Step 1)가 **모든** `db-*-owner/ro` secret을 스캔하므로, 기존 `db-page-owner.sealed.yaml`/`db-page-ro.sealed.yaml`에도 wave 어노테이션을 추가해야 게이트가 통과한다(미적용 시 게이트서 막히거나 게이트를 약화시키는 모순). SealedSecret은 암호문 불변이라 재봉인 없이 `metadata.annotations`만 추가 가능 — `yq -i`로 양 파일에 `argocd.argoproj.io/sync-wave: "-2"` 주입. (page는 이미 self-heal됐으므로 런타임 영향 없음; 게이트 일관성·신규 앱 동일 동작 보장이 목적.) 이 레트로핏을 **게이트를 green으로 만들기 전에** 완료한다.

**Step 3: 통과 확인** — bats PASS (신규 + 레거시 secret 모두 wave < -1).

**Step 4: health-gating 판정 (정보용 — Task 2b를 건너뛰는 근거가 아님)**
`kubectl get application cnpg-data -o yaml` + sealed-secrets health로 "ArgoCD가 SealedSecret을 평문 Secret 생성 이후에만 Healthy로 판정하는가"를 확인하고 결과를 PR 본문에 기록한다. **PASS여도 Task 2b는 생략하지 않는다** — wave 순서는 방어 1층(레이스 폭 축소)일 뿐, 컨트롤러 지연/부분 reconcile/health 동작 변경으로 빈 passwordStatus가 재현될 수 있으므로 결정적 보장(Task 2b)을 항상 둔다(방어 심층화, adversarial pass2-F1).

**Step 5: Commit**
```bash
git add platform/cnpg/prod/test_sync_wave_ordering.bats platform/cnpg/prod/databases/
git commit -m "test: 비번 SealedSecret sync-wave 순서 게이트 추가"
```

### Task 2b: 결정적 비번 적용 보장 — create-database 계약의 **무조건·차단** 단계 (adversarial pass2-F1)

**근거:** wave 순서(Task 1)는 방어 1층일 뿐 ArgoCD health-gating에 의존한다. 컨트롤러 지연/부분 reconcile/health 동작 변경으로 빈 `passwordStatus.resourceVersion`이 언제든 재현될 수 있으므로, **모든 신규 DB 프로비전이 "비번이 실제 적용됨"을 보장하기 전엔 DB를 usable로 간주하지 않는다.** 이 단계는 **선택이 아니며**(health-gating PASS여도 수행), create-database 자동화의 **차단 단계**다.

**실행 모델 (adversarial pass3-F1 — 반드시 명세):** create-database는 GitHub Actions(클러스터 무접근)에서 PR을 자동머지만 한다 → 라이브 폴링/annotate/풀러 인증은 **CI에서 불가**. 따라서 보장은 **인클러스터**로 실행한다:
- `tools/ensure-role-password.ts`를 도는 **ArgoCD PostSync hook Job**을 `platform/cnpg/prod`(cnpg-data 앱)에 둔다 — Cluster/Database가 Synced된 뒤 매 sync마다 멱등 실행.
- 전용 **ServiceAccount + RBAC**: `clusters/databases` status read(get/watch), `database` ns Secret patch(annotate)만(최소권한).
- **fail-closed**: 타임아웃 내 owner·ro 양 롤 `passwordStatus.resourceVersion` 미충족이면 Job 비0 종료 → cnpg-data 앱 **Degraded** → 알림(page 크래시 알림과 동일 채널).
- **온보딩 게이트 — per-DB freshness 마커 (adversarial pass4):** "Job 성공 또는 카나리 양성"은 너무 느슨(stale한 이전 Job 성공/무관 카나리로 통과될 레이스). 대신 Job은 검증 성공 시 **대상 DB로 키된 완료 마커**를 방출한다 — 예: `database` ns의 ConfigMap `db-<name>-ready`에 `{ownerSecretResourceVersion, roSecretResourceVersion, verifiedAt}` 기록. **activate-app/create-app은** 대상 앱의 마커가 존재하고 기록된 resourceVersion이 **현재 owner/ro Secret의 resourceVersion과 일치(=fresh)**함을 확인해야만 노출/롤아웃을 진행한다. 일반 Job 성공이나 무관한 카나리 readiness로는 게이트를 만족시키지 못한다. (create-database PR 자동머지 자체는 막지 않되, "DB usable" 권위는 이 per-DB 마커다.)

**Files (homelab):** `tools/ensure-role-password.ts`(신설) + 테스트, `platform/cnpg/prod/`에 PostSync hook Job + SA/RBAC manifest + kustomization 등록.

**Step 1~4 (TDD):** "Database CR Ready 후, owner·ro **양 롤** 모두 `cluster.status.managedRolesStatus.passwordStatus.<role>.resourceVersion`이 존재할 때까지 **유한 타임아웃** 폴링; 없으면 해당 평문 Secret을 idempotent annotate(resourceVersion bump)해 CNPG 재적용 강제, 재폴링; **타임아웃 초과 시 명시적 실패(exit≠0)로 차단**(fail-closed)"을 작성. fake clock 단위 테스트: 없음→nudge→존재, 그리고 끝까지 없음→타임아웃 실패. CNPG 소유권과 무충돌(annotate는 재reconcile 트리거, 비번 값 불변).

**Step 5: 멱등·무조건성 단언:** 이미 적용된 DB에 재실행해도 무변경·성공(멱등) + create-database 경로에서 **항상** 실행됨을 워크플로 테스트로 단언.

**Step 6: 라이브 수용기준 (모든 신규 DB; WS2 카나리 온보딩 전 차단):** 온보딩 직후 owner·ro 양 롤 `resourceVersion` 채워짐 + conn 자격증명 **풀러 경유 인증 성공**. 미충족이면 진행 금지.

**Step 7: Commit** — `feat: 신규 DB 롤 비번 적용 결정적 보장(ensure-role-password, 무조건 차단)`

---

## WS2 — 상시 카나리 앱 (example-api를 DB 백업으로 전환)

example-api는 현재 인메모리 todos(무DB). 이를 풀러 경유 DB를 쓰는 카나리로 전환해 골든패스(풀러·conn·CNPG 롤·sealed-secrets)를 상시 검증한다.

### Task 3: example-api 풀러-안전 DB 클라이언트 + **분리된** 카나리 DB 모듈 (TDD, ukyi-app/example-api)

**근거(adversarial F3):** 기존 인메모리 todos를 DB로 갈아끼우면 스키마/마이그레이션 미비로 "readiness는 green인데 라우트는 깨진" 카나리가 나올 수 있다. → **기존 todos는 인메모리 그대로 두고**, 골든패스 검증용 **별도 카나리 DB 모듈**을 추가한다(블래스트 반경 0, 스키마 의존을 readiness가 실제로 검증).

**Files (example-api 레포):**
- Read 먼저: `src/index.ts`, `src/todos/*.ts`, `.app-config.yml`.
- Create: `src/db.ts`(pg Pool — **statement_timeout을 startup 파라미터로 안 보냄**; client `query_timeout`·`connectionTimeoutMillis`만) + `src/db.test.ts`.
- Create: `src/canary/canary.repository.ts`(전용 테이블 `canary_heartbeat`에 대한 **idempotent DDL**: `CREATE TABLE IF NOT EXISTS canary_heartbeat(id int primary key default 1, ts timestamptz)` + upsert/read) + 테스트. todos 미변경.
- 부팅 self-migrate(직결 URL)로 DDL 적용 — page 패턴 참고.

**Step 1~4 (TDD):**
- (a) `createPool`이 `statement_timeout`을 pg 옵션으로 **전달하지 않음** 단언 → 구현.
- (b) idempotent DDL이 재실행해도 안전(이미 존재 시 무오류)함을 통합 테스트(disposable DB)로 단언 → 구현.
- (c) canary 리포지토리 upsert→read 왕복이 마이그레이션된 스키마에서 동작함을 단언.

**Step 5: Commit** — `feat: example-api 풀러-안전 DB 클라이언트 + 분리된 카나리 DB 모듈`

### Task 4: DB 백업 readiness (풀러 왕복 SELECT 1)

**Files:** `src/index.ts`(또는 health 컨트롤러), 테스트.
- **liveness `/health`**: 정적 `{ok:true}` (DB 일시장애로 파드가 죽지 않게).
- **readiness `/ready`**: 풀러 경유로 **카나리 테이블 왕복**(`canary_heartbeat` upsert+read, Task 3) 성공 시 200, 실패 시 503. `SELECT 1`이 아니라 **실제 마이그레이션된 스키마 의존을 검증**(F3) → 풀러/conn/롤/스키마 경로 중 무엇이 깨져도 readiness 빠짐 → 알림.

**Step 1~4 (TDD):** fake/통합으로 `/ready`가 카나리 왕복 성공→200, throw(테이블 없음 포함)→503 단언 → 구현. `.app-config.yml`의 readiness probe path를 `/ready`로(차트 `platform/charts/app`가 liveness/readiness path 분리를 지원하는지 확인; 미지원이면 차트에 readiness path 추가를 별도 Task로 — page에서 본 차트 probe 렌더 참고).

**Step 5: Commit** — `feat: example-api DB 왕복 readiness(/ready)`

### Task 5: example-api용 create-database (homelab)

**정규 이름 = `example-api`** (adversarial pass3-F2 — "또는 canary" 분기 제거). provision-db가 이름에서 Secret/env를 파생하므로 전 경로를 한 이름으로 전파: DB명 `example-api` → 핸들 `db-example-api-conn`/`db-example-api-ro-conn` → env `EXAMPLE_API_DATABASE_URL`/`EXAMPLE_API_MIGRATE_DATABASE_URL`/`EXAMPLE_API_RO_DATABASE_URL` → 앱 코드·values.yaml·수용기준 동일 사용.

**Files (homelab):** create-database 디스패처로 `example-api` DB 생성 — provision-db 산출물(WS1 wave + Task 2b 보장 포함). owner==name 불변식상 DB명=앱명=`example-api`.
- Task 1의 wave 픽스 + Task 2b 보장이 적용된 provision-db/Job로 생성되므로 카나리가 #3 회귀를 즉시 실증.

**Step:** `gh workflow run create-database.yaml --repo ukyi-app/homelab -f name=example-api` → 생성 PR 머지. (실행 세션에서 수행; 계획엔 절차로.)

### Task 6: example-api values.yaml conn 배선 + 배포 (homelab)

**Files (homelab):** `apps/example-api/deploy/prod/values.yaml` envFrom에 `db-example-api-conn` 추가(page와 동일 패턴). create-app으로 매니페스트 생성 후 owner가 conn 배선 → 머지 → 배포.

**검증 (비파괴 — 공유 인프라 변형 금지):**
- 카나리 pod Running + `/ready` 200(풀러 왕복 성공) = 골든패스 양성 신호.
- 풀러 설정 회귀는 **공유 `pg-pooler-rw`를 절대 변형하지 않고** 정적으로 가드: `platform/cnpg/prod/test_pooler.bats`가 `ignore_startup_parameters`에 `statement_timeout` 포함을 단언(#145에서 추가됨) → 설정이 빠지면 CI가 fail. 추가로 카나리 `/ready`가 런타임에서 양성 신호를 상시 제공.
- **음성(회귀) 리허설이 꼭 필요하면** 공유 풀러가 아니라 **카나리 전용 격리 Pooler**(별도 CNPG Pooler 리소스)에서만 수행 — 기존 앱(page 등) 경로에 영향 0. (기본 계획에선 비범위: 정적 가드 + 양성 신호로 충분.)

> ⚠️ adversarial F2: 공유 `pg-pooler-rw`에서 `ignore_startup_parameters`를 임시 제거하는 리허설은 **page 등 기존 앱을 중단**시키므로 수용기준에서 제외한다.

**Step 5: Commit/PR** — 워크스트림 독립 PR.

---

## WS3 — 템플릿 하드닝 (ukyi-app/homelab-app-template)

### Task 7: 풀러-안전 DB 클라이언트 아키타입

**Files (template):** Read `scaffold/archetypes/api/src/index.ts` 등. Create `scaffold/archetypes/api/src/db.ts` (Task 3과 동일한 풀러-안전 패턴 — statement_timeout startup 미전송) + 스캐폴드 테스트.

**Step 1~4 (TDD):** 스캐폴드 산출물의 db.ts가 statement_timeout을 pg 옵션으로 안 넣음을 단언 → 구현. (서버측 강제가 필요하면 주석으로 `ALTER ROLE ... SET` 안내.)

**Step 5: Commit** — `feat: 템플릿 DB 아키타입을 풀러-안전 기본값으로`

### Task 8: 템플릿 DB readiness + 현행 kind

**Files (template):** 아키타입에 `/ready` DB 왕복(Task 4 패턴), `.app-config.yml` 템플릿이 `web`/`worker`/`site`만 쓰는지 확인(폐기 `service` 제거 — create-app 검증이 이미 거부하나 템플릿 정설계).

**Step 1~4 (TDD):** 스캐폴드 산출 `.app-config.yml`의 kind가 현행 enum인지 단언 + readiness 존재 단언 → 구현.

**Step 5: Commit** — `feat: 템플릿 readiness DB 왕복 + 현행 kind enum`

### Task 9: (선택) page db.ts 청결화

**Files (page):** `src/core/database/db.ts`에서 `statement_timeout`을 pg Pool startup 옵션에서 제거(현재 풀러 ignore로 동작하므로 기능 무영향). 기존 통합 테스트(직결 createTestPool은 helpers.ts라 무영향) 그린 유지. TDD: db.ts 단위 테스트가 statement_timeout 미전송을 단언.

**Step 5: Commit** — `refactor: page DB 클라이언트 풀러-안전화(statement_timeout startup 미전송)`

---

## 검증 / 롤백 / 비범위

- **검증:** WS1=bats(wave 순서)+카나리 온보딩 시 비번 인증 성공 실증. WS2=카나리 `/ready` 그린 + 회귀 리허설 알림. WS3=스캐폴드 산출물 단위테스트.
- **롤백 (adversarial pass3-F3 — PR revert만으로는 라이브 상태가 안 지워짐):**
  - **WS1**: provision-db/게이트 PR은 git revert. 라이브 SealedSecret의 wave annotation은 `yq -i`로 역제거(암호문 불변). `ensure-role-password` PostSync Job은 manifest 제거 또는 `argocd.argoproj.io/hook` 비활성으로 끔; 부분 실패(Job가 Secret을 annotate한 상태) 복구는 멱등이라 재실행/무해. **CNPG Database는 `databaseReclaimPolicy: retain`** 이라 PR revert로 안 지워짐 — 제거는 **teardown-app(ensure: absent 전환)** 절차로만.
  - **WS2**: 앱 PR git revert + ArgoCD prune. **카나리 DB(example-api)는 retain** — teardown-app으로 absent 전환해 명시적 제거(혹은 의도적으로 보존). conn SealedSecret도 teardown 산출물로 정리.
  - **WS3**: 템플릿 변경 revert는 **신규 스캐폴드에만** 영향(기존 앱 무영향).
  - 각 WS revert 후 ArgoCD가 Synced/Healthy로 수렴하는지 확인(반자동 prune 기대치 명시).
- **비범위(YAGNI):** #4(풀러, #145 완료)·page 재배포(동작 중)·CI 라이브 conn 검증(러너가 풀러 도달 불가→카나리 대체).
- **순서 권고:** WS1 → WS2(WS1 wave를 카나리로 실증) → WS3. WS3 Task 9는 선택.

---

## Adversarial review dispositions

codex 적대적 리뷰 4패스(3패스 cap + 사용자 승인 2패스 추가). 결함이 3→2→3→1로 수렴. 모든 finding을 Accept(반려 0 — 전부 근거 있고 위험 감소).

| Pass | Finding | Sev | 판정 | 반영 |
|---|---|---|---|---|
| 1 | 잔여 SealedSecret→Secret 레이스가 차단 게이트 아님 | high | Accept | WS1 필수 게이트화 + Task 2b 결정적 fallback 신설 |
| 1 | 공유 라이브 Pooler 변형 회귀 리허설(복구경로 없음) | high | Accept | 파괴적 리허설 제거 → 비파괴(정적 bats + 카나리 양성), 격리 Pooler만 허용 |
| 1 | DB백업 example-api가 endpoint 깨진 채 green 가능 | med | Accept | todos 미변경 + 분리된 카나리 DB 모듈(idempotent DDL·스키마 의존 readiness) |
| 2 | 결정적 비번 복구가 (조건부)선택 | high | Accept | ensure-role-password를 무조건·멱등·fail-closed 차단 단계로 |
| 2 | bats 게이트 vs 레거시 레트로핏(선택) 모순 | med | Accept | page 레트로핏을 게이트 전 필수 마이그레이션으로 |
| 3 | 비번 보장이 실행가능 create-database 경로 미배선(CI 클러스터 무접근) | high | Accept | 인클러스터 ArgoCD PostSync Job + SA/RBAC + fail-closed 실행모델 명세 |
| 3 | 카나리 DB명 모호("또는 canary") | med | Accept | `example-api`로 단일화·전파 |
| 3 | 롤백이 영속 라이브 부작용 무시 | med | Accept | 워크스트림별 구체 롤백(retain DB는 teardown-app, annotation yq 역적용 등) |
| 4 | 온보딩 게이트가 stale/무관 신호로 통과 가능(레이스) | high | Accept | per-DB freshness 마커(`db-<name>-ready` + resourceVersion 일치) + activation이 이를 소비 |

**최종 리뷰 상태(정직):** 마지막 실행(pass 4) `verdict: needs-attention`(해당 1건은 직후 반영). pass 4의 픽스는 **사용자 결정("반영 후 확정")에 따라 5차 재검증 없이 확정** — codex로 재승인된 상태는 아님. 잔여 위험은 실행 세션의 TDD·라이브 수용기준(per-DB 마커·풀러 인증 성공)으로 확인한다.

## Execution directives
- **Skill:** `executing-plans`로 **별도 세션, 이 워크트리**(`~/.config/superpowers/worktrees/homelab/hardening`, 브랜치 `hardening/platform-recurrence`)에서 구현.
- **연속 실행:** 배치 사이에 일상 리뷰로 멈추지 말 것. 진짜 블로커(의존성 누락·반복 실패하는 검증·모순/불명확 지시·치명적 계획 공백)에서만 멈춤. 그 외엔 끝까지.
- **멀티레포 주의:** homelab(주) + ukyi-app/example-api(WS2) + ukyi-app/homelab-app-template(WS3) + (선택)page. 각 레포는 자체 클론/PR. homelab main 보호 → 전부 PR. 라이브 클러스터 검증은 OrbStack `k3s` 머신(`orb -m k3s -u root k3s kubectl ...`)으로.
- **커밋 — 직접 적용(`Skill(commit)` 호출 금지):**
  - 한국어 메시지. **AI 마커 금지**(`🤖 Generated with`/`Co-Authored-By: Claude` 등 절대 금지).
  - 형식 `<type>(<scope>): 한국어 설명` (+ 필요시 `- 상세` 본문).
  - type은 `feat|fix|refactor|docs|style|test|chore`만. `perf`/`build`/`ci` 등 금지.
  - 그룹핑: 같은 디렉터리·목적 → 한 커밋; 서로 의존하는 파일 → 한 커밋; 독립 설명 가능한 변경 → 별도 커밋; config/test/docs/style은 각각 분리.
  - 위치: 각 Task의 Commit 단계에서 현재 feature 브랜치 워크트리에 커밋(이미 main 밖).
