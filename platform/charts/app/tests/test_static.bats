#!/usr/bin/env bats
CHART="${BATS_TEST_DIRNAME}/.."
dep() { helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 \
  --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
  --set resources.limits.cpu=100m --set resources.limits.memory=64Mi "$@" | yq 'select(.kind=="Deployment")'; }

@test "static.server rejects caddy (enum is sws-only)" {
  run helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 \
    --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
    --set resources.limits.cpu=100m --set resources.limits.memory=64Mi \
    --set route.host=s.example.com --set kind=static --set static.server=caddy
  [ "$status" -ne 0 ]
}

@test "static probes hit the SWS health endpoint (/health), not service /healthz·/readyz" {
  out=$(dep --set kind=static --set route.host=s.example.com)
  echo "$out" | grep -q 'path: /health'
  run grep -q 'path: /healthz' <<<"$out"; [ "$status" -ne 0 ]
  run grep -q 'path: /readyz' <<<"$out"; [ "$status" -ne 0 ]
}

@test "service probes keep /healthz·/readyz (unchanged)" {
  out=$(dep --set kind=service --set route.host=a.example.com)
  echo "$out" | grep -q 'path: /healthz'
  echo "$out" | grep -q 'path: /readyz'
}
