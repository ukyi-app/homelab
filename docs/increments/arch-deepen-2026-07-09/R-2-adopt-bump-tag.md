---
id: R-2
title: bump-tag의 형식 원자·인라인 왕복을 image-pin 커널 채택으로 치환
status: done
blocked-by: [R-1]
plan: docs/refactors/arch-deepen-2026-07-09.md
created: 2026-07-10
closed: 2026-07-10
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

- [x] characterization suite green at this increment's commit (lock testCmd — 특히 charlock B6 바이트 diff)
- [x] no weakening of the characterization tests (anti-cheat)

## Result

커밋 `84d9ea4`. 컨덕터 검증: lock 85 + lib 9 = 94/94 green(직접 재실행),
스위트 diff 0. /code-review 2축 — Spec: 치환 5지점 전부 커널과 의미 동치 확인,
minor 1건(스프레드 관용구 미사용)은 수정 서브에이전트로 즉시 정합(`{ ...parsed,
tag, digest }`); Standards: 위반 0(Data Clumps 해소 긍정), 판단 콜 중
syncDigestExporter의 언앵커드 `sha-[0-9a-f]{7,40}` 잔존은 커널이 TAG_BODY를
의도적으로 미노출한 결과 — F-3 백로그로 기록(커널 인터페이스 확장 여부 별도 판단).
