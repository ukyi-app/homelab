# tools/ — DX 도구 인덱스

App Platform DX 스크립트(`.mjs`)와 계약 스키마(`.json`) 모음. 각 도구의 **호출 경로**를
명시한다 — 대부분은 워크플로/`dispatch-mutation`이나 `pnpm`/`make` 타겟을 통해서만 돌고,
일부만 직접 `node tools/x.mjs`로 부른다. 라이브 변이는 전부 PR-first(사람 머지 = 승인).

> 신뢰 경계·플로우 전반은 루트 `AGENTS.md`의 "멀티레포 앱 플로우"와 (gitignored) 런북
> `docs/runbooks/app-platform.md` 참고.

## 계약 스키마 (3종 — 혼동 주의)

세 스키마는 **서로 다른 계약**을 검증한다:

| 파일 | 검증 대상 | 누가 읽나 |
|---|---|---|
| `app-config-schema.json` | **외부 앱 레포**의 `.app-config.yml` 자기선언 (v2 계약). `kind`/`resources` 필수, `db`/`redis`는 선프로비저닝 리소스 **이름 배열**, `migrate.cmd`, `secrets`(SealedSecret), `env`/`allowPlaintext` 등. | `create-app.mjs`(SSOT), `seal-secret.mjs`·`env-example.mjs`(앱 레포 측) |
| `homelab-app-schema.json` | **외부 앱 레포**의 `.homelab.yaml` 자기선언 (구 v1 계약 — `onboard-app` 경로). `db`가 `{enabled, migrateCmd}` **객체**(v2의 이름 배열과 다름), redis 없음. v1 온보딩 호환 전용. | `onboard-app.mjs` |
| `app-deploy-schema.json` | **이 레포**의 `apps/<name>/deploy/prod/` 산출물 계약. 필수: `values.yaml`·`.bindings.json`·`source-repo`. create-app이 만드는 암묵 계약의 명문화. | `scripts/check-app-deploy.sh`(SSOT — `make verify`) |

v1(`.homelab.yaml`/`homelab-app-schema.json`)→v2(`.app-config.yml`/`app-config-schema.json`)
차이: v2는 db/redis를 선프로비저닝 리소스 참조 배열로 재정의하고, digest 핀 이미지와
권위 바인딩 레지스트리(`.bindings.json`)·SealedSecret 시크릿을 추가했다. 신규 앱은 v2.

## App Platform 변이 도구 (dispatch-mutation 경유 — 직접 실행 금지)

owner가 homelab에서 `dispatch-mutation`(workflow_dispatch)을 실행하면 reusable 워크플로가
이 도구들을 호출하고 결과를 **PR**로 낸다. 직접 `node`로 돌리지 않는다.

- **`validate-mutation.mjs`** — dispatcher payload 검증기(계약표 강제). `dispatch-mutation.yml`·
  각 `_create-*.yml`이 `--action <a> --payload-file <json>`으로 호출. action별 필수/허용
  입력 외에는 전부 거부(fail-closed); 모든 입력을 비신뢰로 취급(env/파일 경유 + regex).
  `update-image`는 여기 없다(GHCR 폴링이 처리).
- **`create-app.mjs`** — v2 생성기. `_create-app.yml`이 호출
  (`--config .app-config.yml --app --repo --domain --tag sha-<sha> --digest sha256:<hex> [--sealed]`).
  스키마+비즈니스 규칙 검증 후 `apps/<app>/deploy/prod/`(values·`.bindings.json`·`source-repo`·
  kustomization) + `apps.json`(active:false) + 메모리 원장을 한 번에 산출. `--dry-run`은 plan JSON만.
- **`onboard-app.mjs`** — v1 스캐폴더(구 경로). `onboard.yaml`이 호출
  (`--payload <json> --domain <apex>`, payload에 base64 `.homelab.yaml`). `.homelab.yaml` 검증 후
  동일 산출물을 만든다. KSOPS secret-generator 분기는 **deprecated**(신규 앱은 create-app+SealedSecret).
- **`provision-db.mjs`** — create-database 프로비저너. `_create-database.yml`이 호출
  (`--name <db> [--extensions a,b] [--cluster pg]`). 공유 CNPG 안의 논리 DB + owner/ro managed role +
  비밀번호/conn SealedSecret 4개를 산출(`owner==name` 불변식, 논리 DB는 원장 행 비추가).
  비밀번호는 내부 생성→`kubeseal` stdin 직행(평문 비기록). `tools/sealed-secrets-cert.pem` 필요.
- **`provision-cache.mjs`** — create-cache 프로비저너. `_create-cache.yml`이 호출
  (`--name <cache> [--maxmemory-mi 16..1024]`). 앱별 경량 Valkey 인스턴스(cache NS) +
  conn/ro-conn SealedSecret + 원장 행을 산출. 자격은 `kubeseal` stdin 전용. cert 필요.
- **`teardown-app.mjs`** — 앱 한정 철거. `_teardown.yml`(action=teardown-app)이 호출
  (`--app <name>`). `apps/<app>/`·`apps.json` 행·원장 행만 제거 — DB/캐시 conn·CR·Valkey는
  **절대 비접촉**(리소스 철거는 teardown-resource 전담). 멱등.
- **`teardown-resource.mjs`** — DB/캐시 리소스 철거. `_teardown.yml`(action=teardown-resource)이
  호출(`--db <name>`|`--cache <name>`). 참조 0 게이트(`.bindings.json`만 신뢰) → retain(기본,
  tombstone) / purge(`--delete-data` + `--backup-verified <id>` + `--step tombstone|drop|verify|cleanup`
  상태머신, 각 step 별도 커밋). 되돌릴 수 없어 fail-closed 게이트가 두껍다.

## update-image 폴링 (bump 경로 — 인-레포 앱 이미지 전용)

- **`poll-ghcr.mjs`** — GHCR 폴링 bump **플래너**(읽기 전용, 부작용 0). `bump-poll.yml`(10분 주기)이
  `node tools/poll-ghcr.mjs --root . > plan.json`으로 호출. `source-repo` 바인딩이 있는
  `apps/*/deploy/prod`만 순회 — 앱 레포 main 커밋(최신순)을 권위로, 배포 SHA의 descendant + GHCR
  manifest 실존을 증명해 후보를 고른다. `.bindings.json`의 `autoDeploy`가 true면 `bump`(자동 PR+머지),
  false/누락이면 `propose-pr`(fail-closed 승인). 테스트는 `--fixtures <dir>`.
- **`bump-tag.mjs`** — values.yaml의 `image.tag`(+선택 `image.digest`)를 갱신하는 쓰기 도구.
  `bump-poll.yml`이 플래너 출력을 받아 `node tools/bump-tag.mjs <app> sha-<gitsha> [--digest sha256:<hex>]`로
  호출(심층 방어 재검증). `bump.yaml`(레거시)도 사용. digest는 비신뢰 입력이라 형식 검증;
  digest 미지정 시 stale digest를 제거(tag bump가 실제 이미지를 바꾸도록).

## 정적 감사 (읽기 전용)

- **`audit-orphans.mjs`** — registry(`apps.json`)↔매니페스트↔바인딩↔원장 교차 드리프트 리포트.
  `make audit`(전체)·`make ci`/`ci.yaml`(`--ci`, 배포 깨는 유형만 차단)·`_audit.yml`(dispatch
  action=audit)이 호출. `--ci`(dangling-binding/orphan-dns만 비-0)·`--strict`(전부 비-0)·기본(리포트만).

## 앱 시크릿 봉인 (앱 레포 측 — `pnpm` 경유)

- **`seal-secret.mjs`** — `.env` → SealedSecret 봉인 CLI. **`pnpm secret:seal`**(= `node tools/seal-secret.mjs`).
  `.app-config.yml`의 `secrets:[...]`만 allowlist로 봉인(선언 안 된 키는 봉인 안 함, 누락 키는
  이름만 출력하며 실패). 평문은 `kubeseal` stdin 전용. `--config --env [--app --out --namespace --cert]`,
  `--dry-run`은 대상 키 목록만. 같은 스크립트가 app-starter 템플릿에도 동봉(이 사본은 마이그레이션/테스트용).

## 로컬 개발 헬퍼 (앱 레포 측 — `pnpm` 경유)

- **`dev.mjs`** — 로컬 개발 진입점. **`pnpm dev`**(dev Postgres 기동 + 워크스페이스 dev 루프),
  **`pnpm db:up`**/**`pnpm db:reset`**(모드 1: docker postgres 기동/초기화 — 파괴 OK). docker compose는
  `tools/dev-postgres/compose.yaml`. `--dry-run` 지원.
- **`db-url.mjs`** — 모드 2(실데이터 디버깅): 클러스터 DB에 tailscale로 **읽기 전용** 직결.
  **`pnpm db:url --name <db> [--host <ts-ip>]`**. prod의 `db-<name>-ro-conn`에서 `<name>_ro` 롤
  자격(GRANT SELECT only)을 꺼내 host만 tailscale IP로 치환해 `.env.local`에 기록(값 stdout 비노출).
  파괴 수단 없음. 허용 밖 옵션 거부. `--dry-run`은 계획만.
- **`cache-url.mjs`** — db-url의 캐시 대칭. **`pnpm cache:url --name <cache> [--host <ts-ip>]`**.
  prod의 `cache-<name>-ro-conn`(+@read 전용 ACL 유저)에서 자격을 꺼내 `.env.local`의
  `<NAME>_REDIS_URL`에 기록. 파괴 수단 없음.
- **`env-example.mjs`** — `.app-config.yml`(env+secrets+db+redis)에서 `.env.example` 생성.
  **`pnpm env:example [--config <f>] [--out <f>]`**. 값은 비움/플레이스홀더(로컬 패리티용).
