#!/usr/bin/env bats
WF=".github/workflows/ci.yaml"

@test "ci runs chart-test, ledger gate, and bats" {
  run cat "$WF"
  [[ "$output" == *"make chart-test"* ]]
  [[ "$output" == *"verify:ledger"* ]]
  [[ "$output" == *"bats "* ]]
}

@test "ci runs on pull_request and uses pnpm@10" {
  run yq '.on.pull_request' "$WF"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
  run grep -E "pnpm@10" "$WF"
  [ "$status" -eq 0 ]
}
