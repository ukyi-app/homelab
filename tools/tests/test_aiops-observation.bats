#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers/aiops
setup() { aiops_setup; }

@test "observation requires criteria and records review cost without declaring success from time" {
  printf '{"mode":"replay","observation":{"days":14}}' > "$BATS_TEST_TMPDIR/config.json"
  run aiops observation-start --config "$BATS_TEST_TMPDIR/config.json"
  [ "$status" -eq 1 ]
  jq '.observation += {minimumCases:12,requiredSources:["alertmanager","argocd","cnpg","gha","healthchecks"],qualityCriteria:"human reference review",manualBaseline:"manual minutes per incident"}' "$BATS_TEST_TMPDIR/config.json" > "$BATS_TEST_TMPDIR/complete.json"
  run aiops observation-start --config "$BATS_TEST_TMPDIR/complete.json"
  [ "$status" -eq 0 ]
  seed_incident
  aiops replay --incident "$INCIDENT" >/dev/null
  jq -n --arg incident "$INCIDENT" '{incident:$incident,manualMinutes:15,reviewMinutes:3,falsePositive:false,deferred:true}' > "$BATS_TEST_TMPDIR/sample.json"
  run aiops observation-record --input "$BATS_TEST_TMPDIR/sample.json"
  [ "$status" -eq 0 ]
  run aiops observation-summary
  [ "$status" -eq 0 ]
  jq -e '.observation.samples == 1 and .observation.reviewMinutes == 3 and .observation.unknownUsage == 1 and .observation.verdict == "insufficient-evidence" and .observation.simulated == true' <<< "$output"
}
