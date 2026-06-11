#!/usr/bin/env bats

@test "gen:env produces keys from values.yaml env" {
  run node tools/gen-env-example.mjs api --stdout
  [ "$status" -eq 0 ]
  [[ "$output" == *"LOG_LEVEL="* ]]
  [[ "$output" == *"# secret 출처: api-secrets"* ]]
}

@test "gen:env --check passes on committed file" {
  run node tools/gen-env-example.mjs api --check
  [ "$status" -eq 0 ]
}

@test "gen:env --check FAILS on injected drift" {
  cp apps/api/.env.example /tmp/envbak
  printf 'DRIFT=1\n' >> apps/api/.env.example
  run node tools/gen-env-example.mjs api --check
  cp /tmp/envbak apps/api/.env.example
  [ "$status" -ne 0 ]
}
