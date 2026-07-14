---
bugfix: bump-poll-duplicate-pr
invariant-class: bugfix
entry-track: incident
review-track: standard
pipeline-stage: red-capture
issue-tracker: local
worktree:
branch: fix/bump-poll-duplicate-pr
consent-scope:
symptom: "같은 앱 커밋(page sha-815abb…)에 대해 bump-poll이 11분 사이 PR 3개(#348·#350·#353)를 열었다. 각 PR이 15분짜리 required 게이트를 태우고, 먼저 머지된 하나를 뺀 나머지는 DIRTY(충돌)+auto-merge 무장 상태로 영구 잔류한다(pr-sweeper는 BEHIND만 처리)."
red-baseline: b9d294d464a5c864ad679af0707ac77442216e29
bugfix-lock: red
spike-1:
---

## Track note

**증상(라이브 2026-07-13)**: 동일 bump에 대한 중복 PR.

| PR | 시각 | 제안 내용 | 상태 |
|---|---|---|---|
| #348 | 06:34 (앱 빌드 dispatch) | `sha-815abb…` / `sha256:7f175c…` | **OPEN · DIRTY · auto-merge 무장** |
| #350 | 06:35 (크론 `*/10`) | **동일** | **OPEN · DIRTY · auto-merge 무장** |
| #353 | 06:45 (크론) | **동일** | MERGED |

**근본 원인(코드 확인)**: `tools/poll-ghcr.ts`(플래너)는 **GHCR 최신 vs main의 배포 핀**만 비교한다.
PR이 머지되기 전에는 main이 여전히 옛 digest이므로, 폴링할 때마다 "bump 필요"로 판정한다.
`.github/workflows/bump-poll.yaml`은 그 판정을 받아 **run마다 새 브랜치**(`bump-poll/<app>-${RUN_ID}`)를
만들고 **기존 열린 PR을 확인하지 않은 채** `gh pr create`한다(97·117행).

즉 **"이미 열린 PR이 같은 bump를 제안 중"이라는 사실이 플래너의 입력에 없다.**

**왜 pr-sweeper가 못 치우나**: 그 워크플로는 **auto-merge 무장 + BEHIND**인 PR만 `update-branch`한다
(strict 보호 하에서 멈춘 수렴을 깨우는 용도). 중복 PR은 먼저 머지된 형제 때문에 **DIRTY(충돌)** 이 되므로
스위퍼의 대상이 아니고, 아무도 닫지 않는다.

**단일 flip**: 열린 PR이 이미 같은 후보를 제안 중이면 플래너가 **bump/propose-pr → noop(skip)** 으로
판정한다. 진짜 새 후보(다른 tag/digest)는 **계속 PR을 연다**(보존 계약).

**Fork A**(정확한 seam 존재). seam = `tools/poll-ghcr.ts`의 플래너 판정 + 기존 hermetic 테스트
`tools/tests/test_poll-ghcr.bats`(fixtures 기반 데이터 소스 추상화 — 라이브는 `gh api`, 테스트는 fixtures).
"열린 bump PR" 사실을 그 추상화에 추가하면 hermetic RED 테스트가 가능하다.

**별건(이 파이프라인 밖)**:
- 좀비 PR #348·#350 정리(운영 작업 — 랜딩 시 함께).
- 콘텐츠 동일 재빌드가 새 인덱스 digest를 만들어 무의미한 배포 회전을 일으키는 문제(원래 F-1의 다른 절반).
