# 아키텍처 결정 기록 (ADR)

핵심 설계 결정의 **근거와 기각된 대안**을 보존한다(MADR-lite, append-only). AGENTS.md 함정/컨벤션이
*무엇*을 단정한다면, ADR은 그 *이유*를 댄다. public 레포이므로 age 키 경로 등 민감정보는 적지 않는다.

실행 과정 문서(계획·리뷰 산출물)는 착지와 함께 지운다 — 남길 가치가 있는 것은 여기나
`docs/traps-detail.md`, 또는 되돌림이 쓰여질 코드 지점의 주석으로 승격한다(CONTRIBUTING 「conductor
파이프라인 산출물」).

| ADR | 결정 |
|---|---|
| [0001](0001-secret-management-hybrid.md) | 시크릿 관리 하이브리드(SOPS + SealedSecrets) 유지 |
| [0002](0002-terraform-trust-anchor.md) | terraform github/tailscale 루트는 owner 로컬 apply 전용 |
| [0003](0003-single-required-check.md) | required status check는 `gate` 단일 |
| [0004](0004-golden-path-rule-of-two.md) | 골든패스 확장 대신 베스포크 유지(rule-of-two) |
| [0005](0005-data-connection-residual-risk.md) | 데이터 연결 = 일반 SealedSecret · 잔여 위험 informed 감수 |
| [0006](0006-archive-separation-contract-retired.md) | 컷오버에서 복구 원본 제거 · "쓰기≠읽기" 계약을 "쓰기 고정"으로 평행이동 |
