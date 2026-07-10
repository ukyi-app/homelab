---
id: R-3
title: create-app RE 채택 + lib 부기(README·AGENTS) + 안티드리프트 grep-guard
status: open
blocked-by: [R-2]
plan: docs/refactors/arch-deepen-2026-07-09.md
created: 2026-07-10
closed:
---

## What moves

- create-app.ts:41-42의 tag/digest 리터럴 정규식 → TAG_RE/DIGEST_RE
  (fail 문구 그대로).
- 부기: tools/README.md에 lib/image-pin.ts 등재, AGENTS.md의 lib 개수 산문 갱신.
- 안티드리프트 grep-guard @test 1개 추가(test_image-pin-lib.bats에):
  poll-ghcr.ts·bump-tag.ts에 인라인 핀 정규식 리터럴이 재출현하면 FAIL
  (test_ledger-budget.bats:64-68 선례).

## Acceptance

- [ ] characterization suite green at this increment's commit (lock testCmd)
- [ ] grep-guard green + 관련 문서 게이트(check-doc-index 등) 통과
- [ ] no weakening of the characterization tests (anti-cheat)

## Result

(닫힐 때 기록)
