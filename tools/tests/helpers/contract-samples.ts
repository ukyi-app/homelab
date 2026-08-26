// 계약 테스트 표본 SSOT — test_homelab-cli.bats의 행렬 @test 두 개(허용/비허용 행렬 ·
// exitCode 결합)가 같은 코퍼스를 소비한다(cli-deepening 심화 3 티켓 05: 축자 이중 사본 제거).
// 키는 "verb|variant" 우선, "verb" 폴백. 새 동사/variant 분기를 추가하면 여기 표본을 추가한다
// (누락 = 소비 테스트가 fail-loud). 테스트 전용 헬퍼 — 런타임 코드가 import하지 않는다.
import type { ContractRow } from "../../lib/catalog-rows.ts";

type Sample = Record<string, unknown>;

export function buildSamples(doctorIds: readonly string[]): Record<string, Sample> {
  const dbBase = { action: "create-database", name: "mydb", correlation: "corr-fixed-nonce-01" };
  const cacheBase = { action: "create-cache", name: "mycache", correlation: "corr-fixed-nonce-01" };
  const mut = (base: Sample): Record<string, Sample> => ({
    ["success"]: { ...base, waited: false, run: { id: 1, url: "u" }, pr: { number: 1, url: "u", merged: false } },
    ["failure"]: { ...base, error: "x" },
    ["race"]: { ...base, error: "x", observedRuns: 2 },
    ["pending"]: { ...base, pendingReason: "x" },
    ["superseded"]: { ...base, error: "x", pr: { number: 1, url: "u", merged: true, mergeSha: "a" }, applications: [{ name: "cnpg-data" }] },
  });
  const secBase = { action: "update-secrets", name: "myapp", correlation: "corr-fixed-nonce-01", chain: { mode: "dispatch-only" } };
  const appBase = { action: "create-app", name: "myapp", correlation: "corr-fixed-nonce-01" };
  // teardown은 shared mutation* 정의를 쓰지 않는다(dnsReclaim 필수·chain 없음·applications는
  // mutationAbsentApp) — 표본을 직접 짓는다.
  const tdBase = { action: "teardown-app", name: "myapp", correlation: "corr-fixed-nonce-01", dnsReclaim: "iac/tf-reconcile" };
  const td: Record<string, Sample> = {
    ["success"]: { ...tdBase, waited: false, run: { id: 1, url: "u" }, pr: { number: 1, url: "u", merged: false } },
    ["failure"]: { ...tdBase, error: "x" },
    ["race"]: { ...tdBase, error: "x", observedRuns: 2 },
    ["pending"]: { ...tdBase, pendingReason: "x" },
  };
  // app init은 로컬 체인(변이 아님) — correlation 없음, 전용 정의(initSuccess/initFailure).
  const initBase = { app: "myapp", archetype: "api", public: false, repo: "ukyi-app/myapp" };
  const init: Record<string, Sample> = {
    ["success"]: { ...initBase, created: true, scaffolded: true, pushed: true, checkpoint: "pushed" },
    ["no-op"]: { ...initBase, existed: true, scaffolded: true, pushed: true, checkpoint: "pushed" },
    ["failure"]: { ...initBase, checkpoint: "preflight", error: "x" },
  };
  // db url/cache url은 MCP 전용 envelope(urlResult) — 평문 비출력, 계획/수행 보고.
  const url: Record<string, Sample> = {
    ["success"]: { name: "mydb", dryRun: true, wrote: false, mode: "readonly" },
    ["failure"]: { name: "mydb", dryRun: false, wrote: false, error: "x" },
    ["skip"]: { name: "mydb", dryRun: false, wrote: false, note: "x" },
  };
  return {
    doctor: { checks: doctorIds.map((id) => ({ id, status: "pass", detail: "x" })), summary: { pass: doctorIds.length, fail: 0, warn: 0 } },
    status: { mode: "list", apps: [], count: 0 },
    ...Object.fromEntries(Object.entries(mut(dbBase)).map(([v, r]) => ["db create|" + v, r])),
    ...Object.fromEntries(Object.entries(mut(cacheBase)).map(([v, r]) => ["cache create|" + v, r])),
    ...Object.fromEntries(Object.entries(mut(appBase)).map(([v, r]) => ["app create|" + v, r])),
    ...Object.fromEntries(Object.entries(mut(secBase)).map(([v, r]) => ["app secrets|" + v, r])),
    "app secrets|no-op": { ...secBase, waited: false, run: { id: 1, url: "u" } },
    ...Object.fromEntries(Object.entries(td).map(([v, r]) => ["app teardown|" + v, r])),
    ...Object.fromEntries(Object.entries(init).map(([v, r]) => ["app init|" + v, r])),
    ...Object.fromEntries(Object.entries(url).map(([v, r]) => ["db url|" + v, r])),
    ...Object.fromEntries(Object.entries(url).map(([v, r]) => ["cache url|" + v, r])),
  };
}

// 표 파생 행렬 셀 수 — allowed = 행이 선언한 (분기 × variant)의 합, rejected = 동사별
// (전체 variant 수 − 허용 집합 크기)의 합. 구판의 손 재계산 floor(36/34)를 대체한다.
// 행 내 variant 중복은 fail-closed로 던진다 — 같은 verb+variant를 두 분기가 주장하면 oneOf가
// "정확히 하나"를 잃어 스키마 자체가 모호해지고, 중복/dedup 계수 갈림으로 파생과 워커가
// 어긋난다(리뷰 실측). 열거 붕괴 방지의 손 앵커(oneOf 분기 수 31 · 행 수 10 · variant 셀 총합
// 38 · exitCodes 리터럴 7쌍)는 소비 테스트가 파생 밖에 유지한다.
export function matrixCellCounts(rows: readonly ContractRow[], allVariantCount: number): { allowed: number; rejected: number } {
  let allowed = 0;
  let rejected = 0;
  for (const r of rows) {
    const set = new Set<string>();
    const add = (v: string): void => {
      if (set.has(v)) throw new Error(`계약 파손: 행 내 variant 중복 — ${r.verb}|${v}`);
      set.add(v);
      allowed++;
    };
    if (r.mutation) for (const v of r.mutation.variants) add(v);
    for (const s of r.simple ?? []) for (const v of s.variants) add(v);
    rejected += allVariantCount - set.size;
  }
  return { allowed, rejected };
}
