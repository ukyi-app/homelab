# decisions — lib-convergence

### design r1 (codex)

- r1-1 Accept — Plan.action cannot represent valid non-actionable outcomes (런타임 디코드 판별 union `Change | Noop | Refusal`, Lane은 Change 전용, malformed plan fail-closed 거부)
- r1-2 Accept — The target identity is ambiguous across app and platform namespaces (plan 항목·레인 해석·브랜치 명명에 판별 신원 `{kind: "app" | "bespoke", name}` 도입 — CONTEXT.md의 apps 레인/베스포크 레인 어휘와 정렬)
- r1-3 Accept — guardMain cannot preserve multi-domain and machine-output contracts (명명 스캔 도메인 컬렉션 + 도메인별 floor + 명시적 방출 정책, 전 floor 통과 후 SCAN 일괄 방출)
- r1-4 Accept — readLedger lacks the observed domain required for bilateral reconciliation; 권고 두 갈래 중 **narrow** 채택 — readLedger는 fail-closed 로딩·shape·검증만 소유, 양방향 대조는 콜사이트 잔류(공통 대조 interface는 공통형 실증 시 추출)

### design r2 (codex)

재검증(사실): r1-1·r1-3·r1-4 resolved · r1-2 부분 해소(경계 미관통이 r2-1로 정제) + 수정 유발 신규 1건.

- r2-1 Accept — The discriminated target is lost before the mutation boundary (target-bearing CLI 계약 `--kind app|bespoke --name` fail-closed + bump-plan이 브랜치 인코딩·역디코딩 양쪽 소유 + 레거시 무한정 참조 이행 + 동명 app/bespoke e2e; "argv 테스트 118건 생존" 주장을 "호출 계약 변경 행은 갱신"으로 정정)
- r2-2 Accept — The narrowed ledger ownership contradicts the new domain SSOT (CONTEXT.md 「정책 원장」을 축소된 소유권으로 정정 — 대조는 콜사이트 소유를 명시)

WAIVED by user: 라운드 상한(2) 도달. r2 재검증이 r1 수용 4건 중 3건 resolved를 확인했고(r1-2는 r2-1로 정제), r2 발견 2건은 리뷰어 권고를 그대로 구현한 문서 수정으로 반영·검증했다. 잔여 리스크(레거시 이행 규칙 등 미리뷰 신규 서술)는 구현 단계의 티켓별 리뷰가 받으므로, r3 없이 사람 웨이버로 design 게이트를 종결한다.
