#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load helpers/aiops
setup() { aiops_setup; }

@test "retention removes expired incidents and keeps current admission accounting" {
  seed_incident
  run aiops replay --incident "$INCIDENT" --at 2026-09-12T01:00:00Z
  [ "$status" -eq 0 ]
  run aiops prune --at 2026-11-20T00:00:00Z
  [ "$status" -eq 0 ]
  jq -e '.retention.incidentsRemoved == 1 and .retention.evidenceDays == 7 and .retention.incidentDays == 30' <<< "$output"
  run aiops list
  jq -e '.incidents == [] and .budget.active == null' <<< "$output"
}
