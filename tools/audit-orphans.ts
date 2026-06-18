// audit-orphans — registry(apps.json) ↔ 매니페스트 ↔ 바인딩 ↔ 원장 교차 드리프트 리포트.
// 읽기 전용(파괴 없음). 라이브 비교(kubectl)는 별도 — 이 도구는 레포 정적 사실만 본다.
// 유형:
//   orphan-dns            : apps.json active:true 행인데 앱 매니페스트 부재 — DNS 고아(빈 백엔드 노출, 차단)
//   orphan-dns-inactive   : active:false 행인데 매니페스트 부재 — DNS 미노출(정보성, 비차단)
//   missing-registration  : public 앱 매니페스트인데 apps.json 행 부재
//   dangling-binding      : .bindings.json 참조인데 리소스 산출물(CR/conn) 부재
//   dangling-role         : cluster.yaml managed.role인데 passwordSecret sealed 부재 — 고아 role (정보성)
//   unreferenced-resource : 어떤 앱도 참조 안 하는 리소스 — retain/teardown 후보 (정보성)
//   stale-ledger-row      : prod 원장 행인데 apps/도 platform/도 없음
//   incomplete-purge      : tombstone state=purging 잔존 — 상태머신 중단 흔적
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { parse as parseYaml } from "yaml";
import { surfaceHash } from "./lib/surface-hash.ts";

const USAGE = `audit-orphans — registry↔매니페스트↔바인딩↔원장 교차 드리프트 리포트(읽기 전용)
사용법: bun tools/audit-orphans.ts [--repo-root <dir>] [--ci] [--strict]
  --repo-root <dir>  레포 루트(기본 .)
  --ci               배포를 깨는 유형만 비-0 종료(dangling-binding/orphan-dns) — PR 게이트용
  --strict           모든 드리프트 유형을 비-0 종료(수동 점검)
  --help, -h         이 도움말`;
if (process.argv.includes("--help") || process.argv.includes("-h")) { console.log(USAGE); process.exit(0); }

const arg = (k: string, d: string) => { const i = process.argv.indexOf(k); return i > -1 ? process.argv[i + 1] : d; };
const ROOT = arg("--repo-root", ".");
const STRICT = process.argv.includes("--strict");
// --ci: PR 게이트용 — 배포 정합을 깨는 유형만 비-0 종료(missing Secret/빈 백엔드 DNS/원장 드리프트).
// unreferenced-resource(create-db→create-app 사이 정상)·missing-registration·incomplete-purge는
// 정보/경고라 차단하지 않는다. (--strict는 전부 차단 — 수동 점검용.)
const CI = process.argv.includes("--ci");
// CI 차단은 새 app-platform 흐름에서 **정확히** 배포를 깨는 두 유형만:
//   dangling-binding(.bindings.json이 미존재 db/cache 참조 → 배포 시 missing Secret),
//   orphan-dns(apps.json active 행에 앱 매니페스트 부재 → 빈 백엔드로 DNS 노출).
// stale-ledger-row는 제외 — apps/·platform/ 밖에서 관리되는 기존 워크로드(media 등)를
// 오탐해 모든 PR을 막는다. 원장 드리프트는 --strict(수동 점검)로만.
const BLOCKING = new Set(["dangling-binding", "orphan-dns", "activation-exposure-drift"]); // pass3 F1: surfaceHash(app-tree) drift는 비차단(이미지 bump 데드락 회피); restale2 F1: 노출 행(host/public) drift=activation-exposure-drift는 차단(데드락 무관 + 미재검증 DNS 노출 막음)

type RegRow = { name: string; active?: boolean; host?: string | null; public?: boolean };

const findings: { type: string; subject: string; detail: string }[] = [];
const add = (type: string, subject: string, detail: string) => findings.push({ type, subject, detail });
const readJson = (p: string, d: any): any => (existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : d);

// 레포 사실 수집
const registry: RegRow[] = readJson(`${ROOT}/infra/cloudflare/apps.json`, []);
const appsRoot = `${ROOT}/apps`;
const appDirs = (existsSync(appsRoot) ? readdirSync(appsRoot) : [])
  .filter((a) => existsSync(`${appsRoot}/${a}/deploy/prod/values.yaml`));
const dbCRs = existsSync(`${ROOT}/platform/cnpg/prod/databases`)
  ? readdirSync(`${ROOT}/platform/cnpg/prod/databases`).filter((f) => f.endsWith(".yaml") && f !== "kustomization.yaml").map((f) => f.replace(/\.yaml$/, ""))
  : [];
const cacheDirs = existsSync(`${ROOT}/platform/cache/prod`)
  ? readdirSync(`${ROOT}/platform/cache/prod`, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name)
  : [];
const connExists = (kind: string, n: string) => existsSync(`${ROOT}/platform/data-conn/prod/${kind}-${n}-conn.sealed.yaml`);

// 1) registry ↔ 매니페스트
//   active:true orphan → orphan-dns(차단): dns.tf가 public&&active만 노출하므로 빈 백엔드 DNS가 실재.
//   active:false orphan → orphan-dns-inactive(정보, 비차단): DNS 미노출이라 create-app 중간 상태에서 정상.
for (const r of registry) {
  if (!appDirs.includes(r.name)) {
    if (r.active)
      add("orphan-dns", r.name, `apps.json active:true 행인데 apps/${r.name}/deploy/prod 부재 — DNS가 빈 백엔드로 노출 중`);
    else
      add("orphan-dns-inactive", r.name, `apps.json active:false 행인데 apps/${r.name}/deploy/prod 부재 — DNS 미노출(create-app 매니페스트 머지 대기 가능)`);
  }
}
for (const a of appDirs) {
  const values = parseYaml(readFileSync(`${appsRoot}/${a}/deploy/prod/values.yaml`, "utf8")) ?? {};
  if (values.route?.public === true && !registry.some((r) => r.name === a))
    add("missing-registration", a, "public 앱인데 apps.json 행 부재 — activate 불가 상태");
}

// 1b) activation surface-drift (races-5) — active:true(+ 매니페스트 존재) 앱의 커밋된 .activation
// surfaceHash가 현재 canonical surfaceHash(.activation 제외)와 다르면, activation 이후 표면이 바뀐 것.
// ⚠️ codex pass3 F1: **정보성만**(BLOCKING 아님). 차단 게이트로 쓰면 정상 이미지 bump(values.yaml의
// image.tag 변경 → surface 변경)가 머지 불가가 되고, 새 revision은 머지돼야 Healthy가 되므로 데드락
// (autoDeploy 붕괴). 노출 재검증은 런북(activate 절차)이 담당한다. canonical 해시(F3)는 .activation 자기
// 무효화로 인한 false-positive 노이즈를 막기 위해 여전히 필요하다.
for (const r of registry) {
  if (r.active !== true || !appDirs.includes(r.name)) continue;
  const markerPath = `${appsRoot}/${r.name}/deploy/prod/.activation`;
  const marker = readJson(markerPath, null);
  if (!marker || !marker.surfaceHash) {
    add("missing-activation", r.name, "active:true인데 .activation 마커 없음/빈 surfaceHash — 정보성(activate-app 재실행 또는 런북 재검증 권장)");
    continue;
  }
  const current = surfaceHash(ROOT, "HEAD", r.name); // .activation 제외 canonical — 마커와 동일 함수
  if (current && current !== marker.surfaceHash)
    add("activation-surface-drift", r.name, `activation 이후 apps/${r.name} 표면 변경(정보성 — 런북 재검증 권장; 마커 ${String(marker.surfaceHash).slice(0, 12)} ≠ 현재 ${current.slice(0, 12)})`);
  // ⚠️ codex pass4 F1: apps.json 노출 행(host/public)이 바뀌면 앱 트리 무변경이어도 DNS 노출이 변한다 — 정보성으로 잡는다.
  // ⚠️ codex restale2 F1: apps.json 노출 행(host/public) 변경은 app-tree(surfaceHash) drift와 달리 **데드락
  // 위험이 없다**(호스트 변경은 앱 재배포·Healthy 선행 불필요) → 미재검증 public DNS 노출을 막기 위해 **차단**.
  // (owner가 activate-app --flip로 새 노출 재증명+마커 갱신해야 머지 가능 = 의도한 재승인. surfaceHash drift만 정보성.)
  const curProj = { name: r.name, host: r.host ?? null, public: r.public ?? false };
  if (marker.registry && JSON.stringify(curProj) !== JSON.stringify(marker.registry))
    add("activation-exposure-drift", r.name, `activation 이후 apps.json 노출 행 변경(host/public — 마커 ${JSON.stringify(marker.registry)} ≠ 현재 ${JSON.stringify(curProj)}) — activate-app 재실행으로 재승인 필요(차단)`);
}

// 2) 바인딩 ↔ 리소스
const referenced = new Set();
for (const a of appDirs) {
  const b = readJson(`${appsRoot}/${a}/deploy/prod/.bindings.json`, null);
  if (!b) continue;
  for (const n of b.db ?? []) {
    referenced.add(`db:${n}`);
    if (!dbCRs.includes(n) || !connExists("db", n))
      add("dangling-binding", `${a}→db:${n}`, "바인딩 참조인데 Database CR 또는 conn sealed 부재");
  }
  for (const n of b.redis ?? []) {
    referenced.add(`cache:${n}`);
    if (!connExists("cache", n))
      add("dangling-binding", `${a}→cache:${n}`, "바인딩 참조인데 conn sealed 부재");
  }
}

// 3) 미참조 리소스 (정보성 — retain/teardown 후보)
for (const n of dbCRs) if (!referenced.has(`db:${n}`)) add("unreferenced-resource", `db:${n}`, "참조 앱 0 — retain tombstone 또는 teardown-resource 검토");
for (const n of cacheDirs) if (!referenced.has(`cache:${n}`)) add("unreferenced-resource", `cache:${n}`, "참조 앱 0");

// 4) 원장 ↔ 실체 (prod 행만 — 플랫폼 컴포넌트 행은 namespace가 다르거나 platform/에 실체)
const ledger = existsSync(`${ROOT}/docs/memory-ledger.md`) ? readFileSync(`${ROOT}/docs/memory-ledger.md`, "utf8") : "";
for (const m of ledger.matchAll(/<!-- ledger:row --> *([a-z0-9+-]+) *\| *([a-z-]+) *\|/g)) {
  const [, comp, ns] = m;
  if (ns === "prod" && !appDirs.includes(comp) && !existsSync(`${ROOT}/platform/${comp}`))
    add("stale-ledger-row", comp, "원장 prod 행인데 apps/·platform/ 어디에도 실체 없음");
  if (ns === "cache" && !cacheDirs.includes(comp.replace(/^cache-/, "")))
    add("stale-ledger-row", comp, "원장 cache 행인데 인스턴스 디렉토리 없음");
}

// 5) 중단된 purge
const tombs: Record<string, any> = readJson(`${ROOT}/platform/data-conn/prod/.tombstones.json`, {});
for (const [k, v] of Object.entries(tombs))
  if (v.state === "purging") add("incomplete-purge", k, "purge 상태머신이 중단됨 — drop/verify/cleanup 재개 필요");

// 6) dangling-role — cluster.yaml managed.roles 항목인데 passwordSecret sealed가 부재(정보성).
//    purge cleanup이 sealed/CR을 제거했지만 cluster.yaml role 제거 커밋이 빠진 상태를 잡는다
//    (incomplete-purge는 state=purging만 봐서 purge 완료 후 고아 role을 못 본다).
const clusterPath = `${ROOT}/platform/cnpg/prod/cluster.yaml`;
if (existsSync(clusterPath)) {
  const cluster = parseYaml(readFileSync(clusterPath, "utf8")) ?? {};
  const roles = cluster?.spec?.managed?.roles ?? [];
  const dbDir = `${ROOT}/platform/cnpg/prod/databases`;
  for (const role of roles) {
    const secret = role?.passwordSecret?.name;
    if (!secret) continue;
    if (!existsSync(`${dbDir}/${secret}.sealed.yaml`))
      add("dangling-role", role.name, `cluster.yaml managed.role이 부재 sealed(${secret}.sealed.yaml)를 참조 — purge 후 role 제거 커밋 누락 가능`);
  }
}

const blocking = findings.filter((f) => BLOCKING.has(f.type));
console.log(JSON.stringify({ findings, count: findings.length, blocking: blocking.length }, null, 2));
if (STRICT && findings.length > 0) process.exit(1);
if (CI && blocking.length > 0) {
  console.error(`audit-orphans: 배포 정합 위반 ${blocking.length}건 — ${blocking.map((f) => `${f.type}:${f.subject}`).join(", ")}`);
  process.exit(1);
}
