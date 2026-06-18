#!/usr/bin/env bats
# PSA(Pod Security Admission) enforce 라벨 회귀 가드.
# 라벨이 없으면 네임스페이스는 privileged 기본값으로 동작(admission 방어선 0) — 그 회귀를 막는다.
# @test 이름은 영어(디렉토리 단위 실행 시 한글 인코딩 깨짐 — 검증된 버그).

@test "kustomize build renders all six owned namespaces" {
  run bash -c 'kustomize build platform/namespaces/prod'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -c '^kind: Namespace')" -eq 6 ]
}

@test "every owned namespace carries a PSA enforce label (no unregulated namespace)" {
  run bash -c 'kustomize build platform/namespaces/prod'
  [ "$status" -eq 0 ]
  # 6개 ns × enforce 라벨 = 정확히 6건
  [ "$(echo "$output" | grep -c 'pod-security.kubernetes.io/enforce:')" -eq 6 ]
}

@test "prod enforces restricted (shared chart is restricted-compliant)" {
  v="$(kustomize build platform/namespaces/prod 2>/dev/null \
    | yq e 'select(.kind=="Namespace" and .metadata.name=="prod") | .metadata.labels["pod-security.kubernetes.io/enforce"]' -)"
  [ "$v" = "restricted" ]
}

@test "edge enforces only baseline (adguard setcap + allowPrivilegeEscalation can't meet restricted)" {
  v="$(kustomize build platform/namespaces/prod 2>/dev/null \
    | yq e 'select(.kind=="Namespace" and .metadata.name=="edge") | .metadata.labels["pod-security.kubernetes.io/enforce"]' -)"
  [ "$v" = "baseline" ]
}

@test "every owned namespace warns at restricted (progressive hardening signal)" {
  run bash -c 'kustomize build platform/namespaces/prod'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -c 'pod-security.kubernetes.io/warn: restricted')" -eq 6 ]
}
