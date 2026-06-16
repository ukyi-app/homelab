#!/usr/bin/env node
// audit-orphans — registry(apps.json) ↔ 매니페스트 ↔ 바인딩 ↔ 원장 교차 드리프트 리포트.
// 읽기 전용(파괴 없음). 라이브 비교(kubectl)는 별도 — 이 도구는 레포 정적 사실만 본다.
// 유형:
//   orphan-dns            : apps.json 행(특히 active:true)인데 앱 매니페스트 부재 — DNS 고아
//   missing-registration  : public 앱 매니페스트인데 apps.json 행 부재
//   dangling-binding      : .bindings.json 참조인데 리소스 산출물(CR/conn) 부재
//   unreferenced-resource : 어떤 앱도 참조 안 하는 리소스 — retain/teardown 후보 (정보성)
//   stale-ledger-row      : prod 원장 행인데 apps/도 platform/도 없음
//   incomplete-purge      : tombstone state=purging 잔존 — 상태머신 중단 흔적
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { parse as parseYaml } from "yaml";

const USAGE = `audit-orphans — registry↔매니페스트↔바인딩↔원장 교차 드리프트 리포트(읽기 전용)
사용법: node tools/audit-orphans.mjs [--repo-root <dir>] [--ci] [--strict]
  --repo-root <dir>  레포 루트(기본 .)
  --ci               배포를 깨는 유형만 비-0 종료(dangling-binding/orphan-dns) — PR 게이트용
  --strict           모든 드리프트 유형을 비-0 종료(수동 점검)
  --help, -h         이 도움말`;
if (process.argv.includes("--help") || process.argv.includes("-h")) { console.log(USAGE); process.exit(0); }

const arg = (k, d) => { const i = process.argv.indexOf(k); return i > -1 ? process.argv[i + 1] : d; };
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
const BLOCKING = new Set(["dangling-binding", "orphan-dns"]);

const findings = [];
const add = (type, subject, detail) => findings.push({ type, subject, detail });
const readJson = (p, d) => (existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : d);

// 레포 사실 수집
const registry = readJson(`${ROOT}/infra/cloudflare/apps.json`, []);
const appsRoot = `${ROOT}/apps`;
const appDirs = (existsSync(appsRoot) ? readdirSync(appsRoot) : [])
  .filter((a) => existsSync(`${appsRoot}/${a}/deploy/prod/values.yaml`));
const dbCRs = existsSync(`${ROOT}/platform/cnpg/prod/databases`)
  ? readdirSync(`${ROOT}/platform/cnpg/prod/databases`).filter((f) => f.endsWith(".yaml") && f !== "kustomization.yaml").map((f) => f.replace(/\.yaml$/, ""))
  : [];
const cacheDirs = existsSync(`${ROOT}/platform/cache/prod`)
  ? readdirSync(`${ROOT}/platform/cache/prod`, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name)
  : [];
const connExists = (kind, n) => existsSync(`${ROOT}/platform/data-conn/prod/${kind}-${n}-conn.sealed.yaml`);

// 1) registry ↔ 매니페스트
for (const r of registry) {
  if (!appDirs.includes(r.name))
    add("orphan-dns", r.name, `apps.json 행(active=${r.active})인데 apps/${r.name}/deploy/prod 부재${r.active ? " — DNS가 빈 백엔드로 노출 중" : ""}`);
}
for (const a of appDirs) {
  const values = parseYaml(readFileSync(`${appsRoot}/${a}/deploy/prod/values.yaml`, "utf8")) ?? {};
  if (values.route?.public === true && !registry.some((r) => r.name === a))
    add("missing-registration", a, "public 앱인데 apps.json 행 부재 — activate 불가 상태");
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
const tombs = readJson(`${ROOT}/platform/data-conn/prod/.tombstones.json`, {});
for (const [k, v] of Object.entries(tombs))
  if (v.state === "purging") add("incomplete-purge", k, "purge 상태머신이 중단됨 — drop/verify/cleanup 재개 필요");

const blocking = findings.filter((f) => BLOCKING.has(f.type));
console.log(JSON.stringify({ findings, count: findings.length, blocking: blocking.length }, null, 2));
if (STRICT && findings.length > 0) process.exit(1);
if (CI && blocking.length > 0) {
  console.error(`audit-orphans: 배포 정합 위반 ${blocking.length}건 — ${blocking.map((f) => `${f.type}:${f.subject}`).join(", ")}`);
  process.exit(1);
}
