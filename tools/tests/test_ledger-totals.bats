#!/usr/bin/env bats
# ledger Totals 프로즈 치환 SSOT 헬퍼 — 프로즈 드리프트 시 silent no-op 대신 fail-loud.
# ⚠️ 중간 단언은 [ ]만.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LIB="$ROOT/tools/lib/ledger-totals.ts"
}

@test "replaceTotals substitutes the totals prose and returns updated text" {
  run bun -e '
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
  run bun -e '
    import("file://" + process.argv[1]).then(m => {
      try { m.replaceTotals("no totals phrase here\n", 1, 2); console.log("DID-NOT-THROW"); }
      catch (e) { console.log("threw"); }
    });
  ' "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^threw$'
}

@test "teardown-app imports the shared helper (no inline replace regex)" {
  # 인라인 'req ≈ ...' 치환이 teardown-app.ts에서 사라지고 공용 헬퍼를 import 하는지.
  run grep -c 'req ≈' "$ROOT/tools/teardown-app.ts"
  [ "$output" = "0" ]
  grep -q "lib/ledger-totals" "$ROOT/tools/teardown-app.ts"
}

@test "addRow inserts a ledger row after the last existing row" {
  run bun -e '
    import("file://" + process.argv[1]).then(m => {
      const base = "| <!-- ledger:row --> blog           | prod           |    128 |      256 |\n";
      const out = m.addRow(base, { name: "shop", env: "prod", reqMi: 64, limitMi: 128 });
      if (!/<!-- ledger:row --> shop/.test(out)) { console.error("no-insert"); process.exit(1); }
      if ((out.match(/ledger:row/g) || []).length !== 2) { console.error("count"); process.exit(1); }
      console.log("ok");
    }).catch(e => { console.error(e.message); process.exit(1); });
  ' "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}

@test "removeRow removes the named row and throws fail-loud when absent" {
  run bun -e '
    import("file://" + process.argv[1]).then(m => {
      const base = "| <!-- ledger:row --> blog           | prod |  128 |  256 |\n| <!-- ledger:row --> shop           | prod |   64 |  128 |\n";
      const out = m.removeRow(base, "shop");
      if (/ledger:row --> shop/.test(out)) { console.error("not-removed"); process.exit(1); }
      if (!/ledger:row --> blog/.test(out)) { console.error("over-removed"); process.exit(1); }
      try { m.removeRow(base, "nope"); console.log("DID-NOT-THROW"); }
      catch { console.log("ok"); }
    }).catch(e => { console.error(e.message); process.exit(1); });
  ' "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}

@test "parseLedgerRows returns named fields (name/env/reqMi/limitMi) with correct numbers" {
  run bun -e '
    import("file://" + process.argv[1]).then(m => {
      const t = "| <!-- ledger:row --> blog           | prod           |    128 |      256 |\n";
      const rows = m.parseLedgerRows(t); const r = rows[0];
      if (rows.length !== 1 || r.name !== "blog" || r.env !== "prod" || r.reqMi !== 128 || r.limitMi !== 256) { console.error(JSON.stringify(rows)); process.exit(1); }
      console.log("ok");
    }).catch(e => { console.error(e.message); process.exit(1); });
  ' "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}

@test "addRow then parseLedgerRows yields exact summed totals (catches index drift)" {
  run bun -e '
    import("file://" + process.argv[1]).then(m => {
      let t = "| <!-- ledger:row --> blog           | prod           |    100 |      200 |\n";
      t = m.addRow(t, { name: "shop", env: "prod", reqMi: 30, limitMi: 70 });
      const rows = m.parseLedgerRows(t);
      const sumReq = rows.reduce((a,r)=>a+r.reqMi,0), sumLimit = rows.reduce((a,r)=>a+r.limitMi,0);
      if (sumReq !== 130 || sumLimit !== 270) { console.error(sumReq+"/"+sumLimit); process.exit(1); }
      console.log("ok");
    }).catch(e => { console.error(e.message); process.exit(1); });
  ' "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}

@test "parseLedgerRows accepts a digit-bearing env (namespace class regression)" {
  run bun -e '
    import("file://" + process.argv[1]).then(m => {
      const rows = m.parseLedgerRows("| <!-- ledger:row --> aaa | pg18 | 10 | 20 |\n");
      if (rows.length !== 1 || rows[0].env !== "pg18") { console.error(JSON.stringify(rows)); process.exit(1); }
      console.log("ok");
    }).catch(e => { console.error(e.message); process.exit(1); });
  ' "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}
