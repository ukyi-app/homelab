# 테마3 설계: tools CLI lib SSOT 수렴

- 날짜: 2026-06-20
- 상태: 설계 승인됨(사용자 확정 2026-06-20) — hardened-planning Phase B(writing-plans) 진입 대상
- 워크트리: `.claude/worktrees/feat+tools-cli-lib-ssot` (브랜치 `worktree-feat+tools-cli-lib-ssot`, origin/main `37e4d19` 분기)
- 출처: 2026-06-19 홈랩 10차원 심층 감사 8테마 로드맵의 테마3 ("tools CLI lib SSOT 수렴", 중/저·M)

## 1. 배경 / 문제

`tools/` 앱-플랫폼 CLI(16개 `.ts` + 2개 `.mts`)에 **같은 책임의 로직이 여러 파일에 복제·발산**한다.
인레포 앱이 0개라 라이브에선 미발현이지만, 앱 N 증가·teardown·polyglot 도입 시 발효하는 **구조적 잠복 갭**이다.
가장 위험한 발산은 **식별자 검증**으로, 같은 "db/cache 리소스 이름"을 3가지 형태로 검사한다:

| 콜사이트 | 현재 정규식 | trailing hyphen | 길이 |
|---|---|---|---|
| `validate-mutation.ts:31` (`resource` FIELD_RE, `db\|cache:` 접두) | `/^(db\|cache):[a-z][a-z0-9-]*$/` | **허용** | **무제한** |
| `validate-mutation.ts:35` (`NAME_RE`, spec.name용) | `/^[a-z][a-z0-9-]*$/` | **허용** | **무제한** |
| `db-url.ts:22` · `cache-url.ts:19` · `teardown-resource.ts:43` | `/^[a-z][a-z0-9-]*$/` | **허용** | **무제한** |
| `provision-db.ts:49` (실행기) | `/^[a-z]([a-z0-9-]*[a-z0-9])?$/` + `name.length > 30`(L55) | 금지 | ≤**30** |
| `provision-cache.ts:41` (실행기) | `/^[a-z]([a-z0-9-]{0,27}[a-z0-9])?$/` | 금지 | ≤**29** |

→ **디스패처(validate-mutation)·소비자(db-url/cache-url/teardown-resource)는 느슨**, **실행기(provision-\*)는 엄격**, 게다가 **두 실행기끼리도 off-by-one**(30 vs 29). 디스패처가 통과시킨 `foo-`(trailing hyphen)·100자 이름을 실행기가 거부한다. "디스패처 < 실행기" 계약 갭 + 실행기 내부 불일치.

비슷한 복제가 4개 더 있다(아래 §3).

## 2. 목표 / 비목표

### 목표
- `tools/lib/`에 **단일 책임 모듈 5개**를 두고, 흩어진 콜사이트를 그 모듈로 수렴(SSOT).
- 발산하는 검증/로직은 **가장 엄격하고 올바른 정책으로 통일**한다(느슨한 쪽을 끌어올림).
- 통일 과정에서 드러난 **2개 잠복 버그를 고친다**(원장 예산 누수·arg 삼킴 — §4).
- **단일 PR**, 라이브 위험 0(`tools/`는 CI·owner-local 실행 전용, ArgoCD 미싱크).

### 비목표
- CLI 전면 재작성·통합 런처(`cli.mjs` 식 일괄 교체)는 **하지 않는다**(고위험·저가치, P2 백로그에서 보류 판정).
- 각 도구의 **플래그 계약(받는 옵션 집합)·동작 의미는 보존**한다 — 공유 파서는 기존 계약을 깨지 않는 선에서만 채택.
- **app-shared `.mts`(seal-secret·env-example)는 미수정**(Pass1 F3) — app-starter 템플릿에 동봉돼 외부 앱 레포에서 node strip-types로 실행되는 self-contained 스크립트라 homelab-local lib import 금지. 이들은 자체 kubeseal/arg 파싱을 유지한다.
- 새 기능·새 도구 추가 없음. 동작 추가가 아니라 **중복 제거 + 발산 수렴 + 버그 수정**.

## 3. 설계: `tools/lib/` 5개 모듈

기존 `tools/lib/` = `identity.ts`(`APP_NAME_RE`만)·`ledger-totals.ts`(`replaceTotals`만)·`surface-hash.ts` 3개(`.ts`).
모듈 1·2는 **기존 파일 확장**, 3·4·5는 **신설**.

### 모듈 1 — `identity.ts` 확장 (`.ts`): 리소스 식별자 SSOT
- 추가: `RESOURCE_NAME_RE = /^[a-z]([a-z0-9-]{0,28}[a-z0-9])?$/`
  - 의미: 소문자 시작, kebab, **trailing hyphen 금지**, 길이 **1..30**(single-char 허용).
  - `db\|cache` 접두는 정규식에 넣지 않는다(접두 분해는 validate-mutation의 `resource` 파싱 책임). 접두 제거 후 이름 부분에 `RESOURCE_NAME_RE` 적용.
- 추가: `EXT_RE = /^[a-z][a-z0-9_-]*$/` (postgres extension 이름 — underscore 허용)
  - 현재 `validate-mutation.ts:36`·`provision-db.ts:50`에 **바이트 동일 복제** 2곳.
- 기존 `APP_NAME_RE`(앱 이름, 2..40)는 **그대로 유지** — 앱과 리소스는 정책이 다르다(앱 2..40, 리소스 1..30). 별도 상수.
- 통일 대상 콜사이트(리소스 이름): `validate-mutation.ts:31`(접두 분해 후)·`35`, `db-url.ts:22`, `cache-url.ts:19`, `teardown-resource.ts:43`, `provision-db.ts:49`(+L55 길이체크 흡수), `provision-cache.ts:41`.
  - 제외: `seal-secret.mts:54`의 `/^[a-z][a-z0-9-]*$/`는 **secret 항목 키名**(리소스 이름 아님) — 다른 도메인이라 수렴 대상 아님.

### 모듈 2 — `ledger-totals.ts` 확장 (`.ts`): 메모리 원장 행 SSOT
- 추가: 정규식 SSOT + 행 추가/제거 함수.
  - `LEDGER_ROW_RE` — 현재 파싱이 2변형으로 갈림: `audit-orphans.ts:123`(`name|type` 캡처) vs `create-app.ts:124`(`name|type|req|limit` 캡처). 캐노니컬 파서 1개로 통일.
  - `addRow(ledgerText, { name, env, reqMi, limitMi }): string` — 마지막 `<!-- ledger:row -->` 행 뒤에 삽입(현재 `create-app.ts:211-213` 인라인, `provision-cache.ts`의 cache 행 삽입과 동형).
  - `removeRow(ledgerText, name): string` — 해당 행 제거. 매치 0이면 throw(silent no-op 차단, 기존 `replaceTotals` 패턴과 동일 fail-loud).
- 기존 `replaceTotals`는 유지. addRow/removeRow는 호출 후 합계 재계산 → `replaceTotals`와 함께 쓰여 totals 정합 유지.
- 통일 대상: `create-app.ts:124,211-213`(추가)·`audit-orphans.ts:123`(파싱)·`teardown-app.ts:35`(제거)·`provision-cache.ts:62,334`(cache 행 파싱/추가) + **`teardown-resource.ts` purge(removeRow 신규 배선 — §4 버그①)**.

### 모듈 3 — `seal.ts` 신설 (`.ts`): kubeseal 봉인 SSOT
- `sealManifest(manifest: object, certPath: string): string` — 평문 manifest를 메모리에서 kubeseal stdin으로만 흘려 봉인 YAML 반환(디스크 비기록).
- 현재 **바이트 동일 3복제**: `provision-db.ts:136`·`provision-cache.ts:219`·`seal-secret.mts`. provision-db:134 주석이 "seal-secret.mts와 동일 패턴"이라 복제를 이미 인정.
- **`.ts`·homelab 전용 공유**(Pass1 F3 적대리뷰 반영): `seal-secret.mts`는 app-starter 템플릿에 동봉돼 외부 앱 레포에서 `pnpm secret:seal`로 실행되는 **self-contained 스크립트**라(`seal-secret.mts:5`·`test_app-shared-node-smoke` 게이트), homelab-local lib를 import하면 앱 레포 번들에서 모듈 부재로 깨진다(homelab CI는 lib가 있어 green=무성 회귀). 따라서 **seal는 `.ts`**(provision-db·provision-cache 2곳만 공유)이고 **seal-secret.mts는 미수정**(자체 kubeseal 블록 유지).

### 모듈 4 — `kustomization.ts` 신설 (`.ts`): kustomization.yaml 멱등 편집 SSOT
- `addResource(kustomizationYaml, entry): string` / `removeResource(kustomizationYaml, entry): string` — `yaml` 라운드트립(주석 보존), `resources` 리스트에 멱등 추가/제거.
- 현재 비대칭: `provision-cache.ts:233-236`은 기존 doc에 `resources`만 멱등 추가, `create-app.ts:200-203`은 신규 작성. provision-db는 별도 방식. **provision-cache가 provision-db식(신설+멱등)을 채택**해 대칭화.
- 통일 대상: `provision-db.ts`·`provision-cache.ts:233-248`(데이터 conn kustomization 포함).
- 주의: vendor `charts/` 등 비대상 kustomization은 건드리지 않음. 대상은 데이터 리소스(cnpg databases·cache instances·data-conn) 한정.

### 모듈 5 — `cli.ts` 신설 (`.ts`): 인자 파싱 SSOT
- `parseFlags(argv, spec): Record<string, …>` — `--flag value` 루프를 한 곳에서:
  - **값이 `--`로 시작하면 거부**(§4 버그② — 현재 일부 파서가 누락된 값 자리에서 다음 플래그를 값으로 삼킴).
  - **unknown 플래그 거부**(이미 일부 도구가 ALLOWED_FLAGS로 하는 패턴을 표준화).
  - `--help` / `--dry-run` 등 boolean 플래그 지원.
- 현재 16개 파일이 제각각 `process.argv.slice(2)`/`indexOf` 루프. **`.ts`·homelab 전용**(Pass1 F3): app-shared `env-example.mts`·`seal-secret.mts`는 외부 앱 레포 배포 self-contained라 **미수정**(자체 파싱 유지). cli는 homelab `.ts` 도구만 공유.
- **채택 원칙**: 손으로 짠 동일 패턴 루프를 가진 콜사이트만 교체하고, **각 도구의 플래그 집합·의미는 1:1 보존**한다. 한 번에 전부 강제 교체 금지(비목표) — Phase B에서 콜사이트별로 안전한 것만 명시 선정.

## 4. 통일이 고치는 2개 잠복 버그

1. **원장 예산 누수**(모듈 2): `teardown-resource.ts` purge가 원장 행을 제거하지 않아 합계가 stale로 남는다 → 거짓 budget 초과(`docs/memory-ledger.md` limit 합계 ≤ 8704Mi CI 게이트가 오발화 가능). `removeRow` 배선으로 수정.
2. **arg 삼킴**(모듈 5): `--name`처럼 값을 요구하는 플래그 뒤에 값이 빠지면 일부 파서가 다음 플래그(`--dry-run`)를 값으로 삼킨다. `parseFlags`가 `--`시작 값을 거부해 fail-closed.

## 5. "동작보존"의 정확한 의미 (중요 — 리뷰 혼동 방지)

이 작업은 **유효 입력에 대해 동작보존**이다 — 정상 이름/플래그는 추출 전후 **바이트 동일 출력**(diff 검증).
그러나 **발산 수렴은 의도적으로 경계(degenerate) 입력의 동작을 바꾼다**:

- 느슨한 검증기(db-url/cache-url/validate-mutation/teardown-resource)가 **조용히 통과시키던** trailing-hyphen·>30자 이름이 이제 **거부**된다.
- provision-cache의 ≤29가 ≤30으로 1자 완화(provision-db와 정합).
- 누락된 플래그 값(arg 삼킴)이 이제 에러.

이것은 결함이 아니라 **테마3의 목적(계약 갭 폐쇄·하드닝)** 그 자체다. **인레포 리소스 0개**라 끌어올려도 깨질 기존 리소스가 없다(비용 0 마이그레이션 윈도우). 통일 방향은 항상 **느슨→엄격**(보안/정합 게이트 강화)이며, **단조롭게 안전**하다. 검증은 ① 유효 입력 parity diff, ② 경계 입력이 이제 거부됨을 단언하는 신규 테스트로 둘 다 증명한다.

## 6. 결정사항 (3건 — 전부 해소)

- **D1 (seal/cli 형식)** → **`.ts`·homelab 전용 공유**(2026-06-20 최초 `.mts` 완전공유 결정 → Pass1 F3 적대리뷰로 **정정**). seal-secret.mts·env-example.mts는 app-starter 템플릿 동봉 self-contained 스크립트(외부 앱 레포 `pnpm secret:seal`/`env:example` 경로, node strip-types)라 homelab-local lib import 시 **앱 레포 번들서 모듈 부재로 깨진다**(homelab CI는 lib 있어 green=무성 회귀). 따라서 seal/cli는 `.ts`로 두고 homelab `.ts` 도구만 공유, **app-shared `.mts` 2개는 미수정**. tools/lib 전부 `.ts` 일관 유지.
  - identity/ledger-totals/kustomization도 콜사이트가 전부 homelab `.ts`라 **`.ts`**.
- **D2 (RESOURCE_NAME_RE 길이/형태)** → **≤30·single-char 허용·no trailing hyphen** = `/^[a-z]([a-z0-9-]{0,28}[a-z0-9])?$/`. provision-db(30)/provision-cache(29) 발산을 **30**(더 관대·k8s 파생명 `db-<name>-ro-conn` 등 ≤63 여유 충분)으로 통일. single-char는 모든 현행 검증기가 허용 → 보존.
- **D3 (EXT_RE 포함)** → **포함**. validate-mutation:36 + provision-db:50 **바이트 동일 2복제** 확인 → 추출에 SSOT 가치(검증된 발산 위험: 한쪽만 고치면 우회 표면).

## 7. 검증 전략

- **유효 입력 parity**: 각 모듈 추출 전, 현재 동작을 고정하는 테스트를 먼저 작성(TDD) → 추출 후 동일 통과.
- **경계 하드닝**: 통일로 새로 거부되는 입력(trailing hyphen·>30·arg 삼킴)을 거부 단언하는 신규 테스트.
- **게이트**: `make ci`(gate 미러: skeleton·원장 conftest·sops·차트·bats accounting), `bats tools/tests/`.
  - 한글 `@test` 이름 금지(디렉토리 단위 실행 시 인코딩 깨짐 — 검증된 함정). bats `test_` 접두, 중간 단언은 `[ ]`(bash 3.2 `[[ ]]` 침묵통과 함정).
- **라이브 영향 없음**: `tools/`는 ArgoCD 싱크 대상 아님. 머지 후에도 라이브 무변경. 롤백 = `git revert`(단일 PR).

## 8. 위험 / 롤백

- 라이브 위험 **0** — tools/는 CI(GitHub Actions reusable·디스패처)·owner-local 실행 전용.
- 단일 PR이라 blast-radius = tools/ 단위 테스트 + 디스패처 동작. revert 단순.
- 최대 주의점: 콜사이트 교체 시 각 도구의 **종료 코드·에러 메시지·stdout 계약**(특히 시크릿 비노출, JSON 출력 형식) 보존. 디스패처(validate-mutation)의 JSON `{ok,...}` 출력과 provision-\*의 `::error::` 포맷은 CI가 파싱하므로 불변.

## 9. 범위 밖 (명시)

- 통합 런처/CLI 전면 재작성(`cli.mjs`) — P2에서 고위험·저가치로 보류.
- 비대상 식별자(`seal-secret.mts:54` secret 키名, `app_repo`/`sha` 등 FIELD_RE) 수렴.
- vendor `charts/`·barman-plugin·gateway-api CRD 등 비편집 대상.
- 새 도구·새 플래그·동작 추가.
