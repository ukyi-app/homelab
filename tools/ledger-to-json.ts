// 메모리 원장 → conftest 입력 JSON 변환기 — 행 파서 SSOT는 lib/ledger-totals.parseLedgerRows.
// 구 scripts/ledger-to-json.sh(awk 제3 파서)를 대체 — 출력 형식 100% 동일
// ({"budget":N,"rows":[{"component","req","limit"},…]}), 소비자는 scripts/verify-ledger.sh(conftest).
// awk와 달리 LIMIT_BUDGET_MIB 부재 시 기형 JSON 대신 fail-loud(exit 1).
import { readFileSync } from "node:fs";
import { parseLedgerRows } from "./lib/ledger-totals.ts";

const file = process.argv[2] ?? "docs/memory-ledger.md";
const text = readFileSync(file, "utf8");
const budget = Number(text.match(/LIMIT_BUDGET_MIB=(\d+)/)?.[1]);
if (!Number.isFinite(budget)) {
  console.error(`ledger-to-json: LIMIT_BUDGET_MIB 메타를 찾지 못함: ${file}`);
  process.exit(1);
}
const rows = parseLedgerRows(text).map((r) => ({ component: r.name, req: r.reqMi, limit: r.limitMi }));
console.log(JSON.stringify({ budget, rows }));
