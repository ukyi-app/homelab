# tools CLI lib SSOT 수렴 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** `tools/` CLI에 흩어진 5종 중복 로직(식별자 검증·kubeseal 봉인·원장 행·kustomization 편집·인자 파싱)을 `tools/lib/` 단일 모듈로 수렴하고, 수렴 과정에 드러난 2개 잠복 버그(원장 예산 누수·arg 삼킴)를 고친다.

**Architecture:** `tools/lib/`에 모듈 5개 — 기존 `identity.ts`·`ledger-totals.ts` 확장 + 신설 `seal.ts`·`kustomization.ts`·`cli.ts`(전부 `.ts`, homelab 전용). 발산하는 검증은 **느슨→엄격**으로 통일(유효 입력 동작보존, 경계 입력은 의도적 거부). 각 모듈은 TDD: 현재 동작 고정 테스트 → 추출 → 콜사이트 이주 → parity + 하드닝 테스트.

**Tech Stack:** Bun 1.3.x, TypeScript, `yaml` 2.x, bats. lib 5종은 전부 `.ts`(homelab 전용). **app-shared `.mts`(seal-secret·env-example)는 미수정** — app-starter 템플릿 동봉 self-contained라 homelab lib import 금지(Pass1 F3).

**설계 출처:** `docs/plans/2026-06-20-tools-cli-lib-ssot-design.md` (커밋 `8ae56f2` + D1 정정 `dced486`). 결정: D1=seal/cli **`.ts`**·homelab 전용(app-shared .mts 미수정), D2=RESOURCE_NAME_RE ≤30·single-char·no-trail, D3=EXT_RE 포함.

---

## 작업 전 공통 규칙 (모든 Task)

- **bats `@test` 이름은 영어만** — 디렉토리 단위 실행 시 한글 이름 인코딩 깨짐(검증된 함정).
- **bats 중간 단언은 `[ ]`만** — bash 3.2에서 `[[ ]]` 실패가 침묵 통과(set -e가 compound 무시).
- **하네스 셸은 zsh** — `bun -e '...'`의 작은따옴표 안은 셸 보간 안 됨(파일 경로는 `process.argv`로 전달, 기존 `test_ledger-totals.bats` 패턴).
- **app-shared `.mts` 미수정**(Pass1 F3): `seal-secret.mts`·`env-example.mts`는 외부 앱 레포로 배포되는 self-contained 스크립트라 homelab-local lib(`tools/lib/*`)를 import하면 앱 레포 번들서 깨진다 → **건드리지 않는다**(자체 kubeseal/arg 파싱 유지). 신설 lib 5종은 전부 `.ts`(homelab 전용).
- 단위 테스트 실행: `bats tools/tests/<file>.bats` (영향분만 — 전체 run-bats는 Task 6 게이트에서).
- 시크릿 비노출 불변: kubeseal 입력/출력 평문은 stdout/로그/디스크에 절대 안 나간다.
- **TS strict 통과**(F11 — `make ci`=`tsc --strict --noEmit`, tsconfig `strict:true`): `.ts` 소스의 catch 변수는 `unknown`이라 `catch (e) { fail(e instanceof Error ? e.message : String(e)); }`로 감싼다(직접 `e.message` 금지). bats `bun -e` 인라인 스크립트는 typecheck 대상 아님(무관).
- **커밋**: 한국어 conventional, AI 마커 금지. type = feat/fix/refactor/docs/style/test/chore만. 추출=`refactor:`, 명시 버그수정=`fix:`.

---

## Task 1: `identity.ts` — RESOURCE_NAME_RE + EXT_RE 수렴

식별자 검증 발산(3형태)을 SSOT로. 느슨한 4콜사이트가 엄격해진다(trailing hyphen·>30 거부). 기존 `APP_NAME_RE`는 불변.

**Files:**
- Modify: `tools/lib/identity.ts` (추가)
- Modify: `tools/validate-mutation.ts:31,35,36`
- Modify: `tools/db-url.ts:22`
- Modify: `tools/cache-url.ts:19`
- Modify: `tools/teardown-resource.ts:43`
- Modify: `tools/provision-db.ts:49,50,55`
- Modify: `tools/provision-cache.ts:41`
- Test: `tools/tests/test_identity.bats` (확장)

**Step 1: 실패 테스트 작성** — `tools/tests/test_identity.bats`에 아래 `@test` 추가:

```bash
@test "identity exports RESOURCE_NAME_RE (no trailing hyphen, 1..30, single-char ok)" {
  run bun -e '
    import { RESOURCE_NAME_RE } from "./tools/lib/identity.ts";
    const ok  = ["a", "db1", "my-cache", "x".repeat(30)];          // 1자/kebab/30자 유효
    const bad = ["-x", "x-", "Bad", "a_b", "x".repeat(31)];        // 선후행 하이픈/대문자/언더스코어/31자
    for (const s of ok)  if (!RESOURCE_NAME_RE.test(s)) { console.error("FALSE NEG:", s); process.exit(1); }
    for (const s of bad) if (RESOURCE_NAME_RE.test(s))  { console.error("FALSE POS:", s); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}

@test "identity exports EXT_RE (postgres extension names allow underscore)" {
  run bun -e '
    import { EXT_RE } from "./tools/lib/identity.ts";
    const ok  = ["pg_trgm", "uuid-ossp", "postgis"];
    const bad = ["-x", "Bad", "a b", "a;b"];
    for (const s of ok)  if (!EXT_RE.test(s)) { console.error("FALSE NEG:", s); process.exit(1); }
    for (const s of bad) if (EXT_RE.test(s))  { console.error("FALSE POS:", s); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}
```

**Step 2: 실패 확인** — `bats tools/tests/test_identity.bats` → 새 2건 FAIL("RESOURCE_NAME_RE undefined" 등). 기존 3건은 PASS 유지.

**Step 3: 모듈 구현** — `tools/lib/identity.ts`에 추가(기존 `APP_NAME_RE` 아래):

```typescript
// db/cache 리소스 이름 SSOT — provision-db/provision-cache(실행기)·validate-mutation(디스패처)·
// db-url/cache-url/teardown-resource(소비자)가 공유. 정책: 소문자 시작, kebab, trailing hyphen 금지,
// 길이 1..30(single-char 허용·k8s 파생명 db-<name>-ro-conn ≤63 여유). 디스패처가 느슨하면
// 통과시킨 이름을 실행기가 거부하는 계약 갭이 생긴다 — 한 곳에서만 정의한다.
export const RESOURCE_NAME_RE = /^[a-z]([a-z0-9-]{0,28}[a-z0-9])?$/;

// postgres extension 이름 — underscore 허용(pg_trgm 등). validate-mutation·provision-db 공유.
export const EXT_RE = /^[a-z][a-z0-9_-]*$/;
```

**Step 4: 통과 확인** — `bats tools/tests/test_identity.bats` → 새 2건 PASS.

**Step 5: 콜사이트 이주** — 각 파일에서 인라인 정규식 제거 + import. (이주 후 동작: 느슨하던 곳은 엄격해짐 = 의도된 하드닝.)

- `tools/db-url.ts:22` — `import { RESOURCE_NAME_RE } from "./lib/identity.ts";` 추가, `!/^[a-z][a-z0-9-]*$/.test(name)` → `!RESOURCE_NAME_RE.test(name)`.
- `tools/cache-url.ts:19` — 동일.
- `tools/teardown-resource.ts:43` — `!/^[a-z][a-z0-9-]*$/.test(name)` → `!RESOURCE_NAME_RE.test(name)` + import.
- `tools/provision-db.ts` — `import { RESOURCE_NAME_RE, EXT_RE } from "./lib/identity.ts";` 추가. L49 `const NAME_RE = ...` 삭제, L50 `const EXT_RE = ...` 삭제. L55 `if (!NAME_RE.test(name) || name.length > 30)` → `if (!RESOURCE_NAME_RE.test(name))`(≤30 포함, length 체크 제거). **L60 `if (!NAME_RE.test(args.cluster))` → `if (!RESOURCE_NAME_RE.test(args.cluster))`**(F10 — cluster도 NAME_RE를 쓰므로 함께 이주, NAME_RE 삭제 시 undefined 참조 방지. cluster는 **format만** — `resourceNameError("db",…)`를 쓰면 안 됨[기본 cluster명 'pg'가 DB_RESERVED라 거부됨]). L62 `EXT_RE`는 import분 사용(const 삭제만).
- `tools/provision-cache.ts:41` — `!/^[a-z]([a-z0-9-]{0,27}[a-z0-9])?$/.test(name)` → `!RESOURCE_NAME_RE.test(name)` + import. (≤29 → ≤30 정합.)
- `tools/validate-mutation.ts` — `import { APP_NAME_RE, RESOURCE_NAME_RE, EXT_RE } from "./lib/identity.ts";` (기존 APP_NAME_RE import에 합침). L31 `resource: /^(db|cache):[a-z][a-z0-9-]*$/` → `resource: new RegExp(\`^(db|cache):${RESOURCE_NAME_RE.source.slice(1, -1)}$\`)` (RESOURCE_NAME_RE 본문 재사용 — `.source`는 `^...$`라 slice(1,-1)로 앵커 제거). L35 `const NAME_RE = /^[a-z][a-z0-9-]*$/` 삭제, L53 `NAME_RE.test(...)` → `RESOURCE_NAME_RE.test(...)`. L36 `const EXT_RE = ...` 삭제(import 사용).

**Step 6: 하드닝/잔존 테스트 추가** — `tools/tests/test_identity.bats`에:

```bash
@test "resource callsites import RESOURCE_NAME_RE (no inline loose resource regex left)" {
  # 느슨한 ^[a-z][a-z0-9-]*$ 가 리소스 검증 파일에서 사라졌는지(seal-secret.mts는 secret 키名이라 제외)
  run grep -nE '\^\[a-z\]\[a-z0-9-\]\*\$' \
    tools/db-url.ts tools/cache-url.ts tools/teardown-resource.ts tools/validate-mutation.ts
  [ "$status" -ne 0 ]
  for f in db-url cache-url teardown-resource validate-mutation provision-db provision-cache; do
    run grep -q "lib/identity.ts" "tools/$f.ts"
    [ "$status" -eq 0 ]
  done
}

@test "EXT_RE has no inline duplicate left (validate-mutation, provision-db)" {
  run grep -nE 'a-z0-9_-\]\*\$/' tools/validate-mutation.ts tools/provision-db.ts
  [ "$status" -ne 0 ]
}

@test "provision-cache now rejects a >30-char name (29->30 tightening consistent)" {
  run bun tools/provision-cache.ts --name "$(printf 'a%.0s' {1..31})" --dry-run
  [ "$status" -ne 0 ]
}

@test "teardown-resource now rejects a trailing-hyphen resource name" {
  run bun tools/teardown-resource.ts --db bad- --dry-run
  [ "$status" -ne 0 ]
}

@test "provision-db still validates --cluster after NAME_RE removal (F10)" {
  run bun tools/provision-db.ts --name blog --cluster 'Bad Cluster' --dry-run
  [ "$status" -ne 0 ]
}
```

**Step 7: 전체 영향분 테스트** — parity 확인:
```
bats tools/tests/test_identity.bats tools/tests/test_validate-mutation.bats \
     tools/tests/test_provision-db.bats tools/tests/test_provision-cache.bats \
     tools/tests/test_teardown.bats
```
Expected: 전부 PASS. 만약 기존 provision-db/cache 테스트가 정확히 ≤29/≤30 경계나 length>30 메시지를 단언하면 그 단언만 새 정책(≤30·통일 메시지)에 맞춰 갱신(동작보존 원칙 — 유효 입력 동일, 경계만 조정).

**Step 8: 커밋**
```bash
git add tools/lib/identity.ts tools/validate-mutation.ts tools/db-url.ts tools/cache-url.ts \
        tools/teardown-resource.ts tools/provision-db.ts tools/provision-cache.ts tools/tests/test_identity.bats
git commit -m "refactor: 리소스 식별자 정규식을 identity.ts RESOURCE_NAME_RE/EXT_RE로 수렴

- db/cache 이름 검증 3형태(느슨/≤30/≤29) 발산을 ≤30 단일 정책으로 통일
- 느슨한 콜사이트(db-url/cache-url/validate-mutation/teardown-resource) trailing hyphen·초과길이 거부
- EXT_RE 2중복(validate-mutation·provision-db) 제거"
```

---

## Task 1.5: reserved 이름 정책 수렴 (Pass2 F5)

정규식만으로는 디스패처/실행기 갭이 남는다 — 실행기(provision-db `RESERVED`·provision-cache `-ro`)의 예약 정책을 디스패처(validate-mutation)가 모른다. 예약 정책도 SSOT로 끌어올려 디스패처가 fail-fast.

**Files:**
- Modify: `tools/lib/identity.ts` (추가)
- Modify: `tools/validate-mutation.ts` (create-database/create-cache spec.name)
- Modify: `tools/provision-db.ts` (로컬 `RESERVED` → 공유)
- Modify: `tools/provision-cache.ts` (`-ro` → 공유)
- Test: `tools/tests/test_identity.bats` + `tools/tests/test_mutation-dispatch.bats` (확장)

**Step 1: 실패 테스트 작성**

```bash
# test_identity.bats
@test "resourceNameError flags db reserved names and cache -ro suffix" {
  run bun -e '
    import { resourceNameError } from "./tools/lib/identity.ts";
    if (resourceNameError("db", "blog") !== null) { console.error("valid db rejected"); process.exit(1); }
    if (resourceNameError("db", "postgres") === null) { console.error("reserved db accepted"); process.exit(1); }
    if (resourceNameError("cache", "widget") !== null) { console.error("valid cache rejected"); process.exit(1); }
    if (resourceNameError("cache", "foo-ro") === null) { console.error("cache -ro accepted"); process.exit(1); }
    if (resourceNameError("db", "foo-ro") === null) { console.error("db -ro accepted (F8)"); process.exit(1); }
    if (resourceNameError("db", "bad-") === null) { console.error("trailing hyphen accepted"); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}
```
```bash
# test_mutation-dispatch.bats — 디스패처가 실행기보다 먼저 예약 거부
@test "dispatcher rejects a reserved db name before the executor" {
  run bun tools/validate-mutation.ts --action create-database --payload '{"spec":"{\"name\":\"postgres\"}"}'
  [ "$status" -ne 0 ]
}
@test "dispatcher rejects a cache -ro suffix name" {
  run bun tools/validate-mutation.ts --action create-cache --payload '{"spec":"{\"name\":\"foo-ro\"}"}'
  [ "$status" -ne 0 ]
}
@test "dispatcher rejects a db -ro suffix name (F8)" {
  run bun tools/validate-mutation.ts --action create-database --payload '{"spec":"{\"name\":\"foo-ro\"}"}'
  [ "$status" -ne 0 ]
}
```

**Step 2: 실패 확인** — resourceNameError 없음 / 디스패처가 아직 예약 미검사로 FAIL.

**Step 3: 모듈 구현** — `tools/lib/identity.ts`에 추가:

```typescript
// db/cache 예약 이름 — 실행기·디스패처 공유(둘이 다르면 디스패처 통과→실행기 거부 갭).
// db: 시스템 롤/DB·bootstrap initdb(app)와 충돌하면 클러스터가 깨진다.
export const DB_RESERVED_NAMES = new Set(["app", "postgres", "pg", "template0", "template1", "streaming_replica"]);

// 리소스 이름 정책(형식 + 예약) 단일 검사. null=유효, 아니면 거부 사유.
//   '-ro' 접미사: db·cache 공통 예약(foo-ro의 conn이 foo의 읽기전용 conn과 충돌 — provision-db/cache 양쪽에 있던 가드, F8).
export function resourceNameError(kind: "db" | "cache", name: string): string | null {
  if (!RESOURCE_NAME_RE.test(name)) return `이름 형식 불량(소문자 kebab, trailing hyphen 금지, ≤30): ${name}`;
  if (/-ro$/.test(name)) return `'-ro' 접미사 예약: ${name} (읽기전용 conn 이름과 충돌)`;   // db·cache 공통(F8)
  if (kind === "db" && DB_RESERVED_NAMES.has(name)) return `예약된 DB 이름: ${name}`;
  return null;
}
```

**Step 4: 통과 확인** — test_identity.bats 예약 단위 테스트 PASS.

**Step 5: 콜사이트 이주**
- `tools/validate-mutation.ts` — `resourceNameError`를 import. `validateSpec`의 spec.name 검증에서 `RESOURCE_NAME_RE.test` 단독 → `const err = resourceNameError(kind, name); if (err) die(err)`. (kind: create-database→`"db"`, create-cache→`"cache"`.) 디스패처가 예약 이름을 실행기 전에 거부.
- `tools/provision-db.ts` — 로컬 `RESERVED` set + `-ro` 체크(L57-59) + name 검증을 `resourceNameError("db", name)`로 일원화(import, 기존 `RESERVED.has`·`/-ro$/` 분기 제거). **resourceNameError가 `-ro`를 db에도 적용하므로 기존 가드 보존(F8)**.
- `tools/provision-cache.ts` — `/-ro$/` 체크 + 형식 검증을 `resourceNameError("cache", name)`로 일원화.

**Step 6: 잔존 테스트** — `tools/tests/test_identity.bats`에:
```bash
@test "executors use shared reserved policy (no local RESERVED/-ro check left)" {
  run grep -Fq 'resourceNameError' tools/provision-db.ts;        [ "$status" -eq 0 ]
  run grep -Fq '"streaming_replica"' tools/provision-db.ts;      [ "$status" -ne 0 ]   # 로컬 RESERVED 리터럴 제거
  run grep -Fq '/-ro$/' tools/provision-db.ts;                   [ "$status" -ne 0 ]   # provision-db 로컬 -ro 제거(F8)
  run grep -Fq '/-ro$/' tools/provision-cache.ts;                [ "$status" -ne 0 ]   # provision-cache 로컬 -ro 제거
  run grep -Fq 'resourceNameError' tools/validate-mutation.ts;   [ "$status" -eq 0 ]
}
```

**Step 7: 영향분 테스트** — `bats tools/tests/test_identity.bats tools/tests/test_mutation-dispatch.bats tools/tests/test_provision-db.bats tools/tests/test_provision-cache.bats` → PASS.

**Step 8: 커밋**
```bash
git add tools/lib/identity.ts tools/validate-mutation.ts tools/provision-db.ts tools/provision-cache.ts \
        tools/tests/test_identity.bats tools/tests/test_mutation-dispatch.bats
git commit -m "refactor: 리소스 예약 이름 정책을 identity.ts resourceNameError로 수렴(F5·F8)

- db RESERVED·'-ro' 접미사(db·cache 공통)를 실행기에서 디스패처로 끌어올려 계약 갭 폐쇄
- 디스패처가 예약 이름을 실행기 전에 fail-fast"
```

---

## Task 1.6: 워크플로 인라인 정규식 동기화 (Pass4 F9)

`_create-cache.yaml`·`_create-database.yaml`은 비신뢰 입력 재검증용 인라인 정규식 **복사본**을 갖는다(TS lib import 불가 콜사이트 — defense-in-depth, `_create-cache.yaml:1-3` 명시). ≤30 정책과 동기화하고 guard 테스트로 드리프트 차단. **둘 다 fail-closed**(provision-\*가 재검증)라 보안 회귀는 아니지만 SSOT 배포성 정합.

**Files:**
- Modify: `.github/workflows/_create-cache.yaml:43`
- Modify: `.github/workflows/_create-database.yaml:43`
- Test: `tools/tests/test_mutation-dispatch.bats` (확장)

**주의:** `.github/`는 ArgoCD 미싱크(라이브 무영향, CI 전용). 워크플로 파일 변경 push는 `workflows:write` 필요 — **owner 로컬 머지**(App 토큰 auto-merge는 workflows:write 없어 불가). theme3는 owner-driven이라 무방.

**Step 1: 실패 테스트 작성** — guard(옛 패턴 잔존 0, 새 ≤30 존재):
```bash
@test "workflow inline name regex matches the <=30 SSOT policy (no stale copy)" {
  for wf in _create-cache _create-database; do
    run grep -Fq '{0,28}' ".github/workflows/$wf.yaml"; [ "$status" -eq 0 ]            # ≤30(RESOURCE_NAME_RE와 동일) 존재
  done
  run grep -Fq '{0,27}' .github/workflows/_create-cache.yaml; [ "$status" -ne 0 ]        # 옛 ≤29 제거
  run grep -Fq '[a-z0-9-]*[a-z0-9]' .github/workflows/_create-database.yaml; [ "$status" -ne 0 ]  # 옛 무제한 제거
}
```

**Step 2: 실패 확인** — 옛 `{0,27}`·무제한 grep 잔존으로 FAIL.

**Step 3: 동기화**
- `_create-cache.yaml:43` — `/^[a-z]([a-z0-9-]{0,27}[a-z0-9])?$/` → `/^[a-z]([a-z0-9-]{0,28}[a-z0-9])?$/` (RESOURCE_NAME_RE와 동일, ≤30).
- `_create-database.yaml:43` — shell grep `^[a-z]([a-z0-9-]*[a-z0-9])?$`(무제한) → `grep -Eq '^[a-z]([a-z0-9-]{0,28}[a-z0-9])?$'` (ERE 한정수량자, ≤30).

> **주의:** 워크플로 인라인은 tool import 불가라 정규식이 SSOT의 **동기화 복사본**이다(app-shared .mts와 동류). guard 테스트가 드리프트를 차단. reserved/`-ro`는 워크플로가 검사 안 해도 provision-\*가 fail-closed로 잡으므로 **길이/형식만 동기화하면 충분**.

**Step 4: 통과 확인** — guard 테스트 PASS.

**Step 5: 영향분** — `bats tools/tests/test_mutation-dispatch.bats`. 가능하면 `actionlint`로 워크플로 문법 확인(YAML 인라인 스크립트 변경).

**Step 6: 커밋**
```bash
git add .github/workflows/_create-cache.yaml .github/workflows/_create-database.yaml tools/tests/test_mutation-dispatch.bats
git commit -m "fix: 워크플로 인라인 리소스명 정규식을 ≤30 정책에 동기화(F9)

- _create-cache {0,27}→{0,28}, _create-database 무제한→{0,28}
- guard 테스트로 SSOT 드리프트 차단(워크플로 YAML은 TS import 불가 복사본)"
```

---

## Task 2: `seal.ts` — kubeseal 봉인 SSOT

바이트 동일 봉인 블록을 `.ts` 단일 함수로 — provision-db·provision-cache 2곳만(seal-secret.mts는 app-shared라 **미수정**, Pass1 F3).

**Files:**
- Create: `tools/lib/seal.ts`
- Modify: `tools/provision-db.ts:134-141`
- Modify: `tools/provision-cache.ts:217-224`
- Test: `tools/tests/test_seal-lib.bats` (신규)

**Step 1: 실패 테스트 작성** — `tools/tests/test_seal-lib.bats` 신규(kubeseal 부재 환경 고려 — 함수 시그니처/에러 경로만 단언, 실제 봉인은 통합 테스트가 커버):

```bash
#!/usr/bin/env bats
# kubeseal 봉인 SSOT(tools/lib/seal.ts) — 평문은 stdin으로만, 디스크/stdout 비기록.
# ⚠️ 중간 단언은 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "seal.ts exports sealManifest and fails loud on missing cert" {
  run bun -e '
    import { sealManifest } from "./tools/lib/seal.ts";
    try { sealManifest({ kind: "Secret" }, "/nonexistent/cert.pem"); console.log("DID-NOT-THROW"); }
    catch (e) { console.log("threw"); }
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^threw$"
}
```

**Step 2: 실패 확인** — `bats tools/tests/test_seal-lib.bats` → FAIL(모듈 없음).

**Step 3: 모듈 구현** — `tools/lib/seal.ts` (provision-db:134-141 패턴 그대로):

```typescript
// kubeseal 봉인 SSOT — 평문 Secret manifest를 디스크에 쓰지 않고 kubeseal stdin으로만 흘려
// 봉인 YAML을 반환한다. provision-db/provision-cache 공용(homelab 전용 .ts).
// ⚠️ 평문은 절대 stdout/예외메시지에 안 싣는다. (app-shared seal-secret.mts는 자체 블록 유지 — Pass1 F3.)
import { spawnSync } from "node:child_process";

export function sealManifest(manifest: object, certPath: string): string {
  const res = spawnSync("kubeseal", ["--cert", certPath, "--format", "yaml"], {
    input: JSON.stringify(manifest), // kubeseal은 JSON manifest도 받는다(YAML 슈퍼셋)
    encoding: "utf8",
  });
  if (res.error) throw new Error(`kubeseal 실행 실패: ${res.error.message}`);
  if (res.status !== 0) throw new Error(`kubeseal 종료 코드 ${res.status} — cert(${certPath})/컨트롤러 점검 (stderr는 값 미포함 시에만)`);
  return res.stdout;
}
```

**Step 4: 통과 확인** — `bats tools/tests/test_seal-lib.bats` → PASS.

**Step 5: 콜사이트 이주** — provision-db·provision-cache에서만 인라인 `spawnSync("kubeseal", ...)` 블록 제거 + `sealManifest` 호출. 기존 에러 메시지·종료 코드 계약 유지(각 파일의 `fail()`로 감싸 기존 exit code 보존):
- `tools/provision-db.ts:134-141` — `import { sealManifest } from "./lib/seal.ts";` 추가. 인라인 봉인을 `try { sealed = sealManifest(manifest, certPath); } catch (e) { fail(e instanceof Error ? e.message : String(e)); }`로(strict catch, F11). (기존 stdout 비노출·partial 산출 방지 순서 유지 — 봉인 먼저, 파일 쓰기 나중: L152 주석.)
- `tools/provision-cache.ts:217-224` — 동일 패턴(`CERT` 변수 사용).
- **`tools/seal-secret.mts`는 건드리지 않는다**(Pass1 F3) — app-shared(외부 앱 레포 배포)라 자체 kubeseal 블록 유지. 이 파일의 변경 0을 `git diff --stat`으로 확인.

**Step 6: 잔존 테스트 추가** — `tools/tests/test_seal-lib.bats`에:

```bash
@test "provision callsites use sealManifest (no inline kubeseal spawnSync left)" {
  run grep -nE 'spawnSync\("kubeseal"' tools/provision-db.ts tools/provision-cache.ts
  [ "$status" -ne 0 ]
  for f in provision-db.ts provision-cache.ts; do
    run grep -q "lib/seal.ts" "tools/$f"
    [ "$status" -eq 0 ]
  done
}

@test "app-shared seal-secret.mts keeps its own kubeseal block (NOT migrated, F3)" {
  # 외부 앱 레포 배포 self-contained — homelab lib import 금지
  run grep -nE 'spawnSync\("kubeseal"' tools/seal-secret.mts
  [ "$status" -eq 0 ]
  run grep -q "lib/seal" tools/seal-secret.mts
  [ "$status" -ne 0 ]
}
```

**Step 7: 영향분 테스트** — `bats tools/tests/test_seal-lib.bats tools/tests/test_seal-secret.bats tools/tests/test_provision-db.bats tools/tests/test_provision-cache.bats` → 전부 PASS(provision dry-run은 kubeseal 미호출 경로라 영향 없음 확인).

**Step 8: 커밋**
```bash
git add tools/lib/seal.ts tools/provision-db.ts tools/provision-cache.ts tools/tests/test_seal-lib.bats
git commit -m "refactor: kubeseal 봉인을 seal.ts sealManifest로 수렴

- provision-db/provision-cache 바이트 동일 봉인 블록 단일화(homelab 전용 .ts)
- app-shared seal-secret.mts는 외부 앱 레포 배포라 미수정(자체 블록 유지)"
```

---

## Task 3: `ledger-totals.ts` — addRow/removeRow + 원장 예산 누수 수정(fix)

원장 행 파싱/삽입/제거를 SSOT로. **teardown-resource purge가 cache 행을 제거하지 않던 누수(거짓 budget초과)를 고친다.**

**Files:**
- Modify: `tools/lib/ledger-totals.ts` (추가)
- Modify: `tools/create-app.ts:124,211-213`
- Modify: `tools/audit-orphans.ts:123`
- Modify: `tools/provision-cache.ts:62,334` (cache 행 파싱/삽입)
- Modify: `tools/teardown-resource.ts:159-174` (cleanup cache → removeRow, **버그 수정**)
- Test: `tools/tests/test_ledger-totals.bats` (확장)

**Step 1: 실패 테스트 작성** — `tools/tests/test_ledger-totals.bats`에 추가:

```bash
@test "addRow inserts a ledger row after the last existing row" {
  run bun -e '
    import("file://" + process.argv[1]).then(m => {
      const base = "| <!-- ledger:row --> blog           | prod           |    128 |      256 |\n";
      const out = m.addRow(base, { name: "shop", env: "prod", reqMi: 64, limitMi: 128 });
      if (!/<!-- ledger:row --> shop/.test(out)) { console.error("no-insert"); process.exit(1); }
      if ((out.match(/ledger:row/g) || []).length !== 2) { console.error("count"); process.exit(1); }
      console.log("ok");
    }).catch(e => { console.error(e.message); process.exit(1); });
  ' "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}

@test "removeRow removes the named row and throws fail-loud when absent" {
  run bun -e '
    import("file://" + process.argv[1]).then(m => {
      const base = "| <!-- ledger:row --> blog           | prod |  128 |  256 |\n| <!-- ledger:row --> shop           | prod |   64 |  128 |\n";
      const out = m.removeRow(base, "shop");
      if (/ledger:row --> shop/.test(out)) { console.error("not-removed"); process.exit(1); }
      if (!/ledger:row --> blog/.test(out)) { console.error("over-removed"); process.exit(1); }
      try { m.removeRow(base, "nope"); console.log("DID-NOT-THROW"); }
      catch { console.log("ok"); }
    }).catch(e => { console.error(e.message); process.exit(1); });
  ' "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}

@test "parseLedgerRows returns named fields (name/env/reqMi/limitMi) with correct numbers" {
  run bun -e '
    import("file://" + process.argv[1]).then(m => {
      const t = "| <!-- ledger:row --> blog           | prod           |    128 |      256 |\n";
      const rows = m.parseLedgerRows(t); const r = rows[0];
      if (rows.length !== 1 || r.name !== "blog" || r.env !== "prod" || r.reqMi !== 128 || r.limitMi !== 256) { console.error(JSON.stringify(rows)); process.exit(1); }
      console.log("ok");
    }).catch(e => { console.error(e.message); process.exit(1); });
  ' "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}

@test "addRow then parseLedgerRows yields exact summed totals (catches index drift)" {
  run bun -e '
    import("file://" + process.argv[1]).then(m => {
      let t = "| <!-- ledger:row --> blog           | prod           |    100 |      200 |\n";
      t = m.addRow(t, { name: "shop", env: "prod", reqMi: 30, limitMi: 70 });
      const rows = m.parseLedgerRows(t);
      const sumReq = rows.reduce((a,r)=>a+r.reqMi,0), sumLimit = rows.reduce((a,r)=>a+r.limitMi,0);
      if (sumReq !== 130 || sumLimit !== 270) { console.error(sumReq+"/"+sumLimit); process.exit(1); }
      console.log("ok");
    }).catch(e => { console.error(e.message); process.exit(1); });
  ' "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}
```

**Step 2: 실패 확인** — `bats tools/tests/test_ledger-totals.bats` → 새 4건 FAIL.

**Step 3: 모듈 구현** — `tools/lib/ledger-totals.ts`에 추가(기존 `replaceTotals` 유지). 행 포맷은 create-app:213의 `padEnd(14)`/`padStart(6)`/`padStart(8)`을 정확히 보존. **F7(Pass3): 캡처 인덱스 raw 접근 금지 — 콜사이트는 `parseLedgerRows` 명명 필드만 쓴다**(env를 캡처로 추가하면 기존 `m[2]/m[3]`=req/limit 루프가 NaN/undercount로 깨져 예산 게이트 손상):

```typescript
// 원장 행 SSOT — 행 형식: | <!-- ledger:row --> <name padEnd14> | <env padEnd14> | <req padStart6> | <limit padStart8> |
// LEDGER_ROW_RE는 모듈 내부 전용 — 콜사이트는 raw 인덱스 대신 parseLedgerRows(명명 필드)를 쓴다(F7).
const LEDGER_ROW_RE = /<!-- ledger:row --> *([a-z0-9+-]+) *\| *([a-z-]+) *\| *(\d+) *\| *(\d+) *\|/g;

// 캐노니컬 파서 — audit-orphans(name|type)·create-app/provision-cache(name|type|req|limit) 변형 통일.
// String.matchAll은 정규식을 복제하므로 공유 /g lastIndex 오염 없음.
export function parseLedgerRows(text: string): { name: string; env: string; reqMi: number; limitMi: number }[] {
  const rows: { name: string; env: string; reqMi: number; limitMi: number }[] = [];
  for (const m of text.matchAll(LEDGER_ROW_RE)) rows.push({ name: m[1], env: m[2], reqMi: +m[3], limitMi: +m[4] });
  return rows;
}

export function addRow(text: string, row: { name: string; env: string; reqMi: number; limitMi: number }): string {
  const lines = text.split("\n");
  const lastRow = lines.map((l, i) => (l.includes("<!-- ledger:row -->") ? i : -1)).filter((i) => i >= 0).pop();
  if (lastRow === undefined) throw new Error("원장에 ledger:row 행이 없어 삽입 위치를 못 찾음");
  const formatted = `| <!-- ledger:row --> ${row.name.padEnd(14)} | ${row.env.padEnd(14)} | ${String(row.reqMi).padStart(6)} | ${String(row.limitMi).padStart(8)} |`;
  lines.splice(lastRow + 1, 0, formatted);
  return lines.join("\n");
}

export function removeRow(text: string, name: string): string {
  const lines = text.split("\n");
  const re = new RegExp(`<!-- ledger:row --> *${name} `);
  const idx = lines.findIndex((l) => re.test(l));
  if (idx < 0) throw new Error(`원장에서 행 '${name}'을 못 찾음 — 제거 불가(드리프트?)`);
  lines.splice(idx, 1);
  return lines.join("\n");
}
```

> **실행 주의:** create-app:211-213의 실제 행 포맷(env 컬럼 값·padEnd 폭)을 읽어 `formatted`가 **현재와 바이트 동일**한지 확인. **콜사이트는 절대 `m[2]/m[3]` raw 인덱스를 쓰지 말 것**(F7) — `parseLedgerRows()`의 명명 필드 + `.reduce`로 합계. audit-orphans도 `.name`/`.env`로.

**Step 4: 통과 확인** — `bats tools/tests/test_ledger-totals.bats` → 새 2건 PASS.

**Step 5: 콜사이트 이주** (모두 `parseLedgerRows` 명명 필드 사용 — raw 인덱스 금지, F7)
- `tools/create-app.ts` — `import { replaceTotals, addRow, parseLedgerRows } from "./lib/ledger-totals.ts";`. L124-126 `rowRe`+`while(exec)` → `const rows = parseLedgerRows(ledger); const names = rows.map(r => r.name); const sumReq = rows.reduce((a, r) => a + r.reqMi, 0); const sumLimit = rows.reduce((a, r) => a + r.limitMi, 0);`. L211-213 인라인 splice → `addRow(ledger, { name: app, env: "prod", reqMi, limitMi })` 후 `replaceTotals`로 합계 갱신. **출력 바이트 동일 + dry-run `ledger.after` 합계 동일 확인**.
- `tools/audit-orphans.ts:122-123` — 인라인 regex+matchAll → `parseLedgerRows(ledger)`로, `.name`/`.env`(type 컬럼)로 stale 판정.
- `tools/provision-cache.ts:62-67` — `rowRe`+`while(exec)` → `parseLedgerRows`로 `names`/`sumReq`/`sumLimit` 계산. 삽입(L334)은 `addRow(ledger, { name: \`cache-${name}\`, env: <현재 코드의 env 컬럼 값>, reqMi, limitMi })`. component=`cache-${name}` 보존.
- `tools/teardown-resource.ts` (**버그① 수정, F1·F2 반영**) — `import { replaceTotals, removeRow, parseLedgerRows } from "./lib/ledger-totals.ts";`. `cleanup` step에서 cache일 때 원장 행을 프로그램으로 제거. **행 이름은 `cache-${name}`**(provision-cache:66 `component`와 동일 — 바로 이 형태로 원장에 기록됨; bare `name`이면 miss=F1). **멱등은 broad catch가 아니라 사전 존재 검사로**(removeRow/replaceTotals/write의 fail-loud를 삼키면 안 됨=F2). **purgeArtifacts rm 루프보다 먼저** 배치(원장 프로즈 드리프트 시 파괴적 작업 전에 abort):
  ```typescript
  // cleanup 블록 내, purgeArtifacts rm 루프보다 먼저(fail-loud가 파괴적 작업·tombstone 갱신 전에 걸리도록):
  if (kind === "cache") {
    const ledgerPath = `${ROOT}/docs/memory-ledger.md`;
    const component = `cache-${name}`;                       // F1: 원장 행은 cache-<name>로 기록됨
    if (existsSync(ledgerPath)) {
      let lg = readFileSync(ledgerPath, "utf8");
      // 멱등은 사전 존재 검사로(부재면 이미 정리됨). 존재하면 removeRow→합계 재계산→replaceTotals→write를
      // catch 없이 실행 — totals 프로즈 드리프트/write 실패는 cleanup을 중단시켜야 한다(F2: fail-loud 보존).
      if (new RegExp(`<!-- ledger:row --> *${component} `).test(lg)) {
        lg = removeRow(lg, component);
        const rows = parseLedgerRows(lg);                     // F7: 명명 필드(raw 인덱스 금지)
        lg = replaceTotals(lg, rows.reduce((a, r) => a + r.reqMi, 0), rows.reduce((a, r) => a + r.limitMi, 0)); // 프로즈 부재면 throw → cleanup abort
        writeFileSync(ledgerPath, lg);
      }
    }
  }
  ```
  그리고 `manual` 노트의 cache 분기 `"원장 행 제거 확인"` → `"원장 행 자동 제거됨(cache-<name>)"`으로 갱신(수동 단계 제거 반영).

**Step 6: 버그 수정 회귀 테스트 추가** — `tools/tests/test_teardown.bats`(또는 신규 `test_teardown-resource-ledger.bats`)에 두 단언 — (a) cache purge가 `cache-<name>` 행 제거, (b) totals 프로즈 드리프트 시 fail-loud(F2):

```bash
@test "teardown-resource cache purge cleanup removes the cache-name ledger row (budget leak fix)" {
  TMP="$(mktemp -d)"; mkdir -p "$TMP/docs" "$TMP/apps" "$TMP/platform/data-conn/prod" "$TMP/platform/cache/prod/widget"
  printf '%s\n' '<!-- LIMIT_BUDGET_MIB=8704 -->' \
    '| <!-- ledger:row --> cache-widget   | cache          |     64 |      128 |' \
    '**합계:** req ≈ 64 Mi · limit ≈ 128 Mi (≤ 8704 Mi).' > "$TMP/docs/memory-ledger.md"
  echo '{}' > "$TMP/platform/data-conn/prod/.tombstones.json"
  run bun tools/teardown-resource.ts --cache widget --repo-root "$TMP" --delete-data --backup-verified test-id --step cleanup
  [ "$status" -eq 0 ]
  run grep -c 'ledger:row --> cache-widget' "$TMP/docs/memory-ledger.md"
  [ "$output" = "0" ]
  run grep -q '"state": "purged"' "$TMP/platform/data-conn/prod/.tombstones.json"   # 정상 경로는 purged
  [ "$status" -eq 0 ]
}

@test "teardown-resource cache purge fails loud when totals prose drifted (no silent purge)" {
  TMP="$(mktemp -d)"; mkdir -p "$TMP/docs" "$TMP/apps" "$TMP/platform/data-conn/prod" "$TMP/platform/cache/prod/widget"
  printf '%s\n' '<!-- LIMIT_BUDGET_MIB=8704 -->' \
    '| <!-- ledger:row --> cache-widget   | cache          |     64 |      128 |' \
    'totals prose 누락(드리프트)' > "$TMP/docs/memory-ledger.md"
  echo '{}' > "$TMP/platform/data-conn/prod/.tombstones.json"
  run bun tools/teardown-resource.ts --cache widget --repo-root "$TMP" --delete-data --backup-verified test-id --step cleanup
  [ "$status" -ne 0 ]
  run grep -q '"state": "purged"' "$TMP/platform/data-conn/prod/.tombstones.json"   # fail-loud: purged로 안 넘어가야
  [ "$status" -ne 0 ]
}
```
> 실행 시 cleanup의 다른 산출물(conn/kustomization) 부재가 멱등 no-op인지 확인(`removeResource`는 파일 부재 시 no-op). 필요 산출물만 stub. **둘째 테스트가 통과하려면 ledger 제거가 파일 rm·tombstone 갱신보다 먼저**(Step 5)여야 abort 시 purged로 안 넘어간다.

**Step 7: 영향분 테스트** — `bats tools/tests/test_ledger-totals.bats tools/tests/test_create-app.bats tools/tests/test_audit-orphans.bats tools/tests/test_provision-cache.bats tools/tests/test_teardown.bats tools/tests/test_ledger-gate.bats` → 전부 PASS. **추가(F7): create-app/provision-cache dry-run의 `ledger.after` 총합이 정확한지 단언**(알려진 원장 + 신규 앱/캐시 → `after` = 기존 limit합 + 신규 limit). 행 존재만이 아니라 **정확 총합**을 검사해 인덱스 드리프트를 콜사이트 레벨에서도 포착.

**Step 8: 커밋** (추출과 버그수정 분리 — 2 커밋 권장)
```bash
git add tools/lib/ledger-totals.ts tools/create-app.ts tools/audit-orphans.ts tools/provision-cache.ts tools/tests/test_ledger-totals.bats
git commit -m "refactor: 원장 행 파싱/삽입을 ledger-totals.ts parseLedgerRows/addRow로 수렴"
git add tools/teardown-resource.ts tools/tests/test_teardown.bats
git commit -m "fix: teardown-resource cache purge가 원장 행을 제거하도록 수정(예산 누수)

- cleanup step이 파일/kustomization만 제거하고 원장 행은 manual 방치 → limit 합계 stale
- removeRow + replaceTotals 배선으로 budget 게이트 오발화 차단"
```

---

## Task 4: `kustomization.ts` — addResource/removeResource SSOT

kustomization.yaml 멱등 편집(yaml 라운드트립·주석보존)을 SSOT로. provision-cache 비대칭을 provision-db식으로 정합.

**Files:**
- Create: `tools/lib/kustomization.ts`
- Modify: `tools/provision-db.ts` (kustomization 등록부)
- Modify: `tools/provision-cache.ts:233-248`
- Modify: `tools/teardown-resource.ts:97-107` (deregister → removeResource)
- Test: `tools/tests/test_kustomization-lib.bats` (신규)

**Step 1: 실패 테스트 작성** — `tools/tests/test_kustomization-lib.bats`:

```bash
#!/usr/bin/env bats
# kustomization.yaml 멱등 편집 SSOT(tools/lib/kustomization.ts) — yaml 라운드트립·주석보존.
# ⚠️ 중간 단언은 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "addResource adds entry idempotently and preserves comments" {
  run bun -e '
    import { addResource } from "./tools/lib/kustomization.ts";
    const base = "# keep me\napiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n  - a.yaml\n";
    let out = addResource(base, "b.yaml");
    out = addResource(out, "b.yaml");                          // 멱등 — 중복 추가 안 됨
    if (!/# keep me/.test(out)) { console.error("comment lost"); process.exit(1); }
    if ((out.match(/b\.yaml/g) || []).length !== 1) { console.error("dup"); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}

@test "removeResource removes entry (trailing-slash normalized) and is idempotent" {
  run bun -e '
    import { removeResource } from "./tools/lib/kustomization.ts";
    const base = "kind: Kustomization\nresources:\n  - widget/\n  - keep.yaml\n";
    let out = removeResource(base, "widget");                  // name vs name/ 정규화 매칭
    if (/widget/.test(out)) { console.error("not removed"); process.exit(1); }
    if (!/keep.yaml/.test(out)) { console.error("over removed"); process.exit(1); }
    out = removeResource(out, "widget");                       // 멱등
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}
```

**Step 2: 실패 확인** — `bats tools/tests/test_kustomization-lib.bats` → FAIL.

**Step 3: 모듈 구현** — `tools/lib/kustomization.ts` (teardown-resource:97-107 deregister + provision-cache:233-236 register 패턴 통합, `parseDocument`로 주석보존):

```typescript
// kustomization.yaml resources 리스트 멱등 편집 SSOT — provision(등록)·teardown(해제) 공용.
// parseDocument로 주석/포맷 보존. trailing slash 정규화(인스턴스 디렉토리 name vs name/).
import { parseDocument } from "yaml";

const norm = (v: unknown): string => String(v).replace(/\/$/, "");

export function addResource(kustomizationYaml: string, entry: string): string {
  const doc = parseDocument(kustomizationYaml);
  const seq: any = doc.get("resources");
  const items: any[] = seq?.items ?? [];
  if (items.some((it) => norm(it.value ?? it) === norm(entry))) return kustomizationYaml; // 멱등
  if (!seq) doc.set("resources", [entry]);
  else doc.addIn(["resources"], entry);
  return doc.toString();
}

export function removeResource(kustomizationYaml: string, entry: string): string {
  const doc = parseDocument(kustomizationYaml);
  const seq: any = doc.get("resources");
  if (!seq?.items) return kustomizationYaml;
  const idx = seq.items.findIndex((it: any) => norm(it.value ?? it) === norm(entry));
  if (idx < 0) return kustomizationYaml; // 멱등 — 부재면 no-op
  doc.deleteIn(["resources", idx]);
  return doc.toString();
}
```

**Step 4: 통과 확인** — `bats tools/tests/test_kustomization-lib.bats` → PASS.

**Step 5: 콜사이트 이주**
- `tools/teardown-resource.ts:97-107` — `import { removeResource } from "./lib/kustomization.ts";`. `deregister()` 함수 삭제, 호출부(L164 `deregister(a.kust, a.entry)`)를 파일 read→`removeResource`→write로:
  ```typescript
  if (existsSync(a.kust)) writeFileSync(a.kust, removeResource(readFileSync(a.kust, "utf8"), a.entry));
  ```
- `tools/provision-cache.ts:233-248` — 멱등 등록부를 `addResource`로. dataConnKustomization(L248)도 동일.
- `tools/provision-db.ts` — kustomization 등록부를 `addResource`로(provision-db가 이미 신설+멱등이면 함수만 치환; 차이가 있으면 provision-db 동작을 SSOT 함수가 보존하는지 확인).

> **실행 주의:** provision-db/provision-cache의 현재 kustomization 처리(신규 생성 vs 기존 추가)를 읽어 `addResource`가 양쪽 동작을 보존하는지 확인. `seq` 부재 시 `doc.set("resources", [entry])`로 신규 생성 경로 커버.

**Step 6: 잔존 테스트 추가**:
```bash
@test "callsites use kustomization lib (no inline deregister/parseDocument resources left)" {
  run grep -nE 'function deregister' tools/teardown-resource.ts
  [ "$status" -ne 0 ]
  for f in teardown-resource provision-cache provision-db; do
    run grep -q "lib/kustomization.ts" "tools/$f.ts"
    [ "$status" -eq 0 ]
  done
}
```

**Step 7: 영향분 테스트** — `bats tools/tests/test_kustomization-lib.bats tools/tests/test_provision-db.bats tools/tests/test_provision-cache.bats tools/tests/test_teardown.bats` → PASS. (purge cleanup의 "파일 rm 시 kustomization 엔트리도 제거" 불변 — design §3 주의 — 회귀 없음 확인.)

**Step 8: 커밋**
```bash
git add tools/lib/kustomization.ts tools/provision-db.ts tools/provision-cache.ts tools/teardown-resource.ts tools/tests/test_kustomization-lib.bats
git commit -m "refactor: kustomization.yaml 멱등 편집을 kustomization.ts로 수렴

- provision(addResource)/teardown(removeResource) 대칭화
- provision-cache 비대칭을 provision-db식 멱등 등록으로 정합"
```

---

## Task 5: `cli.ts` — parseFlags + arg 삼킴 가드(fix)

흩어진 argv 루프를 SSOT로. **누락 값 자리에서 다음 플래그를 삼키던 버그를 고친다.** 기존 unknown-flag 거부(test_cli-flag-guard.bats)는 보존. **homelab `.ts` 도구만**(app-shared `.mts` 2개는 미수정 — Pass1 F3).

**Files:**
- Create: `tools/lib/cli.ts`
- Modify: 손으로 짠 argv 루프 콜사이트(homelab `.ts`만 — db-url/cache-url/teardown-resource/provision-db/provision-cache + **create-app/teardown-app**[F6]). **env-example.mts·seal-secret.mts는 제외**(app-shared self-contained).
- Test: `tools/tests/test_cli-flag-guard.bats` (확장)

**Step 1: 실패 테스트 작성** — `tools/tests/test_cli-flag-guard.bats`에 추가(arg 삼킴 가드 + 라이브러리 직접 테스트):

```bash
@test "parseFlags rejects a value that starts with -- (arg-swallow guard)" {
  run bun -e '
    import { parseFlags } from "./tools/lib/cli.ts";
    try { parseFlags(["--name", "--dry-run"], { value: ["--name"], bool: ["--dry-run"] }); console.log("DID-NOT-THROW"); }
    catch { console.log("threw"); }
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^threw$"
}

@test "parseFlags rejects unknown flag and accepts a well-formed value" {
  run bun -e '
    import { parseFlags } from "./tools/lib/cli.ts";
    const ok = parseFlags(["--name", "blog", "--dry-run"], { value: ["--name"], bool: ["--dry-run"] });
    if (ok["--name"] !== "blog" || ok["--dry-run"] !== true) { console.error("parse"); process.exit(1); }
    try { parseFlags(["--bogus", "x"], { value: [], bool: [] }); console.log("DID-NOT-THROW"); }
    catch { console.log("ok"); }
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}
```

**Step 2: 실패 확인** — `bats tools/tests/test_cli-flag-guard.bats` → 새 2건 FAIL.

**Step 3: 모듈 구현** — `tools/lib/cli.ts`:

```typescript
// CLI 인자 파싱 SSOT — 흩어진 argv 루프 통일(homelab .ts 도구 전용).
// fail-closed: unknown 플래그 거부, 값이 누락돼 다음 플래그(--)를 삼키는 것 거부.
type FlagSpec = { value: string[]; bool: string[] };

export function parseFlags(argv: string[], spec: FlagSpec): Record<string, string | boolean> {
  const known = new Set([...spec.value, ...spec.bool]);
  const out: Record<string, string | boolean> = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) throw new Error(`예상치 못한 위치 인자: ${a}`);
    if (!known.has(a)) throw new Error(`알 수 없는 옵션: ${a}`);
    if (spec.bool.includes(a)) { out[a] = true; continue; }
    const v = argv[i + 1];
    if (v === undefined || v.startsWith("--")) throw new Error(`옵션 ${a}에 값이 필요하다(값 누락 또는 다음 플래그 삼킴)`);
    out[a] = v; i++;
  }
  return out;
}
```

**Step 4: 통과 확인** — `bats tools/tests/test_cli-flag-guard.bats` → 새 2건 PASS.

**Step 5: 콜사이트 이주(선별 — 안전한 것만)** — **비목표: 16개 전부 강제 교체 금지.** 손으로 짠 `arg()/has()/indexOf` 루프 + ALLOWED_FLAGS 가드 패턴을 가진 mutator/provision/url 도구만 교체하고, **각 도구의 플래그 집합·에러 메시지·종료 코드·출력 계약을 1:1 보존**. 후보(실행 시 각 파일 확인):
- `tools/teardown-resource.ts:25-38` — `arg/has` + ALLOWED_FLAGS → `parseFlags(process.argv.slice(2), { value: [...], bool: ["--dry-run","--delete-data"] })`. (arg 삼킴 버그 실제 수정 지점.)
- `tools/db-url.ts:9-21`·`tools/cache-url.ts` — `arg()` + allowed-set → parseFlags. 종료 코드 2(usage) 보존.
- `tools/provision-cache.ts:30-33`·`tools/provision-db.ts:28-39` — ALLOWED_FLAGS 가드 → parseFlags(메시지 "알 수 없는 옵션" 보존 — test_cli-flag-guard가 단언).
- **`tools/create-app.ts`·`tools/teardown-app.ts`**(F6) — 동일 `arg()+ALLOWED_FLAGS` 패턴(test_cli-flag-guard가 이미 unknown-flag 단언)이라 같은 arg-삼킴 취약. homelab `.ts`라 마이그레이션. **각 도구의 전체 플래그를 parseFlags spec(value/bool)에 빠짐없이 전사**(create-app은 플래그가 많으니 현재 파서를 읽어 1:1). 종료 코드·"알 수 없는 옵션" 메시지 보존.
- **`tools/env-example.mts`·`tools/seal-secret.mts`는 건드리지 않는다**(Pass1 F3) — app-shared(외부 앱 레포 배포)라 homelab lib import 금지. 자체 argv 파싱 유지. 이 두 .mts의 자체 arg-삼킴 보강은 외부 레포 계약/템플릿 동기화를 동반하므로 **범위 밖**(후속 owner-local 판단).

> **실행 주의:** `parseFlags` 도입이 기존 종료 코드(일부는 `process.exit(2)`, 일부 `1`)와 에러 메시지를 바꾸면 안 된다. 도구별로 parseFlags의 throw를 잡아 기존 exit 코드로 변환하거나, parseFlags가 던진 메시지를 기존 포맷으로 감싼다. **test_cli-flag-guard.bats의 "알 수 없는 옵션" grep과 status!=0 단언이 계속 green이어야 한다.** 한 콜사이트씩 이주→해당 도구 bats 즉시 실행.

**Step 6: per-콜사이트 채택 + missing-value 테스트(F6) + 회귀** — `tools/tests/test_cli-flag-guard.bats`에:
```bash
@test "migrated mutators import the shared parseFlags (cli.ts adoption)" {
  for f in db-url cache-url teardown-resource provision-db provision-cache create-app teardown-app; do
    run grep -q "lib/cli.ts" "tools/$f.ts"; [ "$status" -eq 0 ]
  done
}

@test "migrated mutators reject a missing flag value (arg-swallow guard per callsite)" {
  # 값-요구 플래그 뒤 값 누락 → fail-closed(이전엔 다음 플래그를 삼킴). 값-요구 플래그는 각 도구 실제 플래그로.
  run bun tools/teardown-app.ts --app --dry-run;     [ "$status" -ne 0 ]
  run bun tools/db-url.ts --name --dry-run;          [ "$status" -ne 0 ]
  run bun tools/provision-cache.ts --name --dry-run; [ "$status" -ne 0 ]
  run bun tools/teardown-resource.ts --db --dry-run; [ "$status" -ne 0 ]
}
```
그리고 기존 flag-guard 회귀: `bats tools/tests/test_cli-flag-guard.bats`
Expected: 기존 4건(create-app/provision-cache/teardown-app/teardown-resource unknown-flag) + 새 4건(parseFlags 단위 2 + 채택 1 + missing-value 1) 모두 PASS.

**Step 7: 영향분 테스트** — 이주한 각 도구의 bats:
```bash
bats tools/tests/test_cli-flag-guard.bats tools/tests/test_provision-db.bats tools/tests/test_provision-cache.bats \
     tools/tests/test_teardown.bats tools/tests/test_dev-data.bats tools/tests/test_examples.bats
```
Expected: 전부 PASS.

**Step 8: 커밋**
```bash
git add tools/lib/cli.ts tools/teardown-resource.ts tools/db-url.ts tools/cache-url.ts \
        tools/provision-db.ts tools/provision-cache.ts tools/create-app.ts tools/teardown-app.ts \
        tools/tests/test_cli-flag-guard.bats
git commit -m "refactor: 인자 파싱을 cli.ts parseFlags로 수렴 + arg 삼킴 가드(fix)

- 손으로 짠 argv 루프 통일(homelab .ts 도구 — create-app·teardown-app 포함)
- 누락 값 자리에서 다음 --플래그를 값으로 삼키던 버그 차단
- app-shared .mts(env-example/seal-secret)는 미수정(외부 앱 레포 배포)
- 기존 unknown-flag 거부 계약(test_cli-flag-guard) 보존"
```

---

## Task 6: 전체 게이트 + 최종 검증

**Files:** 없음(검증만)

**Step 1: 전체 tools 테스트** — `bats tools/tests/` → 0 failures. (한글 @test·`[[ ]]` 함정 없는지 새 테스트 재확인.)

**Step 2: 게이트 미러** — `make ci` → 전부 PASS(skeleton·ledger conftest·sops·chart-test·bats accounting). bats accounting이 새 테스트 파일(test_seal-lib·test_kustomization-lib)을 credit하는지 확인 — `tools/tests/*` 글롭이라 자동 포함, 누락 시 `test_bats-accounting.bats` 갱신.

**Step 3: 동작보존 최종 확인(F4)** — 유효 입력 parity를 **base(origin/main)와 feature를 별도 체크아웃에서 실제 비교**한다. `git stash`는 커밋 후엔 no-op이라 같은 HEAD끼리 비교하는 거짓 게이트(Pass1 F4) — 임시 워크트리로 base 코드를 실행:
```bash
BASE=$(git merge-base HEAD origin/main)            # = 37e4d19 (테마3 분기 base)
TMPWT="$(mktemp -d)/base"
git worktree add --detach "$TMPWT" "$BASE"
( cd "$TMPWT" && bun install >/dev/null 2>&1
  bun tools/validate-mutation.ts --action create-database --payload '{"spec":"{\"name\":\"blog\"}"}' ) > /tmp/before.txt 2>&1 || true
bun tools/validate-mutation.ts --action create-database --payload '{"spec":"{\"name\":\"blog\"}"}' > /tmp/after.txt 2>&1 || true
git worktree remove --force "$TMPWT"
diff /tmp/before.txt /tmp/after.txt && echo "PARITY OK (유효 입력 동일)"
```
대표 유효 입력(blog 등)은 base와 동일, 경계 입력(trailing hyphen·>30·arg 삼킴)만 feature에서 새로 거부 — design §5. db-url/cache-url/provision dry-run도 같은 방식으로 1~2건 스폿 체크.

**Step 4: 잔존 인라인 0 최종 확인**:
```bash
grep -rnE '\^\[a-z\]\[a-z0-9-\]\*\$' tools/db-url.ts tools/cache-url.ts tools/teardown-resource.ts tools/validate-mutation.ts && echo "LEAK" || echo "clean"
grep -rn 'spawnSync("kubeseal"' tools/provision-db.ts tools/provision-cache.ts && echo "LEAK" || echo "clean"
```
Expected: 둘 다 "clean".

**Step 5: PR 준비** — 변경 요약 + `git log --oneline origin/main..HEAD` 확인. PR 생성은 owner 판단(executing-plans는 커밋까지, 푸시/PR은 별도 — 사용자 지시 시).

---

## 실행 순서 메모

- **순서: Task 1 → 1.5 → 1.6 → 2 → 3 → 4 → 5 → 6**(저위험 foundational → 최다 콜사이트). 한 파일이 여러 Task에서 수정된다 — `validate-mutation`/`provision-db`/`provision-cache`는 Task 1·1.5(+2/4/5), `teardown-resource`는 Task 1·3·4·5, 워크플로 2개는 Task 1.6. **각 Task는 그 파일의 해당 부분만** 건드리고 매번 해당 bats 실행(같은 파일 연쇄 수정 — 직전 Task 커밋 위에 작업).
- 각 Task는 **자체 커밋**(또는 추출/버그수정 분리 커밋). 한 Task 실패 시 그 Task만 롤백.
- 라이브 영향 0 — 머지 후에도 ArgoCD 무변경. 전 과정 워크트리에서.

---

## Adversarial review dispositions

hardened-planning 5-pass codex 적대 리뷰. **Pass 1의 F3은 사용자 승인 설계 변경**(D1 flip: seal/cli `.mts` 완전공유 → `.ts`, app-shared `.mts` 미수정)이라 카운트 리셋. **11 발견 전부 Accept·반영**. 각 게이트는 AskUserQuestion으로 사용자 승인. 사용자 명시 cap 결정으로 **최종 Pass 5에서 종료**(6번째 미실행), F10/F11은 재리뷰 없이 반영.

| Pass | # | 발견 | Sev | Disposition |
|---|---|---|---|---|
| 1 | F1 | cache purge가 `name`으로 원장 행 제거 → 실제 `cache-<name>` miss, broad catch 은폐 | critical | **Accepted** — removeRow를 `cache-${name}` 타깃·fixture `cache-widget` (Task 3) |
| 1 | F2 | ledger cleanup broad catch가 replaceTotals fail-loud·write 에러 삼킴 | high | **Accepted** — 사전 존재검사 멱등·replaceTotals/write fail-loud (Task 3) |
| 1 | F3 | app-shared `.mts`가 homelab-local lib import → 외부 앱 레포 번들 깨짐 | high | **Accepted(설계 변경)** — D1 flip: seal/cli `.ts`, app-shared .mts 미수정 |
| 1 | F4 | 최종 parity가 `git stash`로 같은 HEAD 비교(거짓) | medium | **Accepted** — base(origin/main) 임시 워크트리 비교 (Task 6) |
| 2 | F5 | 정규식만 수렴 — reserved 정책(RESERVED·-ro) 디스패처 미검사 | medium | **Accepted** — resourceNameError + 디스패처 배선 (Task 1.5) |
| 2 | F6 | arg-삼킴 수정이 create-app·teardown-app 누락 | medium | **Accepted** — 둘 다 마이그레이션 + per-콜사이트 테스트 (Task 5) |
| 3 | F7 | LEDGER_ROW_RE env 캡처 추가 → m[2]/m[3] 시프트, 예산 게이트 손상 | high | **Accepted** — parseLedgerRows 명명 필드·raw 인덱스 금지 (Task 3) |
| 4 | F8 | resourceNameError가 -ro를 cache만 → provision-db -ro 가드 유실 | high | **Accepted** — -ro를 db·cache 공통 (Task 1.5) |
| 4 | F9 | 워크플로 YAML 인라인 정규식이 ≤30 정책과 발산 | medium | **Accepted** — _create-cache/_create-database 동기화 + guard (Task 1.6) |
| 5 | F10 | provision-db cluster 검증(L60)이 NAME_RE — 삭제 시 undefined | high | **Accepted** — cluster L60 → RESOURCE_NAME_RE + 테스트 (Task 1) |
| 5 | F11 | `catch (e){e.message}`가 tsc --strict서 타입 에러 | medium | **Accepted** — `e instanceof Error` 가드 + 공통규칙 |

**최종 패스(5) verdict:** `needs-attention` — summary "the plan contains concrete TypeScript breakages that would block execution before the refactor can safely land"(F10/F11). 둘 다 반영. 사용자 합의로 Pass 5에서 종료 — F10/F11은 재리뷰 없이 반영했고, **executing-plans의 `tsc --strict`(make ci) 게이트 + per-Task TDD가 구현 시 잔여를 포착**한다. 수렴 패턴: 4→2→1→2→2 (F8은 F5 수정 유발 회귀를 확인 패스가 포착, F10/F11은 구현 정밀도).

## Execution directives
- **Skill:** implement via `executing-plans` in a **separate session, in this worktree** (`.claude/worktrees/feat+tools-cli-lib-ssot`).
- **Run continuously:** do NOT stop between batches for routine review. Stop ONLY on a genuine blocker — missing dependency, a verification that keeps failing, an unclear/contradictory instruction, or a critical plan gap. Otherwise proceed through every Task to completion. **Task 순서: 1 → 1.5 → 1.6 → 2 → 3 → 4 → 5 → 6.**
- **Commits — apply these rules directly; do NOT invoke `Skill(commit)`** (interactive 확인이 연속 실행을 끊는다):
  - **Language:** 커밋 메시지는 **한국어**. **AI 마커 금지** — `🤖 Generated with`·`Co-Authored-By: Claude` 등 절대 금지.
  - **Format:** `<type>(<scope>): 한국어 설명` (필요 시 `- 상세` 본문).
  - **Type — 다음만:** `feat`/`fix`/`refactor`/`docs`/`style`/`test`/`chore`. `perf`/`build`/`ci` 등 금지. (추출=`refactor:`, 명시 버그수정[원장 누수·arg 삼킴·워크플로 동기화]=`fix:`.)
  - **Grouping:** ① 같은 모듈/디렉토리 함께 ② 목적별 분리(refactor vs fix) ③ 상호 import 파일 함께 ④ config/tests/docs/style 각각 자체 커밋. 각 Task의 Commit 스텝(또는 추출/버그수정 분리)을 따른다.
  - **Where:** 현재 feature 워크트리 브랜치(`worktree-feat+tools-cli-lib-ssot`)에 직접 커밋(이미 main 밖).
- **Push/PR:** owner 판단. `.github/workflows/` 변경(Task 1.6) push는 `workflows:write` 필요 → **owner 로컬 머지**(App 토큰 auto-merge 불가). 라이브 영향 0(tools/·.github는 ArgoCD 미싱크).
