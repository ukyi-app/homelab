#!/usr/bin/env bats
# make ci == ci.yaml job 'gate' 패리티 — push 전 풀 게이트를 한 명령으로 재현하는 단일 진입점.
# bats 수집이 scripts/run-bats.sh 단일 SSOT로 통합된 뒤로는, 양쪽이 같은 러너를 호출하는지(러너-동치)와
# 비-bats 게이트 스텝(ledger·audit·shellcheck·chart·e2e) 미러를 검증한다. drift 시 회귀로 차단.
# dry-run(make -n) + ci.yaml 정적 grep으로 toolchain/age/docker 없이도 돈다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2에서 [[ ]] 실패는 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "make ci invokes the single bats runner (run-bats.sh)" {
  run make -n ci
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "run-bats.sh"
}

@test "ci.yaml gate invokes the same single bats runner (run-bats.sh)" {
  run grep -q 'run-bats.sh' "$ROOT/.github/workflows/ci.yaml"
  [ "$status" -eq 0 ]
}

@test "make ci still mirrors the non-bats gate steps (chart·ledger·audit·shellcheck·e2e)" {
  run make -n ci
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "charts/app/tests"
  echo "$output" | grep -q "verify:ledger"
  echo "$output" | grep -q "audit-orphans"
  echo "$output" | grep -q "shellcheck"
  echo "$output" | grep -q "alertmanager-render-e2e"
}

@test "make ci depends on the m6-tools toolchain check" {
  run make -n ci
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "required"
}
