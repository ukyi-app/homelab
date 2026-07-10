---
id: R-1
title: tools/lib/image-pin.ts 커널 신설 + lib 단위 테스트 + poll-ghcr 채택 (seam-erecting)
status: open
blocked-by: [none]
plan: docs/refactors/arch-deepen-2026-07-09.md
created: 2026-07-10
closed:
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

- [ ] characterization suite green at this increment's commit (lock testCmd: 85케이스)
- [ ] 신규 lib 단위 테스트 green (`bats tools/tests/test_image-pin-lib.bats`)
- [ ] no weakening of the characterization tests (anti-cheat — lock 6개 스위트 무수정)

## Result

(닫힐 때 기록)
