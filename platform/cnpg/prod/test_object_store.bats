#!/usr/bin/env bats
f=platform/cnpg/prod/object-store.yaml

@test "endpoint is R2 and region is auto" {
  grep -q 'endpointURL: .*\.r2\.cloudflarestorage\.com' "$f"
  grep -qE 'name:\s+AWS_REGION' "$f"
}
@test "creds come from the cnpg-r2-creds secret, not inline" {
  grep -q 'name: cnpg-r2-creds' "$f"
  run grep -E 'AWS_SECRET_ACCESS_KEY:\s+\S' "$f"
  [ "$status" -ne 0 ]
}
@test "offsite retention is 14 days" {
  grep -q 'retentionPolicy: "14d"' "$f"
}
