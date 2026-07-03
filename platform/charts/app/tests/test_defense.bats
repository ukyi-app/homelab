#!/usr/bin/env bats
CHART="${BATS_TEST_DIRNAME}/.."
dep() { helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 \
  --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
  --set resources.limits.cpu=100m --set resources.limits.memory=64Mi "$@" | yq 'select(.kind=="Deployment")'; }

@test "pods do not automount the ServiceAccount token by default (apps need no k8s API)" {
  out=$(dep --set kind=worker)
  echo "$out" | grep -q 'automountServiceAccountToken: false'
}

@test "automountServiceAccountToken can be opted in for API-using apps" {
  out=$(dep --set kind=worker --set automountServiceAccountToken=true)
  echo "$out" | grep -q 'automountServiceAccountToken: true'
}

@test "Deployment strategy defaults to Recreate (single-node RWO deadlock safety)" {
  out=$(dep --set kind=web --set route.public=true --set route.host=a.example.com)
  echo "$out" | grep -q 'type: Recreate'
}

@test "strategy can be overridden to RollingUpdate for multi-replica stateless apps" {
  out=$(dep --set kind=web --set route.public=true --set route.host=a.example.com --set strategy.type=RollingUpdate)
  echo "$out" | grep -q 'type: RollingUpdate'
}
