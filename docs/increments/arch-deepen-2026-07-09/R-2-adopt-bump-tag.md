---
id: R-2
title: bump-tag의 형식 원자·인라인 왕복을 image-pin 커널 채택으로 치환
status: open
blocked-by: [R-1]
plan: docs/refactors/arch-deepen-2026-07-09.md
created: 2026-07-10
closed:
---

## What moves

- bump-tag.ts:46·50의 tag/digest 리터럴 정규식 → TAG_RE/DIGEST_RE
  (`tag ?? ""` 관용구 유지).
- 인라인 모드: descriptor JSON.parse → parseDescriptor(타입), 현재 스칼라 정규식
  exec → parseInlinePin, 재조립 템플릿 리터럴 →
  `formatInlinePin({ ...pin, tag, digest })` 스프레드 왕복(C 관용구).

TOCTOU(exit 3)·no-op(exit 0)·path-traversal 가드·node.comment 갱신·
syncDigestExporter·모든 stderr 문구는 무접촉 — `doc.toString()` 산출 바이트 동일.

## Acceptance

- [ ] characterization suite green at this increment's commit (lock testCmd — 특히 charlock B6 바이트 diff)
- [ ] no weakening of the characterization tests (anti-cheat)

## Result

(닫힐 때 기록)
