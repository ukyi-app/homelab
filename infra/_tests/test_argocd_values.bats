#!/usr/bin/env bats

@test "argocd bootstrap values disable HA and tune processors" {
  run grep -q 'redis-ha:' platform/argocd/bootstrap-values.yaml
  [ "$status" -eq 0 ]
  run grep -qE 'statusProcessors:\s*"?4"?' platform/argocd/bootstrap-values.yaml
  [ "$status" -eq 0 ]
  run grep -qE 'operationProcessors:\s*"?2"?' platform/argocd/bootstrap-values.yaml
  [ "$status" -eq 0 ]
}

@test "repo-server wires KSOPS: sops-age mount + SOPS_AGE_KEY_FILE + exec build options" {
  run grep -q 'sops-age' platform/argocd/bootstrap-values.yaml
  [ "$status" -eq 0 ]
  run grep -q '/home/argocd/.config/sops/age/keys.txt' platform/argocd/bootstrap-values.yaml
  [ "$status" -eq 0 ]
  run grep -q -- '--enable-alpha-plugins --enable-exec --enable-helm' platform/argocd/bootstrap-values.yaml
  [ "$status" -eq 0 ]
}

@test "argocd chart version is pinned (semver, not a range)" {
  run grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' platform/argocd/CHART_VERSION
  [ "$status" -eq 0 ]
}
