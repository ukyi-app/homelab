#!/usr/bin/env bats
# adguard edge egress 격리 회귀 가드(업스트림 DNS만). @test 이름은 영어
# (디렉토리 단위 실행 시 한글 인코딩 깨짐 — 검증된 버그).
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 전부 단일 파일이라 그것으로 닫힌다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③
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
  # ⚠️ 이 @test에는 형제 단언이 없다 — 구 `-ne 0`에서는 networkpolicy.yaml을 리네임하면 grep이 rc 2로
  #    죽고도 통과해, 이 파일에서 혼자 초록으로 남았다.
  run grep -Eq 'cidr:[[:space:]]*10\.42' "$P"; [ "$status" -eq 1 ]
}

@test "policy restricts egress only, never ingress (DNS serving deferral)" {
  # adguard는 DNS 서버라 ingress(:53)를 잘못 좁히면 LAN/tailscale DNS 전면 장애 → egress만 격리.
  run grep -q 'Egress' "$P"; [ "$status" -eq 0 ]
  run grep -q 'Ingress' "$P"; [ "$status" -eq 1 ]
}
