// teardown-app — 앱 한정 철거. 공유 리소스 안전 원칙: DB/캐시는 앱과 독립한 리소스이며
// 여러 앱이 같은 리소스를 참조할 수 있다 — 앱 teardown은 conn Secret/Database CR/Valkey를
// **절대 건드리지 않는다**(리소스 철거는 teardown-resource의 참조 0 게이트가 전담).
// 제거 대상: apps/<app>/(바인딩 포함), apps.json 행(active:true였다면 행 제거가 terraform
// apply로 DNS 회수), 원장 행. 멱등(이미 없어도 0 종료).
import { readFileSync, writeFileSync, existsSync, rmSync } from "node:fs";
import { APP_NAME_RE } from "./lib/identity.ts";
import { parseLedgerRows } from "./lib/ledger-totals.ts";
import { removeRowWithTotals } from "./lib/ledger-budget.ts";
import { parseFlags } from "./lib/cli.ts";
import { removeApp } from "./lib/digest-exporter.ts";

// parseFlags: unknown 옵션 + arg 삼킴 fail-closed(arg()가 미지정 플래그를 조용히 무시하던 것 차단). 종료 코드 2 보존.
let __f: Record<string, string | boolean>;
try { __f = parseFlags(process.argv.slice(2), { value: ["--app", "--repo-root"], bool: ["--dry-run"] }); }
catch (e) { console.error(`${e instanceof Error ? e.message : String(e)}\n허용: --app --repo-root --dry-run`); process.exit(2); }
const arg = (k: string, d?: string) => (typeof __f[k] === "string" ? __f[k] as string : d);
const DRY = __f["--dry-run"] === true;
const app = arg("--app");
const ROOT = arg("--repo-root", ".");
if (!app || !APP_NAME_RE.test(app)) {
  console.error("usage: teardown-app --app <name> [--repo-root <dir>] [--dry-run]");
  process.exit(2);
}

const plan: { app: string; remove: string[]; appsJsonRow: any; ledgerRow: boolean; untouched: string } =
  { app, remove: [], appsJsonRow: null, ledgerRow: false, untouched: "db/cache conn·CR·Valkey는 teardown-resource 전담" };

const appDir = `${ROOT}/apps/${app}`;
if (existsSync(appDir)) plan.remove.push(`apps/${app}`);

const appsJsonPath = `${ROOT}/infra/cloudflare/apps.json`;
const registry = existsSync(appsJsonPath) ? JSON.parse(readFileSync(appsJsonPath, "utf8")) : [];
plan.appsJsonRow = registry.find((r: any) => r.name === app) ?? null;

const ledgerPath = `${ROOT}/docs/memory-ledger.md`;
const ledger = existsSync(ledgerPath) ? readFileSync(ledgerPath, "utf8") : "";
plan.ledgerRow = parseLedgerRows(ledger).some((r) => r.name === app);

const dePath = `${ROOT}/platform/victoria-stack/prod/digest-exporter.yaml`;
if (existsSync(dePath) && new RegExp(`(^|[" ])${app}=`).test(readFileSync(dePath, "utf8"))) {
  plan.remove.push("digest-exporter APPS 항목");
}

if (!DRY) {
  if (existsSync(appDir)) rmSync(appDir, { recursive: true });
  if (existsSync(dePath)) writeFileSync(dePath, removeApp(readFileSync(dePath, "utf8"), app));
  if (plan.appsJsonRow) {
    writeFileSync(appsJsonPath, JSON.stringify(registry.filter((r: any) => r.name !== app), null, 2) + "\n");
  }
  if (plan.ledgerRow) {
    // 행 제거 + 합계 재계산(removeRow는 줄 splice라 빈 줄 잔류 없음 — 구 인라인 replace 버그 소멸)
    writeFileSync(ledgerPath, removeRowWithTotals(ledger, app));
  }
}
console.log(JSON.stringify(plan, null, 2));
