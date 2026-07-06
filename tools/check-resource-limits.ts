// 상주 워크로드(Deployment/DaemonSet/StatefulSet) main 컨테이너 자원 가드 — cpu·memory request +
// memory limit 필수(OR policy/memory-limit-allowlist.txt 명시 allowlist) + GOMEMLIMIT ≤ memory limit×0.95(B2).
// (cpu limit은 비요구: CFS quota 유휴 throttling 회피 — 의도적 생략이 SRE 권장. initContainer 비대상.)
// CNPG CR도 스캔한다: kind:Cluster는 컨테이너 개념이 없어 spec.resources를 pseudo-container 'postgres'로
// (allowlist 키 Cluster/<name>/postgres), kind:Pooler는 spec.template.spec.containers[](pgbouncer)로 검사한다.
// 구 scripts/check-resource-limits.sh(bash+yq+python3 3언어)를 bun/TS 단일로 이관 — 메시지·scan-floor 동일.
// 원격-helm 벤더(platform/*/prod/charts/)·barman-plugin은 스캔 밖. make verify가 호출, bats가 행동 검증.
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { parseAllDocuments } from "yaml";
import { parseFlags } from "./lib/cli.ts";

let f: Record<string, string | boolean>;
try { f = parseFlags(process.argv.slice(2), { value: ["--repo-root"], bool: [] }); }
catch (e) { console.error(`${e instanceof Error ? e.message : String(e)}\n허용: --repo-root`); process.exit(2); }
const ROOT = typeof f["--repo-root"] === "string" ? (f["--repo-root"] as string) : ".";

const KINDS = new Set(["Deployment", "DaemonSet", "StatefulSet", "Pooler", "Cluster"]);
// spec.template.spec.containers[] 경로를 쓰는 kind(Pooler = CNPG pgbouncer). Cluster는 별도(spec.resources).
const CONTAINER_KINDS = new Set(["Deployment", "DaemonSet", "StatefulSet", "Pooler"]);
const KIND_RE = /^kind:[ \t]*(Deployment|DaemonSet|StatefulSet|Pooler|Cluster)\b/m;
const MIN_SCAN = 10;
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

const allowPath = `${ROOT}/${ALLOW}`;
const allowed = new Set(
  existsSync(allowPath)
    ? readFileSync(allowPath, "utf8").split("\n").map((l) => l.split("#", 1)[0].trim()).filter(Boolean)
    : [],
);

const platformDir = `${ROOT}/platform`;
const files = (existsSync(platformDir) ? readdirSync(platformDir, { recursive: true }) : [])
  .map((p) => `platform/${String(p)}`)
  .filter((p) => p.endsWith(".yaml") && !p.includes("/charts/") && !p.includes("barman-plugin"))
  .sort();

let count = 0;
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

for (const rel of files) {
  const text = readFileSync(`${ROOT}/${rel}`, "utf8");
  if (!KIND_RE.test(text)) continue;
  count++;
  for (const doc of parseAllDocuments(text)) {
    if (doc.errors.length) { console.error(`FAIL: YAML 파싱 실패: ${rel}: ${doc.errors[0].message}`); process.exit(1); }
    const o = doc.toJS() as any;
    if (!o || typeof o !== "object" || !KINDS.has(o.kind)) continue;
    const name = o.metadata?.name ?? "?";
    if (o.kind === "Cluster") {
      // CNPG Cluster: 컨테이너 없음 — spec.resources를 pseudo-container 'postgres'로 검사(GOMEMLIMIT 무관).
      checkBlock(o.kind, name, "postgres", o.spec?.resources, undefined, rel);
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

// scan-floor: grep 셀렉터 붕괴로 매치가 0~소수면 아무것도 검사 안 하고 GREEN 되는 false-green 차단(fail-loud).
if (count < MIN_SCAN) {
  console.error(`FAIL: 스캔 대상 ${count}건 < ${MIN_SCAN} — grep 셀렉터 회귀 의심(platform 재배치/kind 들여쓰기?)`);
  process.exit(1);
}
if (viol.length) {
  console.log("FAIL: cpu·memory request 또는 memory limit 없는 상주 워크로드 main 컨테이너 — 선언 후 (memory는) 원장 행 동반, 또는 " + ALLOW + "에 이유와 함께 등재:");
  for (const v of viol) console.log("  " + v);
  process.exit(1);
}
console.log(`check-resource-limits OK (${count} 워크로드 매니페스트 스캔, cpu·memory request + memory limit 위반 0)`);
