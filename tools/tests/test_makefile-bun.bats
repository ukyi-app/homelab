#!/usr/bin/env bats
# Makefile bun 전환 — m6-tools가 bun 1.3.14를 핀하고, ci/audit이 bun을 쓰며, MISE_SHIMS node 가드는 제거.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.
# ⚠️ 부재 단언 규약(`-eq 1`)은 docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a가 SSOT다.
#    이 파일 고유 사정: 피연산자가 전부 단일 파일 `Makefile`이고 그 기준은 setup의 `cd "$ROOT"`가
#    고정한다. 아래 두 번째 @test에는 양성 형제가 아예 없어 이 rc가 Makefile 실재의 유일한 증인이다.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "m6-tools gates the pinned bun version, not node/pnpm" {
  run grep -E 'bun --version' Makefile; [ "$status" -eq 0 ]
  run grep -F '1.3.14' Makefile; [ "$status" -eq 0 ]
  # 위 두 줄이 같은 파일의 양성 형제다 — 리네임은 거기서도 red다.
  run grep -E 'node --version|pnpm --version' Makefile; [ "$status" -eq 1 ]
}

@test "MISE_SHIMS node guard removed; ci/audit use bun" {
  run grep -E 'MISE_SHIMS' Makefile; [ "$status" -eq 1 ]
  run grep -E 'node tools/|pnpm verify:ledger' Makefile; [ "$status" -eq 1 ]
}
