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
// 마커 ↔ 파싱 행 1:1 대조 — 정책의 `min_rows` 바닥값은 **전면 붕괴만** 잡는다(실 17행 대비 12).
// 마커를 단 줄이 행 클래스 밖 문자(대문자·`_` 등)로 침묵 드랍되면 예산이 과소 합산돼 fail-open이
// 되는데, 그건 **1행만 빠져도** 성립한다(pg18 env 클래스 회귀의 재발 형태 — lib/ledger-totals.ts 주석).
// 실측: 상위 5행이 클래스 밖으로 밀리면 12행/2256Mi가 남아 바닥값 경계에 걸터앉고 전 게이트가 초록이었다.
// 래칫 없는 **정확** 불변식이라 여기(파서)가 제자리다 — 정책은 예산 의미론만 소유한다.
const markers = text.match(/<!-- ledger:row -->/g)?.length ?? 0;
const parsed = parseLedgerRows(text);
if (parsed.length !== markers) {
  console.error(
    `ledger-to-json: ledger:row 마커 ${markers}건 중 ${parsed.length}건만 파싱됨 — 행 포맷/문자 클래스 드리프트로 예산이 과소 합산된다: ${file}`,
  );
  process.exit(1);
}
const rows = parsed.map((r) => ({ component: r.name, req: r.reqMi, limit: r.limitMi }));
console.log(JSON.stringify({ budget, rows }));
