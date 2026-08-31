#!/usr/bin/env bats
# tailscale ns egress 격리 회귀 가드(privileged proxy lateral 방지). @test 이름은 영어
# (디렉토리 단위 실행 시 한글 인코딩 깨짐 — 검증된 버그).
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 전부 단일 파일이라 그것으로 닫힌다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③
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
  run grep -q '192.168.117.0/24' "$P"; [ "$status" -eq 0 ]
  run grep -q 'port: 6443' "$P"; [ "$status" -eq 0 ]
}

@test "proxy backend egress to gateway traefik on 8443 is declared" {
  run grep -q 'kubernetes.io/metadata.name: gateway' "$P"; [ "$status" -eq 0 ]
  run grep -q 'port: 8443' "$P"; [ "$status" -eq 0 ]
}

@test "proxy backend egress to database pg-rw on 5432 is declared (pg tailscale exposure)" {
  run grep -q 'tailscale-allow-egress-to-database' "$P"; [ "$status" -eq 0 ]
  run grep -q 'kubernetes.io/metadata.name: database' "$P"; [ "$status" -eq 0 ]
  run grep -q 'port: 5432' "$P"; [ "$status" -eq 0 ]
}

@test "tailnet egress (0.0.0.0/0) always excludes private/cluster ranges (lateral guard)" {
  run grep -q '0.0.0.0/0' "$P"; [ "$status" -eq 0 ]
  run grep -q '10.0.0.0/8' "$P"; [ "$status" -eq 0 ]
  run grep -q '172.16.0.0/12' "$P"; [ "$status" -eq 0 ]
  run grep -q '192.168.0.0/16' "$P"; [ "$status" -eq 0 ]
}

@test "pod CIDR is never an allowed ipBlock cidr (default-deny bypass trap)" {
  # ⚠️ 이 @test에는 형제 단언이 없다 — 구 `-ne 0`에서는 networkpolicy.yaml을 리네임하면 grep이
  #    rc 2로 죽고도 통과해, 이 파일에서 혼자 초록으로 남았다.
  run grep -Eq 'cidr:[[:space:]]*10\.42' "$P"; [ "$status" -eq 1 ]
}
