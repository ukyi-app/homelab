#!/usr/bin/env bats
# PSA(Pod Security Admission) enforce 라벨 회귀 가드.
# 라벨이 없으면 네임스페이스는 privileged 기본값으로 동작(admission 방어선 0) — 그 회귀를 막는다.
# @test 이름은 영어(디렉토리 단위 실행 시 한글 인코딩 깨짐 — 검증된 버그).

@test "kustomize build renders all eight owned namespaces" {
  run bash -c 'kustomize build platform/namespaces/prod'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -c '^kind: Namespace')" -eq 8 ]
}

@test "every owned namespace carries a PSA enforce label (no unregulated namespace)" {
  run bash -c 'kustomize build platform/namespaces/prod'
  [ "$status" -eq 0 ]
  # 8개 ns × enforce 라벨 = 정확히 8건
  [ "$(echo "$output" | grep -c 'pod-security.kubernetes.io/enforce:')" -eq 8 ]
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
  [ "$(echo "$output" | grep -c 'pod-security.kubernetes.io/warn: restricted')" -eq 8 ]
}

@test "cnpg-system enforces at least baseline PSA (operator ns: admission floor)" {
  # CreateNamespace로 생성되어 라벨 부재였음 → platform-namespaces가 baseline 부여(라이브 pod baseline-clean 확인).
  v="$(kustomize build platform/namespaces/prod 2>/dev/null \
    | yq e 'select(.kind=="Namespace" and .metadata.name=="cnpg-system") | .metadata.labels["pod-security.kubernetes.io/enforce"]' -)"
  [ "$v" = "baseline" ]
}

@test "cert-manager enforces at least baseline PSA (operator ns: admission floor)" {
  v="$(kustomize build platform/namespaces/prod 2>/dev/null \
    | yq e 'select(.kind=="Namespace" and .metadata.name=="cert-manager") | .metadata.labels["pod-security.kubernetes.io/enforce"]' -)"
  [ "$v" = "baseline" ]
}
