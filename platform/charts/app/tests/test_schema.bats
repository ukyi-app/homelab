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

@test "schema documents the sizing-discipline divergence (limits half)" {
  # 이름을 limits 축으로 좁혔다 — 본문이 재는 건 limits.required와 정책 분기 주석뿐이고,
  # requests 축은 아래 행동 증인 @test가 맡는다(예전 이름은 「both」를 약속하면서 절반이 무증인이었다).
  S="$CHART/values.schema.json"
  run jq -e '.properties.resources.properties.limits.required == ["cpu","memory"]' "$S"; [ "$status" -eq 0 ]
  run jq -e '.properties.resources.comment | test("사이징 디시플린")' "$S"; [ "$status" -eq 0 ]
}

@test "schema rejects an emptied or absent requests axis (the other half of the both name)" {
  # 스키마 JSON을 jq로 미러링하지 않는다 — 동어반복 증인이라 $ref·oneOf 리팩터에 취약하다.
  # 레포 관용구대로 fail-closed는 `run helm template`의 rc로 잰다. 두 프로브가 각각
  # requests의 minLength 축·required 축에 대응한다(실측: 각 축을 지우면 그 프로브만 초록이 된다).
  run helm template t "$CHART" "${complete[@]}" --set resources.requests.cpu=
  [ "$status" -ne 0 ]                     # minLength 축(빈 quantity)
  run helm template t "$CHART" "${complete[@]}" --set resources.requests.cpu=null
  [ "$status" -ne 0 ]                     # required 축(키 삭제)
}
