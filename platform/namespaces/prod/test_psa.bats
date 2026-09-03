#!/usr/bin/env bats
# PSA(Pod Security Admission) enforce 라벨 회귀 가드.
# 라벨이 없으면 네임스페이스는 privileged 기본값으로 동작(admission 방어선 0) — 그 회귀를 막는다.
# @test 이름은 영어(디렉토리 단위 실행 시 한글 인코딩 깨짐 — 검증된 버그).

@test "kustomize build renders all eleven owned namespaces" {
  run bash -c 'kustomize build platform/namespaces/prod'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -c '^kind: Namespace')" -eq 11 ]
}

@test "every owned namespace carries a PSA enforce label (denominator = argocd-owned ns only)" {
  # ⚠️ 괄호가 분모를 정직하게 적는다 — 이 판정은 `platform/namespaces/prod`가 소유하는 ns만 본다.
  #    substrate ns(`local-path-storage`)는 owner-local apply-storage.sh가 적용하므로 원리적으로 밖이고,
  #    "unregulated namespace가 없다"는 전칭을 이 파일이 약속하지 않는다.
  run bash -c 'kustomize build platform/namespaces/prod'
  [ "$status" -eq 0 ]
  # 11개 ns × enforce 라벨 = 정확히 11건
  [ "$(echo "$output" | grep -c 'pod-security.kubernetes.io/enforce:')" -eq 11 ]
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

@test "tailscale ns enforces privileged (operator proxy pods need privileged for TUN/sysctl)" {
  v="$(kustomize build platform/namespaces/prod 2>/dev/null \
    | yq e 'select(.kind=="Namespace" and .metadata.name=="tailscale") | .metadata.labels["pod-security.kubernetes.io/enforce"]' -)"
  [ "$v" = "privileged" ]
}

@test "every owned namespace warns at restricted (progressive hardening signal)" {
  run bash -c 'kustomize build platform/namespaces/prod'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -c 'pod-security.kubernetes.io/warn: restricted')" -eq 11 ]
}

@test "argocd enforces at least baseline PSA (bootstrap-created ns: admission floor)" {
  # scripts/bootstrap.sh:11-13이 라벨 없이 만드는 유일한 ns였다(라이브 PSA 3종 전무, 실측 2026-09-03).
  # ⚠️ 경계가 아니라 위생 — 이 ns의 application-controller SA가 cluster-admin이라 여기 파드를 만들 수 있는
  #    주체는 그 SA로 라벨 자체를 지울 수 있다. 실효는 git 유래 오배포에 대한 admission floor다.
  v="$(kustomize build platform/namespaces/prod 2>/dev/null \
    | yq e 'select(.kind=="Namespace" and .metadata.name=="argocd") | .metadata.labels["pod-security.kubernetes.io/enforce"]' -)"
  [ "$v" = "baseline" ]
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
