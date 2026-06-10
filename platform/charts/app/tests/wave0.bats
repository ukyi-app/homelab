#!/usr/bin/env bats
CHART="${BATS_TEST_DIRNAME}/.."
ARGS="--set image.repo=ghcr.io/o/api --set image.tag=sha-abc1234 \
  --set resources.requests.cpu=50m --set resources.requests.memory=64Mi \
  --set resources.limits.cpu=500m --set resources.limits.memory=128Mi"

@test "ConfigMap is rendered at sync-wave 0" {
  run bash -c "helm template t \"$CHART\" $ARGS --set kind=api --set route.host=api.example.com \
    --set 'env[0].name=LOG_LEVEL' --set 'env[0].value=info' \
    | yq 'select(.kind==\"ConfigMap\")'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"argocd.argoproj.io/sync-wave: \"0\""* ]]
  [[ "$output" == *"LOG_LEVEL"* ]]
}
