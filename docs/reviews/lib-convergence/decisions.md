# decisions — lib-convergence

### design r1 (codex)

- r1-1 Accept — Plan.action cannot represent valid non-actionable outcomes (런타임 디코드 판별 union `Change | Noop | Refusal`, Lane은 Change 전용, malformed plan fail-closed 거부)
- r1-2 Accept — The target identity is ambiguous across app and platform namespaces (plan 항목·레인 해석·브랜치 명명에 판별 신원 `{kind: "app" | "bespoke", name}` 도입 — CONTEXT.md의 apps 레인/베스포크 레인 어휘와 정렬)
- r1-3 Accept — guardMain cannot preserve multi-domain and machine-output contracts (명명 스캔 도메인 컬렉션 + 도메인별 floor + 명시적 방출 정책, 전 floor 통과 후 SCAN 일괄 방출)
- r1-4 Accept — readLedger lacks the observed domain required for bilateral reconciliation; 권고 두 갈래 중 **narrow** 채택 — readLedger는 fail-closed 로딩·shape·검증만 소유, 양방향 대조는 콜사이트 잔류(공통 대조 interface는 공통형 실증 시 추출)
