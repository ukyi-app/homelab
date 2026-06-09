#!/usr/bin/env bats

@test "seed ledger passes the budget policy" {
  scripts/ledger-to-json.sh docs/memory-ledger.md > /tmp/ledger.json
  run conftest test /tmp/ledger.json --policy policy/ledger.rego
  [ "$status" -eq 0 ]
}

@test "over-budget ledger is rejected" {
  cp docs/memory-ledger.md /tmp/bad-ledger.md
  # add a 9000Mi row that blows the 8704 budget
  printf '| <!-- ledger:row --> hog | prod | 100 | 9000 |\n' >> /tmp/bad-ledger.md
  scripts/ledger-to-json.sh /tmp/bad-ledger.md > /tmp/bad.json
  run conftest test /tmp/bad.json --policy policy/ledger.rego
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'over budget'
}
