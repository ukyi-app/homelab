// teardown-app — 앱 한정 철거. 공유 리소스 안전 원칙: DB/캐시는 앱과 독립한 리소스이며
// 여러 앱이 같은 리소스를 참조할 수 있다 — 앱 teardown은 conn Secret/Database CR/Valkey를
// **절대 건드리지 않는다**(리소스 철거는 teardown-resource의 참조 0 게이트가 전담).
// 제거 대상: apps/<app>/(바인딩 포함), apps.json 행(active:true였다면 행 제거가 terraform
// apply로 DNS 회수), 원장 행. 멱등(이미 없어도 0 종료).
import { readFileSync, writeFileSync, existsSync, rmSync } from "node:fs";
import { APP_NAME_RE } from "./lib/identity.mjs";
import { replaceTotals } from "./lib/ledger-totals.mjs";

const arg = (k, d) => { const i = process.argv.indexOf(k); return i > -1 ? process.argv[i + 1] : d; };
// 오타 옵션 침묵-무시 차단 — arg() 헬퍼는 미지정 플래그를 조용히 무시한다(mutator 패밀리 fail-closed).
const ALLOWED_FLAGS = new Set(["--app", "--repo-root", "--dry-run"]);
for (const a of process.argv.slice(2)) {
  if (a.startsWith("--") && !ALLOWED_FLAGS.has(a)) { console.error(`알 수 없는 옵션: ${a}\n허용: ${[...ALLOWED_FLAGS].join(" ")}`); process.exit(2); }
}
const DRY = process.argv.includes("--dry-run");
const app = arg("--app");
const ROOT = arg("--repo-root", ".");
if (!app || !APP_NAME_RE.test(app)) {
  console.error("usage: teardown-app --app <name> [--repo-root <dir>] [--dry-run]");
  process.exit(2);
}

const plan = { app, remove: [], appsJsonRow: null, ledgerRow: false, untouched: "db/cache conn·CR·Valkey는 teardown-resource 전담" };

const appDir = `${ROOT}/apps/${app}`;
if (existsSync(appDir)) plan.remove.push(`apps/${app}`);

const appsJsonPath = `${ROOT}/infra/cloudflare/apps.json`;
const registry = existsSync(appsJsonPath) ? JSON.parse(readFileSync(appsJsonPath, "utf8")) : [];
plan.appsJsonRow = registry.find((r) => r.name === app) ?? null;

const ledgerPath = `${ROOT}/docs/memory-ledger.md`;
const ledger = existsSync(ledgerPath) ? readFileSync(ledgerPath, "utf8") : "";
const rowRe = new RegExp(`^.*<!-- ledger:row --> *${app} .*$`, "m");
plan.ledgerRow = rowRe.test(ledger);

if (!DRY) {
  if (existsSync(appDir)) rmSync(appDir, { recursive: true });
  if (plan.appsJsonRow) {
    writeFileSync(appsJsonPath, JSON.stringify(registry.filter((r) => r.name !== app), null, 2) + "\n");
  }
  if (plan.ledgerRow) {
    // 행 제거 + 합계 프로즈 재계산
    let out = ledger.replace(rowRe, "").replace(/\n\n\n+/g, "\n\n");
    const rows = [...out.matchAll(/<!-- ledger:row --> *[a-z0-9+-]+ *\|[^|]*\| *(\d+) *\| *(\d+) *\|/g)];
    const sumReq = rows.reduce((s, m) => s + +m[1], 0);
    const sumLimit = rows.reduce((s, m) => s + +m[2], 0);
    out = replaceTotals(out, sumReq, sumLimit);
    writeFileSync(ledgerPath, out);
  }
}
console.log(JSON.stringify(plan, null, 2));
