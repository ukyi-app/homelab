# Design — bump-poll 항목 러너 (F-1 deepening)

slug: bump-poll-item-runner
branch: deepen/bump-poll-item-runner (main 기반 — F-0/PR #365와 독립)
origin: handoff F-1 · plan `docs/bugfixes/bump-poll-duplicate-pr.md` F-1(R-38에서 분리)
성격: **행동 보존, 구조 심화**(codebase-design: shallow module → deep module)

## Problem — shallow module

`.github/workflows/bump-poll.yaml` L166-249: bump/propose-pr 항목마다 인라인 셸이 git 오케스트레이션
(`checkout -f main` → `checkout -b bump-poll/<app>-<tag>` → `bump-tag` → `git add writePath+digest-exporter` →
`git commit` → `ensure-bump-pr`)을 **하나의 worktree·index를 공유**하며 실행한다.

- **인터페이스 ≈ 구현**: git 기계가 YAML에 그대로 노출 — 워크플로 작성자가 전부 알아야 한다.
- **상태 공유 표면**: N 항목이 공유 worktree/index. R-38(서브셸은 종료상태만 격리)·H-2(commit 전 실패 시 staged
  `digest-exporter.yaml`이 다음 항목으로 누출)를 `git checkout -f main` 강제 정리로만 막는다(트랜잭션 격리·취약).
- **테스트 seam 없음**: YAML 셸 루프는 단위 테스트 불가. 현 `test_bump-poll-toctou.bats`는 YAML을 grep할 뿐.
  (bump-tag·ensure-bump-pr는 이미 테스트됨 — 무테스트는 오케스트레이션뿐.)
- deletion test: 이 루프를 지우면 복잡성이 워크플로 YAML로 재출현 → pass-through 아님, real deepening.

## Deepening — deep module `tools/run-bump-plan.ts`

작은 인터페이스 뒤에 항목별 격리·오케스트레이션·집계를 은닉한다.

- **인터페이스(seam)**: `bun tools/run-bump-plan.ts --plan <plan.json> [--repo-root <dir>]` → exit code + GHA 주석
  (`::warning::` 항목별 실패 · 끝에 실패 있으면 `::error::` + exit 1). 워크플로의 telegram-on-failure가 그대로 키잉.
- **소유 범위(Q2=A)**: plan.json부터 전부 — bump/propose-pr **필터** · 항목별 worktree 생명주기 · bump-tag 호출 ·
  commit(writer identity를 `git -c user.name/email`로 **명시 설정** — 전역 config 숨은 상태 대신 자기완결) ·
  action별 title/body 생성 · ensure-bump-pr 호출 · fail-closed 집계 · 끝 비-0.
- **YAML에 남는 것**: 환경 셋업만 — checkout · writer 토큰(GH_TOKEN env) · `poll-ghcr → plan.json` ·
  `bun tools/run-bump-plan.ts --plan plan.json` 한 줄. (reconcile-only job은 별개 — 범위 밖.)

## 격리 모델 (Q1=A) — 공간 격리

항목마다 **격리 git worktree**: `git worktree add <tmp> -b bump-poll/<app>-<tag> origin/main` → 그 worktree에서
bump-tag(`--repo-root <tmp>`)→commit→ensure-bump-pr → **모든 경로(성공·실패)에서 `git worktree remove --force`**.
공유 worktree/index 자체가 없어 **R-38·H-2 누출 클래스가 구조적으로 소멸**(각 항목이 자기 worktree에서
digest-exporter를 독립 편집 → 교차 누출 불가). 오브젝트 스토어 공유라 worktree add/remove 비용은 경미.

## 내부 seam & 의존 (Q3=B) — 테스트 표면

bump-tag·ensure-bump-pr는 CLI 전용(export 없음)이라 러너가 **서브프로세스**로 부른다. 테스트는:
- **git·bump-tag = 실제**: `git init` fixture(main + `apps/<app>/deploy/prod/values.yaml` + digest-exporter)에서
  **진짜 worktree**를 만들고 진짜 bump-tag가 파일을 쓴다 → worktree 공간 격리(F-1의 유일 주장)를 실제로 태운다.
- **ensure-bump-pr = stub(PATH)**: 네트워크(push/PR)만 stub — argv 기록 + 시나리오별 성공/실패(`test_ensure-bump-pr.bats`
  idiom). 이 stub이 유일한 seam.
- "1 adapter=가설, 2=real": 실제 ensure-bump-pr(라이브) + 테스트 stub = real seam.

## 행동 보존 불변식 (interface의 invariants)

같은 브랜치명 `bump-poll/<app>-<tag>` · 같은 커밋(writePath + digest-exporter, writer[bot] author) · 같은 PR ·
**항목 독립**(한 항목 실패 ≠ 나머지 굶김) · expect-current TOCTOU 가드(plan 스냅샷 `.current.tag`를 bump-tag에 전달) ·
fail-closed 집계 → 끝 비-0 · ensure-bump-pr = 원격 변이의 유일 소유(그대로) · plan 값은 읽은 그대로 전달(승인 게이트 우회 금지).

## 테스트 전략 (증명할 것)

**러너 실행 테스트** `tools/tests/test_run-bump-plan.bats`(fixture repo + ensure-bump-pr stub, **진짜 git worktree**):
- 정상 다항목: 각 항목이 자기 브랜치·자기 커밋(writePath+digest-exporter, **writer[bot] identity+메시지** — ensure-bump-pr가
  소유권 증명하는 그것)·자기 ensure-bump-pr 호출(argv 계약).
- ★ **H-2 staged-잔여 경로(DG-2) — `git add` 후 실패를 강제**: (a) staging 후 `git commit` 실패, (b) write 후 bump-tag 실패.
  각 경우 다음 항목의 commit이 **자기 경로만** 포함(앞 항목의 staged writePath·digest-exporter **무누출**)·전 worktree remove·
  run 계속(굶김 없음)·끝 비-0. **cleanup-제거 witness**(worktree remove 안 하면 RED) + **격리 teeth**(격리 없애면 누출로 RED).
- **순서 계약**: branch→bump→commit→ensure를 그 순서로(중간 실패 시 이후 미실행).
- **레인 verbatim(승인 게이트)**: 플래너 `.action` 그대로 전달 · propose-pr는 무장 안 함 · auto-merge를 켜는 **별도 플래그
  없음**(레인이 유일 입력, 두 레인 무조건 전달 구현은 RED) — ensure-bump-pr argv로 확인.
- **원격 변이 소유**: 러너는 `git push`·`gh pr create`·auto-merge를 **직접 안 함**(ensure-bump-pr만) · expect-current 전달(TOCTOU).

**thin 워크플로 경계 테스트**(migration 대상 `test_bump-poll-callsite.bats` 22 witness의 워크플로 절반):
- `bump-poll.yaml`에 직접 `git push`·`gh pr create`·auto-merge 스크립트 **없음** · bump 스텝은 run-bump-plan을 plan으로 부르는
  한 줄 · pr-sweeper/다른 워크플로가 bump-poll 네임스페이스 미선택(유지) · reconcile job 분리(유지).

→ 즉 call-site 계약이 **YAML-hermetic-run 게이트에서 러너의 자기 테스트된 인터페이스로 이동**(심화의 정수). 어느 witness도
약화·삭제하지 않고 워크플로 경계 + 러너 레벨로 **분할 이관**한다(DG-1).

## 변경 / 유지

- **신규**: `tools/run-bump-plan.ts` · `tools/tests/test_run-bump-plan.bats` · `tools/README.md` 등재.
- **수정**:
  - `.github/workflows/bump-poll.yaml` — bump 스텝의 셸 루프 → 러너 호출 한 줄.
  - **`tests/gates/test_bump-poll-callsite.bats`(DG-1) — 22 witness를 워크플로 경계(직접 push/`gh pr create`/auto-merge
    없음)와 러너 실행 테스트(순서·레인 verbatim·원격 변이 소유·real-git 격리·staged-잔여·effective-ownership)로 분할 이관.
    어느 계약·변이 witness도 약화·삭제하지 않는다** — 이 게이트가 사실상 F-1 계약의 본체다.
  - `test_bump-poll-toctou.bats` — YAML grep → 러너가 `--expect-current`를 bump-tag에 전달함을 검증하도록 이관.
- **유지(무변경)**: `ensure-bump-pr.ts`(원격 변이 소유) · `bump-tag.ts`(파일 변이) · `poll-ghcr.ts`(플래너) · reconcile job.

## Out of scope

- ensure-bump-pr/bump-tag 내부 리팩터(이미 deep·테스트됨). reconcile-only job. F-0(ruleset)·F-2(형제 close).
- worktree 병렬화(현 순차 유지 — 결정성·git 안전).
