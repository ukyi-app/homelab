#!/usr/bin/env bats

@test "root app recurses platform/argocd/root, uses project default, auto-syncs" {
  run grep -q 'path: platform/argocd/root' platform/argocd/root/root-app.yaml
  [ "$status" -eq 0 ]
  run grep -q 'recurse: true' platform/argocd/root/root-app.yaml
  [ "$status" -eq 0 ]
  run grep -q 'project: default' platform/argocd/root/root-app.yaml
  [ "$status" -eq 0 ]
  run grep -q 'selfHeal: true' platform/argocd/root/root-app.yaml
  [ "$status" -eq 0 ]
}

@test "argocd self-manage app uses the single bootstrap values file + project default" {
  run grep -q 'project: default' platform/argocd/argocd-app.yaml
  [ "$status" -eq 0 ]
  run grep -q 'platform/argocd/bootstrap-values.yaml' platform/argocd/argocd-app.yaml
  [ "$status" -eq 0 ]
}
