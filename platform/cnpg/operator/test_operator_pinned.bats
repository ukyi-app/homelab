#!/usr/bin/env bats

f=platform/argocd/root/apps/cnpg-operator.yaml

@test "operator chart version is pinned (no caret/tilde/wildcard)" {
  # exact git-tag pin cnpg-v0.26.0 (a trailing comment may follow on the line)
  run grep -E 'targetRevision:\s+cnpg-v0\.26\.0' "$f"
  [ "$status" -eq 0 ]
  run grep -E 'targetRevision:\s+[~^*]' "$f"
  [ "$status" -ne 0 ]
}

@test "operator targets cnpg-system namespace" {
  run grep -E 'namespace:\s+cnpg-system' "$f"
  [ "$status" -eq 0 ]
}

@test "operator uses the default AppProject" {
  run grep -E 'project:\s+default' "$f"
  [ "$status" -eq 0 ]
}

@test "operator app is sync-wave -2 (before Cluster CR)" {
  run grep -E 'argocd.argoproj.io/sync-wave:\s*"-2"' "$f"
  [ "$status" -eq 0 ]
}
