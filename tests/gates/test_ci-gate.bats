#!/usr/bin/env bats
WF=".github/workflows/ci.yaml"

@test "ci runs typecheck, chart-test, ledger gate, and bats" {
  run cat "$WF"
  printf '%s' "$output" | grep -qF -- "bun run typecheck"
  printf '%s' "$output" | grep -qF -- "make chart-test"
  printf '%s' "$output" | grep -qF -- "verify:ledger"
  [[ "$output" == *"bats "* ]]
}

@test "ci runs on pull_request and uses the setup-bun composite" {
  run yq '.on.pull_request' "$WF"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
  # bun 버전 핀은 setup-bun composite로 이전 — ci가 composite를 채택하고 composite가 핀한다.
  run grep -F 'uses: ./.github/actions/setup-bun' "$WF"
  [ "$status" -eq 0 ]
  # 버전 **값**의 소유자는 tests/gates/test_setup-bun.bats의 CANON 등식 하나뿐이다 — 여기서는
  # composite가 bun-version을 핀한다는 사실만 본다(리터럴을 복제하면 bump가 손편집 7곳이 된다).
  run grep -E 'bun-version: "[0-9.]+"' .github/actions/setup-bun/action.yml
  [ "$status" -eq 0 ]
}

@test "ci and verify workflows declare a concurrency group with cancel-in-progress" {
  run grep -E "^concurrency:" "$WF"
  [ "$status" -eq 0 ]
  run grep -E "cancel-in-progress" "$WF"
  [ "$status" -eq 0 ]
}
