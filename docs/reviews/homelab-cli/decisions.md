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
