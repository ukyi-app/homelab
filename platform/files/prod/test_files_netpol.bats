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
