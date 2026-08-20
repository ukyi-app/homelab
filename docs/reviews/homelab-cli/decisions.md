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
