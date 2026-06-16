#!/usr/bin/env bats
# make ci == ci.yaml job 'gate' 패리티 — push 전 풀 게이트를 한 명령으로 재현하는 단일 진입점.
# gate 스텝이 추가/변경됐는데 make ci가 안 따라오면 드리프트를 회귀로 차단한다.
# dry-run(make -n)으로만 검사하므로 toolchain/age/docker 없이도 돈다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2에서 [[ ]] 실패는 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "make ci mirrors every ci.yaml gate step (dry-run)" {
  run make -n ci
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "charts/app/tests"
  echo "$output" | grep -q "verify:ledger"
  echo "$output" | grep -q "audit-orphans"
  echo "$output" | grep -q "tools/test"
  echo "$output" | grep -q "shellcheck"
  echo "$output" | grep -q "find platform"
  echo "$output" | grep -q "alertmanager-render-e2e"
}

@test "make ci depends on the m6-tools toolchain check" {
  run make -n ci
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "required"
}
