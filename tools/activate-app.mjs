// activate-app 게이트 — 등록(배포)과 DNS activation(공개)의 분리를 강제한다.
// "현재 Synced된 아무 revision의 Healthy"는 옛 revision의 조기 노출을 허용한다 — 따라서
// 노출하려는 homelab 머지 SHA를 고정하고 다음을 전부 증명해야 active를 플립한다:
//   (1) synced revision이 머지 SHA의 descendant(또는 동일) — 옛 revision 게이트 통과 차단
//   (2) SHA..synced 사이에 이 앱의 표면(apps/<app>/, 공유 차트) 무변경 — 과승인 차단
//   (3) apps.json의 이 앱 행(name/host/public)이 승인 SHA와 동일 — 미승인 hostname 노출 차단
//   (4) Application Synced+Healthy && HTTPRoute Accepted/ResolvedRefs True (같은 revision)
// 통과 시 active:true만 변경(워크트리) — 커밋/PR은 호출자(owner 또는 워크플로)가 PR-first로.
// 라이브 상태는 kubectl로 읽고(--status-file 미지정 시), 테스트는 픽스처 주입.
import { readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import path from "node:path";

function die(msg) {
  console.error(`activate-app: GATE FAIL — ${msg}`);
  process.exit(1);
}

const args = {};
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--flip") args.flip = true;
  else if (a.startsWith("--")) args[a.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = argv[++i];
  else die(`알 수 없는 인자: ${a}`);
}
const { app, sha, syncedRev } = args;
const repoDir = path.resolve(args.repoDir ?? ".");
if (!app || !sha || !syncedRev) die("--app --sha --synced-rev 필수");
if (!/^[a-z][a-z0-9-]{0,38}[a-z0-9]$/.test(app)) die(`app 이름 형식 불량: ${app}`);
if (!/^[0-9a-f]{7,40}$/.test(sha)) die(`sha 형식 불량`);

const git = (...a) => execFileSync("git", a, { cwd: repoDir, encoding: "utf8" });
const gitOk = (...a) => {
  try {
    execFileSync("git", a, { cwd: repoDir, stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
};

// (1) descendant 검증 — moving-main에서 옛 synced revision의 게이트 통과를 차단
if (!gitOk("merge-base", "--is-ancestor", sha, syncedRev))
  die(`synced revision(${syncedRev.slice(0, 12)})이 머지 SHA(${sha.slice(0, 12)})의 descendant가 아니다`);

// (2) 승인 범위 고정 — SHA 이후 이 앱 표면이 변했다면 새 활성화 요청이 필요하다
if (!gitOk("diff", "--quiet", sha, syncedRev, "--", `apps/${app}/`, "platform/charts/app"))
  die(`${sha.slice(0, 12)}..${syncedRev.slice(0, 12)} 사이에 앱 표면(apps/${app}/ 또는 공유 차트)이 변경됨 — 재요청 필요`);

// (3) apps.json 행 고정 — 승인 SHA의 행(name/host/public)과 현재 워크트리 행이 동일해야 한다
const rowOf = (json) => {
  const rows = JSON.parse(json).filter((r) => r.name === app);
  if (rows.length !== 1) die(`apps.json에 ${app} 행이 정확히 1개가 아니다(${rows.length}개)`);
  const { name, host, public: pub } = rows[0];
  return JSON.stringify({ name, host, public: pub });
};
const appsJsonPath = path.join(repoDir, "infra/cloudflare/apps.json");
const approvedRow = rowOf(git("show", `${sha}:infra/cloudflare/apps.json`));
const currentRaw = readFileSync(appsJsonPath, "utf8");
const currentRow = rowOf(currentRaw);
if (approvedRow !== currentRow) die(`apps.json 행이 승인 SHA와 다르다: 승인=${approvedRow} 현재=${currentRow}`);

// (4) 라이브 상태 — Application Synced+Healthy, HTTPRoute Accepted/ResolvedRefs
let status;
if (args.statusFile) {
  status = JSON.parse(readFileSync(args.statusFile, "utf8"));
} else {
  const kubectl = (...a) => JSON.parse(execFileSync("kubectl", a, { encoding: "utf8" }));
  status = {
    application: kubectl("-n", "argocd", "get", "application", `${app}-prod`, "-o", "json"),
    httproute: kubectl("-n", "prod", "get", "httproute", app, "-o", "json"),
  };
}
const sync = status.application?.status?.sync?.status;
const health = status.application?.status?.health?.status;
if (sync !== "Synced") die(`Application sync=${sync} (Synced 아님)`);
if (health !== "Healthy") die(`Application health=${health} (Healthy 아님)`);
const conds = (status.httproute?.status?.parents ?? []).flatMap((p) => p.conditions ?? []);
for (const type of ["Accepted", "ResolvedRefs"]) {
  const c = conds.find((c) => c.type === type);
  if (!c || c.status !== "True") die(`HTTPRoute ${type}=${c?.status ?? "(없음)"} (True 아님)`);
}

// 게이트 전부 통과 — active:true 플립(워크트리). host/public은 절대 건드리지 않는다.
if (args.flip) {
  const rows = JSON.parse(currentRaw);
  const row = rows.find((r) => r.name === app);
  if (row.active === true) console.error("activate-app: 이미 active — 멱등 no-op");
  row.active = true;
  writeFileSync(appsJsonPath, JSON.stringify(rows, null, 2) + "\n");
}
console.log(JSON.stringify({ ok: true, app, sha, syncedRev, flipped: Boolean(args.flip) }));
