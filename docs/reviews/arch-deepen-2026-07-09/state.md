---
refactor: arch-deepen-2026-07-09
invariant-class: refactor
entry-track: architecture
review-track: full
pipeline-stage: design
issue-tracker: local
candidate: image-pin 커널 — poll-ghcr(읽기)·bump-tag(쓰기) 양단에 복제된 배포 핀 형식·descriptor 지식을 tools/lib 커널로 수렴 (스켑틱 축소 범위)
intake-grill: done
spike-1:
---

## Executing 스코프 (사용자 동의 2026-07-10)

현재 체크아웃(refactor/arch-deepen-2026-07-09)에서 진행 — 별도 worktree 없음
(단독 사용 홈랩). R-1→구조 게이트(트리아지 정지)→R-2→R-3 직렬, 증분당 신선한
구현자(opus) 디스패치 + 컨덕터 /code-review(Spec 우선) + **커밋은 컨덕터**.
매 디스패치 전 --gate-check, 매 증분 lock testCmd(85) green.

## Track note

`/gated-refactor` 무인자 호출 → architecture 도어. Rule 0 판정: 행위 보존 +
구조적 심화, 측정 지표 없음, 기계적 breadth 아님 → `invariant-class: refactor`.
main은 protected(PR-first)라 파이프라인 부기는
`refactor/arch-deepen-2026-07-09` 브랜치에서 진행, finishing에서 PR 랜딩.

## 릴리스 게이트 r2 — approve (2026-07-12)

`release-r1.json`은 freshness 스탬프(`reviewedSha`) 이전 스크립트 산물이라 barrier가
landing을 차단했다(`refactor-status.mjs`: "Approving release artifact lacks reviewedSha").
리베이스된 HEAD에서 전체 재리뷰 → `release-r2.json`: **verdict approve, 0 findings**,
`reviewedSha=0bcc2d2`(= verification 커밋 = 브랜치 tip). 트리아지 대상 발견 없음.

**base 정밀도 기록(정직성)**: 로컬 `main` ref(`7013509`)가 리베이스 기준점
(`7d23492` = 당시 origin/main tip)보다 3커밋 뒤처져 있어, 게이트가 본 diff는 23파일
= 실제 PR diff(21파일, `origin/main...HEAD`)의 **상위집합**이다(초과분 = 이미 main에
머지된 trip-mate digest bump 2파일: `apps/trip-mate-api/deploy/prod/values.yaml`,
`platform/victoria-stack/prod/digest-exporter.yaml`). 우리가 보내는 변경은 전부
정확한 커밋에서 리뷰됐으므로 미리뷰 갭은 0 — base만 덜 정밀했다. r1도 동일한 base
(reviewedFileCount 20)였다.

## Discover 결과 (2026-07-10)

탐사 6표면 → 후보 20 → opus 2-렌즈 적대 검증(deletion-test 스켑틱 + seam 평가,
분포 Worth exploring 12 · Speculative 6 · Reject 2). 사용자 선택 = **#4 image-pin 커널**.
전체 증거는 `discover-evidence.json`(후보+스켑틱+seam 원문).

**Deletion-test 증거(검증 완료)**: poll-ghcr.ts:178 ≡ bump-tag.ts:70 —
인라인 핀 정규식 `/^(.+?):(sha-[0-9a-f]{7,40})@(sha256:[0-9a-f]{64})$/` 바이트
동일 복제. sha-* tag 형식 정규식 3벌(poll:152·bump:46·create-app:41), sha256
digest 형식 정규식 3벌(bump:50·create-app:42·repin:17). `.image-pin.json`
descriptor 의미론이 읽기(poll:176-185)/쓰기(bump:63-79)로 양분. 축소 커널을
지우면 이 지식이 2+파일에 재출현 = 집중(deletion test pass). 한쪽 정규식만
드리프트하면 해당 컴포넌트 영구 refuse 루프 — 잡는 게이트 0.

**스켑틱 축소 범위(설계 계약에 반영할 것)**: ① 커널은 얇은 형식/descriptor
계층만(inline-pin parse/format + tag·digest 검증 + descriptor shape) — 깊은
로직(ancestry 증명·TOCTOU·stale-digest 제거)은 읽기/쓰기 측 잔존. ②
repin-pgtools 제외(ops 이미지, 비-sha tag — 개념 불일치), create-app은 형식
검증자만 소비. ③ digest-exporter APPS-sync fail-loud화는 행위 변경 — 이
리팩터에서 제외, 별도 트랙. ④ bump-tag 호출자는 bump-poll.yaml + bump.yaml
2곳(양쪽 행위 보존). ⑤ 신규 lib은 tools/README.md 등재 + AGENTS.md "lib/ 8개"
산문 갱신 필요.

## Grilling 결정 (2026-07-10, discover 그릴 — design은 capture-only)

- **Q1 커널 범위**: 형식 원자(sha-* tag·sha256 digest) + inline-pin parse/format +
  descriptor 타입·관용 파스(`autoDeploy === true` fail-closed 해석 포함). 파일 변이·
  traversal 가드·TOCTOU/no-op·stale-digest·ancestry는 커널 밖.
- **Q2 seam 위치**: 신규 `tools/lib/image-pin.ts` (identity.ts 합류 기각 — 개념 상이).
  부기: tools/README.md 등재 + AGENTS.md lib 개수 산문 갱신.
- **Q3 메시지 소유권**: 커널은 순수 판정/파스만 — 에러 문구·exit·전송로는 전부
  콜사이트 유지(특성화 자명성 우선). parse 실패 = null류 반환, throw 금지.
- **Q4 증분 구조**: R-1 = 커널+lib 단위 테스트+poll-ghcr 채택(=first-increment,
  구조 게이트 대상) → R-2 = bump-tag 채택 → R-3 = create-app RE 채택+부기+안티드리프트 가드.
- **Q5 테스트**: 특성화 lock = 기존 5 스위트 무수정(anti-cheat), 신규
  `tools/tests/test_image-pin-lib.bats`(@test 영어), 마지막 증분에 grep-guard
  (인라인 핀 정규식 리터럴 콜사이트 재출현 FAIL — test_ledger-budget.bats:64-68 선례).

**특성화 seam(평가 완료, lockable=yes)**: 두 CLI stdout+exit —
poll-ghcr `--fixtures/--root/--dry-run` hermetic plan JSON, bump-tag fixture
변이. 기존 test_poll-ghcr.bats(15)+test_bump.bats가 형식 refuse·TOCTOU·
fail-closed 전량 green 고정. testCmd 후보:
`bats tools/tests/test_poll-ghcr.bats tools/tests/test_bump.bats tools/tests/test_digest-exporter-lib.bats tools/tests/test_create-app.bats tools/tests/test_bump-poll-toctou.bats`
