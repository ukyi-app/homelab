#!/usr/bin/env bats
WF=".github/workflows/ci.yaml"

@test "ci runs chart-test, ledger gate, and bats" {
  run cat "$WF"
  [[ "$output" == *"make chart-test"* ]]
  [[ "$output" == *"verify:ledger"* ]]
  [[ "$output" == *"bats "* ]]
}

@test "ci runs on pull_request and uses pnpm@11" {
  run yq '.on.pull_request' "$WF"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
  run grep -E "pnpm@11" "$WF"
  [ "$status" -eq 0 ]
}

@test "ci and verify workflows declare a concurrency group with cancel-in-progress" {
  run grep -E "^concurrency:" "$WF"
  [ "$status" -eq 0 ]
  run grep -E "cancel-in-progress" "$WF"
  [ "$status" -eq 0 ]
  run grep -E "^concurrency:" ".github/workflows/verify.yml"
  [ "$status" -eq 0 ]
  run grep -E "cancel-in-progress" ".github/workflows/verify.yml"
  [ "$status" -eq 0 ]
}
