---
id: R-1
title: tools/lib/image-pin.ts 커널 신설 + lib 단위 테스트 + poll-ghcr 채택 (seam-erecting)
status: done
blocked-by: [none]
plan: docs/refactors/arch-deepen-2026-07-09.md
created: 2026-07-10
closed: 2026-07-10
---

## What moves

- `tools/lib/image-pin.ts` 신설 — B+C 하이브리드 표면: TAG_BODY/DIGEST_BODY 본문
  SSOT → TAG_RE/DIGEST_RE, InlinePin + parseInlinePin/formatInlinePin(INLINE_RE
  본문 합성), PinDescriptor 타입 + parseDescriptor(JSON.parse+캐스트, 정규화 0),
  descriptorAutoDeploy(null-안전 `d?.autoDeploy === true`).
- `tools/tests/test_image-pin-lib.bats` 신설 — 형식 원자 수용/거부·parse/format
  왕복 항등·descriptor 관용·autoDeploy fail-closed 직접 단언(@test 영어).
- **poll-ghcr 채택**: planComponent의 인라인 정규식 exec → parseInlinePin,
  descriptor JSON.parse → parseDescriptor, `pin.autoDeploy === true` →
  descriptorAutoDeploy / planApp의 tag 정규식 → TAG_RE, .bindings.json
  autoDeploy 관용구 → descriptorAutoDeploy (try/catch 유지).

refuse 사유 문자열·throw 경로·plan JSON 형태는 콜사이트에 그대로 — 행위 불변.

## Acceptance

- [x] characterization suite green at this increment's commit (lock testCmd: 85케이스)
- [x] 신규 lib 단위 테스트 green (`bats tools/tests/test_image-pin-lib.bats`)
- [x] no weakening of the characterization tests (anti-cheat — lock 6개 스위트 무수정)

## Result

커밋 `cd84fe5`. 컨덕터 검증: lock 85/85 + lib 9/9 green(직접 재실행), lock 6개
스위트 diff 0. /code-review 2축 — Spec 0건(계약 부합·행위 보존 대조 통과),
Standards 실질 0건(잔존 사본 지적은 R-2/R-3 예정분, 미소비 export는 R-2 소비
예정으로 억제). 이월 없음.
