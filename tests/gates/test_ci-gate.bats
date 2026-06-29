#!/usr/bin/env bats
WF=".github/workflows/ci.yaml"

@test "ci runs typecheck, chart-test, ledger gate, and bats" {
  run cat "$WF"
  [[ "$output" == *"bun run typecheck"* ]]
  [[ "$output" == *"make chart-test"* ]]
  [[ "$output" == *"verify:ledger"* ]]
  [[ "$output" == *"bats "* ]]
}

@test "ci runs on pull_request and uses the setup-bun composite" {
  run yq '.on.pull_request' "$WF"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
  # bun 버전 핀은 setup-bun composite로 이전 — ci가 composite를 채택하고 composite가 핀한다.
  run grep -F 'uses: ./.github/actions/setup-bun' "$WF"
  [ "$status" -eq 0 ]
  run grep -E 'bun-version: "1.3.14"' .github/actions/setup-bun/action.yml
  [ "$status" -eq 0 ]
}

@test "ci and verify workflows declare a concurrency group with cancel-in-progress" {
  run grep -E "^concurrency:" "$WF"
  [ "$status" -eq 0 ]
  run grep -E "cancel-in-progress" "$WF"
  [ "$status" -eq 0 ]
  run grep -E "^concurrency:" ".github/workflows/verify.yaml"
  [ "$status" -eq 0 ]
  run grep -E "cancel-in-progress" ".github/workflows/verify.yaml"
  [ "$status" -eq 0 ]
}
