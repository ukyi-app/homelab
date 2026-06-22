#!/usr/bin/env bats
# adguard edge egress 격리 회귀 가드(업스트림 DNS만). @test 이름은 영어
# (디렉토리 단위 실행 시 한글 인코딩 깨짐 — 검증된 버그).
setup() { P="${BATS_TEST_DIRNAME}/networkpolicy.yaml"; }

@test "default-deny-egress baseline exists (workload-scoped)" {
  run grep -q 'kind: NetworkPolicy' "$P"; [ "$status" -eq 0 ]
  run grep -q 'adguard-default-deny-egress' "$P"; [ "$status" -eq 0 ]
  run grep -q 'app: adguard' "$P"; [ "$status" -eq 0 ]
}

@test "upstream DNS egress on 443 (DoH) and 53 (bootstrap) is declared" {
  run grep -q 'port: 443' "$P"; [ "$status" -eq 0 ]
  run grep -q 'port: 53' "$P"; [ "$status" -eq 0 ]
}

@test "internet egress (0.0.0.0/0) always excludes private/cluster ranges (lateral guard)" {
  run grep -q '0.0.0.0/0' "$P"; [ "$status" -eq 0 ]
  run grep -q '10.0.0.0/8' "$P"; [ "$status" -eq 0 ]
  run grep -q '172.16.0.0/12' "$P"; [ "$status" -eq 0 ]
  run grep -q '192.168.0.0/16' "$P"; [ "$status" -eq 0 ]
}

@test "pod CIDR is never an allowed ipBlock cidr (default-deny bypass trap)" {
  run grep -Eq 'cidr:[[:space:]]*10\.42' "$P"; [ "$status" -ne 0 ]
}

@test "policy restricts egress only, never ingress (DNS serving deferral)" {
  # adguard는 DNS 서버라 ingress(:53)를 잘못 좁히면 LAN/tailscale DNS 전면 장애 → egress만 격리.
  run grep -q 'Egress' "$P"; [ "$status" -eq 0 ]
  run grep -q 'Ingress' "$P"; [ "$status" -ne 0 ]
}
