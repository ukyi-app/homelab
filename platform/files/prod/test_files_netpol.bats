#!/usr/bin/env bats
# files NetworkPolicy 자기격리 회귀 가드. @test 이름은 영어.
N="$BATS_TEST_DIRNAME/networkpolicy.yaml"

@test "default-deny-egress present for files pod" {
  run yq ea 'select(.metadata.name=="files-default-deny-egress") | .spec.policyTypes[0]' "$N"
  [ "$output" = "Egress" ]
  run yq ea 'select(.metadata.name=="files-default-deny-egress") | .spec.egress' "$N"
  [ "$output" = "null" ]
}

@test "DNS egress allowed to kube-dns only" {
  run yq ea 'select(.metadata.name=="files-allow-dns-egress") | .spec.egress[0].to[0].namespaceSelector.matchLabels."kubernetes.io/metadata.name"' "$N"
  [ "$output" = "kube-system" ]
}

@test "NO DB/cache egress (security payoff of dedicated ns)" {
  run grep -c "5432\|6379" "$N"
  [ "$output" = "0" ]
}

@test "ingress from gateway on BOTH 8080 and 8081" {
  run yq ea 'select(.metadata.name=="files-allow-ingress-from-gateway") | [.spec.ingress[0].ports[].port] | sort | join(",")' "$N"
  [ "$output" = "8080,8081" ]
}

@test "no pod-CIDR ipBlock (deny-nullifying trap)" {
  run grep -c "10.42\." "$N"
  [ "$output" = "0" ]
}

@test "NetworkPolicy roster is exact and no rule carries an ipBlock (upper bound)" {
  # ⚠️ 상한 — 위 @test들은 전부 하한(존재·카운트 0)뿐이라 podSelector:{}+ipBlock 0.0.0.0/0인
  #    광역 정책 추가나 기존 정책에 ipBlock 피어 추가 둘 다 무증인이었다(뮤테이션 실측: 33/33 ok).
  #    선례: platform/network-policies/prod/test_netpol.bats:33-37(397b001).
  run yq ea '[select(.kind=="NetworkPolicy") | .metadata.name] | sort | join(",")' "$N"
  [ "$output" = "files-allow-dns-egress,files-allow-ingress-from-gateway,files-default-deny-egress" ]
  run yq ea '[select(.kind=="NetworkPolicy") | .. | select(has("ipBlock")) | .ipBlock.cidr] | length' "$N"
  [ "$output" = "0" ]
}
