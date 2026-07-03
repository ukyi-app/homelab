#!/usr/bin/env bats

CHART="${BATS_TEST_DIRNAME}/.."

# 기본 values.yaml은 image.*와 resources.*를 의도적으로 비워둔다 — 앱이 암묵적 기본값을
# 상속할 수 없게 하기 위해서다. schema의 minLength가 "사이징을 깜빡함"을 렌더 시점 실패로
# 바꾼다. 따라서 순정 기본값으로의 lint/template는 실패가 정상이며, 정상 경로는
# 완전한 오버라이드로 검증한다.

complete=(--set image.repo=ghcr.io/x/y --set image.tag=sha-deadbeef \
  --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
  --set resources.limits.cpu=100m --set resources.limits.memory=64Mi \
  --set route.public=true --set route.host=x.example.com)

@test "helm lint passes on a complete, schema-valid values set" {
  run helm lint "$CHART" "${complete[@]}"
  [ "$status" -eq 0 ]
}

@test "schema rejects the empty default resources (the per-app sizing gate)" {
  run helm template t "$CHART"
  [ "$status" -ne 0 ]
  [[ "$output" == *"resources"* ]]
}

@test "schema rejects values missing a non-empty image" {
  run helm template t "$CHART" \
    --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
    --set resources.limits.cpu=100m --set resources.limits.memory=64Mi
  [ "$status" -ne 0 ]
  [[ "$output" == *"image"* ]]
}

@test "schema rejects invalid kind enum" {
  run helm template t "$CHART" "${complete[@]}" --set kind=database
  [ "$status" -ne 0 ]
}

@test "schema keeps cpu+memory required on both requests and limits (onboarding sizing-discipline; divergence from platform SRE policy is intentional and documented)" {
  S="$CHART/values.schema.json"
  run jq -e '.properties.resources.properties.limits.required == ["cpu","memory"]' "$S"; [ "$status" -eq 0 ]
  run jq -e '.properties.resources.comment | test("사이징 디시플린")' "$S"; [ "$status" -eq 0 ]
}
