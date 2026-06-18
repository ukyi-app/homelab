#!/usr/bin/env bats
# homepage NetworkPolicy(internal-by-default + F5 경계 가드). @test 이름은 영어.
setup() { P="${BATS_TEST_DIRNAME}/networkpolicy.yaml"; }

@test "default-deny-all baseline exists" {
  run grep -q 'kind: NetworkPolicy' "$P"; [ "$status" -eq 0 ]
  run grep -q 'default-deny-all' "$P"; [ "$status" -eq 0 ]
}

@test "egress to vmsingle and dns is declared" {
  run grep -q 'observability' "$P"; [ "$status" -eq 0 ]
  run grep -q '8428' "$P"; [ "$status" -eq 0 ]
  run grep -q 'kube-dns' "$P"; [ "$status" -eq 0 ]
}

@test "ingress from gateway is declared" {
  run grep -q 'gateway' "$P"; [ "$status" -eq 0 ]
  run grep -q '3000' "$P"; [ "$status" -eq 0 ]
}

@test "pod CIDR is never used in ipBlock (default-deny bypass trap)" {
  run grep -q '10.42.0.0/16' "$P"; [ "$status" -ne 0 ]
}

@test "egress is never opened cluster-wide (F5 boundary guard)" {
  run grep -q '0.0.0.0/0' "$P"; [ "$status" -ne 0 ]
}

@test "apiserver egress is scoped by ipBlock, not port-only (F5)" {
  # apiserver 도달은 scoped ipBlock(/32)으로만 — to 없는 포트온리 허용 금지
  run grep -qE '10\.43\.0\.1/32|/32' "$P"; [ "$status" -eq 0 ]
}
