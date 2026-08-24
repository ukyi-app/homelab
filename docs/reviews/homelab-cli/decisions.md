# decisions — homelab-cli

### plan r1 (codex)

- a1 Accept — Timestamp-window run discovery can bind to another mutation (fail-closed 단일 후보 + exit 3로 수용, 디스패처 계약 변경 없이)
- a2 Accept — The secrets chain can dispatch a commit the workflow never reads (선행 조건 4종 + 부분 실패 재개 규칙)
- a3 Accept — Open question: --wait has no correct per-verb completion state machine (동사별 대기 매트릭스 — create-app auto-merge:false 라이브 검증 포함)
- a4 Accept — app init has no idempotency or recovery design across irreversible side effects (preflight·체크포인트 재개·시크릿 쌍 원자성)
- a5 Accept — The promised stable JSON and MCP contract is not actually specified (체크인 버전 스키마 = SSOT, variant·매핑 정의)
- a6 Accept — The known amd64 blocker is not made a release prerequisite (릴리스 blocking 의존 + doctor 템플릿 호환성 검사)
- b1 Accept — Wait can succeed on the previously deployed revision (머지 SHA → sync revision 후손 + Synced + Healthy 판정, a3와 한 결정)
- b2 Accept — Run discovery can attach to another caller's mutation (a1과 한 결정)
- b3 Accept — Open question: how does wait behave for manual-merge mutations? (수동 머지 동사는 bounded pending, 승인 경계 불변, a3와 한 결정)
- b4 Accept — Open question: how is app init resumed after partial failure? (a4와 한 결정)
- b5 Accept — Open question: what blocks release on the external template fix? (a6와 한 결정 + 템플릿 호환성 식별)
- b6 Accept — Open question: what exactly is the stable JSON contract? (a5와 한 결정)
- b7 Accept — Open question: what is the MCP operation and workspace model? (명시 입력·동기 바운디드·run 핸들 상관)

### plan r2-salvage (codex — pane 판독 2회 실패 후 codex 세션 로그에서 무손실 회수, readback_token=cd1a8d58 일치. 게이트 기록 아님)

재검증 판정(사실): a2·a5/b6·a6/b5 resolved · a1/b2·a3·a4/b4·b7 still-open · b1/b3 부분 해소(각각 s6·s5 결함 유발).

- s1 Accept — The single-candidate fix can still adopt another caller's run (디스패처 옵션 correlation 입력 + run-name 에코 — out-of-scope 소폭 개방, validate-mutation 행 추가)
- s2 Accept — The wait matrix never identifies every Application to observe (동사별 Application 집합 명시: db=cnpg-data+data-conn-prod, cache=cache-prod+data-conn-prod — 워크플로 검증 완료)
- s3 Accept — The init resume predicate excludes failures after the first push (소유 술어에 시크릿 쌍 불완전 포함 + 단계 사후조건)
- s4 Accept — The MCP progress contract cannot query the returned handle (status 핸들 조회 모드 + init 타임아웃 체크포인트 반환)
- s5 Accept — The teardown wait state requires a deleted Application to become Healthy (teardown 전용 종결: 머지 관측 + Application 부재)
- s6 Accept — A descendant revision can have reverted the requested mutation (관측 리비전의 desired-state 표면 확인 + superseded variant)

### plan r2 (codex)

재검증(사실 확인): a1·a2·a6·b1·b2·b3·b5·b7·s1·s2·s3·s4·s5·s6 resolved (14/19) · a3·a4·a5·b4·b6 still-open — 아래 신규 2건으로 수렴.

- r2-a1 Accept — The wait fix has no legal state for an update-secrets no-op (no-op variant 추가 + synced revision checksum 검증으로 대체 — a3·a5·b6 잔여 해소)
- r2-a2 Accept — The resume predicate can adopt another template repository (invocation marker 소유 증명 + 마커 부재 시 fail-closed·명시 입양 플래그 — a4·b4 잔여 해소)

WAIVED by user: 라운드 상한(2) 도달. r2 재검증에서 14/19 resolved였고 잔여 5건은 위 2건의 수정으로 전부 수렴하므로, 수정 반영을 확인하고 재재검증(r3) 없이 게이트를 종결한다. (판독 실패 2회는 codex 세션 로그 무손실 회수로 보완 — decisions.md r2-salvage 절 참조.)

### structure r1 (codex)

시도1은 readback-incomplete(양 멤버 json-unparseable — 리뷰어의 code 필드 따옴표 미이스케이프,
리뷰 자체는 HRG 토큰·카운트 3/3으로 완주)로 ok:false. 답은 판독 원문에서 무손실 회수했고
(.scratch/homelab-cli/structure-r1-salvaged-{a,b}.json, 토큰 a=5e549024·b=653fe7e3), 인용 4건은
리뷰된 트리(473a734)와 전건 대조 일치. 아래는 회수본 6건의 인간 트리아지(라운드 결정: 제안 전부 수용).
게이트 아티팩트는 수정 반영 후 r1 재발화로 확보한다.

- a1 Accept — 결과 스키마가 verb별 계약을 판별하지 못한다 (b1과 한 결정: allOf verb→result oneOf 분기)
- b1 Accept — The root schema ignores every verb-specific result contract
- b2 Accept — The schema does not enforce variant-to-exit-code mapping (허용 쌍 oneOf 분기 + mismatch-rejection·SSOT pinning 테스트)
- a2 Accept — VERBS가 transport-neutral operation을 표현하지 못한다 (b3과 한 결정: run이 계약 envelope 반환, 프로세스 관심사는 진입점 소유)
- b3 Accept — The verb registry is a CLI-only seam that MCP cannot reuse
- a3 Defer — doctor의 template preflight가 실제 init 계약을 증명하지 않는다; 공용 검사 술어·versioned contract는 두 번째 소비자(init, 티켓 11)가 생길 때 추출 — 지금 만들면 speculative. defer 노트를 티켓 11 파일에 기록

### structure r1 시도2 (codex)

시도2도 readback-incomplete(양 멤버 json-unparseable — 강화한 이스케이프 지시에도 code 필드
따옴표 미이스케이프 재발). 리뷰는 완주(HRG 토큰·카운트 2/2: a=3ea65a1f·b=dc5ccafa), 판독 원문에서
무손실 회수(.scratch/homelab-cli/structure-r1t2-salvaged-{a,b}.json), 인용 4건 트리(27db0ae) 대조
전건 일치. 시도1 수용분이 반영된 트리에 대한 후속 지적 4건(전부 high, consensus 2그룹) —
인간 트리아지(라운드 결정: 제안 전부 수용).

- A1 Accept — The command catalog is not a reusable source of truth (B1과 한 결정: 계약 리더 lib/contract.ts + operation catalog lib/verbs.ts 추출, bin 모듈은 CLI 셸로)
- B1 Accept — The operation seam is still CLI-specific (op는 Envelope만 반환, json/human 등 표현 관심사는 셸의 어댑터·렌더러로)
- A2 Accept — Result shapes are not discriminated by outcome (B2와 한 결정: verb 분기에 허용 variant 집합 선언 — doctor: success·failure만)
- B2 Accept — The schema does not discriminate state-specific results (전 variant 스윕 테스트를 verb별 허용-결과 행렬로 교체 — 허용 통과·비허용 거부, variant별 증거 필드는 그 variant를 내는 동사 티켓에서 분기 확장)

### structure r2 (codex)

r2는 정식 완주(ok:true, 판독 성공 — code 필드 이스케이프 예시가 유효). 재검증: 수용 9건 중
8건 resolved + A1 still-open(신규 r2-a1과 동일 쟁점), 사실 확인으로 코드 대조 완료.

- r2-a1 Accept — The extracted catalog cannot represent the planned operations; VerbShape 제네릭 + 동사별 union·named export로 수리(동사 추가 = union 멤버 추가, catalog 우회 불가)

WAIVED by user: 라운드 한도 2 도달, 잔여는 r2-a1 1건뿐이고 수리·검증 완료(typecheck·bats 28/28) — 나머지 9건은 r2가 resolved로 재검증. 수리 커밋은 이 절과 같은 커밋

### release r1 (codex — 정식 아티팩트 ok:false, pane 판독 손상. codex 세션 로그에서 무손실 회수: HRG 토큰 a=903de1a3·b=12c7a050, declaredCount 5/3 일치. 회수본 docs/reviews/homelab-cli/release-r1-salvaged.json)

스코프: ticket 12(mcp) 슬라이스(bbd6c70..HEAD, 43KB) — full-branch(558KB)가 herdr 인라인 상한(96KB) 5.7배 초과라 최대 fitting suffix만 게이트(사용자 결정). 2인 패널 모두 needs-attention, 8발견 → 5쟁점. 전건 검증(실코드/실증) 후 사용자 일괄 수용.
- a3=b1 Accept — null/wrong-type 명시 경로가 required-check(존재만) 통과 → str() undefined → cwd 폴백으로 변이가 서버 cwd 실행(보안). 수리: MCP required-check를 타입 인식으로(null/wrong-type/빈 문자열 -32602). 판별성 mutation 검증.
- a4=b2 Accept — db_url/cache_url envDir이 required 아님 → 생략 시 서버 checkout에 자격 기록(보안). 수리: envDir required.
- a2=b3 Accept — 비-wait 변이가 run conclusion(최대 20분)까지 폴링해 단일 스레드 서버 블로킹(계약). 수리: mutation.ts identifyOnly — MCP는 run 식별 직후 pending+run 핸들 즉시 반환(진행은 status(run) 재조회). 판별성 mutation 검증.
- a1 Accept — verification.md가 스펙 요구 amd64 스캐폴드-빌드-스모크 증거 누락. 수리: 릴리스 선행 조건 절 추가(PR#31 머지·doctor 실증·ticket-03-amd64-smoke.md·a37834c).
- a5 Accept — db_url/cache_url이 envelope 대신 raw text 반환(일관성). 수리: urlResult 정의 + db url/cache url verb 분기, url tool도 envelope(계획은 dry-run 캡처·평문 비출력). 계약 floor 32→36/24→34.

### release r2 (codex — 적대 렌즈 재검증. 정식 아티팩트 2회 ok:false(1차 review-timeout·2차 readback-incomplete). 2차는 세션 로그 무손실 회수: 토큰 df4c9de6, count 4 일치. 회수본 release-r1-salvaged.json의 round2)

스코프: r1 수정만(97e8f6f..HEAD, 43KB)·effort high. 적대 렌즈가 r1 수정의 미완·부작용 4건을 정확히 포착 — 전건 실코드 확증 후 사용자 일괄 수용.
- r2-a2/b3 Accept(still-open) — identifyOnly가 conclusion은 건너뛰나 run '출현' 대기(step2)는 공유 deadline(20분)까지 폴링. 수리: MCP 짧은 deadline(HOMELAB_MCP_DEADLINE_MS env 주입, 기본 30s) — run 미출현이면 즉시 pending. 판별성 검증(되돌리면 20분 블로킹).
- r2-b1 Accept(still-open) — required만 타입 검증, optional dryRun:'true'(문자열)가 bool()에서 false로 접혀 실제 자격 쓰기 실행. 수리: 전체 inputSchema 검증(schema-check.ts 재사용)으로 type·enum·additionalProperties·minLength까지. 판별성 검증.
- r2-a5 Accept(still-open) — cache-url 계획의 host가 urlResult에 없어 cache_url 성공 envelope이 스키마 위반. 수리: 계획에서 urlResult 알려진 키만 화이트리스트 복사 + cache_url 테스트. 판별성 검증.
- r2 New Accept — verification.md가 a19f466 이전(97e8f6f)에 핀됨(수정이 코드 변경). 수리: 최종 HEAD 재측정·재핀(r2 수정 커밋에서).
