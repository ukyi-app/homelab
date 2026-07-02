#!/usr/bin/env bats

@test "seed ledger passes the budget policy" {
  bun tools/ledger-to-json.ts docs/memory-ledger.md > /tmp/ledger.json
  run conftest test /tmp/ledger.json --policy policy/ledger.rego
  [ "$status" -eq 0 ]
}

@test "over-budget ledger is rejected" {
  cp docs/memory-ledger.md /tmp/bad-ledger.md
  # add a 9000Mi row that blows the 9216 budget
  printf '| <!-- ledger:row --> hog | prod | 100 | 9000 |\n' >> /tmp/bad-ledger.md
  bun tools/ledger-to-json.ts /tmp/bad-ledger.md > /tmp/bad.json
  run conftest test /tmp/bad.json --policy policy/ledger.rego
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'over budget'
}
