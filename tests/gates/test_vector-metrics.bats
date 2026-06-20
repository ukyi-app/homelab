#!/usr/bin/env bats
# vector 메트릭 노출 — internal_metrics→prometheus_exporter→scrape. ★annotation은 POD TEMPLATE(F4). ⚠️ 중간 단언 [ ]만.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; V="$ROOT/platform/victoria-stack/prod/vector.yaml"
  if ! command -v yq >/dev/null; then
    [ -z "${CI:-}" ] || { echo "FAIL: CI인데 yq 부재 — 구조 검증 불가(dead-green 방지)"; return 1; }
    skip "yq 미설치(로컬만 — CI setup-toolchain 제공)"
  fi
}

@test "vector config exposes internal_metrics source + prometheus_exporter sink" {
  run yq -e 'select(.kind=="ConfigMap" and .metadata.name=="vector-config") | .data."vector.yaml"' "$V"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'type: internal_metrics'
  printf '%s' "$output" | grep -q 'type: prometheus_exporter'
}

@test "scrape annotation is on the POD TEMPLATE (.spec.template.metadata), NOT the DaemonSet object (F4)" {
  D='select(.kind=="DaemonSet" and .metadata.name=="vector")'
  run yq -e "$D | .spec.template.metadata.annotations.\"prometheus.io/scrape\" == \"true\"" "$V"
  [ "$status" -eq 0 ]; [ "$output" = "true" ]
  run yq -e "$D | .spec.template.metadata.annotations.\"prometheus.io/port\" == \"9598\"" "$V"
  [ "$status" -eq 0 ]; [ "$output" = "true" ]
  # DaemonSet object .metadata에 scrape가 가면 안 됨(잘못된 위치 회귀 차단)
  run yq -e "$D | .metadata.annotations.\"prometheus.io/scrape\"" "$V"
  [ "$status" -ne 0 ]
}

@test "vector container exposes the 9598 metrics port" {
  run yq -e 'select(.kind=="DaemonSet" and .metadata.name=="vector") | .spec.template.spec.containers[] | select(.name=="vector").ports[] | select(.containerPort==9598)' "$V"
  [ "$status" -eq 0 ]
}

@test "vector config validation runs in the required gate (containerized vector validate)" {
  [ -x "$ROOT/tests/gates/vector-validate.sh" ]
  run grep -F 'vector-validate.sh' "$ROOT/.github/workflows/ci.yaml"; [ "$status" -eq 0 ]
  run awk '/^  gate:/{g=1} /^  [a-z]/ && !/^  gate:/{g=0} g && /vector-validate/{print}' "$ROOT/.github/workflows/ci.yaml"; [ -n "$output" ]
}
