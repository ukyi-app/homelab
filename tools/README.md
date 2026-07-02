# tools/ — DX 도구 인덱스

App Platform DX 스크립트(`.ts`)와 계약 스키마(`.json`) 모음. 각 도구의 **호출 경로**를
명시한다 — 대부분은 워크플로(변이 디스패처)나 `pnpm`/`make` 타겟을 통해서만 돌고,
일부만 직접 `bun tools/x.ts`로 부른다. 라이브 변이는 전부 PR-first(사람 머지 = 승인).

> 신뢰 경계·플로우 전반은 루트 `AGENTS.md`의 "멀티레포 앱 플로우"와 (gitignored) 런북
> `docs/runbooks/app-platform.md` 참고.

## 계약 스키마 (2종 — 혼동 주의)

두 스키마는 **서로 다른 계약**을 검증한다:

| 파일 | 검증 대상 | 누가 읽나 |
|---|---|---|
| `app-config-schema.json` | **외부 앱 레포**의 `.app-config.yml` 자기선언 (v2 계약). `kind`/`resources` 필수. web 기본 health는 `/health` 하나이며, site는 `kind: site`만 선언하면 내부에서 SWS로 서빙한다. `/metrics`는 `metrics.enabled: true` opt-in이다. 시크릿 키 목록은 `deploy/<app>-secrets.sealed.yaml`의 `encryptedData`가 SSOT다. 연결(DB/Redis)은 앱 SealedSecret(DATABASE_URL/REDIS_URL), 마이그레이션은 앱 self-migrate — 평문 env 필드 없음. | `create-app.ts`, `seal-secret.mts`·`env-example.mts`(앱 레포 측) |
| `app-deploy-schema.json` | **이 레포**의 `apps/<name>/deploy/prod/` 산출물 계약. 필수: `values.yaml`·`.bindings.json`·`source-repo`. create-app이 만드는 암묵 계약의 명문화. | `scripts/check-app-deploy.sh`(SSOT — `make verify`) |

## App 계약: self-migration (DB 스키마 마이그레이션)

플랫폼은 더 이상 migrate Job을 렌더하지 않는다(`migrate-job.yaml`·`migrate.cmd` 제거). DB 스키마
마이그레이션은 **앱의 책임**이며 다음 계약을 따른다:

- **앱이 부팅 시 self-migrate한다** — 컨테이너 시작 시 자신의 직결 `DATABASE_URL`로 마이그레이션을
  실행한 뒤 서비스를 연다. 별도 Job/sync-wave 오케스트레이션 없음.
- **expand/contract(확장-수축) 패턴 필수** — 스키마 변경은 구버전 코드와 호환되는 단계로 쪼갠다
  (① 확장: 새 컬럼/테이블을 nullable·기본값으로 추가 → ② 코드 롤아웃 → ③ 수축: 구 컬럼 제거).
  단일노드 Recreate 배포라 롤백 시 구버전 코드가 새 스키마를 만나도 깨지지 않아야 한다.
- **멱등(idempotent) 강제** — 동일 마이그레이션이 재시작·재배포로 여러 번 돌아도 안전해야 한다
  (이미 적용된 변경은 no-op). 부분 실패 후 재실행도 수렴해야 한다.
- **검증 위치** — 마이그레이션 정합성·멱등성은 **앱 레포 CI**에서 검증한다(homelab은 강제하지 않음;
  homelab 측은 수동 확인). 설계 근거: `docs/plans/2026-06-25-data-connection-as-secret-design.md` §5.8(F3).

## App Platform 변이 도구 (변이 디스패처 경유 — 직접 실행 금지)

owner가 homelab에서 액션별 변이 디스패처(`create-app.yaml` 등, workflow_dispatch)를 실행하면
reusable 워크플로가 이 도구들을 호출하고 결과를 **PR**로 낸다. 직접 `node`로 돌리지 않는다.
(teardown은 예외 — owner-local `make teardown-*`.)

- **`validate-mutation.ts`** — payload 검증기(계약표 강제). 각 변이 디스패처(`create-app.yaml` 등)와
  owner-local `scripts/teardown.sh`가 `--action <a> --payload-file <json>`으로 호출. action별 필수/허용
  입력 외에는 전부 거부(fail-closed); 모든 입력을 비신뢰로 취급(env/파일 경유 + regex).
  `update-image`는 여기 없다(GHCR 폴링이 처리).
- **`create-app.ts`** — v2 생성기. `_create-app.yaml`이 호출
  (`--config .app-config.yml --app --repo --domain --tag sha-<sha> --digest sha256:<hex> [--sealed]`).
  스키마+비즈니스 규칙 검증 후 `apps/<app>/deploy/prod/`(values·`.bindings.json`·`source-repo`·
  kustomization) + `apps.json`(active:true, 머지 즉시 공개 승인) + 메모리 원장을 한 번에 산출. `--dry-run`은 plan JSON만.
- **`update-secrets.ts`** — `_update-secrets.yaml`이 호출. 앱 레포 main HEAD의
  `deploy/<app>-secrets.sealed.yaml`을 검증한 뒤 homelab `apps/<app>/deploy/prod/`에 봉인본을
  복사하고 `values.yaml.envFrom`·`podAnnotations.checksum/secrets`·`kustomization.yaml.resources`를
  함께 갱신한다. 기존 시크릿 회전뿐 아니라 첫 시크릿 추가도 같은 경로로 배선한다.
- **`provision-db.ts`** — create-database 프로비저너. `_create-database.yaml`이 호출
  (`--name <db> [--extensions a,b] [--cluster pg]`). 공유 CNPG 안의 논리 DB + owner/ro managed role +
  비밀번호/conn SealedSecret 4개를 산출(`owner==name` 불변식, 논리 DB는 원장 행 비추가).
  비밀번호는 내부 생성→`kubeseal` stdin 직행(평문 비기록). `tools/sealed-secrets-cert.pem` 필요.
- **`provision-cache.ts`** — create-cache 프로비저너. `_create-cache.yaml`이 호출
  (`--name <cache> [--maxmemory-mi 16..1024]`). 앱별 경량 Valkey 인스턴스(cache NS) +
  conn/ro-conn SealedSecret + 원장 행을 산출. 자격은 `kubeseal` stdin 전용. cert 필요.
- **`teardown-app.ts`** — 앱 한정 철거. owner-local `make teardown-app`(`scripts/teardown.sh`)이 호출
  (`--app <name>`). `apps/<app>/`·`apps.json` 행·원장 행만 제거 — DB/캐시 conn·CR·Valkey는
  **절대 비접촉**(리소스 철거는 teardown-resource 전담). 멱등.
- **`teardown-resource.ts`** — DB/캐시 리소스 철거. owner-local `make teardown-resource`(`scripts/teardown.sh`)가
  호출(`--db <name>`|`--cache <name>`). 자동 refcount는 없다(연결=SealedSecret이라 `.bindings.json`에 db/redis
  참조 없음) → **모든 모드가 `--refs-verified <evidence-id>` attestation 강제**(F1): 런북 수동 확인
  (`apps/*/deploy/prod` grep + 실행 워크로드 `kubectl` + 백업 검증) 후 증거 id를 전달해야 진행.
  retain(기본, tombstone) / purge(`--delete-data` + `--backup-verified <id>` + `--step tombstone|drop|verify|cleanup`
  상태머신, 각 step 별도 커밋). 되돌릴 수 없어 fail-closed 게이트가 두껍다(런북 `docs/runbooks/teardown-resource.md`).

## update-image 폴링 (bump 경로 — 인-레포 앱 이미지 전용)

- **`poll-ghcr.ts`** — GHCR 폴링 bump **플래너**(읽기 전용, 부작용 0). `bump-poll.yaml`(10분 주기)이
  `bun tools/poll-ghcr.ts --root . > plan.json`으로 호출. `source-repo` 바인딩이 있는
  `apps/*/deploy/prod`만 순회 — 앱 레포 main 커밋(최신순)을 권위로, 배포 SHA의 descendant + GHCR
  manifest 실존을 증명해 후보를 고른다. `.bindings.json`의 `autoDeploy`가 true면 `bump`(자동 PR+머지),
  false/누락이면 `propose-pr`(fail-closed 승인). 테스트는 `--fixtures <dir>`.
- **`bump-tag.ts`** — values.yaml의 `image.tag`(+선택 `image.digest`)를 갱신하는 쓰기 도구.
  `bump-poll.yaml`이 플래너 출력을 받아 `bun tools/bump-tag.ts <app> sha-<gitsha> [--digest sha256:<hex>]`로
  호출(심층 방어 재검증). `bump.yaml`(인-repo build write-back, workflow_run)도 사용. digest는 비신뢰 입력이라 형식 검증;
  digest 미지정 시 stale digest를 제거(tag bump가 실제 이미지를 바꾸도록).

## 정적 감사 (읽기 전용)

- **`audit-orphans.ts`** — registry(`apps.json`)↔매니페스트↔바인딩↔원장 교차 드리프트 리포트.
  `make audit`(전체)·`make ci`/`ci.yaml`(`--ci`, 배포 깨는 유형만 차단)·`audit.yaml`(스케줄
  reconciler)이 호출. `--ci`(orphan-dns/activation-exposure-drift만 비-0)·`--strict`(전부 비-0)·기본(리포트만).
- **`ledger-to-json.ts`** — `docs/memory-ledger.md` 표 → conftest 입력 JSON(행 파서 SSOT=`lib/ledger-totals.ts`).
  `scripts/verify-ledger.sh`(= `bun run verify:ledger`, gate)가 호출. 라이브 무관.
- **`check-resource-limits.ts`** — 상주 워크로드 main 컨테이너 cpu·memory request + memory limit +
  GOMEMLIMIT≤limit×0.95 강제(구 bash+yq+python3 이관). **`make verify`**·gate가 호출. `--repo-root`로 스캔 루트 지정.

## 앱 시크릿 봉인 (앱 레포 측 — `pnpm` 경유)

- **`seal-secret.mts`** — `.env` → SealedSecret 봉인 CLI. 앱 레포는 **`pnpm secret:seal`**, homelab은 **`bun run secret:seal`**(= `bun tools/seal-secret.mts`; `.mts`라 node≥22.18 strip-types 양립).
  `.env`의 UPPER_SNAKE 키 전체가 봉인 대상이며, 다음 실행에서 `.env`에서 제거된 키는 봉인본에서도 빠진다.
  `.app-config.yml`에는 시크릿 키 목록을 쓰지 않는다. 키 이름·값 형태는 제한하지 않으며 값은 출력하지 않는다.
  평문은 `kubeseal` stdin 전용. `--app` 생략 시 `APP` env 또는 현재 디렉토리명, `--out` 생략 시
  `deploy/<app>-secrets.sealed.yaml`을 쓴다. `--config --env [--app --out --namespace --cert]`,
  `--dry-run`은 대상 키 목록만. 같은 스크립트가 app-starter 템플릿에도 동봉(이 사본은 마이그레이션/테스트용).

## 로컬 개발 헬퍼 (앱 레포 측 — `pnpm` 경유)

- **`dev.ts`** — 로컬 개발 진입점. **`bun run dev`**(dev Postgres 기동 + 워크스페이스 dev 루프),
  **`bun run db:up`**/**`bun run db:reset`**(모드 1: docker postgres 기동/초기화 — 파괴 OK). docker compose는
  `tools/dev-postgres/compose.yaml`. `--dry-run` 지원.
- **`db-url.ts`** — 모드 2(실데이터 디버깅): 클러스터 DB에 tailscale 직결 URL을 기록.
  **`bun run db:url --name <db> --host <ts-host> [--rw|--admin]`**. 모드(상호배타): 기본=RO
  (`db-<name>-ro-conn`)/`--rw`=owner(`db-<name>-conn`)/`--admin`=superuser(`pg-admin-credentials`, database ns).
  RO/RW → canonical **`DATABASE_URL` → `.env.local`**(앱 런타임 채널). **`--admin` → `DATABASE_ADMIN_URL`
  → `.env.admin.local`**(기본 분리 출력). 필요하면 사용자가 `.env`로 옮겨 봉인할 수 있다. host는 pg-rw-tailscale LB.
  평문 URL stdout 비노출(전 모드). 파괴 수단 없음. `--dry-run`은 계획만. (런북 `docs/runbooks/db-cache-access.md`.)
- **`cache-url.ts`** — db-url의 캐시 대칭. **`bun run cache:url --name <cache> [--rw]`**. 기본=RO
  (`cache-<name>-ro-conn`)/`--rw`=default 유저(`cache-<name>-conn`, Valkey per-instance=관리). canonical
  **`REDIS_URL` → `.env.local`**. ★Valkey tailscale 상시 노출은 deferred → host 기본 **127.0.0.1(port-forward)**;
  선행 `kubectl -n cache port-forward svc/<name> 6379:6379`. 평문 stdout 비노출. 파괴 수단 없음.
- **`env-example.mts`** — SealedSecret `encryptedData` 키에서 `.env.example` 생성.
  **`bun run env:example [--config <f>] [--sealed <f>] [--out <f>]`**. 값은 비움/플레이스홀더(로컬 패리티용). 연결(DB/Redis)
  URL은 스캐폴드하지 않는다(연결=SealedSecret, 로컬은 db-url/cache-url로 `.env.local` 생성).
