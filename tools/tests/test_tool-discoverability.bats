#!/usr/bin/env bats
# 툴링 발견성 — 읽기전용 진입점 make audit + 고빈도 도구 --help 표준.
# (16개 도구 전체 --help/통합 CLI는 F3 P2 — 여기선 침묵-무시/거부 2종만 고친다.)
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "audit-orphans --help prints usage and exits 0" {
  run bun tools/audit-orphans.ts --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "audit-orphans"
  echo "$output" | grep -q -- "--ci"
}

@test "poll-ghcr --help prints usage and exits 0 (was: unknown-arg exit 2)" {
  run bun tools/poll-ghcr.ts --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "poll-ghcr"
  echo "$output" | grep -q -- "--dry-run"
}

@test "make audit runs the read-only static drift audit" {
  run make -n audit
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "audit-orphans"
}
