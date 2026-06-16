#!/usr/bin/env bats
# 전 bats 도메인 accounting 가드의 게이트 테스트 — 미배정(고아)/이중소유/stale .ci-exclude를 차단.
# bash 3.2 함정: 단언은 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "every tracked test_*.bats is assigned to exactly one domain (gate/chart-test/.ci-exclude)" {
  run bash "$ROOT/scripts/check-bats-accounting.sh"
  [ "$status" -eq 0 ]   # 미배정/이중소유/stale 1개라도 있으면 exit 1 + 목록 출력
}
