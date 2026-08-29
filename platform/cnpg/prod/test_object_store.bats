#!/usr/bin/env bats
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 단일 파일이라 그것으로 닫힌다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a
f=platform/cnpg/prod/object-store.yaml

@test "endpoint is R2 and region is auto" {
  grep -q 'endpointURL: .*\.r2\.cloudflarestorage\.com' "$f"
  grep -qE 'name:\s+AWS_REGION' "$f"
}
@test "creds come from the cnpg-r2-creds secret, not inline" {
  grep -q 'name: cnpg-r2-creds' "$f"
  run grep -E 'AWS_SECRET_ACCESS_KEY:\s+\S' "$f"
  [ "$status" -eq 1 ]
}
@test "offsite retention is 14 days" {
  grep -q 'retentionPolicy: "14d"' "$f"
}
