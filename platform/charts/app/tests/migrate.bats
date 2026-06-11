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
  # ArgoCD Sync hook (Sync 단계에서 실행, wave-0 설정 이후)
  [[ "$output" == *"argocd.argoproj.io/hook: Sync"* ]]
  [[ "$output" == *"argocd.argoproj.io/hook-delete-policy: BeforeHookCreation"* ]]
  # Helm hook이면 안 됨: 그 경우 ArgoCD의 PreSync 단계 — wave-0 설정/secret 이전 — 에 실행된다.
  [[ "$output" != *"helm.sh/hook"* ]]
  [[ "$output" == *"- migrate"* ]] # toYaml은 migrateCmd 리스트 항목을 따옴표 없이 렌더한다
  # Application 간 DB 준비 상태는 (sync-wave만이 아니라) Pod 안에서 강제된다
  [[ "$output" == *"name: wait-for-db"* ]]
  [[ "$output" == *"pg_isready"* ]]
}

@test "no migration Job when db.enabled=false" {
  run bash -c "helm template t \"$CHART\" $BASE --set db.enabled=false \
    | yq 'select(.kind==\"Job\")'"
  [ -z "$output" ]
}
