#!/usr/bin/env bats
CHART="${BATS_TEST_DIRNAME}/.."
BASE="--set image.repo=ghcr.io/o/api --set image.tag=sha-abc1234 --set kind=api \
  --set route.host=api.example.com \
  --set resources.requests.cpu=50m --set resources.requests.memory=64Mi \
  --set resources.limits.cpu=500m --set resources.limits.memory=128Mi"

@test "migration Job renders at sync-wave 1 as an ArgoCD Sync hook when db.enabled" {
  run bash -c "helm template t \"$CHART\" $BASE --set db.enabled=true \
    | yq 'select(.kind==\"Job\")'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"argocd.argoproj.io/sync-wave: \"1\""* ]]
  # ArgoCD Sync hook (runs in the Sync phase, AFTER wave-0 config) — Pass-5 Open Item #2
  [[ "$output" == *"argocd.argoproj.io/hook: Sync"* ]]
  [[ "$output" == *"argocd.argoproj.io/hook-delete-policy: BeforeHookCreation"* ]]
  # Must NOT be a Helm hook: that would run in ArgoCD's PreSync phase, before wave-0 config/secrets.
  [[ "$output" != *"helm.sh/hook"* ]]
  [[ "$output" == *"- migrate"* ]] # toYaml renders the migrateCmd list item unquoted
  # cross-Application DB readiness is enforced IN-POD (not just by sync-waves)
  [[ "$output" == *"name: wait-for-db"* ]]
  [[ "$output" == *"pg_isready"* ]]
}

@test "no migration Job when db.enabled=false" {
  run bash -c "helm template t \"$CHART\" $BASE --set db.enabled=false \
    | yq 'select(.kind==\"Job\")'"
  [ -z "$output" ]
}
