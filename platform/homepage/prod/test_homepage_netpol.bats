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

@test "apiserver egress is scoped to node-subnet on 6443 (F5)" {
  # kube-router DNAT 후 dest는 노드 InternalIP:6443 — 노드 서브넷 ipBlock으로 허용(ClusterIP 아님).
  run grep -q '192.168.139.0/24' "$P"; [ "$status" -eq 0 ]
  run grep -q '6443' "$P"; [ "$status" -eq 0 ]
}

@test "egress to glances is scoped to glances pods on 61208" {
  run grep -q '61208' "$P"; [ "$status" -eq 0 ]
  run grep -q 'app.kubernetes.io/name: glances' "$P"; [ "$status" -eq 0 ]
  run grep -q 'kubernetes.io/metadata.name: observability' "$P"; [ "$status" -eq 0 ]
}
