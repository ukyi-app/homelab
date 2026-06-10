#!/usr/bin/env bats
# DEPENDS ON M2: platform/cnpg/prod/r2-creds.enc.yaml is produced by M2's
# seed-secrets.sh (live, needs real R2 creds). These tests pass only after M2 runs.

f=platform/cnpg/prod/r2-creds.enc.yaml # OWNED BY M2 — referenced here

@test "M2 seed for cnpg-r2-creds exists" {
  [ -f "$f" ]
}
@test "seed is SOPS-encrypted (has sops metadata)" {
  run grep -q '^sops:' "$f"
  [ "$status" -eq 0 ]
}
@test "seed has NO plaintext AWS secret" {
  run grep -E 'AWS_SECRET_ACCESS_KEY:\s+[A-Za-z0-9/+]{20,}' "$f"
  [ "$status" -ne 0 ]
}
@test "seed Secret is named cnpg-r2-creds (canonical)" {
  run bash -c "sops --decrypt '$f' | grep -qE 'name:\s+cnpg-r2-creds'"
  [ "$status" -eq 0 ]
}
@test "seed encrypts to two recipients (cluster + offline recovery)" {
  run bash -c "grep -c 'recipient:' '$f'"
  [ "$output" -ge 2 ]
}
@test "M4 does NOT author a duplicate R2 creds secret" {
  run bash -c "ls platform/cnpg/prod/object-store-creds.enc.yaml 2>/dev/null"
  [ "$status" -ne 0 ] # the old M4-owned name must not exist
}
