// 상주 워크로드(Deployment/DaemonSet/StatefulSet) main 컨테이너 자원 가드 — cpu·memory request +
// memory limit 필수(OR policy/memory-limit-allowlist.txt 명시 allowlist) + GOMEMLIMIT ≤ memory limit×0.95(B2).
// (cpu limit은 비요구: CFS quota 유휴 throttling 회피 — 의도적 생략이 SRE 권장. initContainer 비대상.)
// CNPG CR도 스캔한다: kind:Cluster는 컨테이너 개념이 없어 spec.resources를 pseudo-container 'postgres'로
// (allowlist 키 Cluster/<name>/postgres), kind:Pooler는 spec.template.spec.containers[](pgbouncer)로 검사한다.
// 구 scripts/check-resource-limits.sh(bash+yq+python3 3언어)를 bun/TS 단일로 이관.
// 원격-helm 벤더(platform/*/prod/charts/)·barman-plugin은 스캔 밖. make verify가 호출, bats가 행동 검증.
//
// ── 두 스코프: platform(GitOps) + substrate(k3s-bootstrap) ────────────────────────────────────
// `platform-manifests` 하나만 보던 시절, `infra/k3s-bootstrap/storage`가 적용하는 상주 워크로드
// (local-path-provisioner Deployment 2개 — 라이브의 **모든 PV 데이터 경로**)는 이 가드·ArgoCD·
// 원장 셋 다 밖이었다: 두 `resources:` 블록을 통째로 지워도 전 게이트가 초록이었고, 원장 행은
// 주석 한 줄로만 지켜지는 **수기 계상**이었다(감사 2라운드 critic-A).
// 이 가드만 두 스코프를 합쳐 열거한다 — 스코프 확장이 아니라 **소비자 확장**이다. 다른 소비처
// (image-pins·image-ownership·disk-caps)의 분모는 불변이다(각 가드의 SCAN 건수로 실증).
//
// ── substrate는 원장 행과 **기계 대조**된다 ─────────────────────────────────────────────────
// substrate 워크로드는 ArgoCD가 관리하지 않아(`app.kubernetes.io/instance` 라벨 없음) 드리프트를
// 잡아 줄 selfHeal도 없다. 그래서 "선언이 원장과 같은가"를 여기서 기계로 진다: substrate 스코프의
// namespace별 memory 합 == 그 namespace를 쓰는 원장 행들의 합. 양방향이다 — 매니페스트를 올려도,
// 원장 행을 지워도 red다.
//
// ── platform 행도 이제 정적 귀속 + 커버리지 파생으로 기계 대조된다(감사 6라운드 티켓 62) ──
// 티켓 26 착지 시점엔 "platform 행은 여전히 수기 계상"이었다 — namespace가 원장 행 키인데 정적
// 스캔 21개 중 13개가 `metadata.namespace`를 안 쓰고(kustomization `namespace:`가 렌더에서 주입),
// 3개는 helm 렌더에만 존재하고(traefik·sealed-secrets·tailscale), 3개는 `chart:` Application이라
// kustomize 우주 밖(argocd·cert-manager·cnpg-operator)이었기 때문이다. 렌더 없이(권고안 C — 기각된
// 후보는 전수 렌더 리컨실러·행 단위 렌더 bats, `.scratch/audit-2026-09/design-ledger-platform-rows.md`§6)
// 두 규칙만 더해 그중 6개 namespace를 기계 대조로 옮긴다:
//   F1 namespace 귀속(`deriveNamespace`) — `metadata.namespace`가 없으면 그 파일을 **소유한 배포
//     루트 kustomization의 namespace:**로 귀속한다. 중첩 base는 루트까지 상승 — kustomize의
//     namespace transformer가 항상 최상위 값으로 덮어쓰는 실제 동작과 같다(가장 바깥에서 발견한
//     값이 이긴다 — 조상 kustomization을 계속 climb하며 매번 갱신). 루트를 못 찾으면 위반
//     (fail-closed — substrate의 "namespace 미선언 = 귀속 불가"와 같은 극성, 티켓 26).
//   F2 커버리지 파생(`deriveExcludedNamespaces`, 로스터 아님) — 그 namespace를 목적지로 갖는
//     배포 루트 중 (a) `HelmChartInflationGenerator` 생성기를 가진 것이 있거나 (b) `platform/argocd`
//     아래 `chart:` Application의 destination이면 **정적으로 불완전**이라 대조에서 제외하고
//     사유를 출력한다(gateway/tailscale/sealed-secrets = (a), argocd/cert-manager/cnpg-system = (b)).
//     둘 다 아닌 namespace만 "완전"해 등호 대조 대상이다(실측 6: cache·database·edge·files·
//     homepage·observability). 제외 목록은 손으로 유지하지 않는다 — 매 실행이 스캔에서 다시
//     파생한다(F2가 매번 다시 계산 — 캐시·수기 갱신 없음).
import { existsSync, readFileSync } from "node:fs";
import { dirname } from "node:path";
import { parseFlags } from "./lib/cli.ts";
import { parseLedgerRows } from "./lib/ledger-totals.ts";
import { walkManifests } from "./lib/repo-walk.ts";
import { guardMain, takeFloors } from "./lib/scan-floor.ts";

let f: Record<string, string | boolean>;
let floors: Map<string, number>;
try {
  const taken = takeFloors(process.argv.slice(2));
  floors = taken.floors;
  f = parseFlags(taken.rest, { value: ["--repo-root", "--exempt-max"], bool: [] });
} catch (e) { console.error(`${e instanceof Error ? e.message : String(e)}\n허용: --repo-root · --exempt-max <n> · --floor check-resource-limits[:substrate|:ledger]=<n>`); process.exit(2); }
const ROOT = typeof f["--repo-root"] === "string" ? (f["--repo-root"] as string) : ".";

const KINDS = new Set(["Deployment", "DaemonSet", "StatefulSet", "Pooler", "Cluster", "ObjectStore"]);
// spec.template.spec.containers[] 경로를 쓰는 kind(Pooler = CNPG pgbouncer). Cluster는 별도(spec.resources).
const CONTAINER_KINDS = new Set(["Deployment", "DaemonSet", "StatefulSet", "Pooler"]);
// ⚠️ 로스터 축(KINDS 파생)과 표기 축(값 앞 따옴표·들여쓰기 등)은 별개다(감사 6라운드 grep-c-4,
// docs/traps-detail.md 「파일 프리필터를 함께 넓히지 않으면 kind 추가가 vacuous green으로 착지한다」).
// `kind: "Deployment"`처럼 값에 따옴표를 두른 표기는 유효 YAML이고 kubectl·kustomize·ArgoCD가
// 한 줄 스칼라와 동일하게 적용하는데, 앵커된 리터럴 대조(`^kind:[ \t]*(Deployment|…)`)는 값 앞의
// `"`/`'`에서 매치가 끊긴다 — 그 표기의 파일은 프리필터에서 통째로 빠지고, 안에 어떤 자원 위반이
// 있어도 평가되지 않는다(실측 2026-09-05: `kind: "Deployment"` + resources 삭제 → SCAN 21→20 rc=0,
// MIN_SCAN=18이 그 -1을 덮는다). 따옴표 하나를 문자 클래스로 닫아도 계열 전체(들여쓰기·flow 매핑·
// `!!str` 태그)가 남으므로, 프리필터는 **kind-무관 fast path**로 낮추고(그 파일을 열지조차 못하는
// 상태만 막는다) 실제 판정은 파싱 결과(:below `KINDS.has(o.kind)`)에 맡긴다 — 그 대조는 이미
// 표기에 무관하다(YAML 파서가 따옴표를 벗긴 값을 준다).
const KIND_RE = /^[ \t]*kind:/m;
// 열거 붕괴 바닥값. 2026-09-03 실측 스캔 21건 → **18**(3건 철거를 견딘다). 래칫 아님 —
// 도메인이 줄지 않는 한 손댈 일이 없다. ⚠️ 초판 값 10은 실 도메인의 절반이라, 21건 중
// 11건이 조용히 사라져도 초록이었다(호출부 Makefile:78,216·ci.yaml에 `--floor` 오버라이드가
// 0건이라 이 상수가 곧 유효 바닥값이다). 픽스처는 자기 크기를 `_seed_ok`로 맞춘다.
const MIN_SCAN = 18;
// substrate 스코프의 열거 붕괴 바닥값. 2026-09-03 실측 1건(local-path-provisioner.yaml — 나머지
// 두 파일은 StorageClass라 KIND_RE 밖이다). **0으로 두면 안 된다**: 이 스코프가 0건이면 아래 원장
// 대조가 좌변 없이 vacuous해지고, 대응 원장 행은 아무도 안 보는 채로 남는다(그 상태가 이 착지 전
// 현실이었다). 픽스처는 자기 크기를 `--floor substrate=<n>`으로 명시한다(프로덕션 호출은 floor-free
// — ci-parity가 gate 스텝·`make -n ci` 양쪽에서 그것을 강제한다).
const MIN_SUBSTRATE_SCAN = 1;
// F2 커버리지 파생 붕괴 바닥값. 2026-09-04 실측 6 ns(cache·database·edge·files·homepage·
// observability). 0이면 등호 대조가 vacuous해진다(모든 namespace가 "제외"로 파생돼 아무것도
// 안 재고도 초록) — 티켓 26이 substrate에 세운 것과 같은 판정(MIN_SUBSTRATE_SCAN 주석 참조).
// 픽스처는 helm 생성기 마커로 자기 namespace를 제외 처리해 커버리지 0을 만들고
// `--floor check-resource-limits:ledger=0`으로 명시한다(다른 도메인과 같은 관례).
const MIN_LEDGER_SCAN = 6;
const ALLOW = "policy/memory-limit-allowlist.txt";
const LEDGER = "docs/memory-ledger.md";
// 원장 대조 위반의 접두 — report가 실패 클래스를 갈라 보고하는 키다(같은 목록에 섞이면
// "request가 없다"는 머리말 아래에 "합이 다르다"가 실려 진단이 어긋난다). substrate·platform은
// 서로 다른 스코프·다른 위반 문구를 쓰므로 접두도 나눈다 — 하나로 합치면 platform 위반이
// "substrate 워크로드 선언과..." 머리말 아래 실려 오귀속된다.
const SUBSTRATE_LEDGER_VIOL = "substrate 원장: ";
const PLATFORM_LEDGER_VIOL = "platform 원장: ";
const MIB = 2 ** 20;

// GOMEMLIMIT/limit 바이트 파서(구 python to_bytes 이식).
function toBytes(v: string): number | null {
  const m = /^\s*(\d+(?:\.\d+)?)\s*([A-Za-z]*)\s*$/.exec(String(v));
  if (!m) return null;
  const u: Record<string, number> = {
    "": 1, B: 1, Ki: 2 ** 10, Mi: 2 ** 20, Gi: 2 ** 30, Ti: 2 ** 40,
    KiB: 2 ** 10, MiB: 2 ** 20, GiB: 2 ** 30, TiB: 2 ** 40,
    k: 1e3, K: 1e3, M: 1e6, G: 1e9, T: 1e12,
  };
  return m[2] in u ? Number(m[1]) * u[m[2]] : null;
}

// 면제 목록의 **증인**. 형제 둘(check-image-pins.sh:67-83 · check-alert-rules.ts의 ALLOWLIST)은
// 이미 "사유 없는 줄은 거부"를 강제하는데, 정작 blast radius가 가장 큰 이 목록에만 그 규율이
// 없었다 — 한 줄 추가가 곧 상주 워크로드의 memory limit 면제인데 그 줄의 근거를 재는 것이 0이었고,
// 강제 면제가 몇 건까지 늘어도 되는지(상한)도 없었다. 선례: `scripts/check-bats-accounting.sh`의
// `EXCL_MAX`(제외 목록 상한 — "정당하면 같은 PR에서 상한을 올려라").
// 현 강제 면제 0건. 늘리려면 **같은 PR에서** 이 상수를 올려라(그 diff가 곧 리뷰 지점이다).
// `--exempt-max`는 **픽스처 전용** 오버라이드다(자기 크기를 명시하는 관례 — `--floor credential-expiry=1` 선례).
// ⚠️ `Number("abc")`는 NaN이고 `n > NaN`은 항상 false라 상한이 조용히 꺼진다(레포 등재 함정) — 정수만 받는다.
const EXEMPT_MAX = (() => {
  const raw = f["--exempt-max"];
  if (typeof raw !== "string") return 0;
  if (!/^\d+$/.test(raw)) { console.error(`ERROR: --exempt-max는 음이 아닌 정수여야 한다(받은 값: '${raw}')`); process.exit(2); }
  return Number(raw);
})();
const allowPath = `${ROOT}/${ALLOW}`;
const allowRaw = existsSync(allowPath) ? readFileSync(allowPath, "utf8").split("\n") : [];
const allowBad: string[] = [];
const allowEntries: string[] = [];
for (let i = 0; i < allowRaw.length; i++) {
  const line = allowRaw[i];
  const key = line.split("#", 1)[0].trim();
  if (!key) continue; // 순수 주석·공백 — 문서 전용
  // 사유 강제: 인라인 `# 사유` 또는 **직전 줄**의 `#` 주석(check-image-pins.sh:68과 같은 규약).
  const inline = line.includes("#") && line.slice(line.indexOf("#") + 1).trim().length > 0;
  const prev = i > 0 ? allowRaw[i - 1].trim() : "";
  const above = prev.startsWith("#") && prev.replace(/^#+/, "").trim().length > 0;
  if (!inline && !above) allowBad.push(`${ALLOW}:${i + 1} '${key}' — 사유 주석(# ...) 필요(인라인 또는 직전 줄)`);
  allowEntries.push(key);
}
if (allowBad.length > 0) {
  console.error("ERROR: 무근거 면제는 금지다 — 면제 줄은 왜 그 워크로드가 limit 없이 사는지를 적어야 한다:");
  for (const b of allowBad) console.error("  " + b);
  process.exit(2);
}
if (allowEntries.length > EXEMPT_MAX) {
  console.error(`ERROR: ${ALLOW}: 강제 면제 ${allowEntries.length}건 > 상한 ${EXEMPT_MAX} — 게이트에서 상주 워크로드가 빠졌다.`);
  console.error(`  정당한 면제라면 이 상한(tools/check-resource-limits.ts의 EXEMPT_MAX 상수)을 **같은 PR에서** 올려라.`);
  process.exit(2);
}
const allowed = new Set(allowEntries);

// 열거는 공유 워커의 `platform-manifests`·`substrate-manifests` 스코프가 소유한다 — 제외 어휘와
// tracked 열거가 전부 그 안에 있다(제외 목록은 스코프 정의가 SSOT — 여기 복창하지 않는다).
// 아래 MIN_SCAN/MIN_SUBSTRATE_SCAN은 **워크로드 kind 매치 이후**의 바닥값이라 성격이 다르다
// (소비자 소유). 워커의 throw는 guardMain이 fail-loud로 접는다 — raw 스택이 나가면 게이트 출력
// 규약이 깨진다.
const viol: string[] = [];
// substrate namespace → 매니페스트가 **선언한** memory 합(바이트). 원장 대조의 좌변이다.
const substrateNs = new Map<string, { req: number; limit: number }>();
// platform namespace → 매니페스트가 선언(또는 F1이 귀속)한 memory 합(바이트). F2 커버리지
// 파생이 이 중 "완전한" namespace만 골라 원장과 대조한다.
const platformNs = new Map<string, { req: number; limit: number }>();
// F2가 채운다(namespace → 제외 사유). guardMain의 ledger 도메인 enumerate가 열거보다 먼저
// 실행되어 check() 시점엔 이미 채워져 있다(가드 실행 순서: 전 도메인 열거 → floor → 검사).
let excludedNs = new Map<string, string>();

// Mi 표시 — 원장이 Mi 정수 단위라 대조 진단도 같은 단위로 낸다(정수가 아니면 소수를 남긴다:
// "왜 안 맞는가"의 답이 반올림에 먹히면 진단이 아니라 수수께끼가 된다).
function mi(bytes: number): string {
  const v = bytes / MIB;
  return Number.isInteger(v) ? String(v) : String(Math.round(v * 100) / 100);
}

// namespace 합산 — 값 부재는 0으로 싣는다(필수 검사가 이미 그 자리를 물고, 합에서 0이면 원장과
// 어긋나 두 번째 증인이 된다). 파싱 불가 단위는 조용히 0으로 삼키지 않고 위반으로 낸다.
// `target`·`violPrefix`는 호출자(substrate/platform)가 스코프별 맵·위반 접두를 골라 넘긴다 —
// 두 스코프가 같은 tally 로직을 공유하되 서로의 맵·문구를 오염시키지 않는다.
function tally(
  target: Map<string, { req: number; limit: number }>, violPrefix: string,
  ns: string, weight: number, resources: any, key: string, rel: string,
): void {
  const one = (raw: unknown, field: string): number => {
    if (raw == null) return 0;
    const b = toBytes(String(raw));
    if (b == null) { viol.push(`${violPrefix}${key} [${field} '${String(raw)}' 단위 파싱 불가]  (${rel})`); return 0; }
    return b;
  };
  const acc = target.get(ns) ?? { req: 0, limit: 0 };
  acc.req += weight * one(resources?.requests?.memory, "requests.memory");
  acc.limit += weight * one(resources?.limits?.memory, "limits.memory");
  target.set(ns, acc);
}

// 자원 블록 1개(컨테이너 또는 Cluster spec.resources) 검사 — cpu·memory request + memory limit 필수,
// cpu limit 비요구. env가 있으면 GOMEMLIMIT ≤ limit×0.95도 검사(Cluster는 Go 워크로드가 아니라 env 미전달).
// `tallyNs`가 있으면(= substrate·platform 두 스코프 모두) 같은 블록을 원장 대조용으로도 합산한다 —
// 검사와 합산이 같은 자리를 읽어야 "검사는 하는데 회계엔 안 실리는" 세 번째 상태가 표현 불가능해진다.
function checkBlock(
  kind: string, name: string, container: string, resources: any, env: any[] | undefined, rel: string,
  tallyNs?: string, weight = 1,
  tallyTarget?: Map<string, { req: number; limit: number }>, tallyViolPrefix?: string,
): void {
  const requests = resources?.requests ?? {};
  const limits = resources?.limits ?? {};
  if (tallyNs !== undefined && tallyTarget !== undefined) {
    tally(tallyTarget, tallyViolPrefix!, tallyNs, weight, resources, `${kind}/${name}/${container}`, rel);
  }
  // GOMEMLIMIT ≤ limit×0.95 (right-size 시 GOMEMLIMIT 미동반 갱신 → GC 소프트리밋이 cgroup limit
  // 위로 올라가 OOMKill 직행. vmalert 드리프트가 이 검사로 자동 포착 — 원장이 못 보는 2차 축).
  let gomem: string | undefined;
  for (const e of env ?? []) if (e && typeof e === "object" && e.name === "GOMEMLIMIT") gomem = e.value;
  if (gomem && limits.memory != null) {
    const gb = toBytes(gomem), lb = toBytes(limits.memory);
    if (gb != null && lb != null && gb > lb * 0.95) {
      viol.push(`${kind}/${name}/${container} [GOMEMLIMIT ${gomem} > limit×0.95 (${limits.memory})]  (${rel})`);
    }
  }
  const missing: string[] = [];
  if (requests.cpu == null) missing.push("requests.cpu");
  if (requests.memory == null) missing.push("requests.memory");
  if (limits.memory == null) missing.push("limits.memory");
  if (!missing.length) return;
  const key = `${kind}/${name}/${container}`;
  if (!allowed.has(key)) viol.push(`${key} [missing: ${missing.join(",")}]  (${rel})`);
}

// F1: 워크로드가 `metadata.namespace`를 안 쓰면, 그 파일을 **소유한 배포 루트 kustomization의
// namespace:**를 찾는다. `rel`의 디렉토리에서 시작해 `platform/` 바로 아래까지 조상 디렉토리를
// 전부 훑고, `kustomization.yaml`이 있으면 그 `namespace:`로 `found`를 **매번 덮어쓴다** — 가장
// 바깥(최상위)에서 찾은 값이 최종값이 된다. 이는 손으로 고른 것이 아니라 kustomize 자신의 동작과
// 같다: 중첩 base가 자기 namespace를 선언해도, 그 base를 참조하는 상위 kustomization이 자기
// namespace transformer를 다시 적용해 덮어쓴다(`platform/cache/prod/trip-mate`가 이 하위이고
// `platform/cnpg/prod/databases`는 상하위 값이 우연히 같아 구별되지 않는다 — 둘 다 실측 확인).
// 루트를 못 찾으면(어떤 조상에도 `namespace:`가 없으면) undefined — 콜사이트가 위반으로 낸다.
function deriveNamespace(rel: string, root: string): string | undefined {
  let dir = dirname(rel);
  let found: string | undefined;
  while (dir === "platform" || dir.startsWith("platform/")) {
    const kpath = `${root}/${dir}/kustomization.yaml`;
    if (existsSync(kpath)) {
      // 감사 12라운드 77 reg-a3-tools-infra-2 — 값-앵커가 인용 표기(`namespace: "files"`)에
      // 눈멀었었다(형제 관용구: tools/check-image-ownership.ts:356 kind:\s*["']?Application["']?).
      const m = /^namespace:[ \t]*["']?([a-z0-9-]+)/m.exec(readFileSync(kpath, "utf8"));
      if (m) found = m[1];
    }
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return found;
}

// 스코프 하나를 열거한다 — 판정은 두 스코프가 동일하고, 다른 것은 namespace 해소 방식과 tally
// 대상뿐이다. `nsMode`가 없으면(레거시 호출 없음, 항상 지정) namespace를 안 본다.
// - "substrate": `metadata.namespace` 미선언 = 즉시 위반(귀속 불가 — 파일 자신이 유일한 소스).
// - "platform": `metadata.namespace` 미선언이면 F1(`deriveNamespace`)로 배포 루트에서 귀속을
//   시도한다. 그래도 못 찾으면 위반(fail-closed) — 티켓 26 substrate와 같은 극성.
function enumerateScope(scope: string, nsMode: "substrate" | "platform"): number {
  const target = nsMode === "substrate" ? substrateNs : platformNs;
  const violPrefix = nsMode === "substrate" ? SUBSTRATE_LEDGER_VIOL : PLATFORM_LEDGER_VIOL;
  let count = 0;
  for (const { path: rel, text, docs } of walkManifests(scope, ROOT)) {
    // fast path — 파일에 `kind:` 토큰 자체가 없으면 파싱을 건너뛴다(성능 전용, kind 값은 안 본다).
    if (!KIND_RE.test(text)) continue;
    // ⚠️ SCAN 건수는 이 fast path가 아니라 **파싱된 kind**에서 파생한다(:below `KINDS.has(o.kind)`가
    // 처음 성립할 때 파일당 1회) — 그래야 값의 표기(따옴표·들여쓰기 등)에 건수가 무관해진다.
    let counted = false;
    for (const doc of docs) {
      // throw로 알린다 — 커널이 `FAIL: <scan>: 열거 실패`로 접어 마커 없이 죽는다(enumerate 안의
      // 직접 exit는 커널의 순서 보장 밖에서 죽는 경로를 되살린다). fast path가 kind-무관이 되면서
      // 이 throw는 이제 스코프 안의 `kind:` 문자열을 가진 파일 전부에 적용된다(fail-closed 방향 —
      // 실측 2026-09-05: 현 트리 파싱 에러 0건, 런타임 무변화).
      if (doc.errors.length) throw new Error(`YAML 파싱 실패: ${rel}: ${doc.errors[0].message}`);
      const o = doc.toJS() as any;
      if (!o || typeof o !== "object" || !KINDS.has(o.kind)) continue;
      if (!counted) { count++; counted = true; }
      const name = o.metadata?.name ?? "?";
      // namespace는 원장 행의 두 번째 열이다 — 미선언이면 어느 행에도 귀속되지 않으므로
      // (라이브에선 `default`로 떨어진다) 대조 자체가 성립하지 않는다. 즉시 위반으로 낸다.
      let ns: string | undefined = typeof o.metadata?.namespace === "string" ? o.metadata.namespace : "";
      if (!ns && nsMode === "platform") ns = deriveNamespace(rel, ROOT) ?? "";
      if (!ns) {
        const detail = nsMode === "platform" ? "이 파일도, 소유 배포 루트 kustomization도 namespace를 선언하지 않음 — " : "";
        viol.push(`${violPrefix}${o.kind}/${name} [metadata.namespace 미선언 — ${detail}원장 행에 귀속 불가]  (${rel})`);
        ns = undefined;
      }
      // 워크로드 하나가 여러 파드로 상주하면 노드가 무는 것도 그만큼이다 — 원장 행은 namespace
      // 총량이므로 replicas를 곱한다(미선언 = 1, k8s 기본값).
      const weight = typeof o.spec?.replicas === "number" ? o.spec.replicas : 1;
      if (o.kind === "Cluster") {
        // CNPG Cluster: 컨테이너 없음 — spec.resources를 pseudo-container 'postgres'로 검사(GOMEMLIMIT 무관).
        checkBlock(o.kind, name, "postgres", o.spec?.resources, undefined, rel, ns, weight, target, violPrefix);
      } else if (o.kind === "ObjectStore") {
        // barman-plugin ObjectStore: Cluster.spec.plugins[]가 주입하는 **네이티브 사이드카**의 자원을
        // 여기서 선언한다(Cluster CR에는 그 필드가 없다). pseudo-container 'plugin-barman-cloud'.
        checkBlock(o.kind, name, "plugin-barman-cloud", o.spec?.instanceSidecarConfiguration?.resources, undefined, rel, ns, weight, target, violPrefix);
      } else if (CONTAINER_KINDS.has(o.kind)) {
        // Deployment/DaemonSet/StatefulSet/Pooler: spec.template.spec.containers[]
        const containers = o.spec?.template?.spec?.containers ?? [];
        if (o.kind === "Pooler" && containers.length === 0) {
          // template 미지정 Pooler = pgbouncer 자원 unlimited → fail-loud(자원 블록 통째 삭제 우회 차단).
          checkBlock(o.kind, name, "pgbouncer", undefined, undefined, rel, ns, weight, target, violPrefix);
        }
        for (const c of containers) checkBlock(o.kind, name, c.name, c.resources, c.env, rel, ns, weight, target, violPrefix);
      }
    }
  }
  return count;
}

// F2: 커버리지 파생 — 어떤 namespace가 정적으로 「완전」한가(손 로스터 아님, 매 실행이 다시
// 스캔해서 파생한다). platform-manifests 스코프 전체를 다시 훑어(prefilter 없음 — 여기서 찾는
// kind는 KIND_RE의 워크로드 목록 밖이다) 두 신호를 모은다:
// ① `kind: HelmChartInflationGenerator` 문서의 `namespace:` — 그 helm 렌더가 꽂는 namespace는
//    정적 스캔이 못 보는 Deployment(traefik·tailscale-operator·sealed-secrets)를 낳는다.
// ② `kind: Application`(ArgoCD)에서 `spec.source.chart`/`spec.sources[].chart`가 있으면
//    `spec.destination.namespace` — 원격 helm 차트를 렌더하는 Application(argocd·cert-manager·
//    cnpg-operator)의 목적지는 kustomize 우주 밖이다.
// 두 신호 중 하나라도 걸리면 그 namespace는 제외(사유 기록). 아무 것도 안 걸리면 "완전" —
// `reconcilePlatformLedger`가 원장과 등호 대조한다.
function deriveExcludedNamespaces(root: string): Map<string, string> {
  const out = new Map<string, string>();
  for (const { docs } of walkManifests("platform-manifests", root)) {
    for (const doc of docs) {
      if (doc.errors.length) continue; // 파싱 실패는 위 enumerateScope의 fail-loud가 이미 잡는다
      const o = doc.toJS() as any;
      if (!o || typeof o !== "object") continue;
      if (o.kind === "HelmChartInflationGenerator" && typeof o.namespace === "string") {
        if (!out.has(o.namespace)) out.set(o.namespace, "helm 생성기 배포 루트(HelmChartInflationGenerator)");
      } else if (o.kind === "Application" && typeof o.spec?.destination?.namespace === "string") {
        const srcs: any[] = Array.isArray(o.spec?.sources) ? o.spec.sources : (o.spec?.source ? [o.spec.source] : []);
        if (srcs.some((s) => s && typeof s.chart === "string")) {
          if (!out.has(o.spec.destination.namespace)) out.set(o.spec.destination.namespace, "chart: Application destination(원격 helm 렌더)");
        }
      }
    }
  }
  return out;
}

// substrate ↔ 원장 기계 대조. 좌변은 위 합산(namespace별 memory 합), 우변은 그 namespace를 쓰는
// 원장 행들의 합이다(namespace는 행 키가 아니다 — observability·gateway처럼 한 namespace에 행이
// 여럿인 경우가 실재하므로 **합**으로 받는다).
// 좌변이 비면 대조는 vacuous인데, 그 상태는 substrate 도메인의 바닥값이 이미 막는다(0건이면
// floor에서 죽어 여기 도달하지 않는다).
function reconcileSubstrateLedger(): string[] {
  const out: string[] = [];
  if (substrateNs.size === 0) return out;
  let rows: { name: string; env: string; reqMi: number; limitMi: number }[];
  try {
    rows = parseLedgerRows(readFileSync(`${ROOT}/${LEDGER}`, "utf8"));
  } catch (e) {
    out.push(`${SUBSTRATE_LEDGER_VIOL}${LEDGER} 읽기 실패(${e instanceof Error ? e.message : String(e)}) — substrate 워크로드가 있는데 원장을 못 읽으면 대조 불가(fail-closed)`);
    return out;
  }
  for (const ns of [...substrateNs.keys()].sort()) {
    const got = substrateNs.get(ns)!;
    const mine = rows.filter((r) => r.env === ns);
    const decl = `선언 req ${mi(got.req)}Mi · limit ${mi(got.limit)}Mi`;
    if (mine.length === 0) {
      out.push(`${SUBSTRATE_LEDGER_VIOL}namespace '${ns}'의 원장 행이 0건 — substrate 워크로드가 예산 밖이다(${decl}). ${LEDGER}에 행을 추가하고 합계 프로즈를 갱신하라.`);
      continue;
    }
    const wantReq = mine.reduce((a, r) => a + r.reqMi, 0);
    const wantLimit = mine.reduce((a, r) => a + r.limitMi, 0);
    if (got.req !== wantReq * MIB || got.limit !== wantLimit * MIB) {
      out.push(
        `${SUBSTRATE_LEDGER_VIOL}namespace '${ns}': 매니페스트 ${decl} ≠ 원장 행 ${mine.map((r) => r.name).join("+")} (req ${wantReq}Mi · limit ${wantLimit}Mi) — 한쪽만 고쳤다.`,
      );
    }
  }
  return out;
}

// F2가 파생한 커버리지로 platform ↔ 원장을 대조한다 — substrate와 같은 등호(namespace별 memory
// 합 == 그 namespace 원장 행들의 합)이되, **제외된 namespace는 건너뛴다**(등호 대조 대상이 아니라
// 「대조 밖」이라는 판정 자체가 F2의 산출물이다). 완전한(비-제외) namespace가 0건이면 대조할 것이
// 없으므로 원장을 읽지도 않는다(substrate의 같은 조기 반환과 동형 — 무관한 픽스처가 원장 부재로
// 인해 platform 위반을 내면 안 된다).
function reconcilePlatformLedger(): string[] {
  const out: string[] = [];
  const covered = [...platformNs.keys()].filter((ns) => !excludedNs.has(ns)).sort();
  if (covered.length === 0) return out;
  let rows: { name: string; env: string; reqMi: number; limitMi: number }[];
  try {
    rows = parseLedgerRows(readFileSync(`${ROOT}/${LEDGER}`, "utf8"));
  } catch (e) {
    out.push(`${PLATFORM_LEDGER_VIOL}${LEDGER} 읽기 실패(${e instanceof Error ? e.message : String(e)}) — 커버리지 파생상 완전한 platform namespace가 있는데 원장을 못 읽으면 대조 불가(fail-closed)`);
    return out;
  }
  for (const ns of covered) {
    const got = platformNs.get(ns)!;
    const mine = rows.filter((r) => r.env === ns);
    const decl = `정적 귀속 합 req ${mi(got.req)}Mi · limit ${mi(got.limit)}Mi`;
    if (mine.length === 0) {
      out.push(`${PLATFORM_LEDGER_VIOL}namespace '${ns}'의 원장 행이 0건 — F2 커버리지 파생상 완전한(비-제외) namespace인데 원장에 없다(${decl}). ${LEDGER}에 행을 추가하고 합계 프로즈를 갱신하라.`);
      continue;
    }
    const wantReq = mine.reduce((a, r) => a + r.reqMi, 0);
    const wantLimit = mine.reduce((a, r) => a + r.limitMi, 0);
    if (got.req !== wantReq * MIB || got.limit !== wantLimit * MIB) {
      out.push(
        `${PLATFORM_LEDGER_VIOL}namespace '${ns}': ${decl} ≠ 원장 행 ${mine.map((r) => r.name).join("+")} (req ${wantReq}Mi · limit ${wantLimit}Mi) — 한쪽만 고쳤다.`,
      );
    }
  }
  return out;
}

// F2 커버리지의 기계 출력 — 대조에 포함된(완전) namespace와 제외된 namespace + 사유를 나열한다.
// 손으로 유지하는 로스터가 아니라 `platformNs`(관측된 namespace)와 `excludedNs`(F2 판정)의
// 합집합을 매번 다시 렌더한 것이다 — 티켓의 「제외 사유의 기계 출력」 요구가 이 함수다.
function platformCoverageLines(): string[] {
  const all = new Set<string>([...platformNs.keys(), ...excludedNs.keys()]);
  return [...all].sort().map((ns) => (
    excludedNs.has(ns) ? `${ns}: 제외 — ${excludedNs.get(ns)}` : `${ns}: 포함(원장과 등호 대조)`
  ));
}

// 실행 순서(전 도메인 열거 → 전 floor 판정 → SCAN 일괄 방출 → 검사 → 종료코드)는 guardMain이
// 구조로 소유한다 — 콜사이트가 순서를 손으로 맞추던 시절의 드리프트 클래스가 표현 불가능해진다.
guardMain({
  label: "check-resource-limits",
  floors,
  domains: [
    {
      scan: "check-resource-limits",
      min: MIN_SCAN,
      floorHint: "grep 셀렉터 회귀 — platform 재배치/kind 들여쓰기?",
      enumerate: () => enumerateScope("platform-manifests", "platform"),
    },
    {
      scan: "check-resource-limits:substrate",
      min: MIN_SUBSTRATE_SCAN,
      floorHint: "infra/k3s-bootstrap/storage 재배치 — 이 상태의 원장 대조는 좌변이 없어 무측정이다",
      enumerate: () => enumerateScope("substrate-manifests", "substrate"),
    },
    {
      scan: "check-resource-limits:ledger",
      min: MIN_LEDGER_SCAN,
      floorHint: "F2 커버리지 파생 붕괴 — helm 생성기·chart Application 스캔 회귀, 또는 배포 루트가 통째로 사라짐?",
      // 순서 의존: 위 "platform" 도메인이 이미 platformNs를 채운 뒤(guardMain은 domains를 배열
      // 순서대로 열거한다) 여기서 F2를 계산한다. 반환값은 "완전한(비-제외) namespace 수" —
      // 이게 0이면 등호 대조가 통째로 vacuous해지는 자리라 floor가 그 붕괴를 잡는다.
      enumerate: () => {
        excludedNs = deriveExcludedNamespaces(ROOT);
        let covered = 0;
        for (const ns of platformNs.keys()) if (!excludedNs.has(ns)) covered++;
        return covered;
      },
    },
  ],
  output: "stdout",
  check: () => [...viol, ...reconcileSubstrateLedger(), ...reconcilePlatformLedger()],
  report: (v) => {
    const substrateLedgerViol = v.filter((x) => x.startsWith(SUBSTRATE_LEDGER_VIOL));
    const platformLedgerViol = v.filter((x) => x.startsWith(PLATFORM_LEDGER_VIOL));
    const resViol = v.filter((x) => !x.startsWith(SUBSTRATE_LEDGER_VIOL) && !x.startsWith(PLATFORM_LEDGER_VIOL));
    if (resViol.length) {
      console.log("FAIL: cpu·memory request 또는 memory limit 없는 상주 워크로드 main 컨테이너 — 선언 후 (memory는) 원장 행 동반, 또는 " + ALLOW + "에 이유와 함께 등재:");
      for (const x of resViol) console.log("  " + x);
    }
    if (substrateLedgerViol.length) {
      console.log(`FAIL: substrate 워크로드 선언과 ${LEDGER} 행이 어긋난다 — 이 스코프는 ArgoCD 밖이라 원장이 유일한 예산 기록이다:`);
      for (const x of substrateLedgerViol) console.log("  " + x.slice(SUBSTRATE_LEDGER_VIOL.length));
    }
    if (platformLedgerViol.length) {
      console.log(`FAIL: platform 워크로드 선언과 ${LEDGER} 행이 어긋난다 — F2 커버리지 파생상 완전한(비-제외) namespace만 대조 대상이다:`);
      for (const x of platformLedgerViol) console.log("  " + x.slice(PLATFORM_LEDGER_VIOL.length));
    }
    console.log("check-resource-limits:ledger coverage —");
    for (const line of platformCoverageLines()) console.log("  " + line);
  },
  ok: (counts) => {
    console.log(`check-resource-limits OK (${counts[0]} + substrate ${counts[1]} 워크로드 매니페스트 스캔, cpu·memory request + memory limit 위반 0 · substrate 원장 대조 일치 · platform 커버리지 ${counts[2]}ns 원장 대조 일치)`);
    console.log("check-resource-limits:ledger coverage —");
    for (const line of platformCoverageLines()) console.log("  " + line);
  },
});
