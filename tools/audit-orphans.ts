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
//   unwired-conn          : conn 봉인본이 디스크에 있는데 kustomization resources 미등록 — 렌더 제외(정보성; 역방향)
//   orphan-conn           : conn 등록인데 소스(Database CR/인스턴스 디렉토리) 부재 — teardown 잔재/부분 purge (정보성)
//   malformed-conn        : conn 형상인데 레이아웃 분류 불가(이름 정책 밖) — 손으로 쓴 불량 엔트리 (정보성)
//   stale-ledger-row      : prod 원장 행인데 apps/도 platform/도 없음
//   incomplete-purge      : tombstone state=purging 잔존 — 상태머신 중단 흔적
// conn/원장 명명 판정은 레이아웃 커널(lib/resource-layout.ts)을 소비한다 — 자체 정규식 유도는
// 명명 변경 시 조용히 어긋나는 관측 사각이었다(cli-deepening 심화 4).
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { appPaths, appRel } from "./lib/app-surface.ts";
import { parse as parseYaml } from "yaml";
import { surfaceHash } from "./lib/surface-hash.ts";
import { registryProjection } from "./lib/activation-marker.ts";
import { parseLedgerRows } from "./lib/ledger-totals.ts";
import { listUnits } from "./lib/repo-walk.ts";
import { LAYOUT_DIRS, TOMBSTONES_PATH, classifyArtifact, classifyLedgerRow, layoutFor } from "./lib/resource-layout.ts";
import { ScanError, assertFloorKeys, floorOf, scanFloor, takeFloors } from "./lib/scan-floor.ts";
import { typedFlags } from "./lib/cli.ts";

// 도메인 라벨 상수 — 선언(assertFloorKeys)과 조회(floorOf)가 같은 리터럴을 봐야 오타가 조용히
// 꺼진 바닥값이 되지 않는다(guardMain의 scan 필드가 겸하던 역할의 수동 등가물).
// ⚠️ 라벨은 **상수로만** 적는다. `scanFloor("<리터럴>"` · `scan: "<리터럴>"` 두 형태는
//    tests/gates/test_scan-floor.bats의 「정적 콜사이트 집합 == 런타임 방출 집합」 등식이 정적 쪽을
//    파생하는 모양인데, 이 도구는 stdout이 기계 판독 JSON이라 SCAN 마커를 한 줄도 낼 수 없다
//    (아래 「방출 규약」). 라벨을 그 형태로 적으면 정적 집합에만 들어가 그 등식이 red가 된다.
const FLOOR_REGISTRY = "audit-orphans:registry";
const FLOOR_APPS = "audit-orphans:apps";
const FLOOR_CACHES = "audit-orphans:caches";
const FLOOR_LEDGER = "audit-orphans:ledger";
const FLOOR_ROLES = "audit-orphans:roles";
const FLOOR_CONNS = "audit-orphans:conns";
const FLOOR_TOMBSTONES = "audit-orphans:tombstones";
// 선언 로스터 — assertFloorKeys(fail-closed)·USAGE·바닥값 루프가 **같은 배열**을 본다.
// 세 자리가 각자 목록을 들면 그중 하나가 조용히 뒤처진다("하드코딩 소비처 목록은 자기 자신에게만
// 정확하다" — AGENTS.md 함정).
const FLOOR_LABELS = [
  FLOOR_REGISTRY, FLOOR_APPS, FLOOR_CACHES, FLOOR_LEDGER, FLOOR_ROLES, FLOOR_CONNS, FLOOR_TOMBSTONES,
];

const USAGE = `audit-orphans — registry↔매니페스트↔원장 교차 드리프트 리포트(읽기 전용)
사용법: bun tools/audit-orphans.ts [--repo-root <dir>] [--ci] [--strict] [--floor <도메인>=<n>]
  --repo-root <dir>  레포 루트(기본 .)
  --ci               배포를 깨는 유형만 비-0 종료(orphan-dns/activation-exposure-drift/missing-activation) — PR 게이트용
  --strict           모든 드리프트 유형을 비-0 종료(수동 점검)
  --floor <도메인>=<n>  열거 붕괴 바닥값 오버라이드(반복 가능). 도메인: ${FLOOR_LABELS.map((l) => l.split(":").pop()).join(" · ")}
  --help, -h         이 도움말`;
if (process.argv.includes("--help") || process.argv.includes("-h")) { console.log(USAGE); process.exit(0); }

// 바닥값 오버라이드는 공용 어휘 `--floor <도메인>=<n>`뿐이다(kernel-followups 05 — 구 --min-registry
// 폐지, 자체 정수 검증·argv 파서 복제는 커널 parseFloor·takeFloors·typedFlags로 접혔다).
// guardMain은 쓰지 않는다 — 종료코드가 기본/--ci/--strict 3분기라 report(1)/ok(0) 이분법 밖이다
// (stdout JSON은 이유가 아니다: output:"none"이 그 용도다 — check-guard-authority 선례).
let flags;
let FLOORS: Map<string, number>;
try {
  const taken = takeFloors(process.argv.slice(2));
  FLOORS = taken.floors;
  assertFloorKeys(FLOORS, FLOOR_LABELS);
  // 미지 인자·플래그 값 삼킴(--repo-root --ci 류)은 typedFlags가 거부한다 — 종전 위치 검색
  // 파서는 오타·폐지 어휘를 조용히 무시했다(조용히 꺼진 바닥값 클래스).
  flags = typedFlags(taken.rest, { value: ["--repo-root"], bool: ["--ci", "--strict"] });
} catch (e) {
  console.error(`audit-orphans: ${e instanceof Error ? e.message : String(e)}`);
  process.exit(2);
}
const ROOT = flags.str("--repo-root", ".")!;
const STRICT = flags.bool("--strict");
// --ci: PR 게이트용 — 배포 정합/노출을 깨는 유형만 비-0 종료(빈 백엔드 DNS/미재검증 노출 드리프트).
// missing-registration·incomplete-purge·원장 드리프트는 정보/경고라 차단하지 않는다.
// (--strict는 전부 차단 — 수동 점검용.)
const CI = flags.bool("--ci");
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
// ⚠️ 「유일한」은 작성 시점(앱이 있던 체제)의 서술이다 — apps=0 체제에서 unreferenced-conn이 같은 클래스를
//    재개통했다. 그쪽은 상태 한정 억제라 이 집합이 아니라 아래 `reportOnly` 계산에 있다.
const REPORT_ONLY = new Set(["activation-surface-drift"]);

type RegRow = { name: string; active?: boolean; host?: string | null; public?: boolean };

const findings: { type: string; subject: string; detail: string }[] = [];
const add = (type: string, subject: string, detail: string) => findings.push({ type, subject, detail });
const readJson = (p: string, d: any): any => (existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : d);

// 레포 사실 수집
// ⚠️ registry는 **필수 읽기**다(create-app.ts:126과 같은 규율 — bare readFileSync). `readJson(…, [])`로
// 접으면 apps.json 부재/파싱 실패가 "행 0개"로 위장돼 BLOCKING 3종(orphan-dns · activation-exposure-drift ·
// missing-activation)이 전부 0건 평가되고 required check `gate`가 조용히 초록이 된다. 라이브 재현:
// 진짜 missing-activation 위반이 있는 상태에서 apps.json만 치우면 blocking 1→0 · rc 1→0(stderr 0줄).
// 레포 밖 cwd에서 기본 `--repo-root .`로 부르면(Makefile:102 · ci.yaml:72의 형태) 전 도메인이 0건이었다.
// ⚠️ 나머지 readJson 폴백 2곳(.tombstones.json · .activation 마커)은 **부재가 정상 상태**라 건드리지 않는다.
// 값 검증(빈 값·공백이 유효한 0으로 통과하던 자리 — 적대 검토 실측)은 커널 parseFloor가
// takeFloors 안에서 소유한다 — 이 파일의 검증 사본은 05에서 소멸했다.
const registryPath = `${ROOT}/infra/cloudflare/apps.json`;
let registry: RegRow[];
try {
  registry = JSON.parse(readFileSync(registryPath, "utf8"));
} catch (e) {
  console.error(`audit-orphans: registry 읽기 실패(${registryPath}) — 감사 불가: ${e instanceof Error ? e.message : String(e)}`);
  process.exit(1);
}
if (!Array.isArray(registry)) {
  console.error(`audit-orphans: registry(${registryPath})가 배열이 아니다 — 감사 불가`);
  process.exit(1);
}

// ── 일곱 도메인 열거 ─────────────────────────────────────────────────────────────
// **findings 수집보다 먼저** 전부 센다. 커널 독스트링(lib/scan-floor.ts)의 "바닥값과 신호가 한 몸인
// 것이 요점이다 — 둘을 떼어 놓으면 그 사이에 무엇이든 낄 수 있다"를 이 콜사이트에서 지키는 배치다.
// 종전에는 registry 비교와 stdout 출력 사이에 findings 수집 140줄이 끼어 있었고, 나머지 여섯
// 도메인은 바닥값도 신호도 없이 붕괴할 수 있었다(글롭·키 경로 변경 → 0건 검사 후 초록).
// 열거는 공유 워커의 `apps` 유닛 스코프가 소유한다. **의미론적 필터(values.yaml 실재)는 여기 남는다** —
// 스코프가 그걸 걸러버리면 check-app-deploy가 잡아야 할 "필수 산출물 부재"가 열거에서 사라진다
// (design-r1 R-1). 이 가드는 배포 가능한 앱만 보면 되므로 필터가 정당하다.
const appDirs = listUnits("apps", ROOT)
  .map((u) => u.name)
  .filter((a) => existsSync(appPaths(ROOT, a).values));
const cacheDirs = existsSync(`${ROOT}/${LAYOUT_DIRS.cacheProd}`)
  ? readdirSync(`${ROOT}/${LAYOUT_DIRS.cacheProd}`, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name)
  : [];
const ledgerRows = parseLedgerRows(
  existsSync(`${ROOT}/docs/memory-ledger.md`) ? readFileSync(`${ROOT}/docs/memory-ledger.md`, "utf8") : "",
);
const clusterPath = `${ROOT}/${LAYOUT_DIRS.cnpgProd}/cluster.yaml`;
const managedRoles: any[] = existsSync(clusterPath)
  ? ((parseYaml(readFileSync(clusterPath, "utf8")) ?? {})?.spec?.managed?.roles ?? [])
  : [];
const connKustPath = `${ROOT}/${LAYOUT_DIRS.dataConn}/kustomization.yaml`;
// connRaw — 필터 **앞**의 원본 resources(정방향 열거의 전체 도메인). 아래 역방향(디스크→kustomization)이
// wired 판정에 이 배열을 쓴다 — connEntries(필터 뒤)를 쓰면 conn 파일명 규약이 바뀌었을 때 정방향·
// 역방향이 **같은 정규식**을 공유해 함께 0으로 붕괴하고 무발화한다(원장 「열거 붕괴 → vacuous green」).
const connRaw: string[] = existsSync(connKustPath)
  ? ((parseYaml(readFileSync(connKustPath, "utf8")) ?? {}).resources ?? []).map((r: any) => String(r))
  : [];
// conn 형상만 이 절의 소관 — 필터 **뒤**를 센다. 도메인은 "검사 대상"이지 "파일에 적힌 줄"이 아니다.
const connEntries: string[] = connRaw.filter((r: string) => /-conn\.sealed\.yaml$/.test(r));
const tombs: Record<string, any> = readJson(`${ROOT}/${TOMBSTONES_PATH}`, {});
const tombEntries = Object.entries(tombs);

// 역방향(디스크 → kustomization) — 정방향(위)은 kustomization의 resources만 보므로, 등록 자체가
// 누락되면(멱등 헬퍼 실패·손 편집) 그 conn은 어느 열거에도 안 잡혀 0건 검사 후 초록이 된다.
// wired 판정은 connRaw(필터 전)로 해 정방향과 다른 파일 집합(*.sealed.yaml 전체)을 대조한다 —
// 필터를 양쪽에 같은 정규식으로 걸면 파일명 규약이 바뀌었을 때 둘 다 0으로 붕괴해 서로를 못 본다.
// BLOCKING에 넣지 않는다(정보성 — 부분 purge 중간 상태가 정당하게 이 모양을 만든다).
const connDir = `${ROOT}/${LAYOUT_DIRS.dataConn}`;
const wired = new Set(connRaw.map((r) => r.replace(/^\.\//, "")));
const diskConnFiles = existsSync(connDir)
  ? readdirSync(connDir).filter((f) => /\.sealed\.yaml$/.test(f)).sort()
  : [];
for (const f of diskConnFiles)
  if (!wired.has(f))
    add("unwired-conn", f, "봉인본이 디스크에 있는데 data-conn kustomization resources 미등록 — 렌더 제외(미배포·appset prune)");

// ── 바닥값 판정 ──────────────────────────────────────────────────────────────────
// 수치는 소비자가 소유한다(선례: check-image-pins=20 · check-alert-rules=30 · check-guard-authority=15).
// 래칫 아님 — 정당하게 줄어드는 변경에서는 같이 내리고, 그 조정이 diff에 보이는 것이 요점이다.
// **근거 있는 자리에만 양수를 둔다**(근거 없는 매직 넘버 금지). 0인 도메인도 목록에 남는 이유는
// 페이로드 신호(`scan`)를 내기 위해서다 — 바닥값이 0이어도 건수 자체는 관측된다.
const DOMAINS: { label: string; got: number; min: number; hint: string }[] = [
  // 기본 0 — 인-레포 배포 앱이 **0개**라 실 registry가 빈 배열이다(page #455 · trip-mate-api 철거).
  // 앱이 0개인 동안은 0행이 정당해 붕괴와 구별되지 않는다. 앱 온보딩 시 1로 되돌릴 것.
  // 바닥값이 실제로 작동함은 `--floor registry=1`을 명시해 부르는 test_audit-orphans.bats가 계속 증명한다.
  { label: FLOOR_REGISTRY, got: registry.length, min: 0, hint: "apps.json 행 붕괴 — 이 자리가 0건 검사 후 초록이 되던 곳이다(BLOCKING 3종이 전부 이 순회 안에 있다)." },
  // 기본 0 — registry와 같은 근거(인-레포 앱 0개). values.yaml 필터 뒤의 배포 가능 앱 수다.
  { label: FLOOR_APPS, got: appDirs.length, min: 0, hint: "apps/ 유닛 열거 붕괴(repo-walk 스코프·values.yaml 필터)." },
  // 기본 0 — 캐시 인스턴스는 첫 create-cache 전까지 정당하게 0이다.
  { label: FLOOR_CACHES, got: cacheDirs.length, min: 0, hint: "cache 인스턴스 디렉토리 열거 붕괴(LAYOUT_DIRS.cacheProd 경로 변경)." },
  // 기본 1 — docs/memory-ledger.md는 CI가 강제하는 예산 SSOT(AGENTS.md: limit 합계 ≤ 10240Mi)라
  // 구조적으로 항상 ≥1행이다. 0행은 "검사할 게 없다"가 아니라 파일 부재 또는 `<!-- ledger:row -->`
  // 포맷 드리프트이고, 그 상태에서 stale-ledger-row 검사가 통째로 vacuous해진다.
  { label: FLOOR_LEDGER, got: ledgerRows.length, min: 1, hint: "원장 행 파서(ledger-totals LEDGER_ROW_RE) 미매치 또는 docs/memory-ledger.md 부재." },
  // 기본 1 — cluster.yaml managed.roles에는 superuser 시드(ukkiee)가 구조적으로 상주한다. 0은
  // 파일 부재/키 경로(spec.managed.roles) 변경이고, 그때 dangling-role 검사가 vacuous해진다.
  { label: FLOOR_ROLES, got: managedRoles.length, min: 1, hint: "cluster.yaml 부재 또는 spec.managed.roles 키 경로 변경." },
  // 기본 0 — data-conn kustomization의 resources는 정당하게 빌 수 있다(그 파일 주석: "빈 resources여도
  // kustomize build는 성공해야 한다 — appset 발견 시점에 DB 0개 가능").
  { label: FLOOR_CONNS, got: connEntries.length, min: 0, hint: "data-conn kustomization resources 열거 붕괴 또는 conn 파일명 규약 변경." },
  // 기본 0 — tombstone 부재가 정상 상태다(purge를 한 번도 안 돌린 레포).
  { label: FLOOR_TOMBSTONES, got: tombEntries.length, min: 0, hint: ".tombstones.json 경로/포맷 변경." },
];
// 붕괴는 **모아서** 던진다 — 첫 도메인에서 죽으면 나머지 여섯의 상태를 한 번에 못 본다(guardMain ②와 동형).
// 커널은 종료하지 않는다(ScanError throw) — 종료코드는 콜사이트가 소유한다(3분기 유지).
const collapsed: string[] = [];
let collapseCode = 1;
for (const d of DOMAINS) {
  try {
    // quiet — 마커 억제는 출력 채널의 성질이지 판정의 성질이 아니다(커널 독스트링). 신호는 아래 페이로드가 낸다.
    scanFloor(d.label, d.got, floorOf(FLOORS, d.label, d.min), { quiet: true, hint: d.hint });
  } catch (e) {
    if (!(e instanceof ScanError)) throw e;   // 비-ScanError는 커널 자신의 결함 — 접으면 안 된다
    collapsed.push(e.message);
    if (e.exitCode > collapseCode) collapseCode = e.exitCode;   // 계약 파손(2)이 붕괴(1)보다 우선
  }
}
if (collapsed.length > 0) {
  console.error(`audit-orphans: 열거 붕괴 ${collapsed.length}건(scan-floor 바닥값) — 이 자리가 0건 검사 후 초록이 되던 곳이다`);
  for (const m of collapsed) console.error(`FAIL: ${m}`);
  process.exit(collapseCode);
}

// 1) registry ↔ 매니페스트
//   active:true orphan → orphan-dns(차단): dns.tf가 public&&active만 노출하므로 빈 백엔드 DNS가 실재.
//   active:false orphan → orphan-dns-inactive(정보, 비차단): DNS 미노출이라 수동 보류/철거 중이면 정상.
for (const r of registry) {
  if (!appDirs.includes(r.name)) {
    if (r.active)
      add("orphan-dns", r.name, `apps.json active:true 행인데 ${appRel(r.name).prod} 부재 — DNS가 빈 백엔드로 노출 중`);
    else
      add("orphan-dns-inactive", r.name, `apps.json active:false 행인데 ${appRel(r.name).prod} 부재 — DNS 미노출(수동 보류/철거 중 상태일 수 있음)`);
  }
}
for (const a of appDirs) {
  const values = parseYaml(readFileSync(appPaths(ROOT, a).values, "utf8")) ?? {};
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
  const markerPath = appPaths(ROOT, r.name).activation;
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
    add("activation-surface-drift", r.name, `activation 이후 ${appRel(r.name).dir} 표면 변경(정보성 — 런북 재검증 권장; 마커 ${String(marker.surfaceHash).slice(0, 12)} ≠ 현재 ${current.slice(0, 12)})`);
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
for (const r of ledgerRows) { // F7: 명명 필드(raw 인덱스 금지)
  const comp = r.name, ns = r.env;
  if (ns === "prod" && !appDirs.includes(comp) && !existsSync(`${ROOT}/platform/${comp}`))
    add("stale-ledger-row", comp, "원장 prod 행인데 apps/·platform/ 어디에도 실체 없음");
  if (ns === "cache") {
    const row = classifyLedgerRow(comp); // 커널 역방향 — cache-<name> 형상 밖이면 그 자체로 stale
    if (row === null || !cacheDirs.includes(row.name))
      add("stale-ledger-row", comp, "원장 cache 행인데 인스턴스 디렉토리 없음");
  }
}

// 3) 중단된 purge
for (const [k, v] of tombEntries)
  if ((v as any).state === "purging") add("incomplete-purge", k, "purge 상태머신이 중단됨 — drop/verify/cleanup 재개 필요");

// 4) dangling-role — cluster.yaml managed.roles 항목인데 passwordSecret sealed가 부재(정보성).
//    purge cleanup이 sealed/CR을 제거했지만 cluster.yaml role 제거 커밋이 빠진 상태를 잡는다
//    (incomplete-purge는 state=purging만 봐서 purge 완료 후 고아 role을 못 본다).
{
  const cnpgDir = `${ROOT}/${LAYOUT_DIRS.cnpgProd}`;
  for (const role of managedRoles) {
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
if (connEntries.length > 0) {
  const referenced = new Set<string>();
  for (const a of appDirs) {
    const values = parseYaml(readFileSync(appPaths(ROOT, a).values, "utf8")) ?? {};
    for (const e of values.envFrom ?? []) {
      const n = e?.secretRef?.name;
      if (n) referenced.add(String(n));
    }
  }
  for (const raw of connEntries) {
    const c = classifyArtifact(raw);
    if (c === null) {
      // 커널이 못 읽는 conn 형상 — 조용히 건너뛰면 손으로 쓴 불량 엔트리가 감사에서 사라진다
      // (형식 밖 = 산출물 아님으로 접는 관측 축소 금지 — 티켓 06 리뷰 이월).
      add("malformed-conn", raw, "conn 형상인데 레이아웃 분류 불가(이름 정책 밖) — 손으로 쓴 불량 엔트리 의심(정보성)");
      continue;
    }
    const layout = layoutFor(c.kind, c.name);
    const handle = c.role === "conn" ? layout.handles.rw.name : layout.handles.ro.name;
    // 미참조 검사는 rw conn만 — *-ro-conn은 모드2 디버깅 전용(의도적 미참조)이라 제외.
    if (c.role === "conn" && !referenced.has(handle))
      add("unreferenced-conn", handle,
        "data-conn 등록 conn인데 어느 apps/*/values.yaml envFrom도 참조하지 않음 — 앱이 DB/캐시 없이 배포 중일 수 있음(#211 클래스, 정보성)");
    // 소스 부재 — 정방향 열거로는 원리적으로 못 보던 고아(소스가 사라진 conn)를 역방향 분류가
    // 잡는다. **ro-conn도 검사한다** — purge 삼중이 conn→ro-conn 순으로 제거하므로 중단이 남기는
    // 것이 정확히 ro-conn 엔트리다(리뷰 지적: conn 한정이면 그 케이스가 무관측).
    const src = layout.kind === "db" ? `${ROOT}/${layout.paths.cr}` : `${ROOT}/${layout.paths.instanceDir}`;
    if (!existsSync(src))
      add("orphan-conn", handle,
        `conn 등록인데 소스(${layout.kind === "db" ? "Database CR" : "인스턴스 디렉토리"}) 부재 — teardown 잔재/부분 purge 의심(정보성)`);
  }
}

const blocking = findings.filter((f) => BLOCKING.has(f.type));
// 배포 가능 앱이 0개면 참조자 집합(envFrom)이 구조적으로 공집합이라 unreferenced-conn이 **전건 참**이다
// — 판별력 0인 판정을 매일 페이지하면 유일한 정보성 드리프트 채널이 학습된 무시로 죽는다. 그래서 이
// 체제에서만 report-only와 동급으로 접는다(findings/count에는 그대로 남겨 가시성 유지 = REPORT_ONLY와 같은 규율).
// ⚠️ 술어는 반드시 `appDirs.length === 0`이다. `referenced.size === 0`으로 쓰면 **앱이 있는데 envFrom을
//    통째로 빠뜨린 상태**까지 같이 묻는데, 그게 정확히 #211 그 병이라 이 판정이 존재하는 이유다.
// ⚠️ 한계: 앱이 1개라도 착지하면 남은 stale conn이 다시 매일 페이지한다. retain tombstone은 억제 경로가
//    아니므로(위 unreferenced-conn 로직이 tombs를 보지 않는다) tombstone 기반 일반화는 넣지 않는다.
const reportOnly = appDirs.length === 0 ? new Set([...REPORT_ONLY, "unreferenced-conn"]) : REPORT_ONLY;
// alerting: 텔레그램 페이지 대상 = report-only 제외 전 finding. blocking ⊆ alerting ⊆ count(불변식).
const alerting = findings.filter((f) => !reportOnly.has(f.type));
// ── 방출 규약 ────────────────────────────────────────────────────────────────────
// 이 도구는 `SCAN:` 마커를 **어느 모드에서도 내지 않는다**. stdout이 기계 판독 JSON이고
// (audit.yaml:52 `| tee` → jq · tools/tests/test_audit-orphans.bats·test_audit-dangling-role.bats의
// jq 단언 — `--ci` 출력도 jq가 읽는다) 마커 한 줄이 그 소비를 통째로 깬다. 그래서 위 바닥값 판정은
// quiet로 돌리고, 같은 정보를 페이로드 `scan`에 싣는다 — 형제 dns-drift-check.ts가 세운 관용구다
// ("stdout이 기계 판독 JSON이라 SCAN: 마커를 낼 수 없으므로 같은 정보를 페이로드 안에 싣는다").
// ⚠️ 그 형제의 **합계 결함은 복제하지 않는다**(`scanned: appHosts.length + reservedHosts.length`) —
//    합계는 작은 레인의 붕괴를 큰 레인이 덮는다. 여기서는 도메인별 건수를 각각 싣는다.
// ⚠️ 모드별 방출(`--ci`에서만 마커)도 기각했다: 로스터 등식(tests/gates/test_scan-floor.bats)은 무인자
//    실행만 관측하므로 그 마커는 어느 대조도 보지 못하고, 두 모드가 서로 다른 신호 채널을 갖게 된다.
const scan: Record<string, number> = {};
for (const d of DOMAINS) scan[d.label] = d.got;
console.log(JSON.stringify({ findings, count: findings.length, blocking: blocking.length, alerting: alerting.length, scan }, null, 2));
if (STRICT && findings.length > 0) process.exit(1);
if (CI && blocking.length > 0) {
  console.error(`audit-orphans: 배포 정합 위반 ${blocking.length}건 — ${blocking.map((f) => `${f.type}:${f.subject}`).join(", ")}`);
  process.exit(1);
}
