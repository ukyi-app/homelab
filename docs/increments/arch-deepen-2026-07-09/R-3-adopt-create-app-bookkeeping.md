---
id: R-3
title: create-app RE 채택 + lib 부기(README·AGENTS) + 안티드리프트 grep-guard
status: done
blocked-by: [R-2]
plan: docs/refactors/arch-deepen-2026-07-09.md
created: 2026-07-10
closed: 2026-07-10
---

## What moves

- create-app.ts:41-42의 tag/digest 리터럴 정규식 → TAG_RE/DIGEST_RE
  (fail 문구 그대로).
- 부기: tools/README.md에 lib/image-pin.ts 등재, AGENTS.md의 lib 개수 산문 갱신.
- 안티드리프트 grep-guard @test 1개 추가(test_image-pin-lib.bats에):
  poll-ghcr.ts·bump-tag.ts에 인라인 핀 정규식 리터럴이 재출현하면 FAIL
  (test_ledger-budget.bats:64-68 선례).

## Acceptance

- [x] characterization suite green at this increment's commit (lock testCmd)
- [x] grep-guard green + 관련 문서 게이트(check-doc-index 등) 통과
- [x] no weakening of the characterization tests (anti-cheat)

## Result

커밋 `4497de3`. 컨덕터 검증: lock 85 + lib 10 = 95/95 green, doc-index/skeleton
rc=0, lock 스위트·커널 무접촉. /code-review 2축 — Spec 0건(B9/B10 의미 동치
소스 대조 통과, guard 3파일 확장은 정합 완결 판정); Standards 2건 수정 반영:
H1(AGENTS top-level 19→22 실측 교정 — 기존 stale 포함), S1(guard @test의 항진
status 단언 제거 — 선례 정합). guard는 주입 사본 3종 포착·F-3 잔존 템플릿 오탐 0
검증 완료.
