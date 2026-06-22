#!/usr/bin/env bats
# cloudflared edge egress 격리 회귀 가드(터널 종단점 lateral 방지). @test 이름은 영어
# (디렉토리 단위 실행 시 한글 인코딩 깨짐 — 검증된 버그).
setup() { P="${BATS_TEST_DIRNAME}/networkpolicy.yaml"; }

@test "default-deny-egress baseline exists (workload-scoped)" {
  run grep -q 'kind: NetworkPolicy' "$P"; [ "$status" -eq 0 ]
  run grep -q 'cloudflared-default-deny-egress' "$P"; [ "$status" -eq 0 ]
  run grep -q 'app: cloudflared' "$P"; [ "$status" -eq 0 ]
}

@test "dns egress to coredns on 53 is declared" {
  run grep -q 'k8s-app: kube-dns' "$P"; [ "$status" -eq 0 ]
  run grep -q 'port: 53' "$P"; [ "$status" -eq 0 ]
}

@test "tunnel egress to gateway traefik on 8000 is declared" {
  run grep -q 'kubernetes.io/metadata.name: gateway' "$P"; [ "$status" -eq 0 ]
  run grep -q 'port: 8000' "$P"; [ "$status" -eq 0 ]
}

@test "cloudflare edge egress on 7844 and 443 is declared" {
  run grep -q 'port: 7844' "$P"; [ "$status" -eq 0 ]
  run grep -q 'port: 443' "$P"; [ "$status" -eq 0 ]
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
