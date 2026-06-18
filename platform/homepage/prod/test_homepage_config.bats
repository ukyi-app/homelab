#!/usr/bin/env bats
# homepage ConfigMap 가드. @test 이름은 영어(한글 인코딩 깨짐 — 검증된 버그).
setup() { C="${BATS_TEST_DIRNAME}/configmap.yaml"; }

@test "kubernetes integration runs in cluster mode with gateway discovery" {
  run grep -q 'mode: cluster' "$C"; [ "$status" -eq 0 ]
  run grep -q 'gateway: true' "$C"; [ "$status" -eq 0 ]
}

@test "infra widgets query victoriametrics, not metrics-server" {
  run grep -q 'type: prometheusmetric' "$C"; [ "$status" -eq 0 ]
  run grep -q 'vmsingle.observability.svc.cluster.local:8428' "$C"; [ "$status" -eq 0 ]
}

@test "settings declare the dashboard title" {
  run grep -q 'settings.yaml' "$C"; [ "$status" -eq 0 ]
}
