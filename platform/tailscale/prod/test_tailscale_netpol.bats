#!/usr/bin/env bats
# tailscale ns egress 격리 회귀 가드(privileged proxy lateral 방지). @test 이름은 영어
# (디렉토리 단위 실행 시 한글 인코딩 깨짐 — 검증된 버그).
setup() { P="${BATS_TEST_DIRNAME}/networkpolicy.yaml"; }

@test "ns-wide default-deny-egress baseline exists" {
  run grep -q 'kind: NetworkPolicy' "$P"; [ "$status" -eq 0 ]
  run grep -q 'tailscale-default-deny-egress' "$P"; [ "$status" -eq 0 ]
  run grep -q 'podSelector: {}' "$P"; [ "$status" -eq 0 ]
}

@test "dns egress to coredns on 53 is declared" {
  run grep -q 'k8s-app: kube-dns' "$P"; [ "$status" -eq 0 ]
  run grep -q 'port: 53' "$P"; [ "$status" -eq 0 ]
}

@test "apiserver egress is scoped to node-subnet on 6443 (kube-router DNAT, F5)" {
  run grep -q '192.168.139.0/24' "$P"; [ "$status" -eq 0 ]
  run grep -q 'port: 6443' "$P"; [ "$status" -eq 0 ]
}

@test "proxy backend egress to gateway traefik on 8443 is declared" {
  run grep -q 'kubernetes.io/metadata.name: gateway' "$P"; [ "$status" -eq 0 ]
  run grep -q 'port: 8443' "$P"; [ "$status" -eq 0 ]
}

@test "tailnet egress (0.0.0.0/0) always excludes private/cluster ranges (lateral guard)" {
  run grep -q '0.0.0.0/0' "$P"; [ "$status" -eq 0 ]
  run grep -q '10.0.0.0/8' "$P"; [ "$status" -eq 0 ]
  run grep -q '172.16.0.0/12' "$P"; [ "$status" -eq 0 ]
  run grep -q '192.168.0.0/16' "$P"; [ "$status" -eq 0 ]
}

@test "pod CIDR is never an allowed ipBlock cidr (default-deny bypass trap)" {
  run grep -Eq 'cidr:[[:space:]]*10\.42' "$P"; [ "$status" -ne 0 ]
}
