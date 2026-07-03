#!/usr/bin/env bats
# check-doc-index 게이트: scripts/·tools/·workflows README 등재 드리프트 차단.
# ⚠️ 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵통과 함정).
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "check-doc-index passes on the current tree (all artifacts registered)" {
  run ./scripts/check-doc-index.sh
  [ "$status" -eq 0 ]
}

@test "check-doc-index FAILS when a script is missing from scripts/README.md" {
  tmp="scripts/zz_docindex_probe.sh"; : > "$tmp"; chmod +x "$tmp"
  run ./scripts/check-doc-index.sh
  rm -f "$tmp"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "zz_docindex_probe.sh"
}

@test "check-doc-index runs in the required gate via make verify" {
  run awk '/^verify:/{v=1} v && /check-doc-index/{print}' Makefile
  [ -n "$output" ]
}
