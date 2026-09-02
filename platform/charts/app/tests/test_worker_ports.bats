#!/usr/bin/env bats
CHART="${BATS_TEST_DIRNAME}/.."
dep() { helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 \
  --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
  --set resources.limits.cpu=100m --set resources.limits.memory=64Mi "$@" | yq 'select(.kind=="Deployment")'; }

@test "worker emits no http/metrics container ports and no scrape annotation (not served)" {
  # ⚠️ `--set metrics.enabled=true`가 load-bearing이다. 82556e2(테마2 하드닝)가 이 @test를 세울
  #    당시 values 기본값이 `metrics.enabled: true`였으므로 이것은 **worker + opt-in → 무방출**의
  #    증인이었다. 49412fe(#126)가 기본값을 false로 뒤집으면서 증인이 "기본값에서 아무것도 안 난다"로
  #    약해졌다 — worker에서 metrics를 조용히 버리는 것은 의도된 YAGNI 유보이므로, 그 결정을 재는
  #    자리는 여기 하나뿐이다. 기본값 반전이 이 토큰을 다시 삼키지 않게 명시로 고정한다.
  out=$(dep --set kind=worker --set metrics.enabled=true)
  # 빈 렌더 양성 대조 — 아래는 전부 부재 단언이라 `$out`이 비면 공허하게 통과한다(test_route.bats 선례).
  echo "$out" | grep -qF 'kind: Deployment'
  run grep -q 'name: http' <<<"$out"; [ "$status" -ne 0 ]
  run grep -q 'name: metrics' <<<"$out"; [ "$status" -ne 0 ]
  run grep -q 'prometheus.io/scrape' <<<"$out"; [ "$status" -ne 0 ]
}

@test "web defaults to http only and no metrics scrape annotation" {
  out=$(dep --set kind=web --set route.public=true --set route.host=a.example.com)
  echo "$out" | grep -q 'name: http'
  run grep -q 'name: metrics' <<<"$out"; [ "$status" -ne 0 ]
  run grep -q 'prometheus.io/scrape' <<<"$out"; [ "$status" -ne 0 ]
}

@test "web exposes metrics only when metrics.enabled=true" {
  out=$(dep --set kind=web --set route.public=true --set route.host=a.example.com --set metrics.enabled=true)
  echo "$out" | grep -q 'name: http'
  echo "$out" | grep -q 'name: metrics'
  echo "$out" | grep -q 'prometheus.io/scrape'
}

@test "site keeps http port but no metrics (serves files, no /metrics)" {
  out=$(dep --set kind=site --set route.public=true --set route.host=s.example.com)
  echo "$out" | grep -q 'name: http'
  run grep -q 'name: metrics' <<<"$out"; [ "$status" -ne 0 ]
  run grep -q 'prometheus.io/scrape' <<<"$out"; [ "$status" -ne 0 ]
}
