#!/usr/bin/env bats
# homepage NetworkPolicy(internal-by-default + F5 경계 가드). @test 이름은 영어.
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 networkpolicy.yaml 단일 파일이라 그것으로 닫힌다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a
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
  # ⚠️ 부재 단언 단독이라 형제 증인이 없다 — 예전 `-ne 0`에서는 networkpolicy.yaml을 리네임해도
  #    이 파일의 부재 단언 두 @test만 초록으로 남았다(2026-08-29 격리 트리 실측). default-deny
  #    우회 두 함정의 가드가 정작 정책 파일이 사라진 상태에서 통과했다는 뜻이다.
  run grep -q '10.42.0.0/16' "$P"; [ "$status" -eq 1 ]
}

@test "egress is never opened cluster-wide (F5 boundary guard)" {
  # ⚠️ 위 @test와 같다 — 부재 단언 단독이라 대상 부재에 홀로 초록이었다.
  run grep -q '0.0.0.0/0' "$P"; [ "$status" -eq 1 ]
}

@test "apiserver egress is scoped to node-subnet on 6443 (F5)" {
  # kube-router DNAT 후 dest는 노드 InternalIP:6443 — 노드 서브넷 ipBlock으로 허용(ClusterIP 아님).
  run grep -q '192.168.117.0/24' "$P"; [ "$status" -eq 0 ]
  run grep -q '6443' "$P"; [ "$status" -eq 0 ]
}

@test "egress to glances is scoped to glances pods on 61208" {
  run grep -q '61208' "$P"; [ "$status" -eq 0 ]
  run grep -q 'app.kubernetes.io/name: glances' "$P"; [ "$status" -eq 0 ]
  run grep -q 'kubernetes.io/metadata.name: observability' "$P"; [ "$status" -eq 0 ]
}
