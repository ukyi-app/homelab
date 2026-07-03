#!/usr/bin/env bats
# 스키마 fail-closed 회귀 (additionalProperties:false + 전수등재 + extraManifests 제거)
CHART="${BATS_TEST_DIRNAME}/.."
C="--set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 \
   --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
   --set resources.limits.cpu=100m --set resources.limits.memory=64Mi \
   --set route.public=true --set route.host=x.example.com"

@test "schema rejects an unknown top-level key (typo'd security/probe keys cannot pass silently)" {
  run helm template t "$CHART" $C --set kind=web --set securtyContext.foo=bar
  [ "$status" -ne 0 ]
}

@test "schema rejects extraManifests (removed; extra manifests go via kustomize source#3)" {
  run helm template t "$CHART" $C --set kind=web --set 'extraManifests[0].kind=Pod'
  [ "$status" -ne 0 ]
}

@test "schema rejects mutable image tags (immutable sha pin only)" {
  run helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=latest \
    --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
    --set resources.limits.cpu=100m --set resources.limits.memory=64Mi \
    --set route.public=true --set route.host=x.example.com --set kind=web
  [ "$status" -ne 0 ]
}

@test "schema rejects securityContext.privileged=true" {
  run helm template t "$CHART" $C --set kind=web --set securityContext.privileged=true
  [ "$status" -ne 0 ]
}

@test "schema rejects securityContext.allowPrivilegeEscalation=true" {
  run helm template t "$CHART" $C --set kind=web --set securityContext.allowPrivilegeEscalation=true
  [ "$status" -ne 0 ]
}

@test "schema rejects podSecurityContext.runAsNonRoot=false" {
  run helm template t "$CHART" $C --set kind=web --set podSecurityContext.runAsNonRoot=false
  [ "$status" -ne 0 ]
}

@test "schema rejects runAsUser=0 (root) in pod or container security context" {
  run helm template t "$CHART" $C --set kind=web --set podSecurityContext.runAsUser=0
  [ "$status" -ne 0 ]
  run helm template t "$CHART" $C --set kind=web --set securityContext.runAsUser=0
  [ "$status" -ne 0 ]
}

@test "all three fixtures still render under the tightened schema (behavior-preserving)" {
  for k in web worker site; do
    run helm template t "$CHART" -f "$CHART/tests/fixtures/$k.yaml"
    [ "$status" -eq 0 ]
  done
}

@test "deployment template no longer emits an extraManifests range block" {
  run grep -q "extraManifests" "$CHART/templates/deployment.yaml"
  [ "$status" -ne 0 ]
}
