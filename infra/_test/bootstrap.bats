#!/usr/bin/env bats
# LIVE test: requires a running cluster + helm + the M0 cluster age key.
# Run only during the live bootstrap acceptance (Task 2.12), not in offline CI.

@test "make bootstrap is idempotent (second run is a no-op)" {
  run make bootstrap
  [ "$status" -eq 0 ]
  run make bootstrap
  [ "$status" -eq 0 ]
  [[ "$output" == *"unchanged"* || "$output" == *"already"* ]]
}
