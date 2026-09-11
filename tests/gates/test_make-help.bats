#!/usr/bin/env bats
# 내장 목록의 정렬과 레시피 전체 노출을 검증한다.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "just help lists every recipe in sorted order" {
  run just help
  [ "$status" -eq 0 ]
  names="$(printf '%s\n' "$output" | awk '{print $1}')"
  [ -n "$names" ]
  declared="$(sed -nE 's/^([a-zA-Z0-9_.-]+):.*/\1/p' justfile | LC_ALL=C sort -u)"
  [ -n "$declared" ]
  [ "$names" = "$declared" ]
}

@test "bare just lists commands without running any recipe" {
  run just
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'Available recipes:'
  printf '%s\n' "$output" | grep -q 'chart-test'
}
