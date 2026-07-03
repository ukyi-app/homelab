# 아키텍처 결정 기록 (ADR)

핵심 설계 결정의 **근거와 기각된 대안**을 보존한다(MADR-lite, append-only). `docs/plans/`(실행 역사,
수정 금지)와 다르다 — 여기엔 "왜 이렇게 했나"만 둔다. AGENTS.md 함정/컨벤션이 *무엇*을 단정한다면,
ADR은 그 *이유*를 댄다. public 레포이므로 age 키 경로 등 민감정보는 적지 않는다.

| ADR | 결정 |
|---|---|
| [0001](0001-secret-management-hybrid.md) | 시크릿 관리 하이브리드(SOPS + SealedSecrets) 유지 |
| [0002](0002-terraform-trust-anchor.md) | terraform github/tailscale 루트는 owner 로컬 apply 전용 |
| [0003](0003-single-required-check.md) | required status check는 `gate` 단일 |
| [0004](0004-golden-path-rule-of-two.md) | 골든패스 확장 대신 베스포크 유지(rule-of-two) |
