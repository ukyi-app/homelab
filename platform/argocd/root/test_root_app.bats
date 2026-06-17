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

@test "every root/apps yaml is valid and is an Application" {
  for f in platform/argocd/root/apps/*.yaml; do
    run yq e 'true' "$f"; [ "$status" -eq 0 ]
    run yq '.kind' "$f"; [ "$output" = "Application" ]
  done
}

@test "argocd-extras Application targets the right path/namespace with SSA + CreateNamespace=false" {
  A="platform/argocd/root/apps/argocd-extras.yaml"
  run yq '.spec.source.path' "$A"; [ "$output" = "platform/argocd/extras" ]
  run yq '.spec.destination.namespace' "$A"; [ "$output" = "argocd" ]
  run grep -q 'ServerSideApply=true' "$A"; [ "$status" -eq 0 ]
  run grep -q 'CreateNamespace=false' "$A"; [ "$status" -eq 0 ]
}
