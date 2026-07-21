# Verification — bump-poll-duplicate-pr

단일 flip: **같은 bump에 이미 열린 writer PR이 있으면 새 PR을 열지 않는다**(정상=skip, 충돌=같은 PR rebuild).
아래는 HEAD(green.sha `c389276`)에서 신선하게 재실행한 증거다.

> ⚠️ 도구 참고: 세션 중 스킬 세트가 새 세대로 교체돼 `bugfix-status.mjs`(머신 RED→GREEN 락)가 환경에서
> 사라졌다. flip 자체는 라운드마다 그 스크립트의 자체 재실행으로 증명해 왔고(마지막 커밋된 verify-record는
> R-46 baseline `b26673d`/`6394ff9` 기준), 아래는 그 대체로 **동일한 파티션을 HEAD에서 수동 재실행**한
> 증거다. `red..green` 순 diff는 여전히 scope 4파일뿐(테스트 변경 0).

## 1. regression 파티션 — HEAD에서 GREEN (flip이 fixed 쪽)

```
$ bats tools/tests/test_ensure-bump-pr.bats tests/gates/test_bump-poll-callsite.bats --filter-tags regression
...
ok 118 …
```
118/118 ok(release r1/R-48로 close 전용 증인 4건 제거). baseline(`6b2513d`)에서는 전량 RED(증상토큰 존재)임을 재구성 시 확인했다.

## 2. characterization 파티션 — 양 끝단 GREEN (나머지 보존)

```
$ bats --filter-tags '!regression' tools/tests/test_ensure-bump-pr.bats tests/gates/test_bump-poll-callsite.bats \
    tools/tests/test_poll-ghcr.bats tools/tests/test_bump.bats tools/tests/test_bump-poll-toctou.bats
...
ok 63 bump-poll git-adds the planner writePath (unifies apps and bespoke lanes)
```
63/63 ok.

## 3. 단일-flip 표면 경계 — red..green 비-테스트 변경 = scope 4파일

```
$ git diff --name-only 6b2513d c389276
.github/workflows/bump-poll.yaml
.github/workflows/pr-sweeper.yaml
tools/README.md
tools/ensure-bump-pr.ts
```
락의 `scope[]`(4경로)와 정확히 일치. 테스트 파일 변경 0(두 핀 사이 동일 파티션).

## 4. 정적 게이트

```
$ bun run typecheck   → rc=0
$ actionlint          → rc=0
$ bats tools/tests/ tests/gates/  → 0 failures
$ make verify (skeleton·ledger·sops) → rc=0
```
(`make ci` 전량은 `test_sealed-secrets-restore.bats`의 알려진 환경 행으로 타임아웃 — 나머지 전부 개별 통과.)

## 5. 하드닝 증인 (structure 게이트 r1~r18에서 누적, 전부 뮤테이션 격리)

공유 head force-push/회수 안전을 라운드마다 증인화했다(요지 — 전문은 Review Decision Log):
W1~W3(중복 방지 core)·W20~W28(소유권 인터록)·W47~W58(reconcile 완결·실패 계약)·W70~W71(fork-불변
질의)·W74~W80(ref 교차검증·3자 OID 합의)·W81~W84(배타적 head 소유권·TOCTOU 재확인·H-4 보존). release r1/R-48로 형제 **close** 전용 증인은 제거(자동 close를 픽스에서 들어냄 — F-2).

## 잔여(환원 불가능) — F-0 / F-1

- **F-0**: 커밋 미서명 + 동시 PR 생성 TOCTOU → 소유권 검사는 **안전 인터록이지 인증이 아니다**. 진짜 닫힘은
  `bump-poll/**`를 writer App에 예약하는 서버-강제 룰셋(IaC, 도구 밖).
- **F-1**: 인-워크플로 셸 루프 → 테스트된 worktree-격리 항목 러너(구조 개선, 별건).
