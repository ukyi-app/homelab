#!/usr/bin/env bats
f=platform/cnpg/prod/restore-drill-alerting.enc.yaml
@test "drill alerting secret is SOPS-encrypted" {
  grep -q '^sops:' "$f"
}
@test "no plaintext bot token leaks" {
  run grep -E 'TELEGRAM_BOT_TOKEN:\s+[0-9]{6,}:' "$f"
  [ "$status" -ne 0 ]
}
@test "decrypts to canonical key names and Secret name" {
  run bash -c "sops --decrypt '$f' | grep -qE 'name:\s+restore-drill-alerting'"
  [ "$status" -eq 0 ]
  run bash -c "sops --decrypt '$f' | grep -q TELEGRAM_BOT_TOKEN"
  [ "$status" -eq 0 ]
  run bash -c "sops --decrypt '$f' | grep -q HEALTHCHECKS_URL"
  [ "$status" -eq 0 ]
}
@test "encrypted to two recipients (cluster + offline recovery)" {
  run bash -c "grep -c 'recipient:' '$f'"
  [ "$output" -ge 2 ]
}
