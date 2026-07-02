#!/usr/bin/env bats
# ledger-budget lib — 예산 게이트 12줄 사본(create-app/provision-cache) 수렴 + teardown-app 빈 줄 회귀.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LIB="$ROOT/tools/lib/ledger-budget.ts"
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

@test "budgetViolation flags duplicate row and over-budget with the exact gate messages" {
  run bun -e '
    import("file://" + process.argv[1]).then(m => {
      const text = "<!-- ledger:meta LIMIT_BUDGET_MIB=100 -->\n| <!-- ledger:row --> aaa | prod | 10 | 60 |\n**합계:** req ≈ 10 Mi · limit ≈ 60 Mi\n";
      const agg = m.analyzeLedger(text);
      const dup = m.budgetViolation(agg, "aaa", 10, "hint");
      const over = m.budgetViolation(agg, "bbb", 50, "hint");
      const ok = m.budgetViolation(agg, "bbb", 40, "hint");
      if (!/aaa.*이미 있다/.test(dup)) { console.error("dup:" + dup); process.exit(1); }
      if (!/원장 예산 초과: 현재 60Mi \+ bbb 50Mi > 100Mi/.test(over)) { console.error("over:" + over); process.exit(1); }
      if (ok !== null) { console.error("ok:" + ok); process.exit(1); }
      console.log("ok");
    }).catch(e => { console.error(e.message); process.exit(1); });
  ' "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}

@test "analyzeLedger throws fail-loud when LIMIT_BUDGET_MIB meta is missing" {
  run bun -e '
    import("file://" + process.argv[1]).then(m => {
      try { m.analyzeLedger("no meta\n"); console.log("DID-NOT-THROW"); }
      catch { console.log("threw"); }
    });
  ' "$LIB"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^threw$"
}

@test "teardown of a middle row leaves no blank line inside the table (blank-line regression)" {
  mkdir -p "$TMP/root/docs" "$TMP/root/infra/cloudflare"
  cat > "$TMP/root/docs/memory-ledger.md" <<'EOF'
<!-- ledger:meta VM_ALLOCATABLE_MIB=1024 LIMIT_BUDGET_MIB=512 -->

| component | namespace | req_mi | limit_mi |
|---|---|---:|---:|
| <!-- ledger:row --> aaa            | prod           |     10 |       20 |
| <!-- ledger:row --> bbb            | prod           |     10 |       20 |
| <!-- ledger:row --> ccc            | prod           |     10 |       20 |

**합계:** req ≈ 30 Mi · limit ≈ 60 Mi (반드시 ≤ 512 Mi 유지).
EOF
  echo "[]" > "$TMP/root/infra/cloudflare/apps.json"
  run bun "$ROOT/tools/teardown-app.ts" --app bbb --repo-root "$TMP/root"
  [ "$status" -eq 0 ]
  run bash -c "sed -n '/ledger:row --> aaa/,/ledger:row --> ccc/p' '$TMP/root/docs/memory-ledger.md' | grep -c '^$'"
  [ "$output" = "0" ]
  grep -q 'req ≈ 20 Mi · limit ≈ 40 Mi' "$TMP/root/docs/memory-ledger.md"
  run grep -c 'ledger:row --> bbb' "$TMP/root/docs/memory-ledger.md"
  [ "$output" = "0" ]
}

@test "teardown-app no longer carries an inline ledger row parser (lib SSOT adoption)" {
  run grep -c 'matchAll' "$ROOT/tools/teardown-app.ts"
  [ "$output" = "0" ]
  grep -q 'lib/ledger-budget' "$ROOT/tools/teardown-app.ts"
}
