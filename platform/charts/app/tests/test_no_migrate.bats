#!/usr/bin/env bats
# migrate Job 템플릿·db values 제거 가드 — 앱이 부팅 시 self-migrate(expand/contract+멱등).
# 중간 단언은 [ ]만 (bats bash 3.2에서 [[ ]] 실패는 침묵 통과).
CHART="${BATS_TEST_DIRNAME}/.."

@test "no migrate-job template exists (app self-migrates)" {
  [ ! -f "$CHART/templates/migrate-job.yaml" ]
}

@test "values.schema.json no longer defines db object" {
  run jq -e '.properties | has("db") | not' "$CHART/values.schema.json"
  [ "$status" -eq 0 ]
}

@test "values.yaml no longer defines a db block" {
  run grep -qE '^db:' "$CHART/values.yaml"
  [ "$status" -ne 0 ]
}

@test "no chart template renders a migrate Job (db removed)" {
  out=$(helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 \
    --set kind=web --set route.public=true --set route.host=a.example.com \
    --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
    --set resources.limits.cpu=100m --set resources.limits.memory=64Mi)
  run bash -c "echo \"\$1\" | yq 'select(.kind==\"Job\")'" _ "$out"
  [ -z "$output" ]
}
