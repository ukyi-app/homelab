#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers/aiops
setup() { aiops_setup; }

@test "twelve fixed cases do not turn missing model reports into quality evidence" {
  mkdir "$BATS_TEST_TMPDIR/reports"
  printf '{"answers":{}}\n' > "$BATS_TEST_TMPDIR/answers.json"
  run aiops evaluate --cases tools/fixtures/aiops/cases.json --answers "$BATS_TEST_TMPDIR/answers.json" --reports "$BATS_TEST_TMPDIR/reports"
  [ "$status" -eq 1 ]
  jq -e '.cases == 12 and (.sources | length) == 5 and .quality == "unverified" and .missingReports == 12' <<< "$output"
}
