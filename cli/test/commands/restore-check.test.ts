import { describe, expect, test } from "bun:test";
import { expectPlanReadOnly, kubectlRule, runCli, type Rule } from "../harness";
import cmd from "../../src/commands/restore-check";
import { dbWorld, runIn } from "../fixtures/restore-db-world/world";

const notFound = { code: 1, stderr: 'Error from server (NotFound): x "y" not found\n' };
const recent = () => new Date(Date.now() - 3600_000).toISOString();

function planRules(): Rule[] {
  const pg = {
    spec: { imageName: `ghcr.io/cloudnative-pg/postgresql:18.6@sha256:${"a".repeat(64)}`, storage: { size: "8Gi" }, plugins: [{ name: "barman-cloud.cloudnative-pg.io", parameters: { serverName: "pg-20261023" } }] },
    status: { conditions: [{ type: "ContinuousArchiving", status: "True" }] },
  };
  return [
    kubectlRule(["-n", "database", "get", "clusters.postgresql.cnpg.io", "pg", "-o", "json"], { stdout: JSON.stringify(pg) }),
    kubectlRule(["-n", "database", "get", "backups.postgresql.cnpg.io", "-o", "json"], { stdout: JSON.stringify({ items: [{ spec: { cluster: { name: "pg" } }, status: { phase: "completed", stoppedAt: recent() } }] }) }),
    kubectlRule(["-n", "database", "get", "configmaps", "restore-check", "-o", "json"], notFound),
    kubectlRule(["-n", "database", "get", "databases.postgresql.cnpg.io", "-o", "json"], { stdout: JSON.stringify({ items: [{ spec: { cluster: { name: "pg" }, name: "probe" } }] }) }),
  ];
}

describe("db restore-check: plan(PATH 스텁)", () => {
  test("plan은 쓰기 0건", async () => {
    const r = await runCli(["db", "restore-check", "--json"], planRules());
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.status).toBe("pending");
    expect(r.json.steps.map((s: { id: string }) => s.id)).toEqual(["backups", "lock", "tmp", "contents", "cleanup"]);
  });
});

function checkWorld() {
  const w = dbWorld("probe");
  w.obj("backup", "database", "b1")!.status.stoppedAt = recent();
  w.put("database", "database", "probe2", { spec: { cluster: { name: "pg" }, name: "probe2" } });
  w.tmpDbs = new Set(["probe", "probe2"]);
  return w;
}

describe("db restore-check: 흐름(가짜 세계)", () => {
  test("임시 클러스터 → DB 확인 → 정리, 기록까지 지운다. 공유 Cluster pg에는 쓰지 않는다", async () => {
    const w = checkWorld();
    const r = await runIn(w, cmd, "apply", {});
    expect(r.status).toBe("done");
    expect(w.records.size).toBe(0);
    expect([...w.objects.keys()].filter((k) => k.startsWith("cluster/database/pg-restore-"))).toEqual([]);
    expect(w.writes.some((x) => /DROP|recreate|restoreMain|dumpToR2/.test(x))).toBe(false);
  });

  test("임시 클러스터가 Ready가 아니면 실패하고 기록·클러스터를 남긴다. 고친 뒤 같은 실행을 잇는다", async () => {
    const w = checkWorld();
    w.tmpReady = false;
    const r = await runIn(w, cmd, "apply", {});
    expect(r.status).toBe("failed");
    expect(r.steps.find((s) => s.id === "cleanup")!.result).toBe("not-run");
    expect(w.records.size).toBe(1);
    const run = w.records.get("database/restore-check")!.run;
    w.tmpReady = true;
    w.writes = [];
    const again = await runIn(w, cmd, "apply", {});
    expect(again.status).toBe("done");
    // 같은 실행의 임시 클러스터를 다시 만들지 않는다
    expect(w.writes).not.toContain("pg createTmpCluster");
    expect(w.runObjects(run)).toEqual([]);
  });

  test("DB 하나가 임시 클러스터에 없으면 실패(정리하지 않는다)", async () => {
    const w = checkWorld();
    w.tmpDbs = new Set(["probe"]);
    const r = await runIn(w, cmd, "apply", {});
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("probe2");
    expect(w.records.size).toBe(1);
  });

  test("base backup이 26시간보다 오래됐으면 시작하지 않는다", async () => {
    const w = checkWorld();
    w.obj("backup", "database", "b1")!.status.stoppedAt = "2026-01-01T00:00:00Z";
    const r = await runIn(w, cmd, "apply", {});
    expect(r.status).toBe("failed");
    expect(w.writes).toEqual([]);
  });
});
