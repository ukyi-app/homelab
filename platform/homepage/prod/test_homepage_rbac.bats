#!/usr/bin/env bats
# homepage RBAC(최소권한 read-only ClusterRole) 가드. @test 이름은 영어.
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 rbac.yaml 단일 파일이라 그것으로 닫힌다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a
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
  # ⚠️ 부재 단언 단독이라 형제 증인이 없다 — 예전 `-ne 0`에서는 rbac.yaml을 리네임해도 이 파일의
  #    부재 단언 두 @test만 초록으로 남았다(2026-08-29 격리 트리 실측). 클러스터 범위
  #    권한의 최소권한 단언이 정작 권한 파일이 사라진 상태에서 통과했다는 뜻이다.
  run grep -qE '\bcreate\b|\bupdate\b|\bpatch\b|\bdelete\b' "$R"; [ "$status" -eq 1 ]
}

@test "clusterrole does not depend on metrics-server" {
  # ⚠️ 위 @test와 같다 — 부재 단언 단독이라 형제 증인이 없고, 위 실측의 생존 2건 중 나머지가 이 @test다.
  run grep -q 'metrics.k8s.io' "$R"; [ "$status" -eq 1 ]
}

@test "binding targets the homepage namespace serviceaccount" {
  run grep -q 'namespace: homepage' "$R"; [ "$status" -eq 0 ]
}
