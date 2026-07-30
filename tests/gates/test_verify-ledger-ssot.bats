#!/usr/bin/env bats
# ledger 검증 파이프라인을 1곳(scripts/verify-ledger.sh)으로 수렴 — 인라인 conftest 3중 복제 제거.
# ⚠️ 중간 단언은 [ ]만.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "verify-ledger.sh SSOT script exists and is executable" {
  [ -x "$ROOT/scripts/verify-ledger.sh" ]
  grep -q 'ledger-to-json.ts' "$ROOT/scripts/verify-ledger.sh"
  grep -q 'conftest test' "$ROOT/scripts/verify-ledger.sh"
}

@test "package.json verify:ledger delegates to the SSOT script" {
  run bun -e "process.stdout.write(require('$ROOT/package.json').scripts['verify:ledger'])"
  echo "$output" | grep -q 'scripts/verify-ledger.sh'
}

@test "Makefile verify target no longer inlines the conftest pipeline" {
  run grep -c 'conftest test /tmp/ledger.json' "$ROOT/Makefile"
  [ "$output" = "0" ]
  grep -q 'scripts/verify-ledger.sh' "$ROOT/Makefile"
}
