#!/usr/bin/env bats
# 단일 러너의 수집 집합 불변식. bash 3.2 함정 회피 — 단언은 grep 파이프/[ ]로.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "run-bats.sh lists every test_*.bats except .ci-exclude entries" {
  run bash "$ROOT/scripts/run-bats.sh" --list
  [ "$status" -eq 0 ]
  list="$output"   # run 재호출이 $output을 덮으므로 로컬에 보존
  # 포함: 일반 게이트 테스트
  echo "$list" | grep -q 'platform/argocd/root/test_render.bats'
  # 제외: .ci-exclude 멤버 (중간 negate는 침묵 통과 → run+status로 강제)
  run grep -q 'tests/posture/test_internal-by-default.bats' <<<"$list"
  [ "$status" -ne 0 ]
  run grep -q 'tools/tests/test_dev-postgres.bats' <<<"$list"
  [ "$status" -ne 0 ]
}

@test "run-bats.sh --list = all test_*.bats minus platform/charts minus .ci-exclude" {
  gate=$(git -C "$ROOT" ls-files '*test_*.bats' | grep -vE '^platform/charts/' | wc -l | tr -d ' ')
  excl=$(grep -vcE '^[[:space:]]*(#|$)' "$ROOT/tests/.ci-exclude")
  listed=$(bash "$ROOT/scripts/run-bats.sh" --list | grep -c '\.bats$')
  [ "$listed" -eq "$((gate - excl))" ]   # infra prune 없음 — CI-safe infra는 gate
}

@test "run-bats.sh runs under macOS default /bin/bash 3.2 (no mapfile/set -u)" {
  # AGENTS.md bash3.2 함정: 러너가 owner macOS의 /bin/bash로 반드시 동작해야 한다.
  run /bin/bash "$ROOT/scripts/run-bats.sh" --list
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'test_.*\.bats'
}

@test "run-bats.sh has executable bit (Makefile/CI invoke ./scripts/run-bats.sh directly)" {
  # Task 0.5가 make ci·ci.yaml에서 ./scripts/run-bats.sh 직접 호출 → exec 비트 없으면 깨진다.
  [ -x "$ROOT/scripts/run-bats.sh" ]
}
