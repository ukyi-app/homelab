#!/usr/bin/env bats
CHART="${BATS_TEST_DIRNAME}/.."
dep() { helm template t "$CHART" --set image.repo=ghcr.io/o/x --set image.tag=sha-abc1234 \
  --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
  --set resources.limits.cpu=100m --set resources.limits.memory=64Mi "$@" | yq 'select(.kind=="Deployment")'; }

@test "livenessProbe override replaces the default (distroless: no /bin/true exec)" {
  out=$(dep --set kind=worker --set livenessProbe.grpc.port=9000 --set livenessProbe.periodSeconds=20)
  echo "$out" | grep -q 'grpc'
  run grep -q '/bin/true' <<<"$out"; [ "$status" -ne 0 ]
}

@test "default worker liveness is exec /bin/true when no override (unchanged)" {
  out=$(dep --set kind=worker)
  echo "$out" | grep -q '/bin/true'
}

@test "preStopSleepSeconds=0 omits the preStop block (distroless: no /bin/sleep)" {
  out=$(dep --set kind=service --set route.host=a.example.com --set preStopSleepSeconds=0)
  run grep -q 'preStop' <<<"$out"; [ "$status" -ne 0 ]
}

@test "default preStop still uses /bin/sleep (unchanged)" {
  out=$(dep --set kind=service --set route.host=a.example.com)
  echo "$out" | grep -q 'sleep'
}
