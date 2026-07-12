# tools/ — DX 도구 인덱스

App Platform DX 스크립트(`.ts`)와 계약 스키마(`.json`) 모음. 각 도구의 **호출 경로**를
명시한다 — 대부분은 워크플로(변이 디스패처)나 `bun`/`make` 타겟을 통해서만 돌고,
일부만 직접 `bun tools/x.ts`로 부른다. 라이브 변이는 전부 PR-first(사람 머지 = 승인).

> 신뢰 경계·플로우 전반은 루트 `AGENTS.md`의 "멀티레포 앱 플로우"와 (gitignored) 런북
> `docs/runbooks/app-platform.md` 참고.

## 계약 스키마 (2종 — 혼동 주의)

두 스키마는 **서로 다른 계약**을 검증한다:

| 파일 | 검증 대상 | 누가 읽나 |
|---|---|---|
| `app-config-schema.json` | **외부 앱 레포**의 `.app-config.yml` 자기선언 (v2 계약). `kind`/`resources` 필수. web 기본 health는 `/health` 하나이며, site는 `kind: site`만 선언하면 내부에서 SWS로 서빙한다. `/metrics`는 `metrics.enabled: true` opt-in이다. 시크릿 키 목록은 `deploy/<app>-secrets.sealed.yaml`의 `encryptedData`가 SSOT다. 연결(DB/Redis)은 앱 SealedSecret(DATABASE_URL/REDIS_URL), 마이그레이션은 앱 self-migrate — 평문 env 필드 없음. | `create-app.ts`, `seal-secret.mts`(앱 레포 벤더)·`env-example.mts`(homelab 로컬 전용) |
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
- **`repin-pgtools.ts`** — ops 이미지 `pg-tools:18-rclone`의 5개 소비처(4파일: cache backup ×2·cnpg
  ensure-role-password/restore-drill/pgdump-hedge)의 인라인 `@sha256` 핀을 새 digest로 일괄 재핀(부분 갱신
  skew=PgDumpHedgeStale 차단). `bump.yaml`이 build 완료 후 호출. digest 형식 검증·멱등(불변 시 no-op). `--root`로 스캔 루트.

## 공유 형식 커널 (lib/ — 콜사이트가 정책 소유)

- **`lib/image-pin.ts`** — 배포 핀 형식 커널(TAG_RE/DIGEST_RE·인라인 핀 parse/format·descriptor
  타입·autoDeploy fail-closed). 순수 형식 판정과 왕복만 소유하고 파일 I/O·exit·에러 문구는
  콜사이트가 소유한다 — 콜사이트마다 정규식이 갈리는 오배포 표면을 SSOT로 없앤다.
  소비자: `poll-ghcr`·`bump-tag`·`create-app`.

## 정적 감사 (읽기 전용)

- **`audit-orphans.ts`** — registry(`apps.json`)↔매니페스트↔바인딩↔원장 교차 드리프트 리포트.
  `make audit`(전체)·`make ci`/`ci.yaml`(`--ci`, 배포 깨는 유형만 차단)·`audit.yaml`(스케줄
  reconciler)이 호출. `--ci`(orphan-dns/activation-exposure-drift만 비-0)·`--strict`(전부 비-0)·기본(리포트만).
- **`ledger-to-json.ts`** — `docs/memory-ledger.md` 표 → conftest 입력 JSON(행 파서 SSOT=`lib/ledger-totals.ts`).
  `scripts/verify-ledger.sh`(= `bun run verify:ledger`, gate)가 호출. 라이브 무관.
- **`check-resource-limits.ts`** — 상주 워크로드 main 컨테이너 cpu·memory request + memory limit +
  GOMEMLIMIT≤limit×0.95 강제(구 bash+yq+python3 이관). **`make verify`**·gate가 호출. `--repo-root`로 스캔 루트 지정.
- **`check-alert-rules.ts`** — vmalert 룰 expr의 eval-time 안티패턴 정적 lint(`-dryRun`은 파싱만 해서 못 잡는
  클래스). 모드 A=상태-파생 카운터(`policy/alert-instance-stability-denylist.txt`) 위 rollup이 instance를
  안 벗김 / 모드 B=산술 `on()`·`ignoring()` 조인 피연산자가 집계 미포함 raw 셀렉터(422) — 둘 다 재부팅 IP
  churn 오탐(PR #327) / **모드 C**=push 메트릭(주기 > vmalert instant 룩백)을 연속성 보존 rollup 없이 참조하거나
  윈도 < 주기 → 시리즈 구멍 → `for:` pending 리셋 → **영구 무발화**(죽은 알림 PR #339·#341).
  모드 C의 구성요소(전부 fail-closed):
  - **레지스트리**(in-code `DEFAULT_REGISTRY`): 메트릭 → 생산자 + `schedule`. `schedule`은 **판별 가능한
    소스** — `cron`(레포 내 CronJob: 주기를 여기서만 파생, 파일 부재/파싱불가=FAIL) 또는 `external`(레포 밖
    launchd 등: 상수 + **근거(why) 필수**). 룩백도 `vmalert.yaml`의 `-datasource.queryStep`에서 파생(미지정=5m).
  - **완전성 가드(메트릭 단위)**: 생산자 표면(`platform·scripts·infra·tools·apps·ops·.github`, 룰 디렉토리 제외)에서
    **VM에 쓰는 모든 파일**을 찾아 **push되는 메트릭 이름을 추출** — 미등록 생산자/미등록 메트릭/**추출 실패
    (페이로드 정적 해석 불가 = fail-closed)**는 전부 FAIL(기존 exporter에 메트릭만 추가하는 우회 경로 차단).
    역방향(레지스트리 메트릭을 더는 push 안 함)도 FAIL. 발견 신호는 단일 엔드포인트가 아니라 ①VM 수집 경로
    (`api/v1/import{,/csv,/native}`·`api/v1/write`·`/influx`·`/datadog`·`/opentsdb`) ②vmsingle/vmagent 호스트
    **+ 쓰기 동사**(`--data-binary`·`-X POST`·`remoteWrite` — URL이 변수로 합성돼도 잡힌다) 두 갈래다.
    읽기 전용 소비자(homepage 위젯·grafana·netpol)는 쓰기 신호가 없어 후보가 아니다. 인프라 릴레이
    (vmagent·vmalert `remoteWrite`)만 `PRODUCER_EXEMPT`에 **사유와 함께** 면제.
  - **셀렉터 정규화**: `{__name__="m"}` · `{"m"}`(VM 축약)을 `m{...}`로 되돌려 검사(문자열 은닉 우회 차단).
    `__name__=~`·`!~`·`!=`는 정적 판정 불가 → fail-closed(정당하면 allowlist).
  - **연속성 보존 rollup만 인정**: `*_over_time` 계열(단일 샘플로도 값을 냄). `irate`/`idelta`/`rate`/`increase`/
    `delta`/`deriv`는 2샘플 이상을 요구해 push 메트릭엔 무력하다 → **rollup으로 인정하지 않음**(가짜 픽스 차단).
  - 검사하는 것은 **하한 `W ≥ 주기`뿐** — 누락 내성(2×)·상한(`W < for:`)은 e2e preflight 소관(헤더 주석 참조).
  면제는 `policy/alert-instance-stability-allowlist.txt`(사유 주석 필수). **`make verify`**·gate가 호출.
  `--repo-root` 지원. `--registry <json>`은 **테스트 픽스처 주입 전용**(실 레포는 항상 기본 레지스트리로 검증).
- **`activate-app.ts`** — 재활성/노출 재승인 게이트(owner-local). host/public 표면 변경 시 descendant +
  표면 무변경 + 행 고정을 검증해 재노출을 재승인한다(런북 `app-platform.md`). 라이브 무변경(게이트만).
- **`dns-drift-check.ts`** — active&&public 앱 host + 예약 platform host(`reserved-hosts.json`)가 실제
  resolve되는지(apply 누락=NXDOMAIN, transient는 별도 버킷) 검사. `dns-drift.yaml`(주기)이 호출. resolver 주입(`--fixture`)으로 테스트. 읽기 전용.
- **`contract-drift-check.ts`** — 동봉 계약(vendored `seal-secret.mts`·`sealed-secrets-cert.pem`)이 다운스트림
  3위치(template scaffold·page·trip-mate-api)와 어긋나는지 정규화 diff(`vendored-contract.json` SSOT). files(Rust)는 대상 아님.
  `contract-drift.yaml`(주 1회)이 호출·telegram 알림. `--self-test` 오프라인 유닛, 라이브 raw fetch는 워크플로 전용. 읽기 전용.
- **`verify-db-marker.ts`** — `_create-database.yaml` PostSync에서 provision-db 마커(role 비번 적용 등)를
  검증(fail-closed — 마커 부재=비-0). 읽기 전용.

## 앱 시크릿 봉인 (앱 레포 측 — bun 경유)

- **`seal-secret.mts`** — `.env` → SealedSecret 봉인 CLI. 앱 레포·homelab 모두 **`bun run secret:seal`**(= `bun tools/seal-secret.mts`; `.mts`라 node≥22.18 strip-types 백업 양립).
  `.env`의 UPPER_SNAKE 키 전체가 봉인 대상이며, 다음 실행에서 `.env`에서 제거된 키는 봉인본에서도 빠진다.
  `.app-config.yml`에는 시크릿 키 목록을 쓰지 않는다. 키 이름·값 형태는 제한하지 않으며 값은 출력하지 않는다.
  평문은 `kubeseal` stdin 전용. `--app` 생략 시 `APP` env 또는 현재 디렉토리명, `--out` 생략 시
  `deploy/<app>-secrets.sealed.yaml`을 쓴다. `--config --env [--app --out --namespace --cert]`,
  `--dry-run`은 대상 키 목록만. 같은 스크립트가 app-starter 템플릿에도 동봉(이 사본은 마이그레이션/테스트용).
- **`seal-batch.ts`** — **homelab owner-local 시크릿 봉인**(앱 레포 아님 — 위 seal-secret.mts와 신뢰 맥락 다름).
  `adguard-auth`·`argocd-notify`·`files`·`ghcr-pull`(prod·files·observability 3평면) 봉인본을 선언 테이블로
  통합. `make seal-<name>`(별칭)·`make seal-all`(회전 드릴)이 호출(owner-local). 봉인 전 `secret-cert-check`
  preflight fail-closed(break-glass `--offline-ok`/`SEAL_OFFLINE=1`). 평문·해시·토큰은 kubeseal stdin 전용(값 미출력).

## 로컬 개발 헬퍼 (bun 경유)

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
- **`env-example.mts`** — SealedSecret `encryptedData` 키에서 `.env.example` 생성 — homelab 로컬 전용(앱 미배포).
  **`bun run env:example [--config <f>] [--sealed <f>] [--out <f>]`**. 값은 비움/플레이스홀더(로컬 패리티용). 연결(DB/Redis)
  URL은 스캐폴드하지 않는다(연결=SealedSecret, 로컬은 db-url/cache-url로 `.env.local` 생성).
