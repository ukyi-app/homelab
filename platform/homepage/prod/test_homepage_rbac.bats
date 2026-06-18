#!/usr/bin/env bats
# homepage RBAC(최소권한 read-only ClusterRole) 가드. @test 이름은 영어.
setup() { R="${BATS_TEST_DIRNAME}/rbac.yaml"; }

@test "serviceaccount, clusterrole and binding are defined" {
  run grep -q 'kind: ServiceAccount' "$R"; [ "$status" -eq 0 ]
  run grep -q 'kind: ClusterRole' "$R"; [ "$status" -eq 0 ]
  run grep -q 'kind: ClusterRoleBinding' "$R"; [ "$status" -eq 0 ]
}

@test "clusterrole can discover gateway httproutes" {
  run grep -q 'gateway.networking.k8s.io' "$R"; [ "$status" -eq 0 ]
  run grep -q 'httproutes' "$R"; [ "$status" -eq 0 ]
}

@test "clusterrole is read-only (no write verbs)" {
  run grep -qE '\bcreate\b|\bupdate\b|\bpatch\b|\bdelete\b' "$R"; [ "$status" -ne 0 ]
}

@test "clusterrole does not depend on metrics-server" {
  run grep -q 'metrics.k8s.io' "$R"; [ "$status" -ne 0 ]
}

@test "binding targets the homepage namespace serviceaccount" {
  run grep -q 'namespace: homepage' "$R"; [ "$status" -eq 0 ]
}
