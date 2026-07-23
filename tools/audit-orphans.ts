// audit-orphans — registry(apps.json) ↔ 매니페스트 ↔ 원장 교차 드리프트 리포트.
//   (연결=SealedSecret 전환으로 db/redis 바인딩 교차검사는 제거 — .bindings.json엔 autoDeploy만)
// 읽기 전용(파괴 없음). 라이브 비교(kubectl)는 별도 — 이 도구는 레포 정적 사실만 본다.
// 유형:
//   orphan-dns            : apps.json active:true 행인데 앱 매니페스트 부재 — DNS 고아(빈 백엔드 노출, 차단)
//   orphan-dns-inactive   : active:false 행인데 매니페스트 부재 — DNS 미노출(정보성, 비차단)
//   missing-registration  : public 앱 매니페스트인데 apps.json 행 부재
//   missing-activation    : active:true+public 앱인데 .activation 마커(registry projection) 부재 — 재노출 게이트 사각(차단)
//   dangling-role         : cluster.yaml managed.role인데 passwordSecret sealed 부재 — 고아 role (정보성)
//   unreferenced-conn     : data-conn 등록 conn인데 어느 apps/*/values.yaml envFrom도 미참조 (정보성; *-ro-conn 제외)
//   stale-ledger-row      : prod 원장 행인데 apps/도 platform/도 없음
//   incomplete-purge      : tombstone state=purging 잔존 — 상태머신 중단 흔적
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { parse as parseYaml } from "yaml";
import { surfaceHash } from "./lib/surface-hash.ts";
import { registryProjection } from "./lib/activation-marker.ts";
import { parseLedgerRows } from "./lib/ledger-totals.ts";

const USAGE = `audit-orphans — registry↔매니페스트↔원장 교차 드리프트 리포트(읽기 전용)
사용법: bun tools/audit-orphans.ts [--repo-root <dir>] [--ci] [--strict]
  --repo-root <dir>  레포 루트(기본 .)
  --ci               배포를 깨는 유형만 비-0 종료(orphan-dns/activation-exposure-drift/missing-activation) — PR 게이트용
  --strict           모든 드리프트 유형을 비-0 종료(수동 점검)
  --help, -h         이 도움말`;
if (process.argv.includes("--help") || process.argv.includes("-h")) { console.log(USAGE); process.exit(0); }

const arg = (k: string, d: string) => { const i = process.argv.indexOf(k); return i > -1 ? process.argv[i + 1] : d; };
const ROOT = arg("--repo-root", ".");
const STRICT = process.argv.includes("--strict");
// --ci: PR 게이트용 — 배포 정합/노출을 깨는 유형만 비-0 종료(빈 백엔드 DNS/미재검증 노출 드리프트).
// missing-registration·incomplete-purge·원장 드리프트는 정보/경고라 차단하지 않는다.
// (--strict는 전부 차단 — 수동 점검용.)
const CI = process.argv.includes("--ci");
// CI 차단은 **정확히** 배포 정합/노출을 깨는 세 유형만:
//   orphan-dns(apps.json active 행에 앱 매니페스트 부재 → 빈 백엔드로 DNS 노출),
//   activation-exposure-drift(activation 이후 apps.json host/public 변경 → 미재검증 DNS 노출),
//   missing-activation(active&&public 앱에 .activation 마커 부재 → 재노출 게이트 영구 우회).
// 연결=SealedSecret이라 .bindings.json엔 db/redis 참조가 없다(dangling-binding 제거).
// stale-ledger-row는 제외 — apps/·platform/ 밖 워크로드 오탐 방지. 원장 드리프트는 --strict로만.
const BLOCKING = new Set(["orphan-dns", "activation-exposure-drift", "missing-activation"]); // pass3 F1: surfaceHash(app-tree) drift는 비차단(이미지 bump 데드락 회피); restale2 F1: 노출 행(host/public) drift=activation-exposure-drift는 차단(데드락 무관 + 미재검증 DNS 노출 막음); missing-activation: 마커 부재=재노출 게이트 사각(차단)
// REPORT_ONLY: 정보성이면서 **설계상 재발하는** 드리프트 — 텔레그램 페이지에서 제외한다(감사 JSON엔 유지 = 가시성).
// activation-surface-drift는 이미지 bump마다 apps/<app> 표면 해시가 바뀌어(비차단, autoDeploy 데드락 회피 위해
// 의도적 비차단) 매 주기 알림을 내던 유일한 노이즈원이다. 실제 노출 재검증은 blocking activation-exposure-drift
// (apps.json host/public)가 페이지하므로 이건 report-only로 강등한다. audit.yaml이 `alerting`으로 게이트한다.
const REPORT_ONLY = new Set(["activation-surface-drift"]);

type RegRow = { name: string; active?: boolean; host?: string | null; public?: boolean };

const findings: { type: string; subject: string; detail: string }[] = [];
const add = (type: string, subject: string, detail: string) => findings.push({ type, subject, detail });
const readJson = (p: string, d: any): any => (existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : d);

// 레포 사실 수집
const registry: RegRow[] = readJson(`${ROOT}/infra/cloudflare/apps.json`, []);
const appsRoot = `${ROOT}/apps`;
const appDirs = (existsSync(appsRoot) ? readdirSync(appsRoot) : [])
  .filter((a) => existsSync(`${appsRoot}/${a}/deploy/prod/values.yaml`));
const cacheDirs = existsSync(`${ROOT}/platform/cache/prod`)
  ? readdirSync(`${ROOT}/platform/cache/prod`, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name)
  : [];

// 1) registry ↔ 매니페스트
//   active:true orphan → orphan-dns(차단): dns.tf가 public&&active만 노출하므로 빈 백엔드 DNS가 실재.
//   active:false orphan → orphan-dns-inactive(정보, 비차단): DNS 미노출이라 수동 보류/철거 중이면 정상.
for (const r of registry) {
  if (!appDirs.includes(r.name)) {
    if (r.active)
      add("orphan-dns", r.name, `apps.json active:true 행인데 apps/${r.name}/deploy/prod 부재 — DNS가 빈 백엔드로 노출 중`);
    else
      add("orphan-dns-inactive", r.name, `apps.json active:false 행인데 apps/${r.name}/deploy/prod 부재 — DNS 미노출(수동 보류/철거 중 상태일 수 있음)`);
  }
}
for (const a of appDirs) {
  const values = parseYaml(readFileSync(`${appsRoot}/${a}/deploy/prod/values.yaml`, "utf8")) ?? {};
  if (values.route?.public === true && !registry.some((r) => r.name === a))
    add("missing-registration", a, "public 앱인데 apps.json 행 부재 — activate 불가 상태");
}

// 1b) activation surface-drift (races-5) — .activation 마커가 있는 active:true 앱만 검사한다.
// create-app PR 머지 자체가 첫 공개 승인이라 초기 active:true 앱에는 마커가 없어도 정상이다.
// 마커가 있으면 surfaceHash가 현재 canonical surfaceHash(.activation 제외)와 다른지 확인한다.
// ⚠️ codex pass3 F1: **정보성만**(BLOCKING 아님). 차단 게이트로 쓰면 정상 이미지 bump(values.yaml의
// image.tag 변경 → surface 변경)가 머지 불가가 되고, 새 revision은 머지돼야 Healthy가 되므로 데드락
// (autoDeploy 붕괴). 노출 재검증은 런북(activate 절차)이 담당한다. canonical 해시(F3)는 .activation 자기
// 무효화로 인한 false-positive 노이즈를 막기 위해 여전히 필요하다.
for (const r of registry) {
  if (r.active !== true || !appDirs.includes(r.name)) continue;
  const markerPath = `${appsRoot}/${r.name}/deploy/prod/.activation`;
  const marker = readJson(markerPath, null);
  // ⚠️ 마커 없는 active&&public 앱은 유일 차단 재노출 게이트(activation-exposure-drift)가 registry
  // projection 부재로 **영구 제외**된다(감사 사각). create-app(공개 생성)·activate-app(--flip) 둘 다
  // 마커를 기록하므로, 부재/registry 누락 = 미검증 DNS 노출이 게이트를 우회 → BLOCKING.
  // (public 한정: internal 앱은 apps.json 미등록·active:false는 dns.tf가 노출 안 함 → 노출 사각 없음.)
  if (r.public === true && (!marker || !marker.registry)) {
    add("missing-activation", r.name, `active:true+public 앱인데 .activation 마커(registry projection)가 없음 — 재노출 게이트가 이 앱을 영구 제외(create-app/activate-app가 마커를 기록해야 함, 차단)`);
    continue;
  }
  if (!marker || !marker.surfaceHash) continue;
  const current = surfaceHash(ROOT, "HEAD", r.name); // .activation 제외 canonical — 마커와 동일 함수
  if (current && current !== marker.surfaceHash)
    add("activation-surface-drift", r.name, `activation 이후 apps/${r.name} 표면 변경(정보성 — 런북 재검증 권장; 마커 ${String(marker.surfaceHash).slice(0, 12)} ≠ 현재 ${current.slice(0, 12)})`);
  // ⚠️ codex pass4 F1: apps.json 노출 행(host/public)이 바뀌면 앱 트리 무변경이어도 DNS 노출이 변한다 — 정보성으로 잡는다.
  // ⚠️ codex restale2 F1: apps.json 노출 행(host/public) 변경은 app-tree(surfaceHash) drift와 달리 **데드락
  // 위험이 없다**(호스트 변경은 앱 재배포·Healthy 선행 불필요) → 미재검증 public DNS 노출을 막기 위해 **차단**.
  // (owner가 activate-app --flip로 새 노출 재증명+마커 갱신해야 머지 가능 = 의도한 재승인. surfaceHash drift만 정보성.)
  const curProj = registryProjection(r); // 마커와 동일 projection(키 순서 계약)
  if (marker.registry && JSON.stringify(curProj) !== JSON.stringify(marker.registry))
    add("activation-exposure-drift", r.name, `activation 이후 apps.json 노출 행 변경(host/public — 마커 ${JSON.stringify(marker.registry)} ≠ 현재 ${JSON.stringify(curProj)}) — activate-app 재실행으로 재승인 필요(차단)`);
}

// 2) 원장 ↔ 실체 (prod 행만 — 플랫폼 컴포넌트 행은 namespace가 다르거나 platform/에 실체)
// (연결=SealedSecret 이후 바인딩↔리소스/미참조 리소스 교차는 제거 — .bindings.json엔 db/redis 참조 없음)
const ledger = existsSync(`${ROOT}/docs/memory-ledger.md`) ? readFileSync(`${ROOT}/docs/memory-ledger.md`, "utf8") : "";
for (const r of parseLedgerRows(ledger)) { // F7: 명명 필드(raw 인덱스 금지)
  const comp = r.name, ns = r.env;
  if (ns === "prod" && !appDirs.includes(comp) && !existsSync(`${ROOT}/platform/${comp}`))
    add("stale-ledger-row", comp, "원장 prod 행인데 apps/·platform/ 어디에도 실체 없음");
  if (ns === "cache" && !cacheDirs.includes(comp.replace(/^cache-/, "")))
    add("stale-ledger-row", comp, "원장 cache 행인데 인스턴스 디렉토리 없음");
}

// 3) 중단된 purge
const tombs: Record<string, any> = readJson(`${ROOT}/platform/data-conn/prod/.tombstones.json`, {});
for (const [k, v] of Object.entries(tombs))
  if (v.state === "purging") add("incomplete-purge", k, "purge 상태머신이 중단됨 — drop/verify/cleanup 재개 필요");

// 4) dangling-role — cluster.yaml managed.roles 항목인데 passwordSecret sealed가 부재(정보성).
//    purge cleanup이 sealed/CR을 제거했지만 cluster.yaml role 제거 커밋이 빠진 상태를 잡는다
//    (incomplete-purge는 state=purging만 봐서 purge 완료 후 고아 role을 못 본다).
const clusterPath = `${ROOT}/platform/cnpg/prod/cluster.yaml`;
if (existsSync(clusterPath)) {
  const cluster = parseYaml(readFileSync(clusterPath, "utf8")) ?? {};
  const roles = cluster?.spec?.managed?.roles ?? [];
  const cnpgDir = `${ROOT}/platform/cnpg/prod`;
  for (const role of roles) {
    const secret = role?.passwordSecret?.name;
    if (!secret) continue;
    // 비밀번호 시크릿 경로 2종: provision-db owner/ro는 databases/<secret>.sealed.yaml(SealedSecret),
    // KSOPS 시드 롤(ukkiee 등)은 <secret>.enc.yaml(secret-generator.yaml가 렌더). 둘 다 없으면 고아.
    if (!existsSync(`${cnpgDir}/databases/${secret}.sealed.yaml`) && !existsSync(`${cnpgDir}/${secret}.enc.yaml`))
      add("dangling-role", role.name, `cluster.yaml managed.role이 비밀번호 시크릿(${secret})의 sealed/.enc.yaml를 어디서도 못 찾음 — purge 후 role 제거 커밋 누락 가능`);
  }
}

// 5) unreferenced-conn — data-conn kustomization의 conn 항목인데 어느 apps/*/values.yaml
//    envFrom도 참조하지 않음(정보성, 비차단). *-ro-conn은 모드2 디버깅 전용(의도적 미참조)이라 제외.
//    trip-mate 실재발(#211): conn이 봉인·커밋돼도 앱이 envFrom을 배선 안 하면 어떤 게이트도 안 잡았다.
//    (이름 재사용/공유 등 이름≠앱 케이스가 있어 차단하지 않는다 — 정보로만 표면화.)
const connKustPath = `${ROOT}/platform/data-conn/prod/kustomization.yaml`;
if (existsSync(connKustPath)) {
  const connKust = parseYaml(readFileSync(connKustPath, "utf8")) ?? {};
  const connEntries: string[] = (connKust.resources ?? [])
    .map((r: any) => String(r))
    .filter((r: string) => /^(db|cache)-.+-conn\.sealed\.yaml$/.test(r) && !r.endsWith("-ro-conn.sealed.yaml"));
  const referenced = new Set<string>();
  for (const a of appDirs) {
    const values = parseYaml(readFileSync(`${appsRoot}/${a}/deploy/prod/values.yaml`, "utf8")) ?? {};
    for (const e of values.envFrom ?? []) {
      const n = e?.secretRef?.name;
      if (n) referenced.add(String(n));
    }
  }
  for (const entry of connEntries) {
    const handle = entry.replace(/\.sealed\.yaml$/, "");
    if (!referenced.has(handle))
      add("unreferenced-conn", handle,
        "data-conn 등록 conn인데 어느 apps/*/values.yaml envFrom도 참조하지 않음 — 앱이 DB/캐시 없이 배포 중일 수 있음(#211 클래스, 정보성)");
  }
}

const blocking = findings.filter((f) => BLOCKING.has(f.type));
// alerting: 텔레그램 페이지 대상 = report-only 제외 전 finding. blocking ⊆ alerting ⊆ count(불변식).
const alerting = findings.filter((f) => !REPORT_ONLY.has(f.type));
console.log(JSON.stringify({ findings, count: findings.length, blocking: blocking.length, alerting: alerting.length }, null, 2));
if (STRICT && findings.length > 0) process.exit(1);
if (CI && blocking.length > 0) {
  console.error(`audit-orphans: 배포 정합 위반 ${blocking.length}건 — ${blocking.map((f) => `${f.type}:${f.subject}`).join(", ")}`);
  process.exit(1);
}
