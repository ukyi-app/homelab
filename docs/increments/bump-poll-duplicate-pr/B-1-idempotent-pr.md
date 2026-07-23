---
id: B-1
title: ensure-bump-pr을 실제 상태 기계로(create/adopt/skip/rebuild + 무장 축) + bump-poll 배선
status: done
blocked-by: [none]
plan: docs/bugfixes/bump-poll-duplicate-pr.md
created: 2026-07-14
closed: 2026-07-14
---

## What to build

**(a) `tools/ensure-bump-pr.ts`**(scope): 동결된 create 경로를 **실제 상태 기계**로 교체.
조회는 **상한 없는 완전 열거**(GraphQL connection을 **한 페이지씩** 소비 — `--paginate --slurp` 금지,
검색 API 금지), 식별은 `(head, base)` 쌍, 신뢰는 동일-레포 + `author.__typename == "Bot"` + writer login.

| 신뢰된 PR(동일-레포 + writer Bot + 같은 base) | 원격 브랜치 | 결정 |
|---|---|---|
| 없음 | 없음 | **create**: `git push origin HEAD:refs/heads/<b>` → `gh pr create` |
| 없음 | 있음(고아) | **adopt**: leased push(원격 OID) → `gh pr create` |
| 없음(단, **비신뢰 동일-레포 PR**이 열려 있음) | 필연적으로 있음 | **fail-closed**: 변이 0 — 남의 브랜치를 덮지 않는다 |
| 있음 · **DIRTY 또는 BEHIND**(`STALE_STATES`) · 사람 흔적 0 | — | **rebuild**: leased push(`headRefOid`) → PR 재사용(create 금지) |
| 있음 · DIRTY/BEHIND · **사람의 흔적 있음** | — | **skip**: force-push 0 — 리뷰·승인 상태를 파괴하지 않는다(H-4) |
| 있음 · 그 외(CLEAN·BLOCKED·**UNKNOWN**…) | — | **skip**: push·create 0회 |

**BEHIND 수렴은 실행기 몫이다**(r7 R-25) — `gh pr update-branch`는 **절대 부르지 않는다**(head가 머지 커밋이
되면 소유권 증명이 영구 실패 → 그 앱의 bump 하드 스톨). **소유권**(writer ident + 결정적 bump 커밋 메시지)은
force-push만이 아니라 **무장의 전제조건**이다(R-23): 미증명이면 변이 0 + **기존 무장 회수**.

**무장 축(결정과 직교 · 양방향 reconcile)**: lane=`bump` + 신뢰 PR + 미무장 + **증명된 head** → **재무장**
(결정이 skip이든 rebuild든) · 이미 무장 → 손대지 않음 · 새 PR → 생성 직후 무장 · lane=`propose-pr` →
**절대 무장하지 않고 낡은 무장은 해제**(`gh pr merge --disable-auto <번호>`).

**(b) `.github/workflows/bump-poll.yaml`**(scope): 브랜치명을 `bump-poll/<app>-<tag>`로(RUN_ID 제거),
**로컬 브랜치·커밋만 준비**하고 실행기를 호출한다. `gh pr create`·`git push`·`auto-merge-or-fail.sh`를
**직접 호출하지 않는다**. 플래너의 `action`을 **verbatim**으로 `--action`에 전달(읽은 뒤 재대입 금지).
회수(`--reconcile-only`)는 **writer 토큰만 쓰는 별도 job**으로 매 주기 돈다(플래너·reader 비의존).

**(c) `.github/workflows/pr-sweeper.yaml`**(scope): 선택 접두에서 `bump-poll`을 **제거**한다 —
그 네임스페이스의 원격 상태는 실행기가 **단독 소유**한다(다른 봇 접두는 그대로).

## Acceptance criteria

- [ ] `bats tools/tests/test_ensure-bump-pr.bats tests/gates/test_bump-poll-callsite.bats --filter-tags regression` → **exit 0**(회귀 106건 전부 GREEN)
- [ ] characterization(63) → exit 0 (특히 fail-closed 6종·negative argv 10종·propose-pr 무장 0)
- [ ] `make ci` → rc=0 · `actionlint` → clean(워크플로 변경)
- [ ] 비-테스트 변경이 `scope[]` 3파일뿐(B4)

## Blocked by

None - can start immediately

## Result

커밋 `73b546a`(B-1 본체) → structure r6~r9(R-22~R-35)에서 계약이 깊어졌다. GREEN 핀 `c4a1a12`:
회귀 **106건 전부 RED→GREEN**, 보존 63건 유지, 비-테스트 변경은 `scope[]` **3파일**뿐(B4).

- **상태 기계**: 신뢰 PR 존재가 최우선 → **DIRTY·BEHIND**(`STALE_STATES`)면 `rebuild`(leased force-push,
  create 금지) — 단 **사람의 흔적**(리뷰·리뷰어 요청·assignee·사람 코멘트·`hold` 라벨·draft·reopen —
  **잘렸거나 관측 불가면 "흔적 있음"**)이 있으면 밀지 않고 `skip`. 그 외(CLEAN·BLOCKED·UNKNOWN 및 미지
  상태)는 `skip`(변이 0 — 미지 상태도 비변이 쪽으로 fail-safe). 신뢰 PR 없음 + 고아 원격 브랜치 →
  `adopt`(leased push) / 둘 다 없음 → `create` / 비신뢰 동일-레포 PR이 있으면 fail-closed.
- **무장 축(직교·양방향)**: `shouldArm = lane === "bump" && (createsPr || (armGap && headProof.ok))` ·
  `shouldDisarm = staleArm && (lane === "propose-pr" || !headProof.ok)` — 둘 다 판정 분기 **밖에서** 계산.
  `propose-pr`은 어느 경로로도 무장에 닿지 못한다(승인 게이트 구조적 보존). **해제가 첫 변이**다
  (force-push가 체크를 green으로 되돌리기 전에 낡은 인가를 거둔다).
- **`--reconcile-only`**(H-1·R-27·V-1): 해제 스윕 전용 패스. 대상은 **`bump-poll/*` 네임스페이스**(플래너
  출력이 아니다 — `--app`/`--tag`/`--action`을 거부한다), 레인은 autoDeploy SSOT에서 직접 읽으며
  **부재·파손도 `propose-pr`**(R-26). bump 레인은 그 앱의 **가장 새로운** 신뢰 PR만 무장을 유지하고 더 오래된
  형제는 전부 회수한다(순서 불명이면 전부 — 과잉 회수는 다음 주기가 재무장, 과소 회수는 무승인 머지).
- **실패 계약**(R-32·V-2): **회수 대상을 가릴 수 있는 관측 실패는 그 자체가 회수 실패**다 → 두 경로가 같은
  집계를 쓰고, **모든 변이를 마친 뒤** 비-0 종료한다(억제 = 공격 표면 — 한 앱의 실패가 다른 앱을 굶기지 않는다).
- **워크플로**: 결정적 브랜치(`bump-poll/<app>-<tag>`, RUN_ID 제거) + 로컬 커밋만 준비 → 실행기 호출.
  직접 `git push`·`gh pr create`·`auto-merge-or-fail.sh` 전부 제거. 레인은 verbatim 전달. 회수는 **별도 job**
  (writer 게이트만 — reader가 비어도 돈다, R-31). `pr-sweeper`에서 `bump-poll` 접두 제거(R-25).
- **하네스 결함 수리**(fix 전 별도 커밋으로 red에 고정): bats `run`이 `$output`을 덮어써 W2/W3/W6의
  `.action` 단언이 **어떤 구현으로도 통과 불가**였다 → 보존된 `$JSON`에서 읽도록 복구(약화 아님, 강화).
  그 baseline에서도 회귀는 RED임을 재증명했다.
- 검증: `make ci` rc=0 · `actionlint` clean · typecheck clean.
