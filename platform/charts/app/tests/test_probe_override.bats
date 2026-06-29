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

@test "worker has NO default liveness probe (distroless-safe; avoids /bin/true CrashLoop)" {
  out=$(dep --set kind=worker)
  # 기본 liveness 미렌더 — /bin/true 없음 + livenessProbe 키 자체 없음(override 시에만 등장).
  run grep -q '/bin/true' <<<"$out"; [ "$status" -ne 0 ]
  run grep -q 'livenessProbe' <<<"$out"; [ "$status" -ne 0 ]
}

@test "preStopSleepSeconds=0 omits the preStop block (distroless: no /bin/sleep)" {
  out=$(dep --set kind=web --set route.host=a.example.com --set preStopSleepSeconds=0)
  run grep -q 'preStop' <<<"$out"; [ "$status" -ne 0 ]
}

@test "default preStop omits /bin/sleep (distroless-safe)" {
  out=$(dep --set kind=web --set route.host=a.example.com)
  run grep -q 'preStop' <<<"$out"; [ "$status" -ne 0 ]
}

@test "preStopSleepSeconds>0 explicitly enables /bin/sleep" {
  out=$(dep --set kind=web --set route.host=a.example.com --set preStopSleepSeconds=3)
  echo "$out" | grep -q 'sleep'
}
