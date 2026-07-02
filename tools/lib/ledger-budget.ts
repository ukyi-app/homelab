// 메모리 원장 예산 게이트 공용 — create-app·provision-cache의 12줄 사본 수렴 + teardown-app 행 제거.
// 행 파서·행 조작 프리미티브는 lib/ledger-totals.ts(SSOT) — 이 모듈은 집계·게이트·합계 동반 갱신만 얹는다.
// 실패는 throw(Error) — 종료코드/프리픽스(::error:: 등)는 콜사이트 fail()이 결정한다.
import { addRow, parseLedgerRows, removeRow, replaceTotals } from "./ledger-totals.ts";

export type LedgerAgg = {
  text: string;
  rows: ReturnType<typeof parseLedgerRows>;
  names: string[];
  sumReq: number;
  sumLimit: number;
  budget: number;
};

// 원장 텍스트 → 집계(행·합계·예산). LIMIT_BUDGET_MIB 부재는 throw(fail-loud).
export function analyzeLedger(text: string): LedgerAgg {
  const rows = parseLedgerRows(text);
  const budget = Number(text.match(/LIMIT_BUDGET_MIB=(\d+)/)?.[1]);
  if (!Number.isFinite(budget) || budget <= 0) throw new Error("원장 메타(LIMIT_BUDGET_MIB)를 찾지 못함");
  return {
    text, rows,
    names: rows.map((r) => r.name),
    sumReq: rows.reduce((a, r) => a + r.reqMi, 0),
    sumLimit: rows.reduce((a, r) => a + r.limitMi, 0),
    budget,
  };
}

// 예산 게이트 — 위반 시 사유 문자열, 통과 시 null. hint는 도구별 액션 안내("resources/replicas를 줄여라" 등).
export function budgetViolation(agg: LedgerAgg, component: string, limitMi: number, hint: string): string | null {
  if (agg.names.includes(component)) return `원장에 '${component}' 행이 이미 있다`;
  if (agg.sumLimit + limitMi > agg.budget)
    return `원장 예산 초과: 현재 ${agg.sumLimit}Mi + ${component} ${limitMi}Mi > ${agg.budget}Mi — ${hint}`;
  return null;
}

// 행 추가 + Totals 프로즈 동반 갱신(쓰기 측 수렴).
export function appendRowWithTotals(agg: LedgerAgg, row: { name: string; env: string; reqMi: number; limitMi: number }): string {
  const out = addRow(agg.text, row);
  return replaceTotals(out, agg.sumReq + row.reqMi, agg.sumLimit + row.limitMi);
}

// 행 제거 + Totals 재계산 — removeRow는 줄 splice라 빈 줄이 남지 않는다(구 인라인 replace 버그 소멸).
export function removeRowWithTotals(text: string, name: string): string {
  const out = removeRow(text, name);
  const rows = parseLedgerRows(out);
  return replaceTotals(out, rows.reduce((a, r) => a + r.reqMi, 0), rows.reduce((a, r) => a + r.limitMi, 0));
}
