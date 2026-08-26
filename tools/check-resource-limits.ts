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
  f = parseFlags(taken.rest, { value: ["--repo-root"], bool: [] });
} catch (e) { console.error(`${e instanceof Error ? e.message : String(e)}\n허용: --repo-root · --floor check-resource-limits=<n>`); process.exit(2); }
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
