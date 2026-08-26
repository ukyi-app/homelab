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
  homelab 측은 수동 확인). 앱 self-migrate는 expand/contract + 멱등이 전제이고 순서를 강제하는 Job이
  없으므로 **규칙 준수에 의존한다**(잔여 위험 — `docs/decisions/0005-data-connection-residual-risk.md`).

## homelab CLI (통합 진입점 — 워킹 스켈레톤)

- **`homelab.ts`** — `homelab` 서브커맨드 CLI **셸**(argv 파싱·--help·렌더링·stdout 순수성·종료코드만).
  동사의 실체는 `lib/verbs.ts` operation catalog가 SSOT — 이 bin 모듈은 import하면 main이 실행되므로
  MCP 등 다른 소비자는 lib 쪽을 import한다. 변이는 전부 기존 변이 디스패처를
  `gh workflow run`으로 트리거하는 래퍼가 될 예정이고(신뢰 경계 불변 — actor 가드·전역 직렬화·
  PR-first 그대로), 현재 동사는 `doctor`·`status`·`db create|url`·`cache create|url`·`app init|create|secrets|teardown`·`mcp`다.
  `homelab app create <app> [--wait]` = 수동 머지 변이(머지 = 공개 승인, auto-merge:false — 엔진은 어떤
  경로로도 auto-merge를 켜지 않는다): 기본은 run 추적+PR URL, --wait는 미머지면 '사람 머지 대기' 바운디드
  pending, 머지 관측 시 라이브 수렴(<app>-prod + values.yaml 표면)으로 전환.
  `homelab app teardown <app> --confirm <app> [--wait]` = **파괴 동사**(destructive 표시 — MCP 노출 제외).
  수동 머지 변이(머지 = 파괴 승인, auto-merge:false). 파괴 오발사 가드로 앱 이름 재입력을 요구한다:
  `--confirm` 값이 앱 이름과 정확히 일치해야 하고, 플래그가 없으면 TTY에서 재입력을 프롬프트하며 비-TTY
  (스크립트)에서는 거부한다(둘 다 디스패치 전 거부 — 원장에 gh 호출 0건). 확인은 CLI 셸(homelab.ts)이
  소유하고 서버 측 재검증은 _teardown-app.yaml이 기존대로 유지한다. `--wait`의 종결은 다른 동사와 다르다
  (`converge: "absence"`): 삭제 대상 Application은 Healthy가 될 수 없으므로, 성공 = 머지 관측 +
  Application 부재(appset finalizer cascade prune 완료 — `kubectl get … --ignore-not-found`가 빈 stdout)다.
  극성 반전 두 지점: 철거 머지는 표면(apps/<app>/…)을 제거하므로 머지 SHA에 표면이 남아 있으면 failure
  (철거 미반영)이고, Application은 sync/health가 아니라 존재/부재로 판정한다. DNS 회수는 iac/tf-reconcile
  소관이라 이 명령의 관측 대상이 아니다(결과 `dnsReclaim`에 명시).
  `homelab app secrets <app> [--wait]` = 이중 모드(`lib/secrets.ts`): 앱 레포 안(마커 .app-config.yml +
  canonical remote)이면 seal(벤더 tools/seal-secret.mts 위임)→봉인본만 커밋→push→원격 main 도달성 증명→
  update-secrets 디스패치를 연쇄하고 선행 조건(main·클린 트리·canonical) 실패 시 디스패치 없이 거부, 밖이면
  디스패치만. `--no-seal` = 재봉인 없이 이미 커밋·push된 봉인본을 재디스패치(push 성공·디스패치 실패 후
  재실행 수렴 경로 — kubeseal 암호문은 매번 달라 재봉인은 언제나 새 커밋·새 PR·파드 롤링). 디스패처가
  변경 없음을 보고하면(PR 0) no-op variant(머지 SHA 없음, --wait는 main 기준 표면 blob 동치로 검증).
  seal 위임 argv는 벤더 도구 계약 그대로(`--config .app-config.yml --env .env --app <app>`) — 평문은
  그 도구의 kubeseal stdin 전용, CLI는 .env를 읽지 않는다.
  `homelab cache create <name> [--maxmemory-mi 16..1024] [--wait]` = 변이 엔진의 두 번째 인스턴스
  (create-cache 디스패치, 빈 maxmemory=디스패처 기본 64 소유, 수렴 집합 cache-prod·data-conn-prod,
  표면 = 인스턴스 deployment.yaml + conn 봉인본). `homelab cache url` = conn URL 엔진
  (`lib/conn-url.ts`)의 catalog op — 다른 동사와 같은 envelope 계약(--json), 사람용은 렌더러 소유.
  `homelab db create <name> [--ext a,b] [--wait]` = 첫 변이 동사(공유 변이 엔진 `lib/mutation.ts`의
  첫 인스턴스): create-database 디스패처를 correlation 수령증과 함께 트리거 → nonce 에코 run-name으로
  자기 run 특정(정확히 1개, ≥2=race exit 3) → conclusion 추적(실패 잡 열거) → `--wait`면 auto-merge
  머지 관측 + Application 집합(cnpg-data·data-conn-prod) 수렴(머지 SHA 후손+Synced+Healthy+표면 실존,
  후손 리비전 표면 부재=superseded). KUBECONFIG 부재=머지까지 확인+omitted=["live"].
  `homelab db url` = conn URL 엔진(`lib/conn-url.ts`)의 catalog op — envelope 계약(--json)·F2
  채널 분리·상호배타는 엔진 술어 소유(구 패스스루 계약은 티켓 08에서 op 계약으로 대체됨).
  `homelab status [<app>] [--run <url>|--pr <url>] [--json]` = 상태 관찰(관측 전용): 인자 없음=
  전체 앱 목록·요약(레포 데이터), `<app>`=핀·바인딩·최근 run·열린 PR(+KUBECONFIG 있으면 ArgoCD
  `<app>-prod` sync/health, 없으면 라이브 구간 생략 — envelope.omitted=["live"]·exit 0), 핸들
  조회=run/PR URL로 그 오퍼레이션 단위 상태(대기·conclusion·머지 여부 — MCP tool 입력과 같은 계약).
  **설치**: `bun link`(레포 루트) → package.json `bin`이 `homelab`을 전역 PATH에 심링크. 유일하게
  셰뱅+exec 비트를 갖는 .ts다(test_shebang-exec.bats가 bin 선언에서 예외를 파생). 레포 밖(앱 레포
  디렉토리 포함)에서도 동작한다(자기 위치는 import.meta 기준 해석).
  `homelab doctor [--json]` = 플랫폼 전제 진단(관측 전용): gh 인증·로그인=HOMELAB_OWNER 일치(actor
  가드 사전 검증)·토큰 스코프(repo·workflow, 헤더 부재=fine-grained 추정 warn), bun·kubeseal 존재,
  KUBECONFIG 유무(부재=warn·깨진 경로=fail), 템플릿 접근성·호환성(스캐폴더 비대화형 계약 +
  컴파일 아키타입 3종 TARGETARCH — site는 arch 중립이라 대상 아님). fail ≥ 1이면 exit 1.
  테스트: `tools/tests/test_homelab-cli.bats`(라우팅·계약)·`test_homelab-doctor.bats`(진단 —
  PATH stub + NUL argv 원장, 하네스 `tools/tests/helpers/cli_stub.bash`).
- **`cli-result-schema.json`** — CLI `--json` 출력·MCP tool 결과가 공유하는 **결과 계약 SSOT**
  (envelope `homelab-cli/1`). variant 어휘(success/failure/race/skip/pending/no-op/superseded)·
  종료코드 매핑(x-contract.exitCodes — pending=1 근거 포함)·stdout 순수성(--json이면 stdout은
  오브젝트 하나, 사람용은 stderr)·MCP 에러 매핑을 정의한다. CLI가 런타임에 읽는다(코드 상수로
  복제 금지). ⚠️ **생성물이다 — 직접 편집 금지**: 행렬 분기·verb enum은 `generate-result-schema.ts`가
  기술자 행에서 생성한다(수정은 기술자/생성기 조각 → `--write` 재생성, byte 드리프트 게이트가 강제).
  골든 픽스처: `tools/tests/fixtures/homelab/*.golden.json`.
- **`generate-result-schema.ts`** — cli-result-schema.json **생성기**(cli-deepening 심화 3): 행렬
  분기(allOf member 0)·verb enum은 기술자 행(lib/catalog-rows `CONTRACT_ROWS`)에서, initSuccess·
  initFailure의 archetype enum은 플랫폼 좌표(lib/platform `ARCHETYPES` — 심화 6 후속)에서 생성하고,
  x-contract·variant→exitCode 재진술·나머지 definitions 본문은 수제 조각으로 보존한다(컴팩트 스타일 —
  과거 리뷰의 의도적 결정). 기본 `--check`(byte 대조 — make verify 로컬 보조), `--write`(재생성).
  **게이트 강제는 bats**(test_result-schema-gen.bats — run-bats 수집)가 담당한다. 기술자(행·좌표) 외
  무참조라 생성물 부재·파손에서도 재생성 성립(설계 게이트 r1 D3). 이름이 가드 열거 규약(check-*)의
  밖인 것은 의도다 — 생성기 겸 게이트라 check- 접두가 거짓이 된다.

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
- **`ensure-bump-pr.ts`** — bump PR **멱등 실행기**(조회 → 결정 → 변이를 한 seam에). `bump-poll.yaml`이
  브랜치(`bump-poll/<kind>/<name>-<tag>` — **RUN_ID 없음**: 같은 bump = 같은 브랜치, kind가 동명 app/bespoke를 가른다)를 최신 main에서 재구축해
  로컬 커밋을 얹은 뒤 이 도구를 부르면, **원격 변이(push·PR·무장/해제)는 전부 이 도구만** 한다.
  **조회 = 상한 없는 완전 열거(ref-연결)**: `gh api graphql`의
  `repository.ref(qualifiedName:refs/heads/<branch>).associatedPullRequests(states:OPEN, first:100)` connection을
  **한 페이지씩** 소비(`--paginate --slurp` 금지 — 전 페이지를 한 `spawnSync` 캡처에 담으면 버퍼 초과로 gh가
  살해된다) + `git ls-remote --heads origin <branch>`. ★ **ref-연결이라 포크를 구조적으로 배제**한다(라이브 실측:
  associatedPullRequests는 **head-연결** — 우리 ref가 head인 same-repo PR만 준다, base=main에도 0건) → 질의 작업
  (서브프로세스·페이지 수)이 **포크 수와 무관**하다. 옛 `pullRequests(headRefName)` 이름-매치는 포크가 같은
  브랜치명으로 오염시켜 폴링·회수를 포크 수만큼 태울 수 있었다(R-40). ★ **ref 관측은 ls-remote와 교차 검증**한다
  (R-43): ref-조회의 `ref`(부재=null / 존재+`target.oid`)와 `git ls-remote`는 **비원자적 두 읽기**다 → create/adopt는
  **둘이 합의**할 때만 한다(둘 다 부재 → create · 둘 다 존재 + OID 일치 → adopt · 한쪽만 존재하거나 OID 상이 →
  **fail-closed**, 회수 경로는 `revocationBlind`). 예전엔 `ref:null`을 "PR 0건"으로 접은 뒤 ls-remote만 보고 adopt해,
  stale/저하된 GraphQL 뷰가 **실재하는 PR을 숨기면** 남의 커밋을 덮었다. ★ **회수·무장도 3자 OID 합의**를 요구한다
  (R-44): 열거한 `ls-remote` OID를 관측 씸(`observeBranchPr`)에 넘겨 **GraphQL ref tip · ls-remote tip · 신뢰 PR
  `headRefOid`가 모두 일치**할 때만 무장을 유지·부여·회수한다. 어긋나면(형제 조회가 다른 tip의 빈 connection을
  주거나, PR head가 ref tip과 다르거나) `revocationBlind`(회수 경로)·fail-closed(주 경로)로 접는다 — stale tip의
  "PR 0건"은 실제 tip에 무장 좀비가 없다는 증거가 아니다. `foldConnection`은 **페이지 간 OID 변화도 거부**한다.
  마지막 페이지가 `hasNextPage:true`면 fail-closed(완전성 증명). ★ **force-push 직전엔 인가를 재검증**한다
  (R-46/R-47): 초기 스캔~push 사이에 남이 이 head로 다른 base PR을 열거나 리뷰어가 신뢰 PR에 리뷰·hold
  라벨을 달 수 있다 → rebuild 직전 재조회로 **경합 없음 + 같은 신뢰 PR·같은 head + `humanTouch===null`**을
  요구한다(TOCTOU 창 최소화 — F-0는 ref 생성/push 벡터를 닫아 노출을 좁힐 뿐, 동시 PR 생성 자체는 못 없애는
  수용된 R-46 잔여). **검색 API 금지** — 결과적 일관성이라 직전 주기가
  만든 PR이 **거짓 부재**가 된다.
  **식별 = `(head, base)` 쌍 · 신뢰 = 동일-레포 + `author.__typename == "Bot"` + 정규화된 writer login**
  (파서·신뢰 술어는 각각 **하나뿐**이고, `author` **키 부재는 "우리 것 아님"이 아니라 관측 실패**다).
  판정: 신뢰 PR 없음+브랜치 없음 → `create` / 신뢰 PR 없음+**고아 브랜치** → `adopt`(원격 OID lease) /
  신뢰 PR + **DIRTY 또는 BEHIND** → `rebuild`(`--force-with-lease=<ref>:<headRefOid>` force-push, PR 재사용) /
  그 외(CLEAN·BLOCKED·**UNKNOWN**…) → `skip`(변이 0). 조회 실패·깨진 JSON·스키마 위반은 fail-closed.
  ⚠️ lease는 반드시 `<ref>:<기대 OID>` — bare lease는 원격 추적 참조가 없어 stale 거부된다.
  ⚠️ **`gh pr update-branch`는 절대 부르지 않는다** — head가 머지 커밋이 되어 아래 소유권 증명이 **영구 실패**
  (그 앱의 bump가 하드 스톨)한다. 그래서 `bump-poll/*` 네임스페이스의 **유일한 소유자가 이 도구**이며,
  `pr-sweeper`는 이 접두를 더는 선택하지 않는다(다른 봇 접두는 그대로).
  **소유권**: force-push·무장 전에 원격 head가 **우리 bump 커밋**(writer ident + 결정적 커밋 메시지)임을
  증명해야 한다 — 미증명이면 변이 0이고 **이미 걸린 무장은 회수**한다. ⚠️ 커밋은 서명되지 않으므로 이건
  **안전 인터록이지 인증이 아니다**(강제 가능한 불변식은 `bump-poll/**`를 writer App 전용으로 예약하는 ruleset).
  **무장은 판정과 직교하는 축이자 양방향 reconcile이다**: `--action`(필수·기본값 없음 — 플래너 `.action`을
  **그대로**)이 `bump`면 무장 갭을 그 run의 **판정이 무엇이든** 메우고(create/adopt는 생성 직후), `propose-pr`은
  **절대 무장하지 않고 낡은 무장은 해제**한다(사람 머지 = 배포 승인). 무장을 켜는 **별도 플래그는 없다** —
  있으면 호출부가 두 레인 모두에 넘기는 것만으로 승인 게이트가 우회된다. **사람의 흔적**(리뷰·리뷰어 요청·
  assignee·사람 코멘트·`hold` 라벨·draft·reopen — **잘렸거나 관측 불가면 "흔적 있음"**)은 신뢰 PR의 force-push(rebuild)를 막는다.
  **`--reconcile-only`** = **해제 스윕 전용** 패스(push·create·무장 0). 회수는 보안 속성이라 플래너의
  가용성에 의존하면 안 된다 → `bump-poll.yaml`의 **별도 job**에서 **writer 토큰만으로 매 주기** 돈다. 대상은
  `bump-poll/*` **원격 ref 전체**(`--kind`·`--name`·`--tag`·`--action` 거부 — target은 브랜치명에서 복원), 레인은 autoDeploy
  SSOT(`.bindings.json`/`.image-pin.json`)에서 직접 읽고 **부재·파손도 `propose-pr`**(인가 문맥의 fail-closed는
  "아무것도 안 함"이 아니라 **"권한을 거둠"**). bump 레인은 그 앱의 **가장 새로운** 신뢰 PR만 무장을 유지하고
  **더 오래된 형제는 전부 회수**한다(순서 불명 = 전부 회수 — 과잉 회수는 다음 주기가 재무장하지만 과소 회수는
  무승인 머지다). **회수 대상을 가릴 수 있는 관측 실패는 그 자체가 회수 실패**다 → 집계해서 **모든 변이를 마친 뒤**
  비-0 종료(한 앱의 실패가 다른 앱을 굶기지 않는다). superseded 형제는 **무장 해제만** 한다 — 자동 close·브랜치
  삭제는 이 도구의 계약이 아니다(파괴는 사람/owner 몫).
  테스트는 `git`/`gh`/`bash` **PATH stub**으로 argv를 NUL 구분 원장에 기록해 순서·부작용·인자 경계를
  단언(`tools/tests/test_ensure-bump-pr.bats`), 호출부 계약은 `tests/gates/test_bump-poll-callsite.bats`.
- **`bump-tag.ts`** — values.yaml의 `image.tag`(+선택 `image.digest`)를 갱신하는 쓰기 도구.
  `bump-poll.yaml`이 플래너 출력을 받아 `bun tools/bump-tag.ts <app> sha-<gitsha> [--digest sha256:<hex>]`로
  호출(심층 방어 재검증). `bump.yaml`(인-repo build write-back, workflow_run)도 사용. digest는 비신뢰 입력이라 형식 검증;
  digest 미지정 시 stale digest를 제거(tag bump가 실제 이미지를 바꾸도록).
- **`run-bump-plan.ts`** — bump **항목 러너**(F-1 — 인-워크플로 셸 루프 대체). `bump-poll.yaml`의 bump 스텝이
  `bun tools/run-bump-plan.ts --plan plan.json` 한 줄로 호출 — plan.json의 bump/propose-pr 항목을 **항목마다 격리
  git worktree**에서 오케스트레이션한다(worktree add → bump-tag → commit(writer 신원 명시) → ensure-bump-pr →
  worktree remove, 모든 경로 정리). 공유 worktree/index가 없어 R-38(종료상태만 격리)·H-2(staged digest-exporter
  누출)가 **구조적으로 불가능**하다. plan 입구는 bump-plan module의 `decodePlan`(fail-closed — 미지 action·
  신원 불량·kind↔pin 부정합은 red)이고, target 신원은 `--kind/--name` 쌍으로 ensure-bump-pr까지 관통한다.
  원격 변이(push·PR·무장)는 **ensure-bump-pr만** 하고, 러너는 플래너 레인
  (`--action`)을 재해석 없이 **그대로** 넘긴다(auto-merge 켜는 별도 플래그 없음 — 승인 게이트 우회 불가). 실패는
  fail-closed 집계 후 비-0. 앱명은 공유 `APP_NAME_RE`(identity.ts)로 검증(분기 금지). 테스트는 **진짜 git worktree
  fixture + ensure-bump-pr stub**(`--ensure-bin`/`--ensure-script` argv seam)으로
  격리·H-2 staged-잔여·순서·레인·집계·**실효 소유권**(정체성·커밋 메시지를 실행기 소스에서 파생해 대조)·
  베스포크 `--pin` 레인을 실증(`tools/tests/test_run-bump-plan.bats`). races-4 TOCTOU의 정적 절반은
  `tools/tests/test_bump-poll-toctou.bats`, 워크플로 call-site **경계**(bump 스텝의 명령 = 러너 호출 하나)는
  `tests/gates/test_bump-poll-callsite.bats`.
- **`repin-ops-image.ts`** — ops 미러 이미지(`pg-tools:18-rclone`·`skopeo:alpine`)의 인라인 `@sha256`
  핀을 새 digest로 일괄 재핀(부분 갱신 skew 차단). CLI: `<image-key> <digest>`. 이미지별 canonical 태그·
  바닥값은 도구 안 CATALOG가 SSOT. `bump.yaml`이 build 완료 후 이미지별로 호출. digest 형식 검증·멱등.
  ⚠️ **대상을 하드코딩하지 않고 레포에서 파생한다**(D-1). 예전엔 `CONSUMERS` 4파일이 상수였고 같은 4개를
  `tests/gates/test_pgtools-digest.bats`가 다시 하드코딩했으며 헤더 주석은 "5개 소비처(4파일)"였다 —
  **세 산출물이 서로는 일치하고 레포와는 어긋났다**. 실측(2026-07-28): 목록 밖의 `adguard/rewrite-reconciler`
  ·`victoria-stack/pvc-du-exporter`가 낡은 digest에 묶인 채 재핀 대상이 아니었고, 그런데도 도구는
  `changed/CONSUMERS.length`로 **성공을 보고**했다. 이제 `repo-walk`의 `image-ownership` 스코프로 열거하고
  참조 0건이면 **비-0으로 죽는다**(조용한 no-op 금지). `--root`로 스캔 루트.

## 공유 커널 (lib/ — 콜사이트가 정책 소유, 단 정책이 콜사이트마다 갈릴 때)

- **`lib/contract.ts`** — 결과 계약 SSOT 리더: cli-result-schema.json의 x-contract(envelope 버전·
  종료코드 매핑)를 런타임에 읽어 노출(`ENVELOPE`·`EXIT`·`exitFor`·`Envelope` 타입 — 코드 상수
  복제 금지). 소비자: `homelab.ts`·`lib/verbs.ts`·(예정) MCP 서버.
- **`lib/verbs.ts`** — 동사 operation catalog(transport 중립·부수효과 없는 import-safe SSOT).
  행 = path(라우팅 어휘)+desc(--help)+op(타입 입력→계약 Envelope). argv 파싱·렌더링은 CLI 셸
  소유이고 MCP는 op를 직접 호출한다(structure r1 A1·B1). 후속 동사는 여기 행을 추가.
- **`lib/catalog-rows.ts`** — 변이 레인 신원 행 + 결과 계약 행(**순수 기술자, import 0** — 설계 게이트 r1 D3).
  액션별 한 행 = 디스패처/reusable 파일명 · 디스패치 입력 이름 · 브랜치 중립 패턴({key}·{runId}·{tag}) ·
  수렴 Application 집합+표면 패턴. 생성 방향(verbs·secrets의 `laneMutationFields`)과 파싱 방향(status의
  `isDispatchLaneBranch`/`laneBranchTail`)이 같은 행에서 파생된다. bump-poll은 CLI 동사 없는
  파싱 전용 레인(tail=tag — TAG_RE 조합은 소비자 몫). 워크플로 YAML과의 정적 parity 가드는
  후속 티켓이 이 행을 대조 축으로 쓴다. 왕복·리터럴 앵커는 test_lane-rows.bats.
- **`lib/resource-layout.ts`** — 리소스 산출물 레이아웃 커널(cli-deepening 심화 4, CONTEXT.md
  "산출물 레이아웃"): kind+name → 산출물 집합(파일 경로 · kustomization 엔트리 · role 라벨
  handles/envKeys · 원장 행 · tombstone 키)과 **scope 태그**(purge-제거/공유-잔존/수동-이연 —
  teardown purge의 의도된 부분집합을 데이터로 성문화). 역방향 `classifyArtifact`(경로/엔트리 →
  {kind, name, role})가 같은 커널에 산다 — 소스 없는 고아 conn도 분류된다(설계 게이트 r1 D2).
  순수 문자열 유도만(yaml 편집 비흡수). 왕복·리터럴 앵커는 test_resource-layout.bats.
  소비 4모드: provision-db/cache(정방향, paths·handles·envKeys) · teardown-resource(역제거 —
  `purgeArtifactsFor` 삼중·`TOMBSTONES_PATH`) · audit-orphans(감사 — classify 소비, orphan-conn/
  malformed-conn 축) · db-url/cache-url(읽기). 레인 행(catalog-rows)과의 표면 경로 일치는
  import-0 계약상 parity 가드(test_lane-rows.bats)가 대조한다.
- **`lib/conn-url.ts`** — conn URL 엔진(`runDbUrl()`·`runCacheUrl()`·입력 술어 — cli-deepening
  심화 5): db url/cache url의 실체. 계획이 타입 값(UrlResult ↔ urlResult 스키마 1:1)이라 계획 키
  드리프트(release r2-a5 클래스)가 컴파일 타임 오류로 강등. 평문 비출력·F2 채널 분리(--admin ↔
  .env.admin.local)·RW/ADMIN 상호배타는 엔진 소유. 핸들·env 키는 레이아웃 커널 소비. 소비자 3:
  CLI 셸·MCP(같은 op)·bin 껍데기(db-url/cache-url — 기존 출력 계약 보존). envLocal·envDir 축은
  입력에 존재하되 MCP는 envDir만 노출(설계 Q9).
- **`lib/mutation.ts`** — 공유 변이 엔진(`runMutation()`) — 변이 동사들의 공통 골격: correlation
  nonce → 디스패치 → run 특정(정확히 1 — 관측 차분은 신원이 아니다) → 추적 → PR 특정 →
  [--wait] 머지 관측 + Application 집합 수렴(후손 판정은 gh compare — 로컬 git 이력 무의존,
  health 단독 판정 금지, 후손 리비전 표면 부재=superseded). 시간 심 pollMs/deadlineMs +
  HOMELAB_CORRELATION 주입(테스트). 소비자: verbs.ts `db create`(이후 cache/app 변이 동사).
- **`lib/exec.ts`** — 외부 명령 실행 커널(`sh`·`ghJson` — ghJson은 오브젝트/배열 jq 전용, 스칼라
  jq는 raw라 sh 직접, `git`·`pushRoutes` — push 지향 관측 `git remote get-url --push --all`:
  pushurl 복수·insteadOf/pushInsteadOf 전개 반영) — status·mutation·init·secrets 공유. 판정 정책은
  콜사이트 소유(doctor의 gh()는 ENOENT 판별 자기 정책이 있어 별도 유지). push 라우팅 검사의
  테스트 전용 완화 플래그 이름(`ALLOW_PUSH_REWRITE_ENV` = HOMELAB_TEST_ALLOW_PUSH_REWRITE)도
  여기 산다 — HOMELAB_CORRELATION 주입과 같은 부류(테스트 심).
- **`lib/secrets.ts`** — app secrets 엔진(`runAppSecrets()`·`appSecretsInputError()`): 이중 모드 판별(git
  toplevel의 .app-config.yml 마커 → canonical remote(identity.isCanonicalClone) + push 라우팅 안전
  (identity.pushRouteError — pushurl/insteadOf/pushInsteadOf 재배선 fail-closed) 필수, 아니면 거부 /
  마커 없음 → 디스패치만),
  연쇄 각 단계를 사후조건으로 증명(봉인본 외 변경 거부·ls-remote 도달성). 디스패치는 공유 변이 엔진
  (noopOnMissingPr — pr-first-commit 멱등 no-op를 정당한 no-op variant로).
- **`lib/status.ts`** — homelab CLI status 엔진(`runStatus()`·`statusInputError()`). 계층 계약:
  레포(핀·바인딩)+GitHub(run·PR)가 기본, 라이브(ArgoCD)는 KUBECONFIG 있을 때만(부재=생략,
  조회 실패=live.error — 유일한 선택 계층). GitHub 계층 오류는 fail-loud(빈 목록 위장 금지).
  입력 검증 술어는 CLI(usage exit 2)·MCP(invalid params)가 공유. 관측 전용(gh api·kubectl get만).
- **`lib/doctor.ts`** — homelab CLI doctor 진단 엔진(`runDoctor()`). 점검 항목·상태 판정·detail
  문구를 소유한다(관측 전용 — `gh api` 읽기만, 테스트가 argv 원장으로 강제). 선행 gh-auth 실패로
  판정 불가한 항목은 pass가 아니라 fail(fail-closed). detail은 결정적(절대경로·시각 금지 — 골든
  픽스처 계약). 소비자: `homelab.ts`(이후 MCP 서버도 같은 엔진 재사용 예정).
- **`lib/init.ts`** — app init 엔진(`runAppInit()`·`appInitInputError()`): 앱 레포 시작 로컬 체인
  (변이 디스패처 아님 — correlation 없음). preflight(부수효과 0) → 레포 생성(기본 private) → 클론
  (canonical 판정 identity.isCanonicalClone) → push 라우팅 게이트(identity.pushRouteError) →
  스캐폴드 → invocation marker(.homelab-init) → 커밋·첫 push → [--dispatch-secrets면 시크릿 쌍].
  각 단계는 사후조건으로 증명하고 재실행이 그 지점부터 수렴한다(멱등). 소유 증명은 계보가 아니라
  마커(plan r2 r2-a2) — 마커 없는 기존 레포는 fail-closed(--adopt로만). 시크릿 쌍은 원자적(절반
  상태 결과 명시·재실행 수렴), private key 값은 --body-file 전용이라 argv/출력에 비노출(엔진이 키를
  읽지 않는다). variant: success(한 단계 이상 수행)·no-op(이미 완료)·failure(preflight/거부/단계 오류
  + checkpoint).
- **`lib/mcp.ts`** — MCP 서버(`runMcpServer()`·`handleRequest()`): stdio JSON-RPC 2.0(개행 구분)
  위에 파괴 제외 전 동사를 tool로 노출한다. MCP 프레젠테이션 계층(homelab.ts가 CLI를 소유하듯) —
  tool 이름(verb.path.join("_"))·입력 스키마·인자→op 입력 매핑·JSON-RPC 프레이밍만 갖고 동사 실체는
  verbs.ts op다. 노출 = VERBS 중 !destructive(teardown 제외, 초기화 totality 가드가 파괴 누출·신규
  동사 누락을 fail-closed 차단). --wait류 미노출(동기 바운디드)·명시 경로(secrets=repoPath·init=
  parentDir, cwd 추론 없음)·결과는 CLI --json과 같은 envelope(isError는 x-contract.mcp variant 매핑)·
  usage 오류는 invalid params(-32602). 무상태 — 동시 호출은 run/PR URL 핸들로 독립, 재시작 후 정상.
  url 패스스루(db/cache url)는 캡처 실행(stdio 오염 방지)+명시 envDir. `homelab mcp`가 진입점(서버는
  transport 모드라 catalog 밖 — 자기 자신 비노출).
- **`lib/template-contract.ts`** — 스캐폴더 비대화형 계약 SSOT(`SCAFFOLD_CONTRACT_MARKERS`·
  `scaffoldContractError()`): doctor(사전 진단)와 init(실제 실행 preflight)이 **같은 술어**를 공유한다
  (structure r1 a3 — 두 번째 소비자 init이 생겨 추출). 마커 = --archetype·--name·--yes. 둘이 갈리면
  doctor가 통과시킨 템플릿을 init이 실행 중 거부하는 계약 갭이 생긴다.
- **`lib/platform.ts`** — 플랫폼 좌표 SSOT(HOMELAB_REPO·TEMPLATE_REPO·ARCHETYPES·
  ARCH_NEUTRAL_ARCHETYPES·COMPILED_ARCHETYPES). doctor가 검증한 대상과 이후 init이 쓰는 대상이
  콜사이트마다 갈리지 않게 한 곳에서만 정의(identity.ts와 같은 원칙 — 저긴 이름 형식, 여긴 좌표).
  **아키타입 어휘 리터럴은 ARCHETYPES 한 곳뿐**이고 나머지 표면은 전부 파생이다(cli-deepening 심화 6):
  MCP `app_init` inputSchema enum(mcp.ts)·결과 계약 enum(생성기 → cli-result-schema.json initSuccess·
  initFailure)·CLI 사용법(homelab.ts)·doctor TARGETARCH 검사 대상(COMPILED = ARCHETYPES − 중립 opt-out,
  신규 아키타입은 기본 검사 대상 — fail-closed). 리터럴 사본이면 아키타입 확장 시 init 엔진은
  수용하는데 MCP만 -32602로 거부하거나 결과 계약만 낡는 드리프트가 난다. 강제: test_platform.bats(파생
  계약 + `fullstack` 감시 토큰 전역 가드)·test_homelab-mcp.bats(입력·결과 두 표면의 확장 수용)·
  test_result-schema-gen.bats(생성물 파생)·test_homelab-appinit.bats(사용법 파생). **확장 절차**는
  platform.ts ARCHETYPES 주석이 SSOT다(추가 → 중립 여부 → `--write` 재생성 → bats 손 앵커 갱신).
- **`lib/schema-check.ts`** — cli-result-schema.json 전용 미니 검증기(`schemaErrors()`, ajv 무의존).
  지원 키워드 화이트리스트 밖은 **throw로 fail-closed**(모르는 제약의 조용한 통과 차단).
  골든 픽스처·계약 테스트 전용 — create-app.ts의 check()는 .app-config.yml 정책 소유가
  콜사이트라 별개 유지.
- **`lib/repo-walk.ts`** — 저장소 스캔 워커(`walkManifests(scope)`·`listUnits(scope)`). 가드들이
  각자 갖던 **열거 의미론**(tracked=git ls-files vs filesystem)·**제외 어휘**·**YAML 파싱**·
  **유닛 파생**을 한 곳에 모은다. ⚠️ scan-floor는 **두지 않는다** — 열거자는 "글롭이 깨져 0건"과
  "정당하게 0건"(앱 0개 = 첫 온보딩 전)을 구별할 도메인 지식이 없다. 소비자가 이미 자기 바닥값을
  갖고 있고(MIN_SCAN), 그건 의미론적 필터 이후를 세므로 더 정확하다. 스코프는 **이름 붙인 고정 집합**이다 — 조합 가능한
  기술자로 열면 제외 어휘가 호출자로 되밀려 지금의 9벌 중복이 API로 승격된다.
  ⚠️ 스코프는 **의미론적 필터를 담지 않는다**: 어떤 소비자에겐 맞는 필터가 다른 소비자에겐
  치명적이다(audit-orphans는 `values.yaml` 있는 앱만 보면 되지만 check-app-deploy는 그 파일의
  **부재**를 잡아야 한다 — 열거자가 미리 거르면 위반이 사라진다). 미등록 스코프·열거 붕괴는
  throw(exit·문구는 콜사이트 소유). 셸 가드용 CLI(`--manifests <scope> --root <path>`)가 경로 목록만
  내보내므로 셸은 자기 grep/yq 추출을 유지한다 — 종료코드 0/2(사용법·미등록 스코프).
  등록 스코프: `platform-manifests`(차트 소스 **제외** — 렌더 전 템플릿은 YAML 파싱 불가) ·
  `platform-image-refs`(차트 소스 **포함** — 공급망 가드는 조용히 좁히면 안 된다) · `apps-values` ·
  `apps-manifests` · `rules`(알림 룰 매니페스트 — 그 디렉토리를 검사 대상으로 볼지 생산자로
  볼지는 소비자가 정한다) · `producers`(레포 전역 — tracked라 .scratch/·워크트리 잔재가 구조적으로
  빠진다. 구 큐레이트 7-루트 목록은 그 잔재 때문이었으므로 근거가 사라져 제거) ·
  `guards`(가드 진입점 3계열 = `scripts/(check|verify)-*.sh` · `tools/(check|verify)-*.ts` ·
  `tests/gates/*.sh` — **공용 TEST_HARNESS 제외 어휘 금지**: 그 어휘의 `tests?/`가 ci.yaml이 직접
  부르는 e2e 하네스 8개를 통째로 지운다. 그 8개가 정확히 회계 커버리지 0이던 대상이다) ·
  유닛 스코프 `apps`/`platform`(디렉토리 존재 질문이라 **filesystem** 열거 —
  실측상 tracked와 결과 동일하고 픽스처 비용만 크다).
  같은 트리를 보는 두 스코프가 다른 이유는 **질문이 다르기** 때문이다("배포되는 매니페스트인가"
  vs "이미지 참조를 담을 수 있는가"). 소비자: `check-resource-limits`·`check-image-pins`·`check-app-deploy`·`check-skeleton`·
  `check-app-netpol`·`audit-orphans`·`poll-ghcr`·`check-alert-rules`·`check-guard-authority`·
  `lib/status`(homelab status — `apps` 유닛 열거). (`surface-hash`는 **대상 아님** — 워킹트리
  해시라 미커밋 파일을 포함해야 커밋 후 값과 일치한다.)
- **`lib/image-pin.ts`** — 배포 핀 형식 커널(TAG_RE/DIGEST_RE·인라인 핀 parse/format·descriptor
  타입·autoDeploy fail-closed). 순수 형식 판정과 왕복만 소유하고 파일 I/O·exit·에러 문구는
  콜사이트가 소유한다 — **정책이 콜사이트마다 갈리기** 때문이다(poll-ghcr는 null을 refuse로,
  bump-tag는 exit 2로). 콜사이트마다 정규식이 갈리는 오배포 표면을 SSOT로 없앤다.
  소비자: `poll-ghcr`·`bump-tag`·`create-app`.
- **`lib/sealed-contract.ts`** — 봉인 계약 커널(`readSealed(raw, app)` 단일 함수). 6검증(kind·
  namespace=prod·name=`<app>-secrets`·encryptedData 비었음·키 UPPER_SNAKE·**strict scope**)의 **판정과
  에러 문구** + checksum + **디스크에 쓸 바이트**를 소유한다. strict scope = scope 확대 어노테이션
  (namespace-wide/cluster-wide) 거부(`check-app-deploy.sh` 게이트와 같은 정책의 툴-경로 adapter).
  image-pin과 달리 **에러 문구까지** 커널이 갖는 이유:
  두 소비자가 **같은 정책을 같은 문구로** 판정하기 때문이다(정책이 콜사이트마다 갈리지 않는다).
  콜사이트가 남기는 것: `::error::<tool>:` 접두·exit·파일 I/O·optionality·envFrom/kustomization 배선 모드.
  `facts.bytes`/`facts.checksum`이 한 값이라 "해시한 것 ≠ 디스크에 쓴 것"이 구조적으로 불가능(#299).
  소비자: `create-app`(그린필드)·`update-secrets`(제자리 병합).

## 정적 감사 (읽기 전용)

- **`audit-orphans.ts`** — registry(`apps.json`)↔매니페스트↔바인딩↔원장 교차 드리프트 리포트.
  `make audit`(전체)·`make ci`/`ci.yaml`(`--ci`, 배포 깨는 유형만 차단)·`audit.yaml`(스케줄
  reconciler)이 호출. `--ci`(orphan-dns/activation-exposure-drift만 비-0)·`--strict`(전부 비-0)·기본(리포트만).
- **`ledger-to-json.ts`** — `docs/memory-ledger.md` 표 → conftest 입력 JSON(행 파서 SSOT=`lib/ledger-totals.ts`).
  `scripts/verify-ledger.sh`(= `bun run verify:ledger`, gate)가 호출. 라이브 무관.
- **`check-guard-authority.ts`** — G1 권위 경로 회계: 모든 가드(`lib/repo-walk.ts`의 `guards` 스코프)가
  **실제로 실행되는 경로를 최소 하나** 갖는지 계산한다. 가드가 추가되고 README에 등재되고 전 게이트가
  초록인데 **CI에서 한 번도 안 도는** 상태를 막는다. **계산하되 선언하지 않는다** — 소유권 레지스트리를
  만들지 않고 멤버십을 실제로 정하는 것에게 묻는다: `ci.yaml`의 `gate` job(로컬 composite action 전개) ·
  `run-bats.sh --list`(수집 bats) · `on.schedule` 워크플로 · `make -n <타깃>`(Makefile 텍스트 파싱 아님) ·
  `package.json` 별칭 전이 해소(`bun run verify:ledger` → `verify-ledger.sh`).
  **`make verify`·`make ci`는 비권위**(CI에서 돌지 않는 로컬 mirror)로 분리해 센다. 판정은
  `authoritative >= 1` — venue는 의도적으로 겹치므로 정확히-하나 모델이면 오탐이 난다.
  `tests/gates/test_guard-authority.bats`가 호출(픽스처 red-green + 실 레포 전건).
- **`check-image-ownership.ts`** — G2 이미지 **소유권 회계**: 레포의 모든 이미지 참조가 **권위 있는 핀
  소유자**를 갖는지 계산한다. `scripts/check-image-pins.sh`와 **다른 질문**이다 — 저건 "digest로
  핀됐는가", 여긴 "그 digest를 **누가 갱신하는가**". 둘은 독립이다(실측: `pg-tools:18-rclone`이 두
  digest로 갈렸는데 핀 게이트는 **둘 다 통과**시켰다 — 핀의 *존재*만 보고 *일치*는 안 본다).
  **두 축을 분리한다**: freshness 소유자(새 버전을 가져오는 것) ≠ digest 소유자(immutable 핀을
  보증하는 것). helm 차트 내부 이미지가 그 전형 — 차트 **버전**은 Renovate 소유지만 내부 이미지는
  렌더 시점 mutable tag라 digest 소유자가 **없다**.
  소유자는 **계산한다**: ops 미러 이미지→`repin-ops-image` · `apps/*/deploy/prod/values.yaml`·`.image-pin.json`
  descriptor→`bump-poll` · 그 외 추적 매니페스트→**Renovate 도달성 실측**(`renovate.json`의
  managerFilePatterns 매치 ∧ ignorePaths 비매치 — 분류표를 믿지 않는다. 근사이므로 알려진 매치/논매치를
  센티넬 테스트로 박아 붕괴를 감지한다).
  불변식: **같은 `repo:tag`는 같은 digest**(핀 게이트가 못 보는 축) · **base64 안에 숨은 참조**도 회계
  대상(벤더 manifest의 `SIDECAR_IMAGE`가 Secret 안 base64 tag-only라 커버리지가 0이었다) · 차트 선언
  완전성(레포에 파일이 없는 차트 내부 이미지 클래스).
  무소유는 `policy/image-ownership.json`에 **why·freshness·since·owner_action과 함께 선언 필수**이고
  매치되지 않는 선언(죽은 선언)도 red다. 벤더 파일을 **포함**해 본다(수정 금지여도 소유자 질문엔 답이
  있어야 한다 — repo-walk `image-ownership` 스코프). `tests/gates/test_image-ownership.bats`가 호출.
- **`check-workflow-readiness.ts`** — G-09 준비상태 회계: 자격/설정 부재로 **job이 통째로 skip됐는데
  run은 초록**인 경로를 닫는다. GHA job conclusion 어휘엔 "안 돌았다"가 없고, 스텝-레벨로 게이트된
  job은 스텝을 전부 skip해도 **success**로 끝난다(2026-07-27 라이브 실측: tf-reconcile의 신뢰 앵커
  드리프트 감시 2개가 한 번도 실행된 적 없이 매 30분 초록). skip된 job은 `if: always()` 스텝조차
  실행하지 않으므로 신호는 **게이트 밖의 별도 accounting job**에서만 낼 수 있다.
  두 모드가 한 파일에 있는 이유는 게이트 탐지 규칙이 SSOT여야 하기 때문이다:
  - **정적**(무인자, `ci.yaml` gate 명시 스텝 + `make verify`) — `policy/workflow-readiness.json`
    원장 ↔ 실제 워크플로 **양방향** 대조. 미선언 게이트(역방향)·죽은 선언(정방향)·`outputs.executed`
    미승격·회계 job 부재/`!cancelled()` 누락/`needs` 누락·`expect_executed` 바닥값·**면제 불가
    보안 항목**(`bump-poll.reconcile`은 required+error 고정)을 강제.
  - **런타임**(`--workflow <file>`, env `WORKFLOW_NEEDS`=`toJSON(needs)`) — 각 워크플로 accounting
    job이 호출. `needs.*.result`(job-level) / `needs.*.outputs.executed`(step-level)로 판정하고
    severity에 따라 `::error::`+exit 1 또는 `::warning::`. **실패는 실행된 것으로 센다**(이미 loud).
  게이트 탐지는 **자격 변수의 공백 검사**(`secrets.*`/`vars.*` env를 `[ -n "$X" ]`로 재고 플래그를
  내림)를 요구한다 — 이 선이 도메인-크기 게이트(열거 붕괴 클래스, 처방=scan-floor)와 결과 플래그
  (terraform `drift=false` 등)를 갈라낸다. `tests/gates/test_workflow-readiness.bats`가 호출.
- **`check-ci-parity.ts`** — `make ci` ↔ `ci.yaml` job `gate` **패리티 회계**. Makefile은 `ci`를 "gate를
  로컬에서 재현"이라 선언하는데, 그 주장을 검증하던 것은 `test_make-ci-parity.bats`의 **하드코딩된 5개
  토큰**뿐이었다 — 실측 시점에 gate의 run 스텝 19건 중 **8건**이 `make ci`에 없었는데 전 검사가 초록이었다
  (하필 그 5개가 전부 미러된 것들이라 우연히 통과했다). 이제 스텝 목록을 `ci.yaml`에서 **파생**해
  `policy/ci-parity.json`과 대조한다: 미계상 red · 죽은 선언 red · `mirrored`는 **`make -n ci` 실제 출력**
  대조(Makefile 텍스트를 파싱하지 않는다 — 조건부·전제 타깃을 사람이 재구현하면 그 재구현이 다음 드리프트다).
  ⚠️ 그래서 `make -n`은 **부수효과가 없어야** 한다: 레시피에 `$(MAKE)`가 있으면 GNU make는 `-n`에서도 그 줄을
  실행하므로 서브-make 금지(`test_make-ci-parity.bats`가 강제).
- **`check-disk-caps.ts`** — 디스크 **자기-상한 ↔ 볼륨 선언** 정합(D-4). 워크로드가 바이트로 선언하는
  자기 데이터 상한(`-retention.maxDiskSpaceUsageBytes` 등)이 자기 볼륨의 선언 용량보다 **작은지** 본다.
  라이브 실측(2026-07-29): `victorialogs`가 15GB / 10Gi = **139.7%**였고 전 게이트가 초록이었다.
  ⚠️ 판정은 **바이트 환산**으로 한다 — `GB`=10⁹ · `Gi`=2³⁰라 접미사만 보면 15GB < 10Gi로 잘못 읽힌다.
  ⚠️ 플래그는 `maxDisk` 패턴으로 **발견**한다(하드코딩 목록 금지). 열거 바닥값 + "볼륨 선언 없으면
  fail-closed"까지 둔다 — 비교 대상이 없는 것은 통과가 아니라 판정 불가다.
- **`check-resource-limits.ts`** — 상주 워크로드 main 컨테이너 cpu·memory request + memory limit +
  GOMEMLIMIT≤limit×0.95 강제(구 bash+yq+python3 이관). **`make verify`**(로컬 mirror)·gate 수집 bats(`tests/test_resource_limits.bats`)가 호출 — ci.yaml gate 스텝이 직접 부르지는 않는다(`check-guard-authority` 실측). `--repo-root`로 스캔 루트 지정.
- **`check-alert-rules.ts`** — vmalert 룰 expr의 eval-time 안티패턴 정적 lint(`-dryRun`은 파싱만 해서 못 잡는
  클래스). 모드 A=상태-파생 카운터(`policy/alert-instance-stability-denylist.txt`) 위 rollup이 instance를
  안 벗김 / 모드 B=산술 `on()`·`ignoring()` 조인 피연산자가 집계 미포함 raw 셀렉터(422) — 둘 다 재부팅 IP
  churn 오탐(PR #327) / **모드 C**=push 메트릭(주기 > vmalert instant 룩백)을 연속성 보존 rollup 없이 참조하거나
  윈도 < 주기 → 시리즈 구멍 → `for:` pending 리셋 → **영구 무발화**(죽은 알림 PR #339·#341).
  모드 C의 구성요소(전부 fail-closed):
  - **레지스트리**(in-code `DEFAULT_REGISTRY`): 메트릭 → 생산자 + `schedule`. `schedule`은 **판별 가능한
    소스** — `cron`(레포 내 CronJob: 주기를 여기서만 파생, 파일 부재/파싱불가=FAIL) 또는 `external`(CronJob 밖
    스케줄 — 호스트 systemd timer 등: 상수 + **근거(why) 필수**). 룩백도 `vmalert.yaml`의
    `-datasource.queryStep`에서 파생(미지정=5m).
  - **완전성 가드(메트릭 단위)**: 생산자 표면(`platform·scripts·infra·tools·apps·ops·.github`, 룰 디렉토리 제외)에서
    **VM에 쓰는 모든 파일**을 찾아 **push되는 메트릭 이름을 추출** — 미등록 생산자/미등록 메트릭/**추출 실패
    (페이로드 정적 해석 불가 = fail-closed)**는 전부 FAIL(기존 exporter에 메트릭만 추가하는 우회 경로 차단).
    역방향(레지스트리 메트릭을 더는 push 안 함)도 FAIL. 발견 신호는 단일 엔드포인트가 아니라 **3갈래**다:
    ①VM 수집 경로(`api/v1/import{,/csv,/native}`·`api/v1/write`·`/influx`·`/datadog`·`/opentsdb`)
    ②vmsingle/vmagent 호스트 **+ 쓰기 동사**(`--data-binary`·`-X POST`·`remoteWrite` — URL 합성 push)
    ③**페이로드 모양** — 쓰기 동사 + Prometheus exposition 조립(URL이 **전부 시크릿/변수**여도 잡힌다).
    판정표: [URL 있음·추출 성공]=생산자 / [URL 있음·추출 실패]=**fail-closed FAIL** / [URL 없음·동사+추출 성공]=생산자 /
    [URL 없음·추출 실패]=후보 아님(exposition이 아닌 JSON API 호출 — AdGuard·telegram·alertmanager는 통과).
    메트릭 추출은 인라인(`printf 'name %s\n'`·`VAR="${VAR}name{…} val\n"`)과 **heredoc 본문**(진짜 개행
    `name{labels} value$`)을 본다(S-2 — heredoc으로 몰래 push하던 정적 리터럴 누락 차단).
    읽기 전용 소비자(homepage 위젯·grafana·netpol)는 쓰기 신호가 없어 후보가 아니다. 인프라 릴레이
    (vmagent·vmalert `remoteWrite`)만 `PRODUCER_EXEMPT`에 **사유와 함께** 면제.
  - **셀렉터 정규화**: `{__name__="m"}` · `{"m"}`(VM 축약)을 `m{...}`로 되돌려 검사(문자열 은닉 우회 차단).
    `__name__=~`·`!~`·`!=`는 정적 판정 불가 → fail-closed(정당하면 allowlist).
  - **연속성 보존 rollup만 인정**: `*_over_time` 계열(단일 샘플로도 값을 냄). `irate`/`idelta`/`rate`/`increase`/
    `delta`/`deriv`는 2샘플 이상을 요구해 push 메트릭엔 무력하다 → **rollup으로 인정하지 않음**(가짜 픽스 차단).
  - **스코프 인식 윈도 귀속**: 메트릭을 **실제로 감싸는** depth-0 종료 서브쿼리의 `[W]`만 본다(S-1 — 형제
    서브쿼리의 미끼 윈도로 죽은 알림이 통과하거나 정당한 룰이 오검출되던 위치 기반 폴백 제거).
  - 검사하는 것은 **하한 `W ≥ 주기`뿐** — 누락 내성(2×)·상한(`W < for:`)은 e2e preflight 소관(헤더 주석 참조).
  면제는 `policy/alert-instance-stability-allowlist.txt`(사유 주석 필수). **`make verify`**·gate가 호출.
  `--repo-root` 지원. `--registry <json>`은 **테스트 픽스처 주입 전용**(실 레포는 항상 기본 레지스트리로 검증).
- **`activate-app.ts`** — 재활성/노출 재승인 게이트(owner-local). host/public 표면 변경 시 descendant +
  표면 무변경 + 행 고정을 검증해 재노출을 재승인한다(런북 `app-platform.md`). 라이브 무변경(게이트만).
- **`dns-drift-check.ts`** — active&&public 앱 host + 예약 platform host(`reserved-hosts.json`)가 실제
  resolve되는지(apply 누락=NXDOMAIN, transient는 별도 버킷) 검사. `dns-drift.yaml`(주기)이 호출. resolver 주입(`--fixture`)으로 테스트. 읽기 전용.
  **레인별 바닥값** `--min-reserved`(기본 1, fail-closed) — 예약 platform host는 구조적으로 항상 ≥1이라
  0은 "대상 없음"이 아니라 SSOT 부재/키 변경이다. 픽스처만 `--min-reserved 0`으로 **명시** 해제한다
  (기본을 0으로 두면 조용히 꺼진 바닥값이 된다). 출력의 `scanned`가 스캔 신호다 — stdout이 기계 판독
  JSON이라 `SCAN:` 마커를 못 낸다.
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
