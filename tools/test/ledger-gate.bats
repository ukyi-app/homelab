#!/usr/bin/env bats
# M0 owns the ledger format + verify:ledger gate. This suite asserts the M6 apps fit the
# budget and that the gate rejects an over-budget ledger. (NOTE: verify:ledger validates the
# LEDGER DOC, not app values; a missing per-app memory LIMIT is caught earlier by the chart's
# values.schema.json minLength — see tools/test/schema.bats.)

@test "verify:ledger passes on current apps (M6 rows within budget)" {
  run pnpm verify:ledger
  [ "$status" -eq 0 ]
}

@test "verify:ledger FAILS an over-budget ledger (negative test, gate mechanism)" {
  cp docs/memory-ledger.md /tmp/bad-ledger.md
  printf '| <!-- ledger:row --> hog | prod | 100 | 9000 |\n' >> /tmp/bad-ledger.md
  scripts/ledger-to-json.sh /tmp/bad-ledger.md > /tmp/bad.json
  run conftest test /tmp/bad.json --policy policy/ledger.rego
  [ "$status" -ne 0 ]
  [[ "$output" == *"over budget"* ]]
}
