#!/usr/bin/env bats
# db/redis conn 핸들 소비 — create-app이 넣는 envFrom secretRef가 렌더되는지.
# ⚠️ 중간 단언은 [ ]만 사용 — bats가 bash 3.2로 돌 때 [[ ]] 실패는 침묵 통과된다.

CHART="$BATS_TEST_DIRNAME/.."

@test "db conn handle wires a secretRef into deployment envFrom" {
  out=$(helm template t "$CHART" --set kind=service --set route.host=t.home.example.com \
    --set image.repo=ghcr.io/x/y --set image.tag=sha-abc1234 --set resources.requests.cpu=50m --set resources.requests.memory=64Mi --set resources.limits.cpu=200m --set resources.limits.memory=128Mi \
    --set-json 'envFrom=[{"secretRef":{"name":"db-orders-conn"}}]')
  echo "$out" | grep -q "db-orders-conn"
}

@test "cache conn handle and app secrets render together in envFrom" {
  out=$(helm template t "$CHART" --set kind=service --set route.host=t.home.example.com \
    --set image.repo=ghcr.io/x/y --set image.tag=sha-abc1234 --set resources.requests.cpu=50m --set resources.requests.memory=64Mi --set resources.limits.cpu=200m --set resources.limits.memory=128Mi \
    --set-json 'envFrom=[{"secretRef":{"name":"cache-sessions-conn"}},{"secretRef":{"name":"orders-secrets"}}]')
  echo "$out" | grep -q "cache-sessions-conn"
  echo "$out" | grep -q "orders-secrets"
}
