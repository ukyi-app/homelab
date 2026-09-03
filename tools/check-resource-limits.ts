// 상주 워크로드(Deployment/DaemonSet/StatefulSet) main 컨테이너 자원 가드 — cpu·memory request +
// memory limit 필수(OR policy/memory-limit-allowlist.txt 명시 allowlist) + GOMEMLIMIT ≤ memory limit×0.95(B2).
// (cpu limit은 비요구: CFS quota 유휴 throttling 회피 — 의도적 생략이 SRE 권장. initContainer 비대상.)
// CNPG CR도 스캔한다: kind:Cluster는 컨테이너 개념이 없어 spec.resources를 pseudo-container 'postgres'로
// (allowlist 키 Cluster/<name>/postgres), kind:Pooler는 spec.template.spec.containers[](pgbouncer)로 검사한다.
// 구 scripts/check-resource-limits.sh(bash+yq+python3 3언어)를 bun/TS 단일로 이관.
// 원격-helm 벤더(platform/*/prod/charts/)·barman-plugin은 스캔 밖. make verify가 호출, bats가 행동 검증.
import { existsSync, readFileSync } from "node:fs";
import { parseFlags } from "./lib/cli.ts";
import { walkManifests } from "./lib/repo-walk.ts";
import { guardMain, takeFloors } from "./lib/scan-floor.ts";

let f: Record<string, string | boolean>;
let floors: Map<string, number>;
try {
  const taken = takeFloors(process.argv.slice(2));
  floors = taken.floors;
  f = parseFlags(taken.rest, { value: ["--repo-root", "--exempt-max"], bool: [] });
} catch (e) { console.error(`${e instanceof Error ? e.message : String(e)}\n허용: --repo-root · --exempt-max <n> · --floor check-resource-limits=<n>`); process.exit(2); }
const ROOT = typeof f["--repo-root"] === "string" ? (f["--repo-root"] as string) : ".";

const KINDS = new Set(["Deployment", "DaemonSet", "StatefulSet", "Pooler", "Cluster", "ObjectStore"]);
// spec.template.spec.containers[] 경로를 쓰는 kind(Pooler = CNPG pgbouncer). Cluster는 별도(spec.resources).
const CONTAINER_KINDS = new Set(["Deployment", "DaemonSet", "StatefulSet", "Pooler"]);
// ⚠️ KINDS와 **반드시 함께** 넓힌다. 이 정규식이 파일 단위 프리필터라(:enumerate의 첫 줄),
// KINDS에만 kind를 더하면 그 파일은 아예 열리지 않고 count도 늘지 않는다 — 게이트가 0건을
// 검사하고 초록을 낸다(「열거 붕괴 → vacuous green」). 2026-09-01 ObjectStore 추가 시 실측 확인.
const KIND_RE = /^kind:[ \t]*(Deployment|DaemonSet|StatefulSet|Pooler|Cluster|ObjectStore)\b/m;
// 열거 붕괴 바닥값. 2026-09-03 실측 스캔 21건 → **18**(3건 철거를 견딘다). 래칫 아님 —
// 도메인이 줄지 않는 한 손댈 일이 없다. ⚠️ 초판 값 10은 실 도메인의 절반이라, 21건 중
// 11건이 조용히 사라져도 초록이었다(호출부 Makefile:78,216·ci.yaml에 `--floor` 오버라이드가
// 0건이라 이 상수가 곧 유효 바닥값이다). 픽스처는 자기 크기를 `_seed_ok`로 맞춘다.
const MIN_SCAN = 18;
const ALLOW = "policy/memory-limit-allowlist.txt";

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

// 열거는 공유 워커의 `platform-manifests` 스코프가 소유한다 — 제외 어휘와 tracked 열거가 전부
// 그 안에 있다(제외 목록은 스코프 정의가 SSOT — 여기 복창하지 않는다). 아래 MIN_SCAN은
// **워크로드 kind 매치 이후**의 바닥값이라 성격이 다르다(소비자 소유). 워커의 throw는
// guardMain이 fail-loud로 접는다 — raw 스택이 나가면 게이트 출력 규약이 깨진다.
const viol: string[] = [];

// 자원 블록 1개(컨테이너 또는 Cluster spec.resources) 검사 — cpu·memory request + memory limit 필수,
// cpu limit 비요구. env가 있으면 GOMEMLIMIT ≤ limit×0.95도 검사(Cluster는 Go 워크로드가 아니라 env 미전달).
function checkBlock(
  kind: string, name: string, container: string, resources: any, env: any[] | undefined, rel: string,
): void {
  const requests = resources?.requests ?? {};
  const limits = resources?.limits ?? {};
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

// 실행 순서(전 도메인 열거 → 전 floor 판정 → SCAN 일괄 방출 → 검사 → 종료코드)는 guardMain이
// 구조로 소유한다 — 콜사이트가 순서를 손으로 맞추던 시절의 드리프트 클래스가 표현 불가능해진다.
guardMain({
  floors,
  domains: [{
    scan: "check-resource-limits",
    min: MIN_SCAN,
    floorHint: "grep 셀렉터 회귀 — platform 재배치/kind 들여쓰기?",
    enumerate: () => {
      let count = 0;
      for (const { path: rel, text, docs } of walkManifests("platform-manifests", ROOT)) {
        if (!KIND_RE.test(text)) continue;
        count++;
        for (const doc of docs) {
          // throw로 알린다 — 커널이 `FAIL: <scan>: 열거 실패`로 접어 마커 없이 죽는다(enumerate 안의
          // 직접 exit는 커널의 순서 보장 밖에서 죽는 경로를 되살린다).
          if (doc.errors.length) throw new Error(`YAML 파싱 실패: ${rel}: ${doc.errors[0].message}`);
          const o = doc.toJS() as any;
          if (!o || typeof o !== "object" || !KINDS.has(o.kind)) continue;
          const name = o.metadata?.name ?? "?";
          if (o.kind === "Cluster") {
            // CNPG Cluster: 컨테이너 없음 — spec.resources를 pseudo-container 'postgres'로 검사(GOMEMLIMIT 무관).
            checkBlock(o.kind, name, "postgres", o.spec?.resources, undefined, rel);
          } else if (o.kind === "ObjectStore") {
            // barman-plugin ObjectStore: Cluster.spec.plugins[]가 주입하는 **네이티브 사이드카**의 자원을
            // 여기서 선언한다(Cluster CR에는 그 필드가 없다). pseudo-container 'plugin-barman-cloud'.
            checkBlock(o.kind, name, "plugin-barman-cloud", o.spec?.instanceSidecarConfiguration?.resources, undefined, rel);
          } else if (CONTAINER_KINDS.has(o.kind)) {
            // Deployment/DaemonSet/StatefulSet/Pooler: spec.template.spec.containers[]
            const containers = o.spec?.template?.spec?.containers ?? [];
            if (o.kind === "Pooler" && containers.length === 0) {
              // template 미지정 Pooler = pgbouncer 자원 unlimited → fail-loud(자원 블록 통째 삭제 우회 차단).
              checkBlock(o.kind, name, "pgbouncer", undefined, undefined, rel);
            }
            for (const c of containers) checkBlock(o.kind, name, c.name, c.resources, c.env, rel);
          }
        }
      }
      return count;
    },
  }],
  output: "stdout",
  check: () => viol,
  report: (v) => {
    console.log("FAIL: cpu·memory request 또는 memory limit 없는 상주 워크로드 main 컨테이너 — 선언 후 (memory는) 원장 행 동반, 또는 " + ALLOW + "에 이유와 함께 등재:");
    for (const x of v) console.log("  " + x);
  },
  ok: (counts) => console.log(`check-resource-limits OK (${counts[0]} 워크로드 매니페스트 스캔, cpu·memory request + memory limit 위반 0)`),
});
