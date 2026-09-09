// teardown-app — 앱 한정 철거. 공유 리소스 안전 원칙: DB/캐시는 앱과 독립한 리소스이며
// 여러 앱이 같은 리소스를 참조할 수 있다 — 앱 teardown은 conn Secret/Database CR/Valkey를
// **절대 건드리지 않는다**(리소스 철거는 teardown-resource의 참조 0 게이트가 전담).
// 제거 대상: apps/<app>/(바인딩 포함), apps.json 행(active:true였다면 행 제거가 terraform
// apply로 DNS 회수), 원장 행. 멱등(이미 없어도 0 종료).
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { APP_NAME_RE } from "./lib/identity.ts";
// 앱 표면의 경로·제거는 app-surface module 소유(d4) — create가 쓰는 집합과의 대칭이 거기서 강제된다.
import { appPaths, appRel, removeAppSurface } from "./lib/app-surface.ts";
import { parseLedgerRows } from "./lib/ledger-totals.ts";
import { removeRowWithTotals } from "./lib/ledger-budget.ts";
import { parseFlags } from "./lib/cli.ts";
import { hasApp, removeApp } from "./lib/digest-exporter.ts";
// 동봉 계약 target 행 — create-app이 쓰는 커널의 역방향(앱-외부 표면의 대칭은 이 add/remove 쌍이 진다).
import { hasAppTargets, removeAppTargets } from "./lib/vendored-targets.ts";

// parseFlags: unknown 옵션 + arg 삼킴 fail-closed(arg()가 미지정 플래그를 조용히 무시하던 것 차단). 종료 코드 2 보존.
let __f: Record<string, string | boolean>;
try { __f = parseFlags(process.argv.slice(2), { value: ["--app", "--repo-root"], bool: ["--dry-run"] }); }
catch (e) { console.error(`${e instanceof Error ? e.message : String(e)}\n허용: --app --repo-root --dry-run`); process.exit(2); }
const arg = (k: string, d?: string) => (typeof __f[k] === "string" ? __f[k] as string : d);
const DRY = __f["--dry-run"] === true;
const app = arg("--app");
const ROOT = arg("--repo-root") ?? ".";
if (!app || !APP_NAME_RE.test(app)) {
  console.error("usage: teardown-app --app <name> [--repo-root <dir>] [--dry-run]");
  process.exit(2);
}

const plan: { app: string; remove: string[]; appsJsonRow: any; ledgerRow: boolean; untouched: string } =
  { app, remove: [], appsJsonRow: null, ledgerRow: false, untouched: "db/cache conn·CR·Valkey는 teardown-resource 전담" };

const appDir = appPaths(ROOT, app).dir;
if (existsSync(appDir)) plan.remove.push(appRel(app).dir);

const appsJsonPath = `${ROOT}/infra/cloudflare/apps.json`;
const registry = existsSync(appsJsonPath) ? JSON.parse(readFileSync(appsJsonPath, "utf8")) : [];
plan.appsJsonRow = registry.find((r: any) => r.name === app) ?? null;

const ledgerPath = `${ROOT}/docs/memory-ledger.md`;
const ledger = existsSync(ledgerPath) ? readFileSync(ledgerPath, "utf8") : "";
plan.ledgerRow = parseLedgerRows(ledger).some((r) => r.name === app);

const dePath = `${ROOT}/platform/victoria-stack/prod/digest-exporter.yaml`;
// 소속 판정은 커널(hasApp) — 계획과 실제 제거(removeApp)가 **같은 문법**(같은 APPS_RE·splitApps)을
// 본다. 손 부분매치 정규식은 APPS value 밖의 셸 로그(`app=$APP`)에도 매치해 계획을 거짓 양성으로
// 만들었고, 반대로 APPS 라인 소실(포맷 드리프트)은 조용히 지나쳐 쓰기 단계에서만 죽었다.
// 파일 부재 = no-op은 그대로, 포맷 드리프트는 plan 단계에서 커널 throw(아래 쓰기와 같은 조건).
if (existsSync(dePath) && hasApp(readFileSync(dePath, "utf8"), app)) {
  plan.remove.push("digest-exporter APPS 항목");
}

// 동봉 계약 매니페스트 — 부재는 **no-op**이다(멱등 철거 계약: 뺄 행 자체가 없다). create-app 쪽
// 부재가 fail-closed인 것과 방향이 다른 근거는 거기 주석이 갖는다 — 그쪽 부재는 "행이 영영 안
// 들어감"이라 다음 리컨실이 발화하지만, 이쪽 부재는 새 거짓 상태를 만들지 않는다. 형제(digest-exporter)도
// 같은 비대칭이다. 소속 판정은 커널(hasAppTargets)이라 계획과 실제 제거가 **같은 문법**을 본다
// (부재=false는 정상 no-op, 포맷 드리프트=throw는 고장).
const vcPath = `${ROOT}/tools/vendored-contract.json`;
const vcBefore = existsSync(vcPath) ? readFileSync(vcPath, "utf8") : null;
if (vcBefore !== null && hasAppTargets(vcBefore, app)) {
  plan.remove.push("vendored-contract target 행");
}

if (!DRY) {
  removeAppSurface(ROOT, app); // 멱등 — 이미 없어도 조용(0 종료 계약)
  if (existsSync(dePath)) writeFileSync(dePath, removeApp(readFileSync(dePath, "utf8"), app));
  if (plan.appsJsonRow) {
    writeFileSync(appsJsonPath, JSON.stringify(registry.filter((r: any) => r.name !== app), null, 2) + "\n");
  }
  if (vcBefore !== null) {
    // 멱등 — 등재돼 있지 않으면 커널이 같은 바이트를 내고, 그때는 파일을 만지지 않는다.
    const vcNext = removeAppTargets(vcBefore, app);
    if (vcNext !== vcBefore) writeFileSync(vcPath, vcNext);
  }
  if (plan.ledgerRow) {
    // 행 제거 + 합계 재계산(removeRow는 줄 splice라 빈 줄 잔류 없음 — 구 인라인 replace 버그 소멸)
    writeFileSync(ledgerPath, removeRowWithTotals(ledger, app));
  }
}
console.log(JSON.stringify(plan, null, 2));
