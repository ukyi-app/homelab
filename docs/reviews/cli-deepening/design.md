# cli-deepening — homelab CLI 심화(deepening) 설계

- 슬러그: `cli-deepening` · 날짜: 2026-08-24 · 패스: `/deepen` (Stage 1 산출물)
- 근거: 아키텍처 스캔 워크플로 `wf_1e77625e-ad3` — 탐사 5영역 병렬 + 후보별 적대 검증 8건(삭제 테스트 재수행·rule-of-two·ADR 대조). 원후보 14 → 검증 통과 8 → 중복 발견 병합 후 6.
- ADR `docs/decisions/0001~0006` 전건 대조: 충돌 0 (후보별 검증 에이전트가 개별 확인).
- 결정 절차: grilling 2라운드(Q1~Q10) 전 항목 사용자 확정.
- 어휘: `/codebase-design` — module·interface·implementation·depth·seam·adapter·leverage·locality를 그대로 쓴다.

## 확정 결정 원장 (Q1~Q10)

| # | 결정 | 내용 |
|---|---|---|
| Q1 | 후보 6 범위 | 첫 슬라이스만(archetype enum 파생). 전면 입력 표면 카탈로그화는 다음 패스 후보로 이연 — structure r1 B1(표현 관심사는 셸 소유) 재협상이 선행 조건임을 기록 |
| Q2 | 순서 | 5 → 1 → 2 → 3 → 4 → 6 |
| Q3 | 후보 2 구현 | 표→oneOf **생성기**(스키마는 표준 draft-07 산출물로 유지) + 생성물 드리프트 게이트. 해석기(schema-check 자체 키워드)는 draft-07 이탈이라 기각 |
| Q4 | 후보 4 계약 | byte-parity 계약 폐기·대체 승인. bin(db-url.ts/cache-url.ts)은 엔진 위 얇은 껍데기로 존속. F2 채널 분리·RW/ADMIN 상호배타는 엔진 입력 술어로 이관 |
| Q5 | 후보 3 앵커 | 감사 독립성은 **커널 단위 테스트의 리터럴 앵커**가 담당. audit-orphans는 커널을 온전히 소비(자체 정규식 제거 — 관측 사각의 원인이었다) |
| Q6 | 표의 물리 배치 | **VERBS 행 확장** — 동사 하나의 계약 전모(결과 계약 + 레인 신원)가 catalog 행 하나. 별도 모듈 분산은 기각 |
| Q7 | validate-mutation | **참조·대조** — CONTRACT는 신뢰 경계 서버 끝의 자기 선언으로 무변경 유지. catalog 행 ↔ CONTRACT 일치는 정적 가드가 대조(양끝 상호검증 보존) |
| Q8 | canonical 술어 배치 | identity.ts에 두고 **owner를 인자로** 받는다(import-0 순수성 보존, test_identity.bats 표면 합류) |
| Q9 | MCP --env-local | 엔진 입력 타입에는 모델링하되 **MCP inputSchema 노출은 보류**(파일 기록 축의 MCP 확대는 별도 신뢰 경계 결정) |
| Q10 | 설계 게이트 | 실행(kind design, 아티팩트 `docs/reviews/cli-deepening/design-r<n>.json`) |

## 진행 순서와 의존 구조

```
5(canonical 술어) → 1(레인 신원) → 2(결과 계약 표화) → 3(레이아웃 커널) → 4(url 승격) → 6(첫 슬라이스)
```

- 심화 1·2는 같은 VERBS 행 확장 위에 앉는다. 1이 행 구조(`lane` 서브오브젝트)를 먼저 만들고 2가 `contract` 서브오브젝트를 더한다.
- 심화 4는 3이 만든 레이아웃 커널(conn 핸들·경로 유도)을 소비한다. 3 착지 시 db/cache 레인 행의 표면 경로도 커널 파생으로 교체된다(1 시점에는 리터럴).
- 각 심화는 독립 머지 가능한 수직 슬라이스로 티켓화한다. 모든 티켓의 공통 AC: `make verify` + 전체 `bats tools/tests/ </dev/null` 그린, 티켓별 신규 단위 표면 그린.
- 작업 브랜치: main에서 새로 판다(직전 피처 브랜치 homelab-cli는 머지·삭제됨).

---

## 심화 1 — canonical 클론 판정의 단일 술어화 (후보 5 · Strong)

**문제(실측)**: "이 클론의 origin이 canonical `ukyi-app/<app>`인가"를 init.ts:233(`[:/]OWNER/app(\.git)?$`, host 무앵커)과 secrets.ts:43(github.com 3-scheme 앵커드)이 서로 다른 정규식으로 판정한다. 발산 3축(host 앵커·scheme 열거·경로 중첩). init이 통과시킨 클론을 secrets가 거부하는 동사 간 비일관과, mirror-host 클론에 마커·push가 오귀속될 가능성이 실재한다. foreign-host 축은 테스트 미커버.

**심화된 module**: identity.ts에 순수 술어 — 2단 판정(게이트 r1 D1 수용 반영).

```
① 구성 신원:   isCanonicalClone(owner, app, originUrl)   — 앵커드 3-scheme + .git 허용 · 중첩 금지
② 라우팅 안전: isSafePushRoute(owner, app, routes)       — routes = push 지향 질의가 열거한 전 목적지(복수형)
```

판정 강도는 secrets 쪽(앵커드: `https://github.com/` · `git@github.com:` · `ssh://git@github.com/` + `.git` 허용, 중첩 금지)으로 수렴. owner·관측값 인자화로 identity.ts의 import-0 순수성을 보존한다. **관측은 호출자 소유다**: 구성 신원은 `remote.origin.url`을, 라우팅 안전은 **push 지향 질의 `git remote get-url --push --all origin`**으로 관측해 인자로 넘긴다 — 이 질의만이 `pushInsteadOf`까지 전개하고 복수 push 목적지를 열거한다(`git ls-remote --get-url`은 fetch 지향이라 `insteadOf`만 전개하므로 부적격 — 게이트 r2 D1′ 교정). `isSafePushRoute`는 단수 유효 URL이 아니라 **routes 복수형**을 받으며, 0개면 fail-closed이고 반환된 전 경로가 canonical이어야 통과한다. push를 수행하는 두 동사(init·secrets)는 push 전에 ①·② 모두를 통과해야 한다(fail-closed) — origin.url만으로는 pushurl·rewrite 우회 경로에 봉인본·마커 커밋이 오귀속될 수 있음을 게이트 r1이 실증했다.

**seam 뒤로 들어가는 것**: host/scheme/중첩/.git/owner/app 판정 + push 라우팅 안전 판정 전부. **이동하는 콜사이트**: init.ts ensureClone(:230-234)·secrets.ts runAppSecrets(:114-117)이 술어 소비로 교체. git() 래퍼 중복(init.ts:53·secrets.ts:38)은 부수 정리.

**행동 변화(의도됨)**: init이 비표준 URL 형태(credential 포함 https, 포트 명시 ssh 등)와 우회 라우팅(pushurl·rewrite)에 fail-closed로 좁아진다 — 보안 술어로서 올바른 방향이고 기존 오류 문구("수동 확인 필요")가 이미 있다.

**테스트**: test_identity.bats류 단위 표면에 발산 축 전부를 핀(foreign-host 신규). 라우팅 적대 테스트는 순수 술어 단위(합성 값)로 끝내지 않는다(게이트 r2 D1′) — 실물 git 설정(foreign `pushInsteadOf` · `insteadOf` · 복수 `pushurl`)을 구성한 **프로세스 경계 bats**가, 술어가 아니라 **호출자가** 실제 push 경로를 관측·거부함을 push 이전 시점에 증명한다. 기존 하네스는 insteadOf로 canonical https URL을 로컬 bare에 매핑하므로, 라우팅 안전 검사는 **명시적 테스트 전용 주입**(하네스가 선언하는 우회 플래그) 뒤에서만 완화된다 — production 기본은 fail-closed이고, 하네스의 매핑을 production 술어가 조용히 통과시키는 경로는 두지 않는다.

**이긴 대안**: platform.ts 배치(OWNER 직접 참조) — 순수성 상실로 기각. 구성 신원 단독 판정 — 게이트 r1 D1(high)이 pushurl/rewrite 우회를 실증해 기각.

---

## 심화 2 — 변이 레인 신원의 성문화 (후보 1 · Strong · 탐사 3곳 독립 수렴)

**문제(실측)**: 레인 신원(디스패치 입력 이름·PR 브랜치 문법·수렴 Application 집합·표면 경로)이 리터럴 사본 4~6벌로 산다 — YAML 원본 5(_create-database.yaml:81 · _create-cache.yaml:77 · _create-app.yaml:134 · _update-secrets.yaml:73 · _teardown-app.yaml:69), 생성 방향 사본 5(verbs.ts:90,121,144,170 · secrets.ts:129 — 전부 "명명 SSOT: _*.yaml" 주석 부착), 파싱 방향 사본 4레인(status.ts:30-40), 표면 경로 리터럴 6, bats 원장 3+파일. TS↔YAML 정적 대조 가드 0. YAML 쪽 개명은 어떤 테스트도 red로 만들지 못하고, 최악 레인(update-secrets)은 noopOnMissingPr(mutation.ts:137-145) 탓에 드리프트가 **침묵 no-op 성공**으로 위장하며 status는 해당 앱 변이 PR을 조용히 누락한다.

**심화된 module**: VERBS catalog 행 확장. 변이 동사 행에 `lane` 서브오브젝트를 더한다.

```
lane: {
  dispatchFile: "create-database.yaml",     // 디스패처(공개 진입점)
  workflow: "_create-database.yaml",        // reusable
  inputs: [...],                            // 디스패치 입력 이름(ext 계열 포함)
  branchPattern: "create-database/{name}-{runId}",  // 중립 패턴 — 생성/파싱 쌍의 SSOT
  surfacePaths: [...],                      // 수렴 표면 경로(3 착지 후 db/cache는 커널 파생)
  applications: [...],                      // 수렴 Application 집합
}
```

- branchFor 클로저·surfacePath 리터럴·status.ts isAppLaneBranch 하드코딩이 전부 이 행에서 파생된다. 생성(템플릿 채움)과 파싱(패턴→정규식)이 같은 패턴에서 나오므로 왕복 불변식 `parse(generate(x)) = x`를 단위 테스트가 직접 단언한다.
- bump-poll 레인(CLI 동사 없는 파싱 전용 6번째 변주)은 catalog 밖 파싱 전용 보조 행으로 수용한다(같은 모듈 내 `PARSE_ONLY_LANES`류) — 행 스키마가 이 변주를 수용해야 한다는 검증 지적 반영.
- 행 데이터의 물리 배치(게이트 r1 D3 수용): lane·contract 행 데이터는 import 0의 **순수 기술자 모듈**(`tools/lib/catalog-rows.ts`)에 살고, verbs.ts의 VERBS 행이 이를 참조해 op와 결합한다 — "동사당 한 행"의 논리는 catalog에 유지되고, 물리적으로는 생성기와 런타임이 순환 없이 같은 기술자를 소비한다(§심화 3).

**정적 parity 가드**: test_mutation-dispatch.bats에 추가(gate 수집 글롭 안 — ADR 0003 배치 제약). 기존 correlation 에코 가드(:206-228)와 같은 bun+yaml 구조 파싱으로 `_*.yaml`의 `branch:`·디스패처 `workflow_dispatch.inputs`를 행과 대조한다. YAML `${{ }}` 표현식이 워크플로마다 다르므로(steps.spec.outputs.name / steps.img.outputs.app / inputs.app) 정규화 매핑은 **가드 쪽**에 둔다 — 런타임 행은 중립 패턴만 소유한다.

**validate-mutation 관계(Q7)**: CONTRACT(8행 — 디스패처 5 + 회귀 앵커 3, 소비 3갈래: 디스패처 validate 잡·reusable 재검증·scripts/teardown.sh)는 무변경. 행 `inputs` ↔ `CONTRACT[action]` required+optional 일치를 parity 가드가 추가 대조한다. 양끝(클라이언트 선언 vs 서버 요구) 상호검증 성질을 보존한다.

**독립 앵커**: bats 원장의 리터럴 단언(test_homelab-db.bats:97 등)은 행에서 파생시키지 않고 유지한다 — 파생시키면 동어반복.

**소멸**: branchFor 사본 5, surfacePath 리터럴 6, 파싱 하드코딩 4레인, "명명 SSOT" 주석 5. **테스트**: 기존 bats 전부 생존 + 왕복 단위 표면 신규 + parity 가드 신규.

**이긴 대안**: 별도 lib/lanes.ts 모듈(Q6에서 행 확장에 패배) · CONTRACT 흡수(Q7에서 참조·대조에 패배).

---

## 심화 3 — 결과 계약 행렬의 표화 (후보 2 · Strong)

**문제(실측)**: cli-result-schema.json(866행)의 allOf member 0에 있는 oneOf 31분기 중 21분기(~255행)가 action enum 1값 + chain not/required 1줄만 다른 사본이다. mutation 계열 동사 추가마다 분기 5~6개 복제 + test_homelab-cli.bats의 SAMPLES 코퍼스(~42행) 2벌 축자 갱신 + 손 floor(현재 36/34/36/7) 재계산이 반복됐다(8커밋 실측 — app create는 신규 정의 0개에 +74행).

**심화된 module**: VERBS 행에 `contract` 서브오브젝트(허용 variant 집합·action 값·chain 유무·result 정의 참조) + 생성기.

- **순수 기술자 모듈**(게이트 r1 D3 수용): 행 데이터는 `tools/lib/catalog-rows.ts` — contract.ts도, 생성물 JSON도, mutation.ts도 import하지 않는 순수 데이터 모듈이다. VERBS(런타임)와 생성기가 함께 이 기술자를 소비하고, 생성물은 런타임 독자(contract.ts)만 읽는다. `생성기 → VERBS → contract.ts → 생성물`의 의존 순환이 원리적으로 불가능해져, 생성물이 없거나 파손된 상태에서도 재생성이 가능하다.
- **생성기** `tools/generate-result-schema.ts`(bun): 기술자를 import해 cli-result-schema.json **전체**를 생성한다. definitions 31종의 본문은 생성기 내 데이터로 이관하되 수제 형태 유지(생성 대상의 핵심은 행렬 배선 — member 0의 21개 행렬 분기·verb/variant enum·per-verb allOf 결합).
- **드리프트 게이트**: 재생성 결과와 커밋본의 byte 동일성을 bats로 대조(make verify 경로) + **생성물 부재 재생성 테스트** — cli-result-schema.json이 없거나 파손된 상태에서 재생성이 성공함을 단언(복구 경로 보장, 게이트 r1 D3).
- **손 앵커(열거 붕괴 방지)**: x-contract.exitCodes ↔ allOf member 1의 의도된 이중부기(스키마 379행 주석)는 한 소스 생성으로 내부 감시가 죽으므로, 대체 앵커를 bats에 손으로 둔다 — (i) variant→exitCode 리터럴 7쌍 핀, (ii) oneOf 분기 수 핀(행 수 핀 ≥1), (iii) SAMPLES 1벌(공유 헬퍼)로 수렴.

**불변(보존 계약)**: contract.ts의 x-contract 런타임 소비(모듈 로드 시 JSON 읽기·exitFor fail-closed)는 무변경 — 생성물이 표준 draft-07 + x-contract 블록을 그대로 담는다. schemaErrors(schema-check.ts)의 KNOWN 화이트리스트에 새 키워드를 도입하지 않는다(소비자는 bats뿐임을 실측 확인). 골든 검증 bats 9파일 생존.

**소멸**: 동사 추가 시 스키마 손 편집(+68~162행/회), SAMPLES 2벌, floor 손 산술. **동사 추가 = 행 1 + (신규 result shape일 때만) 정의·표본 추가** — 표가 흡수하는 것은 행렬 배선이지 신규 형상이 아님을 명시(검증 교정 반영).

**이긴 대안**: 해석기(draft-07 이탈·하위호환 부담 — Q3 기각) · SAMPLES 공유 헬퍼만 추출(행렬 복제·floor 산술이 남아 부분 수리에 그침).

---

## 심화 4 — 리소스 산출물 레이아웃 커널 (후보 3 · Strong)

**문제(실측)**: db/cache 산출물의 명명·배치 지식(conn 핸들 `db-<name>-conn` 계열, env 키 `<NAME>_DATABASE_URL` 계열, CR/인스턴스/봉인본 경로, kustomization 엔트리, cache 전용 원장 행 `cache-<name>`, tombstone 키)이 7개 module에 각자 재유도된다 — provision-db 4곳+α, teardown-resource 6곳(purgeArtifacts는 손 역미러), audit-orphans 정규식 1(생성 명명과 독립 유도 → 명명 변경 시 unreferenced-conn 0건 위장), verbs 2, db-url 2, cache-url 2. 실사고 흔적: F1(원장 행 이름 추정 어긋남 — 리뷰가 잡은 실결함), kustomization 고아 엔트리 클래스, bats 픽스처 3벌 복제.

**심화된 module**: `tools/lib/resource-layout.ts` — 순수 문자열 유도 커널.

```
정방향: layoutFor(kind: "db" | "cache", name: string) → {
  files: [{ path, scope }],            // scope: "purge-제거" | "공유-잔존" | "수동-이연"
  kustomizationEntries: [...],
  handles: { conn, ... },              // role 라벨 구조 — rw / ro / admin / migrate
  envKeys: { rw, ro, admin, ... },     // 위치·접미 지식 없이 role로 조회
  ledgerRow?,                          // cache 전용
  tombstoneKey,
}
역방향: classifyArtifact(경로 | kustomization 엔트리) → { kind, name, role } | null
```

- **scope 태그가 인터페이스의 일부다**(검증 교정 반영): teardown의 purgeArtifacts는 의도된 부분집합(cluster.yaml managed.roles는 수동 커밋, 상위 kustomization databases/ 엔트리는 공유 잔존, CR ensure-flip은 drop step 소유)이므로 커널이 그 scoping 지식을 데이터로 소유한다 — 지금은 teardown 구현에만 암묵적으로 산다.
- **비흡수 경계**: yaml 편집은 흡수하지 않는다(provision-db.ts:240의 lib/kustomization.ts 직렬화 차이 이주 거부 결정 존중). 커널은 이름·경로·엔트리 문자열의 유도만 한다.
- **양방향이 인터페이스의 일부다**(게이트 r1 D2 수용): audit은 임의의 엔트리에서 출발한다 — 소스 CR/디렉토리가 이미 사라진 고아 conn 봉인본을 포함해. 정방향 열거만으로는 그런 고아가 원리적으로 관측에서 사라지므로, `classifyArtifact`가 역방향 판정을 커널 안에서 소유해 audit이 파싱 규약을 재창조하지 않는다. 왕복 불변식(`classifyArtifact(x)` 성공 ⇒ `layoutFor(분류 결과)`가 x를 포함)을 단위 테스트가 직접 단언한다.

**소비 4모드**: provision-db/provision-cache(정방향 쓰기) · teardown-resource(역제거 — purgeArtifacts가 커널 집합 소비) · audit-orphans(감사 — 자체 정규식 제거, Q5) · verbs 레인 행 표면 경로 + db-url/cache-url(읽기).

**독립 앵커(Q5)**: 커널 단위 테스트에 리터럴 기대값(`db-orders-conn`·`cache-demo-conn` 등 실제 문자열)을 손으로 핀 — 정·역방향 일치 불변식을 인터페이스에서 직접 단언. 각 도구의 프로세스 경계 bats는 생존. **감사 픽스처(게이트 r1 D2)**: 소스 리소스 없이 고아 conn 엔트리만 남은 픽스처에서 audit이 그 고아를 검출함을 단언한다.

**소멸**: 사본 리터럴 15+곳, F1 클래스·kustomization 고아 클래스·감사 관측 사각(구조적). **선례**: identity.ts·sealed-contract.ts readSealed와 같은 in-repo 커널 패턴.

**이긴 대안**: audit 자체 정규식 유지(이중 유도 — 관측 사각 존치라 기각) · yaml 편집까지 흡수(기존 결정 재론이라 제외).

---

## 심화 5 — url 동사의 catalog 승격 (후보 4 · Strong · 탐사 2곳 독립 수렴)

**문제(실측)**: db url/cache url만 catalog seam을 우회하는 CliOnlyVerb 패스스루라서 — MCP가 자식 스크립트를 2회 실행(dry-run 계획 + 실기록)하고 URL_PLAN_KEYS 5키 화이트리스트(release r2-a5 실사고의 산물)로 envelope을 합성하며(urlEnvelope 23행 + argv 재부호화 38행), CLI는 usage가 공통 옵션으로 광고하는 `--json`을 exit 2로 거부한다(라이브 실증 — spec 스토리 25 위반). totality 가드(mcp.ts:226-230)가 CliOnlyVerb의 MCP tool 존재를 강제해 타입 이름이 seam에서 거짓이 됐다.

**심화된 module**: `tools/lib/conn-url.ts` — 단일 lib 엔진(kind별 입력 타입 2종 + 공유 내부). DB_URL·CACHE_URL이 catalog 정식 op가 된다(status.ts 패턴).

- 계획이 **타입 반환값**이 된다 — URL_PLAN_KEYS 드리프트 버그 클래스(r2-a5)가 스키마 위반 사후 검출에서 컴파일 타임 타입 오류로 강등.
- F2 채널 분리 불변식(`--admin` ↔ `.env.admin.local` 전용)·RW/ADMIN 상호배타는 엔진 **입력 술어**로 이관(Q4). 평문 비출력 규율은 엔진 소유.
- envLocal 축은 엔진 입력 타입에 모델링, MCP inputSchema에서는 제외(Q9 — 이후 노출 비용은 inputSchema 한 줄).
- bin(db-url.ts/cache-url.ts)은 엔진 위 얇은 껍데기로 존속 — package.json `db:url`/`cache:url` 소비자 보존.
- 스키마: urlResult 재사용 — 골든 매트릭스가 이미 urlResult를 이 동사의 계약으로 취급하므로 스키마 변경은 불필요할 가능성이 높다(검증 판단). 필요 시 심화 3의 표에 행만 갱신.

**계약 재협상(Q4 승인)**: byte-parity bats 2건(test_homelab-db.bats:239 · test_homelab-cache.bats:133)과 tools/README.md의 "같은 동작 재노출이 계약" 문구를 폐기하고, "url 동사도 op envelope 계약, 사람용 출력은 렌더러 소유"로 대체한다. CLI argv 표면(--env-local·--admin·정확한 stderr 문구·종료코드)은 엔진 이관 시 의식적으로 보존한다.

**소멸**: urlEnvelope 23행 · URL_PLAN_KEYS · CliOnlyVerb union·cliOnly 분기 · homelab.ts dbUrlCli/cacheUrlCli spawn(:401-430) · "exit" VerbOutput kind와 main() 분기 · MCP argv 재부호화 38행 · 실기록 경로 자식 2회 실행 · r2-a5 화이트리스트 테스트(test_homelab-mcp.bats:227 — interface를 지나친 테스트의 증상). **신규**: 엔진 단위 표면(계획·술어·비출력)·어댑터 골든.

**이긴 대안**: urlEnvelope의 verbs.ts 재배치만(프로세스 경계가 남아 3자 결합 존치 — 검증이 Strong 미달로 판정한 원안) · 현상 유지(설계된 pass-through라는 반론은 --json 거짓 광고·이중 실행 비용 앞에서 기각).

---

## 심화 6 — archetype enum 파생 (후보 6 첫 슬라이스 · Q1)

mcp.ts:169의 archetype enum 리터럴(platform.ts ARCHETYPES의 사본 — 실측된 유일한 입력 표면 드리프트: 확장 시 MCP만 -32602 거부)을 ARCHETYPES에서 파생시킨다. 전면 입력 표면 카탈로그화(선언 3벌 → 1벌, totality 장치 2벌 제거)는 **다음 심화 패스 후보로 이연** — 재개 조건: 심화 2·3이 확정한 행 모양 + structure r1 B1(표현 관심사는 셸 소유, docs/reviews/homelab-cli/decisions.md) 재협상. shallow config-language 위험(transport 발산을 전부 표현하는 행이 대체 대상만큼 복잡해짐)이 검증에서 지적됐음을 함께 기록한다.

---

## 공통 보존 불변식 (전 심화 공통 AC)

- fail-closed 강제 보존 — 표화·파생은 기계 강제의 표현을 바꾸는 것이지 산문 표로의 퇴행이 아니다(structure r1 결정의 본질 유지).
- 신뢰 경계 무변경: validate-mutation.ts·actor 가드·전역 직렬화(homelab-mutation)·PR-first. MCP destructive 제외·명시 경로 규약 유지.
- 독립 앵커 원칙: bats 원장 리터럴·커널 테스트 리터럴·variant→exitCode 손 핀은 파생 금지.
- contract.ts x-contract 런타임 소비·schemaErrors KNOWN 화이트리스트·골든 검증 bats 9파일 무변경 생존.
- 각 티켓: `make verify` + 전체 `bats tools/tests/ </dev/null` 그린.

## 비후보 판정 기록 (재탐사 방지)

스캔이 deep으로 확증해 건드리지 않는 module: contract.ts envelope seam · doctor.ts·cli.ts · 변이 엔진 본체(variant 축은 실재 동사가 요구) · exec.ts · seal 이중화(의도된 벤더링). 삭제 테스트 불합격으로 기각: ArgoCD 관측 3벌 추출 · 디스패처 actor 가드 스텝 통합 · 봉인 경로 TS 상수 통합(반쪽 SSOT) · gh 래퍼 3종 통합 · 레거시 도구 argv 골격 공용화. 미검증 이월(다음 패스에서 재평가 가능): 미니 JSON-스키마 검증기 3벌 수렴 · 스캐폴더 계약 판정 취득 흡수 · 엔진 입력 이중 채널 · surface-hash 빈 문자열 접힘(Speculative).

## 게이트 기록

- 설계 게이트(Q10): kind `design`, 아티팩트 `docs/reviews/cli-deepening/design-r<n>.json`, 이 문서가 리뷰 대상. 통과(또는 명시 웨이버) 전까지 본 문서는 미커밋 유지.
- r1 (codex · xhigh · working-tree): ok:true · needs-attention · 발견 3건(high 2 · medium 1) — D1(push 라우팅 안전) · D2(커널 양방향화) · D3(순수 기술자 모듈) 전건 사용자 수용, 본 문서에 반영. 결정 원장: `decisions.md` `### design r1 (codex)`.
- r2 (codex · xhigh · working-tree): ok:true · needs-attention · 발견 1건(high) — D2·D3 해소 확인, D1′(push 관측 프리미티브가 fetch 지향) 수용·본 문서 반영. 라운드 상한 2 도달, **사람 웨이버로 종결**(decisions.md `### design r2 (codex)` 참조).
