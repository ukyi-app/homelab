#!/usr/bin/env bats

f=platform/argocd/root/apps/cnpg-operator.yaml

@test "operator chart version is pinned (no caret/tilde/wildcard)" {
  # chart: 소스라 targetRevision은 차트 semver(0.28.3) — git URL+태그(cnpg-v0.26.0)는 ArgoCD가
  # "improper constraint"로 거부한다(cnpg-operator.yaml 주석 참고). 0.28.3 ↔ git tag cnpg-v0.28.3.
  run grep -E 'targetRevision:\s+0\.28\.3' "$f"
  [ "$status" -eq 0 ]
  run grep -E 'targetRevision:\s+[~^*]' "$f"
  [ "$status" -ne 0 ]
}

@test "operator targets cnpg-system namespace" {
  run grep -E 'namespace:\s+cnpg-system' "$f"
  [ "$status" -eq 0 ]
}

# 테마1 권한경계 재배정(default→platform). @test 이름은 영어만(한글이면 디렉토리 실행 시 침묵 스킵).
@test "operator uses the platform AppProject" {
  run grep -E 'project:\s+platform' "$f"
  [ "$status" -eq 0 ]
}

@test "operator app is sync-wave -2 (before Cluster CR)" {
  run grep -E 'argocd.argoproj.io/sync-wave:\s*"-2"' "$f"
  [ "$status" -eq 0 ]
}
