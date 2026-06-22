#!/usr/bin/env bats
# PSA restricted conftest 백스톱 — 스키마가 못 잡는 약화(capabilities.add·Unconfined seccomp 등)를
# 렌더 파드에서 잡는다(라이브 admission 패리티, 적대 리뷰 Pass1 #4·Pass3 #3). @test 영어(CJK 함정).
CHART="${BATS_TEST_DIRNAME}/.."
REGO="$CHART/tests/psa-restricted.rego"

@test "chart fixtures (service/worker/static) pass PSA restricted conftest" {
  for k in service worker static; do
    run bash -c "helm template t '$CHART' -f '$CHART/tests/fixtures/$k.yaml' | conftest test --policy '$REGO' -"
    echo "$output"
    [ "$status" -eq 0 ]
  done
}

@test "conftest denies capabilities.add beyond NET_BIND_SERVICE (schema-allowed weakening)" {
  run bash -c "helm template t '$CHART' -f '$CHART/tests/fixtures-bad/caps-add.yaml' | conftest test --policy '$REGO' -"
  echo "$output"
  [ "$status" -ne 0 ]
}

@test "conftest denies Unconfined seccomp (schema-allowed weakening)" {
  run bash -c "helm template t '$CHART' -f '$CHART/tests/fixtures-bad/seccomp-unconfined.yaml' | conftest test --policy '$REGO' -"
  echo "$output"
  [ "$status" -ne 0 ]
}
