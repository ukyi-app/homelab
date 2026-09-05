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
  # ⚠️ 존재 단언은 **import 줄**로 좁힌다 — 형제 test_ledger-totals.bats와 같은 클래스다(맨
  #    `lib/ledger-budget` 매치는 파일 어디든 주석 한 줄에도 걸린다). 2026-09-04 형제 전수 열거에서
  #    같은 파일(teardown-app.ts)을 재는 두 번째 자리로 발견돼 같은 커밋에서 함께 좁혔다.
  grep -qE '^import .*"\./lib/ledger-budget\.ts"' "$ROOT/tools/teardown-app.ts"
}

# 양성 대조 — 이 스위트의 픽스처는 전부 올바른 합계 형식을 품고 있어서, 실 원장이 그 형식을 잃어도
# 전건 초록이었다(2026-08-31~09-02 실제 사례: 세 변이 디스패처가 원장 단계에서 죽는 동안 CI 초록).
# 픽스처가 아니라 **실 원장**에 쓰기 경로를 물린다.
@test "replaceTotals accepts the real ledger (the write path is not throwing)" {
  run bun -e '
    const [ledgerPath, libPath] = process.argv.slice(1);
    const fs = require("node:fs");
    import("file://" + libPath).then(m => {
      const out = m.replaceTotals(fs.readFileSync(ledgerPath, "utf8"), 1, 2);
      if (!/req ≈ 1 Mi · limit ≈ 2 Mi/.test(out)) { console.error("NO-SUBSTITUTION"); process.exit(1); }
      console.log("ok");
    }).catch(e => { console.error(e.message); process.exit(1); });
  ' "$ROOT/docs/memory-ledger.md" "$ROOT/tools/lib/ledger-totals.ts"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}
