#!/usr/bin/env bats
# bump-poll **호출부 계약** — 원격 변이(브랜치 push·PR 생성)는 오직 tools/ensure-bump-pr.ts를 통해서만.
#
# 왜 이 게이트가 필요한가(plan r2 R-4): ensure-bump-pr가 아무리 옳게 판정해도, 워크플로가 도구를
# 부르기 **전에** 스스로 push/create를 하면 프로덕션은 그대로 중복 PR을 낸다(도구만 GREEN). 순서·부작용
# 계약을 프로덕션 호출부에 못 박아야 그 false-green이 닫힌다.
#   ① `gh pr create` 직접 호출 0 — PR 생성은 도구가 관측(gh pr list + git ls-remote) 뒤에만 한다.
#   ② `git push` 직접 호출 0 — skip 판정이 "아무것도 변이하지 않음"이 되려면 push도 도구 몫이어야 한다.
#      (워크플로가 먼저 push하면: 판정이 skip이어도 원격 브랜치가 갱신되고, `gh pr create` 실패 시엔
#       **고아 원격 브랜치**가 남아 다음 주기 plain push와 non-fast-forward 충돌 → 배포 정지.)
#   ③ 브랜치명에 RUN_ID 없음 — run마다 브랜치가 달라지면 "이 bump의 열린 PR"을 조회할 대상 자체가 없다.
#
# 회귀(test_tags=regression): 지금은 RED(워크플로가 아직 옛 방식 — 직접 push + 직접 gh pr create + RUN_ID).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]]·중간 `!`는 침묵 통과.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  F="$ROOT/.github/workflows/bump-poll.yaml"
}

# bats test_tags=regression
@test "bump-poll never calls gh pr create directly (PR creation goes through ensure-bump-pr)" {
  run grep -n "gh pr create" "$F"
  if [ "$status" -eq 0 ]; then
    echo "duplicate bump PR: bump-poll.yaml still calls 'gh pr create' directly — PR 생성은 tools/ensure-bump-pr.ts(조회→결정→변이)를 통해서만"
    echo "$output"
    false
  fi
}

# bats test_tags=regression
@test "bump-poll never pushes the bump branch directly (a skip decision must mutate nothing)" {
  run grep -nE '(^|[^-[:alnum:]])git push' "$F"
  if [ "$status" -eq 0 ]; then
    echo "orphan bump branch: bump-poll.yaml still runs 'git push' itself — push는 ensure-bump-pr가 관측 뒤에 (lease와 함께) 해야 한다"
    echo "$output"
    false
  fi
}

# bats test_tags=regression
@test "bump-poll drives the PR step through tools/ensure-bump-pr.ts" {
  run grep -n "tools/ensure-bump-pr.ts" "$F"
  if [ "$status" -ne 0 ]; then
    echo "duplicate bump PR: bump-poll.yaml이 tools/ensure-bump-pr.ts를 호출하지 않는다 — 멱등 실행기가 배선되지 않으면 도구 GREEN이 프로덕션을 고치지 못한다"
    false
  fi
}

# bats test_tags=regression
@test "the bump branch name carries no RUN_ID (same bump converges to one branch)" {
  run grep -n "RUN_ID" "$F"
  if [ "$status" -eq 0 ]; then
    echo "duplicate bump PR: bump-poll.yaml still derives the branch from RUN_ID — 같은 bump가 run마다 다른 브랜치를 만들어 조회 대상이 사라진다"
    echo "$output"
    false
  fi
}

# ---------------------------------------------------------------------------
# 보존 — 재작성이 기존 계약(플래너·TOCTOU 가드)을 깨지 않았음을 확인(지금도 GREEN)
# ---------------------------------------------------------------------------

@test "bump-poll still plans with poll-ghcr and re-proves the from-tag via bump-tag --expect-current" {
  run grep -q "tools/poll-ghcr.ts" "$F"
  [ "$status" -eq 0 ]
  run grep -qE 'bump-tag\.ts .*--expect-current' "$F"
  [ "$status" -eq 0 ]
}
