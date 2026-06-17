// 메모리 원장 Totals 프로즈 치환 SSOT — create-app/onboard-app/provision-cache/teardown-app 공용.
// 프로즈 문구가 드리프트하면 String.replace가 조용히 no-op이 되어 합계가 stale로 남는다 →
// 매치가 0이면 throw해 fail-loud(silent no-op 차단).
const TOTALS_RE = /req ≈ \d+ Mi · limit ≈ \d+ Mi/;

export function replaceTotals(text, sumReqMi, sumLimitMi) {
  if (!TOTALS_RE.test(text)) {
    throw new Error(
      `ledger Totals 프로즈를 찾지 못함(정규식 '${TOTALS_RE.source}') — 원장 포맷 드리프트로 합계 갱신 불가`,
    );
  }
  return text.replace(TOTALS_RE, `req ≈ ${sumReqMi} Mi · limit ≈ ${sumLimitMi} Mi`);
}
