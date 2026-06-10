#!/usr/bin/env bats

CHART="${BATS_TEST_DIRNAME}/.."

# The default values.yaml deliberately leaves image.* and resources.* EMPTY so an app
# cannot inherit a silent default — the schema's minLength turns "forgot to size it" into
# a render-time failure. So lint/template on the bare defaults is EXPECTED to fail; the
# valid path is asserted with a complete override.

complete=(--set image.repo=ghcr.io/x/y --set image.tag=sha-deadbeef \
  --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
  --set resources.limits.cpu=100m --set resources.limits.memory=64Mi \
  --set route.host=x.example.com)

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
