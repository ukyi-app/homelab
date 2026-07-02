// 메모리 원장 Totals 프로즈 치환 SSOT — create-app/provision-cache/teardown-app 공용.
// 프로즈 문구가 드리프트하면 String.replace가 조용히 no-op이 되어 합계가 stale로 남는다 →
// 매치가 0이면 throw해 fail-loud(silent no-op 차단).
const TOTALS_RE = /req ≈ \d+ Mi · limit ≈ \d+ Mi/;

export function replaceTotals(text: string, sumReqMi: number, sumLimitMi: number): string {
  if (!TOTALS_RE.test(text)) {
    throw new Error(
      `ledger Totals 프로즈를 찾지 못함(정규식 '${TOTALS_RE.source}') — 원장 포맷 드리프트로 합계 갱신 불가`,
    );
  }
  return text.replace(TOTALS_RE, `req ≈ ${sumReqMi} Mi · limit ≈ ${sumLimitMi} Mi`);
}

// 원장 행 SSOT — 행 형식: | <!-- ledger:row --> <name padEnd14> | <env padEnd14> | <req padStart6> | <limit padStart8> |
// LEDGER_ROW_RE는 모듈 내부 전용 — 콜사이트는 raw 인덱스 대신 parseLedgerRows(명명 필드)를 쓴다(F7).
// env 클래스는 숫자 허용([a-z0-9-]) — 숫자 포함 namespace 행(예: pg18)이 TS 파서만 침묵 드랍되면
// 예산 게이트가 과소 합산돼 fail-open. awk 파서(제거됨)와 동치 유지.
const LEDGER_ROW_RE = /<!-- ledger:row --> *([a-z0-9+-]+) *\| *([a-z0-9-]+) *\| *(\d+) *\| *(\d+) *\|/g;

// 캐노니컬 파서 — audit-orphans(name|type)·create-app/provision-cache(name|type|req|limit) 변형 통일.
// String.matchAll은 정규식을 복제하므로 공유 /g lastIndex 오염 없음.
export function parseLedgerRows(text: string): { name: string; env: string; reqMi: number; limitMi: number }[] {
  const rows: { name: string; env: string; reqMi: number; limitMi: number }[] = [];
  for (const m of text.matchAll(LEDGER_ROW_RE)) rows.push({ name: m[1], env: m[2], reqMi: +m[3], limitMi: +m[4] });
  return rows;
}

export function addRow(text: string, row: { name: string; env: string; reqMi: number; limitMi: number }): string {
  const lines = text.split("\n");
  const lastRow = lines.map((l, i) => (l.includes("<!-- ledger:row -->") ? i : -1)).filter((i) => i >= 0).pop();
  if (lastRow === undefined) throw new Error("원장에 ledger:row 행이 없어 삽입 위치를 못 찾음");
  const formatted = `| <!-- ledger:row --> ${row.name.padEnd(14)} | ${row.env.padEnd(14)} | ${String(row.reqMi).padStart(6)} | ${String(row.limitMi).padStart(8)} |`;
  lines.splice(lastRow + 1, 0, formatted);
  return lines.join("\n");
}

export function removeRow(text: string, name: string): string {
  const lines = text.split("\n");
  const re = new RegExp(`<!-- ledger:row --> *${name} `);
  const idx = lines.findIndex((l) => re.test(l));
  if (idx < 0) throw new Error(`원장에서 행 '${name}'을 못 찾음 — 제거 불가(드리프트?)`);
  lines.splice(idx, 1);
  return lines.join("\n");
}
