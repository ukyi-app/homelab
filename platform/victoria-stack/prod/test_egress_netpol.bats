#!/usr/bin/env bats
# observability 외부 egress 격리 회귀 가드(alertmanager·relay, NETPOL-4 minimal). @test 이름은 영어
# (디렉토리 단위 실행 시 한글 인코딩 깨짐 — 검증된 버그).
setup() { P="${BATS_TEST_DIRNAME}/networkpolicy.yaml"; }

@test "alertmanager and relay default-deny-egress baselines exist" {
  run grep -q 'alertmanager-default-deny-egress' "$P"; [ "$status" -eq 0 ]
  run grep -q 'deadmanswitch-relay-default-deny-egress' "$P"; [ "$status" -eq 0 ]
}

@test "workloads selected by app.kubernetes.io/name (live label parity)" {
  run grep -q 'app.kubernetes.io/name: alertmanager' "$P"; [ "$status" -eq 0 ]
  run grep -q 'app.kubernetes.io/name: deadmanswitch-relay' "$P"; [ "$status" -eq 0 ]
}

@test "alertmanager reaches the relay deadman webhook on 9095 (internal hop not dropped)" {
  run grep -q 'port: 9095' "$P"; [ "$status" -eq 0 ]
}

@test "external egress (0.0.0.0/0) always excludes private/cluster ranges (lateral guard)" {
  run grep -q '0.0.0.0/0' "$P"; [ "$status" -eq 0 ]
  run grep -q '10.0.0.0/8' "$P"; [ "$status" -eq 0 ]
  run grep -q '172.16.0.0/12' "$P"; [ "$status" -eq 0 ]
  run grep -q '192.168.0.0/16' "$P"; [ "$status" -eq 0 ]
}

@test "metrics east-west plane is intentionally untouched (no ns-wide default-deny)" {
  # vmagent가 전 ns를 scrape(role:pod SD)라 ns-wide deny는 near-allow-all → 외부 egress만 워크로드별 격리.
  run grep -q 'podSelector: {}' "$P"; [ "$status" -ne 0 ]
}

@test "pod CIDR is never an allowed ipBlock cidr (default-deny bypass trap)" {
  run grep -Eq 'cidr:[[:space:]]*10\.42' "$P"; [ "$status" -ne 0 ]
}
