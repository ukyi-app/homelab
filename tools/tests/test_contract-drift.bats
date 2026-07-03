#!/usr/bin/env bats
# 동봉 계약 매니페스트·정규화 로직 가드 (CI-safe — 라이브 raw fetch는 contract-drift.yaml 워크플로 전용).
# ⚠️ 중간 부정 단언은 run+[ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; M="tools/vendored-contract.json"; }

@test "vendored-contract manifest is valid JSON with existing local sources" {
  jq -e '.vendored | length > 0' "$M"
  for s in $(jq -r '.vendored[].source' "$M"); do
    [ -f "$s" ] || { echo "누락 source: $s"; return 1; }
  done
}

@test "vendored-contract excludes files repo (Rust — no vendored seal tooling)" {
  run jq -e '[.vendored[].targets[].repo] | index("files")' "$M"
  [ "$status" -ne 0 ]
}

@test "cert targets require exact normalization (public sealing cert must be byte-identical)" {
  n=$(jq -r '[.vendored[] | select(.source|endswith(".pem")) | .targets[] | select(.normalize!="exact")] | length' "$M")
  [ "$n" -eq 0 ]
}

@test "drift checker self-test passes (offline normalize unit — ts formatter-insensitive: ws/;/,, pem exact)" {
  run bun tools/contract-drift-check.ts --self-test
  [ "$status" -eq 0 ]
}
