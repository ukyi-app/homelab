#!/usr/bin/env bats
# homepage config(configMapGenerator 소스 파일) 가드. @test 이름은 영어(한글 인코딩 깨짐).
setup() { C="${BATS_TEST_DIRNAME}/config"; }

@test "kubernetes integration runs in cluster mode with gateway discovery" {
  run grep -q 'mode: cluster' "$C/kubernetes.yaml"; [ "$status" -eq 0 ]
  run grep -q 'gateway: true' "$C/kubernetes.yaml"; [ "$status" -eq 0 ]
}

@test "infra widgets query victoriametrics, not metrics-server" {
  run grep -q 'type: prometheusmetric' "$C/services.yaml"; [ "$status" -eq 0 ]
  run grep -q 'vmsingle.observability.svc.cluster.local:8428' "$C/services.yaml"; [ "$status" -eq 0 ]
}

@test "settings declare the dashboard title as ukyi" {
  run grep -qE '^title:[[:space:]]*ukyi$' "$C/settings.yaml"; [ "$status" -eq 0 ]
}

@test "settings apply header/target/search/background tweaks" {
  run grep -qE '^headerStyle:[[:space:]]*boxedWidgets' "$C/settings.yaml"; [ "$status" -eq 0 ]
  run grep -qE '^target:[[:space:]]*_blank' "$C/settings.yaml"; [ "$status" -eq 0 ]
  run grep -q 'searchDescriptions: true' "$C/settings.yaml"; [ "$status" -eq 0 ]
  run grep -q '/images/background.jpg' "$C/settings.yaml"; [ "$status" -eq 0 ]
  run grep -q 'hideVersion: true' "$C/settings.yaml"; [ "$status" -eq 0 ]
  run grep -q 'statusStyle: dot' "$C/settings.yaml"; [ "$status" -eq 0 ]
}
