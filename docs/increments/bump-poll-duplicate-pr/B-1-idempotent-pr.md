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

| 신뢰된 PR(동일-레포 + writer) | 원격 브랜치 | 결정 |
|---|---|---|
| 없음 | 없음 | **create**: `git push origin HEAD:refs/heads/<b>` → `gh pr create` |
| 없음 | 있음(고아) | **adopt**: leased push(원격 OID) → `gh pr create` |
| 있음 · CLEAN/BEHIND/BLOCKED/UNKNOWN | — | **skip**: push·create 0회 |
| 있음 · DIRTY | — | **rebuild**: leased push(`headRefOid`) → PR 재사용(create 금지) |

**무장 축(결정과 직교)**: lane=`bump` + 신뢰 PR + 미무장 → **재무장**(결정이 skip이든 rebuild든) ·
이미 무장 → 손대지 않음 · 새 PR → 생성 직후 무장 · lane=`propose-pr` → **절대 무장 없음**.

**(b) `.github/workflows/bump-poll.yaml`**(scope): 브랜치명을 `bump-poll/<app>-<tag>`로(RUN_ID 제거),
**로컬 브랜치·커밋만 준비**하고 실행기를 호출한다. `gh pr create`·`git push`·`auto-merge-or-fail.sh`를
**직접 호출하지 않는다**. 플래너의 `action`을 **verbatim**으로 `--action`에 전달(읽은 뒤 재대입 금지).

## Acceptance criteria

- [ ] `bats tools/tests/test_ensure-bump-pr.bats tests/gates/test_bump-poll-callsite.bats --filter-tags regression` → **exit 0**(회귀 15건 전부 GREEN)
- [ ] characterization(79) → exit 0 (특히 fail-closed 6종·negative argv 10종·propose-pr 무장 0)
- [ ] `make ci` → rc=0 · `actionlint` → clean(워크플로 변경)
- [ ] 비-테스트 변경이 `scope[]` 2파일뿐(B4)

## Blocked by

None - can start immediately

## Result

커밋 `73b546a`. 회귀 **15건 전부 RED→GREEN**, 보존 79건 유지, 비-테스트 변경 2파일(B4).

- **상태 기계**: 신뢰 PR 존재가 최우선 → DIRTY면 `rebuild`(leased force-push, create 금지) / 그 외
  (CLEAN·BEHIND·BLOCKED·UNKNOWN 및 미지 상태)는 `skip`(변이 0 — 미지 상태도 비변이 쪽으로 fail-safe).
  신뢰 PR 없음 + 고아 원격 브랜치 → `adopt`(leased push) / 둘 다 없음 → `create`.
- **무장 축(직교)**: `shouldArm = lane === "bump" && (createsPr || armGap)` — 판정 분기 **밖에서** 계산.
  `propose-pr`은 어느 경로로도 무장에 닿지 못한다(승인 게이트 구조적 보존).
- **워크플로**: 결정적 브랜치(`bump-poll/<app>-<tag>`, RUN_ID 제거) + 로컬 커밋만 준비 → 실행기 호출.
  직접 `git push`·`gh pr create`·`auto-merge-or-fail.sh` 전부 제거. 레인은 verbatim 전달.
- **하네스 결함 수리**(fix 전 별도 커밋으로 red에 고정): bats `run`이 `$output`을 덮어써 W2/W3/W6의
  `.action` 단언이 **어떤 구현으로도 통과 불가**였다 → 보존된 `$JSON`에서 읽도록 복구(약화 아님, 강화).
  그 baseline에서도 회귀는 RED임을 재증명했다.
- 검증: `make ci` rc=0(1316 ok) · `actionlint` clean · typecheck clean.
