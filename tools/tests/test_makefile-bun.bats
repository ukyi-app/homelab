#!/usr/bin/env bats
# Makefile bun 전환 — m6-tools가 bun 1.3.10을 핀하고, ci/audit이 bun을 쓰며, MISE_SHIMS node 가드는 제거.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "m6-tools gates the pinned bun version, not node/pnpm" {
  run grep -E 'bun --version' Makefile; [ "$status" -eq 0 ]
  run grep -F '1.3.10' Makefile; [ "$status" -eq 0 ]
  run grep -E 'node --version|pnpm --version' Makefile; [ "$status" -ne 0 ]
}

@test "MISE_SHIMS node guard removed; ci/audit use bun" {
  run grep -E 'MISE_SHIMS' Makefile; [ "$status" -ne 0 ]
  run grep -E 'node tools/|pnpm verify:ledger' Makefile; [ "$status" -ne 0 ]
}

@test "make ci runs the typecheck gate (ci.yaml parity — A.5 pass4 F2)" {
  run grep -E 'bun run typecheck' Makefile; [ "$status" -eq 0 ]
}
