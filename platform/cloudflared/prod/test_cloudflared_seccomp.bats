#!/usr/bin/env bats
# cloudflared seccompProfile 정합 — 다른 컴포넌트 표준(RuntimeDefault)과 비대칭 해소. ⚠️ 중간 단언 [ ]만.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"; D="$ROOT/platform/cloudflared/prod/deployment.yaml"
  if ! command -v yq >/dev/null; then
    [ -z "${CI:-}" ] || { echo "FAIL: CI인데 yq 부재 — 구조 검증 불가(dead-green 방지)"; return 1; }
    skip "yq 미설치(로컬만 — CI setup-toolchain 제공)"
  fi
}

@test "cloudflared sets seccompProfile RuntimeDefault (parity with other components)" {
  # pod 또는 container securityContext에 seccompProfile RuntimeDefault
  run yq -e 'select(.kind=="Deployment") | (.spec.template.spec.securityContext.seccompProfile.type == "RuntimeDefault" or (.spec.template.spec.containers[].securityContext.seccompProfile.type == "RuntimeDefault"))' "$D"
  [ "$status" -eq 0 ]; [ "$output" = "true" ]
}
