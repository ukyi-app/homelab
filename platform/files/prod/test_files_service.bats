#!/usr/bin/env bats
# files Service 2종 회귀 가드. @test 이름은 영어.
S="$BATS_TEST_DIRNAME/service.yaml"

@test "files-internal Service exposes 8080 to internal port" {
  run yq ea 'select(.metadata.name=="files-internal") | .spec.ports[0].port' "$S"
  [ "$output" = "8080" ]
  run yq ea 'select(.metadata.name=="files-internal") | .spec.ports[0].targetPort' "$S"
  [ "$output" = "internal" ]
}

@test "files-public Service exposes 8081 to public port" {
  run yq ea 'select(.metadata.name=="files-public") | .spec.ports[0].port' "$S"
  [ "$output" = "8081" ]
  run yq ea 'select(.metadata.name=="files-public") | .spec.ports[0].targetPort' "$S"
  [ "$output" = "public" ]
}
