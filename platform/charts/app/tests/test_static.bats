#!/usr/bin/env bats
CHART="${BATS_TEST_DIRNAME}/.."
dep() { helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 \
  --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
  --set resources.limits.cpu=100m --set resources.limits.memory=64Mi "$@" | yq 'select(.kind=="Deployment")'; }

@test "static.server rejects caddy (enum is sws-only)" {
  run helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 \
    --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
    --set resources.limits.cpu=100m --set resources.limits.memory=64Mi \
    --set route.host=s.example.com --set kind=site --set static.server=caddy
  [ "$status" -ne 0 ]
}

@test "site probes hit the SWS health endpoint (/health), not legacy split health paths" {
  out=$(dep --set kind=site --set route.host=s.example.com)
  echo "$out" | grep -q 'path: /health'
  run grep -q 'path: /healthz' <<<"$out"; [ "$status" -ne 0 ]
  run grep -q 'path: /readyz' <<<"$out"; [ "$status" -ne 0 ]
}

@test "web probes use one /health endpoint by default" {
  out=$(dep --set kind=web --set route.host=a.example.com)
  echo "$out" | grep -q 'path: /health'
  run grep -q 'path: /healthz' <<<"$out"; [ "$status" -ne 0 ]
  run grep -q 'path: /readyz' <<<"$out"; [ "$status" -ne 0 ]
}
