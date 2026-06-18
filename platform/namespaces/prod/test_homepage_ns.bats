#!/usr/bin/env bats
# homepage 네임스페이스(PSA restricted) 가드. @test 이름은 영어(한글 인코딩 깨짐 — 검증된 버그).
setup() { N="${BATS_TEST_DIRNAME}/namespaces.yaml"; }

@test "homepage namespace is defined" {
  run bash -c "yq ea 'select(.kind==\"Namespace\" and .metadata.name==\"homepage\") | .metadata.name' '$N'"
  [ "$output" = "homepage" ]
}

@test "homepage namespace enforces restricted PSA" {
  run bash -c "yq ea 'select(.metadata.name==\"homepage\") | .metadata.labels.\"pod-security.kubernetes.io/enforce\"' '$N'"
  [ "$output" = "restricted" ]
}
