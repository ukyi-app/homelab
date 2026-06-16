#!/usr/bin/env bats
# verify-traps.sh — docs/traps.md enforcement 원장이 가리키는 가드 파일이 실재하는지.
# '강제됐다'고 적힌 함정의 guard 파일이 삭제/리네임된 드리프트를 차단(KD-4). 순수 파일 존재 검사.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

@test "verify-traps passes — every guard path in the ledger exists" {
  run bash scripts/verify-traps.sh
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "실재 OK"
}

@test "verify-traps flags a ledger guard path that does not exist" {
  printf '| 함정 | status | guard |\n|---|---|---|\n| x | gate-enforced | `tools/test/nonexistent-guard.bats` |\n' > "$TMP/bad.md"
  run bash scripts/verify-traps.sh "$TMP/bad.md"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "nonexistent-guard"
}
