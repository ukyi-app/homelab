#!/usr/bin/env bats

setup() {
  export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
  WORK="apps/_rttest/prod"
  mkdir -p "$WORK"
  cp test/fixtures/sample-secret.yaml "$WORK/secret.enc.yaml"
}

teardown() {
  rm -rf apps/_rttest
}

@test "sops encrypts a prod-path secret to two recipients" {
  run sops --encrypt --in-place "apps/_rttest/prod/secret.enc.yaml"
  [ "$status" -eq 0 ]
  run grep -c 'recipient:' "apps/_rttest/prod/secret.enc.yaml"
  [ "$output" -eq 2 ]
  run grep -q 'super-secret-value-123' "apps/_rttest/prod/secret.enc.yaml"
  [ "$status" -ne 0 ]   # plaintext must NOT survive
}

@test "sops decrypt round-trips to the original plaintext" {
  sops --encrypt --in-place "apps/_rttest/prod/secret.enc.yaml"
  run sops --decrypt "apps/_rttest/prod/secret.enc.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'TOKEN: super-secret-value-123'
  echo "$output" | grep -q 'URL: postgres://user:pw@db:5432/app'
}
