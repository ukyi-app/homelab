#!/usr/bin/env bats
CHART="${BATS_TEST_DIRNAME}/.."
dep() { helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 \
  --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
  --set resources.limits.cpu=100m --set resources.limits.memory=64Mi "$@" | yq 'select(.kind=="Deployment")'; }

@test "worker emits no http/metrics container ports and no scrape annotation (not served)" {
  out=$(dep --set kind=worker)
  run grep -q 'name: http' <<<"$out"; [ "$status" -ne 0 ]
  run grep -q 'name: metrics' <<<"$out"; [ "$status" -ne 0 ]
  run grep -q 'prometheus.io/scrape' <<<"$out"; [ "$status" -ne 0 ]
}

@test "web defaults to http only and no metrics scrape annotation" {
  out=$(dep --set kind=web --set route.host=a.example.com)
  echo "$out" | grep -q 'name: http'
  run grep -q 'name: metrics' <<<"$out"; [ "$status" -ne 0 ]
  run grep -q 'prometheus.io/scrape' <<<"$out"; [ "$status" -ne 0 ]
}

@test "web exposes metrics only when metrics.enabled=true" {
  out=$(dep --set kind=web --set route.host=a.example.com --set metrics.enabled=true)
  echo "$out" | grep -q 'name: http'
  echo "$out" | grep -q 'name: metrics'
  echo "$out" | grep -q 'prometheus.io/scrape'
}

@test "site keeps http port but no metrics (serves files, no /metrics)" {
  out=$(dep --set kind=site --set route.host=s.example.com)
  echo "$out" | grep -q 'name: http'
  run grep -q 'name: metrics' <<<"$out"; [ "$status" -ne 0 ]
  run grep -q 'prometheus.io/scrape' <<<"$out"; [ "$status" -ne 0 ]
}
