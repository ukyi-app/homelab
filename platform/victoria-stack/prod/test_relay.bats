#!/usr/bin/env bats
# deadmanswitch relay 회귀 가드 — busybox 1.36 nc에는 -q 옵션이 없다.
# 'nc -l -p PORT -q 1'은 invalid option으로 즉시 죽어 webhook을 영구 거부했고, 그 결과
# healthchecks를 과도 ping해 dead-man switch를 무력화한 라이브 인시던트가 있었다. 재발 방지.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  F="$ROOT/platform/victoria-stack/deadmanswitch-relay.yaml"
}

@test "relay nc listener does not use the busybox-incompatible -q flag" {
  run grep -nE 'nc[[:space:]].*-q' "$F"
  [ "$status" -ne 0 ]
}
