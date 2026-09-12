#!/usr/bin/env bats
# 설치 계획은 호스트를 변경하지 않는 공개 경계다.
bats_require_minimum_version 1.5.0
load helpers/aiops
setup() { aiops_setup; }

@test "host plan separates roles and leaves activation gated" {
  run aiops host-plan --output "$BATS_TEST_TMPDIR/install"
  [ "$status" -eq 0 ]
  jq -e '.activation == "disabled" and (.roles | length) == 6 and .limits.wholeAttemptSeconds == 1200 and .limits.diskMiB == 512' <<< "$output"
  [ -f "$BATS_TEST_TMPDIR/install/aiops-worker.service" ]
  [ -f "$BATS_TEST_TMPDIR/install/config.example.json" ]
  run aiops readiness --config "$BATS_TEST_TMPDIR/install/config.example.json"
  [ "$status" -eq 1 ]
  jq -e '.ready == false and (.pending | index("subscription-authentication")) != null and (.pending | index("observation-criteria")) != null' <<< "$output"
}

@test "preflight commands create group writable SQLite before the collector starts" {
  run aiops host-plan --output "$BATS_TEST_TMPDIR/install"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$AIOPS_STATE/incidents.sqlite")" = 660 ]
  [ "$(stat -c %a "$AIOPS_STATE")" = 700 ]
  jq -e '.collection.kubectl == "/usr/local/bin/kubectl"' "$BATS_TEST_TMPDIR/install/config.example.json"
  run aiops readiness --config "$BATS_TEST_TMPDIR/install/config.example.json"
  [ "$status" -eq 1 ]
  jq -e '.commissioning.ready == false and (.commissioning.pending | index("acceptance-isolation")) != null and (.commissioning.pending | index("acceptance-diagnosticCases")) == null' <<< "$output"
}
