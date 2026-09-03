#!/usr/bin/env bats
# db/redis conn 핸들 소비 — create-app이 넣는 envFrom secretRef가 렌더되는지.
# ⚠️ 중간 단언은 [ ]만 사용 — bats가 bash 3.2로 돌 때 [[ ]] 실패는 침묵 통과된다.

CHART="$BATS_TEST_DIRNAME/.."

@test "db conn handle wires a secretRef into deployment envFrom" {
  out=$(helm template t "$CHART" --set kind=web --set route.host=t.home.example.com \
    --set image.repo=ghcr.io/x/y --set image.tag=sha-abc1234 --set resources.requests.cpu=50m --set resources.requests.memory=64Mi --set resources.limits.cpu=200m --set resources.limits.memory=128Mi \
    --set-json 'envFrom=[{"secretRef":{"name":"db-orders-conn"}}]')
  echo "$out" | grep -q "db-orders-conn"
}

@test "cache conn handle and app secrets render together in envFrom" {
  out=$(helm template t "$CHART" --set kind=web --set route.host=t.home.example.com \
    --set image.repo=ghcr.io/x/y --set image.tag=sha-abc1234 --set resources.requests.cpu=50m --set resources.requests.memory=64Mi --set resources.limits.cpu=200m --set resources.limits.memory=128Mi \
    --set-json 'envFrom=[{"secretRef":{"name":"cache-sessions-conn"}},{"secretRef":{"name":"orders-secrets"}}]')
  echo "$out" | grep -q "cache-sessions-conn"
  echo "$out" | grep -q "orders-secrets"
}

@test "worker kind also wires conn handles into envFrom" {
  # 위 두 @test가 전부 kind=web이라, deployment.yaml의 envFrom 블록에 kind 조건이 끼어도
  # (예: 인접한 두 isServed 블록과 합쳐지는 리팩터) worker의 conn 핸들이 조용히 사라진 채
  # 전건 초록이었다(실측: `{{- if and .Values.envFrom (eq .Values.kind "web") }}` 하에서 57/0 ok).
  # worker는 route.host가 불요다. site 레인은 추가하지 않는다 — site fixture에 envFrom이 없어
  # 대조군이 아니고 커버리지를 제조하는 꼴이다.
  out=$(helm template t "$CHART" --set kind=worker \
    --set image.repo=ghcr.io/x/y --set image.tag=sha-abc1234 \
    --set resources.requests.cpu=50m --set resources.requests.memory=64Mi \
    --set resources.limits.cpu=200m --set resources.limits.memory=128Mi \
    --set-json 'envFrom=[{"secretRef":{"name":"db-orders-conn"}}]')
  echo "$out" | grep -qF 'kind: Deployment'   # 빈 렌더 양성 대조(render.sh:6-10 규율)
  echo "$out" | grep -qF 'db-orders-conn'
}
