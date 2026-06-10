#!/usr/bin/env bats
DF="apps/pg-tools/Dockerfile"

@test "pg-tools Dockerfile installs kubectl, psql(16), rclone, curl" {
  run grep -iE 'kubectl' "$DF"; [ "$status" -eq 0 ]
  run grep -iE 'postgresql-client-16|psql' "$DF"; [ "$status" -eq 0 ]
  run grep -iE 'rclone' "$DF"; [ "$status" -eq 0 ]
  run grep -iE 'curl' "$DF"; [ "$status" -eq 0 ]
}

@test "pg-tools is in the CI build matrix (canonical 16-rclone tag)" {
  run yq '.jobs.build.strategy.matrix.app' .github/workflows/build.yaml
  [[ "$output" == *"pg-tools"* ]]
}
