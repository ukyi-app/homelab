import { describe, expect, test } from "bun:test";
import { expectPlanReadOnly, ghGet, kubectlRule, runCli, type Rule } from "../harness";
import { MAIN, R, homelab } from "../fixtures/app-add-world/world";

const items = (xs: unknown[]) => ({ stdout: JSON.stringify({ items: xs }) });
const dir = (names: string[]) => names.map((name) => ({ name, type: "dir" }));

function world(o: { apps: string[]; data: string[]; dbs: string[]; pvs?: unknown[]; pvcs?: unknown[]; pods?: unknown[]; restore?: boolean }): Rule[] {
  const restore = (kind: string) => kubectlRule(["get", kind, "-A", "-l", "homelab.ukyi.app/restore", "-o", "json"], items(o.restore && kind === "jobs.batch" ? [{ metadata: { namespace: "database", name: "restore-x-r2" } }] : []));
  return [
    ...homelab({}),
    ghGet(`${R}/contents/apps?ref=${MAIN}`, 200, dir(o.apps)),
    ghGet(`${R}/contents/data?ref=${MAIN}`, 200, dir(o.data)),
    kubectlRule(["-n", "database", "get", "databases.postgresql.cnpg.io", "-o", "json"], items(o.dbs.map((name) => ({ metadata: { name } })))),
    kubectlRule(["get", "persistentvolumes", "-A", "-o", "json"], items(o.pvs ?? [])),
    kubectlRule(["get", "pods", "-A", "-l", "homelab.ukyi.app/restore", "-o", "json"], items([])),
    kubectlRule(["get", "pods", "-A", "-o", "json"], items(o.pods ?? [])),
    kubectlRule(["get", "persistentvolumeclaims", "-A", "-l", "homelab.ukyi.app/restore", "-o", "json"], items([])),
    kubectlRule(["get", "persistentvolumeclaims", "-A", "-o", "json"], items(o.pvcs ?? [])),
    restore("clusters.postgresql.cnpg.io"),
    restore("jobs.batch"),
  ];
}

describe("data list", () => {
  test("시나리오 9: 앱을 지운 뒤 data·DB·안 쓰는 PVC·멈춘 복원 Job이 보인다, 쓰기 0건", async () => {
    const r = await runCli(["data", "list", "--json"], world({
      apps: ["homelab-probe"],
      data: ["homelab-probe", "memo"],
      dbs: ["homelab-probe", "memo", "old"],
      pvs: [{ metadata: { name: "pv-1" }, status: { phase: "Released" }, spec: { claimRef: { namespace: "app-old", name: "valkey-data" } } }, { metadata: { name: "pv-2" }, status: { phase: "Bound" } }],
      pvcs: [{ metadata: { namespace: "app-memo", name: "valkey-data" } }, { metadata: { namespace: "app-homelab-probe", name: "valkey-data" } }],
      pods: [{ metadata: { namespace: "app-homelab-probe" }, spec: { volumes: [{ persistentVolumeClaim: { claimName: "valkey-data" } }] } }],
      restore: true,
    }));
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    const d = Object.fromEntries(r.json.steps.map((s: any) => [s.id, s.detail]));
    expect(d["orphan-data"]).toBe("1개: memo");
    expect(d["orphan-database"]).toBe("1개: old");
    expect(d["released-pv"]).toBe("1개: pv-1(app-old/valkey-data)");
    expect(d["unmounted-pvc"]).toBe("1개: app-memo/valkey-data");
    expect(d["restore-objects"]).toBe("1개: job database/restore-x-r2");
    expect(r.json.status).toBe("same");
  });

  test("끝난 파드(Succeeded·Failed)의 옛 PVC 참조는 마운트로 세지 않는다, Terminating은 센다(#884 P2-6)", async () => {
    const pvcs = ["a", "b", "c"].map((name) => ({ metadata: { namespace: "app-memo", name } }));
    const pod = (claim: string, extra: object) => ({ metadata: { namespace: "app-memo", ...("deletionTimestamp" in extra ? extra : {}) }, spec: { volumes: [{ persistentVolumeClaim: { claimName: claim } }] }, status: "phase" in extra ? extra : { phase: "Running" } });
    const r = await runCli(["data", "list", "--json"], world({ apps: [], data: [], dbs: [], pvcs, pods: [pod("a", { phase: "Succeeded" }), pod("b", { phase: "Failed" }), pod("c", { deletionTimestamp: "2026-10-26T00:00:00Z" })] }));
    expect(r.code).toBe(0);
    expect(r.json.steps.find((s: any) => s.id === "unmounted-pvc").detail).toBe("2개: app-memo/a, app-memo/b");
  });

  test("없으면 없음, 읽기 실패는 exit 1", async () => {
    const ok = await runCli(["data", "list"], world({ apps: ["a"], data: ["a"], dbs: ["a"] }));
    expect(ok.code).toBe(0);
    expect(ok.stdout).toContain("없음");
    const bad = world({ apps: [], data: [], dbs: [] }).map((x) => (x.argv.includes("persistentvolumes") ? kubectlRule(["get", "persistentvolumes", "-A", "-o", "json"], { code: 1, stderr: "forbidden" }) : x));
    expect((await runCli(["data", "list"], bad)).code).toBe(1);
  });
});
