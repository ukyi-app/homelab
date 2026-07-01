#!/usr/bin/env bats
# files 네임스페이스 PSA/Prune 회귀 가드(test_homepage_ns.bats 미러).
# @test 이름은 영어(디렉토리 단위 실행 시 한글 인코딩 깨짐 — 검증된 버그).
setup() { N="${BATS_TEST_DIRNAME}/namespaces.yaml"; }

@test "files namespace enforces restricted PSA" {
  run yq ea 'select(.kind=="Namespace" and .metadata.name=="files") | .metadata.labels."pod-security.kubernetes.io/enforce"' "$N"
  [ "$output" = "restricted" ]
}

@test "files namespace has Prune=false" {
  run yq ea 'select(.kind=="Namespace" and .metadata.name=="files") | .metadata.annotations."argocd.argoproj.io/sync-options"' "$N"
  [ "$output" = "Prune=false" ]
}
