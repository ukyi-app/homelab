#!/usr/bin/env bats

setup() {
  export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
  TMP="apps/_guardtest/prod"
  mkdir -p "$TMP"
}
teardown() { rm -rf apps/_guardtest; }

@test "guard BLOCKS a plaintext *.enc.yaml" {
  cp test/fixtures/sample-secret.yaml apps/_guardtest/prod/leak.enc.yaml
  run ./scripts/sops-guard.sh apps/_guardtest/prod/leak.enc.yaml
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'BLOCKED'
}

@test "guard ALLOWS a properly encrypted *.enc.yaml" {
  cp test/fixtures/sample-secret.yaml apps/_guardtest/prod/ok.enc.yaml
  sops --encrypt --in-place apps/_guardtest/prod/ok.enc.yaml
  run ./scripts/sops-guard.sh apps/_guardtest/prod/ok.enc.yaml
  [ "$status" -eq 0 ]
}

@test "guard ignores non-secret yaml" {
  echo "kind: ConfigMap" > apps/_guardtest/prod/plain.yaml
  run ./scripts/sops-guard.sh apps/_guardtest/prod/plain.yaml
  [ "$status" -eq 0 ]
}
