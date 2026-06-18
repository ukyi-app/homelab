#!/usr/bin/env bats
# ledger Totals 프로즈 치환 SSOT 헬퍼 — 프로즈 드리프트 시 silent no-op 대신 fail-loud.
# ⚠️ 중간 단언은 [ ]만.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LIB="$ROOT/tools/lib/ledger-totals.ts"
}

@test "replaceTotals substitutes the totals prose and returns updated text" {
  run node -e '
    import("file://" + process.argv[1]).then(m => {
      const before = "blah\n**합계:** req ≈ 100 Mi · limit ≈ 200 Mi (≤ 8704 Mi).\n";
      const after = m.replaceTotals(before, 150, 250);
      if (!/req ≈ 150 Mi · limit ≈ 250 Mi/.test(after)) { console.error("no-sub"); process.exit(1); }
      console.log("ok");
    }).catch(e => { console.error(e.message); process.exit(1); });
  ' "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^ok$'
}

@test "replaceTotals throws (fail-loud) when the totals prose is missing" {
  run node -e '
    import("file://" + process.argv[1]).then(m => {
      try { m.replaceTotals("no totals phrase here\n", 1, 2); console.log("DID-NOT-THROW"); }
      catch (e) { console.log("threw"); }
    });
  ' "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^threw$'
}

@test "teardown-app imports the shared helper (no inline replace regex)" {
  # 인라인 'req ≈ ...' 치환이 teardown-app.mjs에서 사라지고 공용 헬퍼를 import 하는지.
  run grep -c 'req ≈' "$ROOT/tools/teardown-app.mjs"
  [ "$output" = "0" ]
  grep -q "lib/ledger-totals" "$ROOT/tools/teardown-app.mjs"
}
