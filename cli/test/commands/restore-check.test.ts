import { describe, expect, test } from "bun:test";
import { expectPlanReadOnly, kubectlRule, runCli, type Rule } from "../harness";
import cmd from "../../src/commands/restore-check";
import { RESTORE_CHECK_LAST, RESTORE_CHECK_PASS } from "../../src/core/kubectl";
import { dbWorld, runIn, type World } from "../fixtures/restore-db-world/world";

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
    expect(r.json.steps.map((s: { id: string }) => s.id)).toEqual(["previous", "backups", "lock", "tmp", "contents", "cleanup"]);
  });
});

const PG_UID = "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0";

function checkWorld() {
  const w = dbWorld("probe");
  w.obj("backup", "database", "b1")!.status.stoppedAt = recent();
  w.put("database", "database", "probe2", { spec: { cluster: { name: "pg" }, name: "probe2" } });
  w.tmpDbs = new Set(["probe", "probe2"]);
  const pg = w.obj("cluster", "database", "pg")!;
  pg.metadata = { ...pg.metadata, uid: PG_UID, annotations: { "argocd.argoproj.io/sync-options": "Prune=false,Delete=false" } };
  return w;
}

// Cluster pg의 결과 annotation(없으면 undefined). 원문과 해석을 함께.
const ann = (w: World, key: string): string | undefined => w.obj("cluster", "database", "pg")!.metadata.annotations?.[key];
const lastOf = (w: World) => JSON.parse(ann(w, RESTORE_CHECK_LAST)!);
const TARGET = /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/;

describe("db restore-check: 흐름(가짜 세계)", () => {
  test("임시 클러스터 → DB 확인 → 정리 → 통과 기록 → 실행 기록 지움. 공유 Cluster pg에는 결과 annotation 두 키만 쓴다", async () => {
    const w = checkWorld();
    const before = structuredClone(w.obj("cluster", "database", "pg")!);
    const t0 = Date.now();
    const r = await runIn(w, cmd, "apply", {});
    expect(r.status).toBe("done");
    expect(w.records.size).toBe(0);
    expect([...w.objects.keys()].filter((k) => k.startsWith("cluster/database/pg-restore-"))).toEqual([]);
    expect(w.writes.some((x) => /DROP|recreate|restoreMain|dumpToR2/.test(x))).toBe(false);
    // 순서: 정리(0개 확인) 뒤 통과 기록, 그 뒤 실행 기록 삭제
    const order = w.writes.filter((x) => /deleteRestoreObjects|restoreCheckMark|recordDelete/.test(x));
    expect(order).toEqual(["deleteRestoreObjects database", "restoreCheckMark pass", "recordDelete database/restore-check"]);
    // 되읽은 내용: last = pass, 키 순서 고정
    const raw = ann(w, RESTORE_CHECK_PASS)!;
    expect(ann(w, RESTORE_CHECK_LAST)).toBe(raw);
    const v = JSON.parse(raw);
    expect(Object.keys(v)).toEqual(["v", "run", "result", "at", "target", "server", "dbs", "cluster"]);
    expect(v).toMatchObject({ v: 1, result: "pass", server: "pg-20261023", dbs: 2, cluster: PG_UID });
    expect(v.run).toMatch(/^[a-z0-9]{1,22}$/);
    expect(v.target).toMatch(TARGET);
    expect(Date.parse(v.at)).toBeGreaterThanOrEqual(Math.floor(t0 / 1000) * 1000);
    expect(Date.parse(v.at) - Date.parse(v.target)).toBeGreaterThanOrEqual(9 * 60_000);
    // Cluster pg의 다른 필드는 그대로다(두 키를 빼면 처음과 같다)
    const after = structuredClone(w.obj("cluster", "database", "pg")!);
    delete after.metadata.annotations[RESTORE_CHECK_LAST];
    delete after.metadata.annotations[RESTORE_CHECK_PASS];
    expect(after).toEqual(before);
  });

  test("plan(가짜 세계)은 결과 기록을 포함해 쓰기 0건", async () => {
    const w = checkWorld();
    const r = await runIn(w, cmd, "plan", {});
    expect(r.status).toBe("pending");
    expect(w.writes).toEqual([]);
    expect(ann(w, RESTORE_CHECK_LAST)).toBeUndefined();
  });

  test("통과 기록이 실패하면 완료가 아니다: 실행 기록이 남고, 재실행이 복구 없이 정리·기록을 잇는다", async () => {
    const w = checkWorld();
    w.fail.set("restoreCheckMark pass", new Error("annotate 실패(주입)"));
    const r = await runIn(w, cmd, "apply", {});
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("annotate 실패");
    expect(w.records.size).toBe(1);
    expect(w.records.get("database/restore-check")!.data["ok.contents"]).toBe("1");
    expect(ann(w, RESTORE_CHECK_PASS)).toBeUndefined();
    const run = w.records.get("database/restore-check")!.run;
    w.writes = [];
    const again = await runIn(w, cmd, "apply", {});
    expect(again.status).toBe("done");
    expect(w.writes).not.toContain("pg createTmpCluster");
    expect(w.records.size).toBe(0);
    expect(JSON.parse(ann(w, RESTORE_CHECK_PASS)!).run).toBe(run);
  });

  test("DB 확인 실패는 last에 fail(missing_db)을 남기고 옛 pass는 그대로 둔다", async () => {
    const w = checkWorld();
    expect((await runIn(w, cmd, "apply", {})).status).toBe("done");
    const oldPass = ann(w, RESTORE_CHECK_PASS)!;
    w.tmpDbs = new Set(["probe"]);
    const r = await runIn(w, cmd, "apply", {});
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("probe2");
    expect(ann(w, RESTORE_CHECK_PASS)).toBe(oldPass);
    const last = lastOf(w);
    expect(Object.keys(last)).toEqual(["v", "run", "result", "at", "target", "server", "dbs", "cluster", "reason"]);
    expect(last).toMatchObject({ v: 1, result: "fail", reason: "missing_db", dbs: 2, cluster: PG_UID, run: w.records.get("database/restore-check")!.run });
    expect(w.writes.filter((x) => x.startsWith("restoreCheckMark"))).toEqual(["restoreCheckMark pass", "restoreCheckMark fail"]);
  });

  test("missing_db 뒤 --abort는 같은 실행의 실패 기록을 덮지 않는다. 객체 0개 확인·실행 기록 정리는 그대로", async () => {
    const w = checkWorld();
    w.tmpDbs = new Set(["probe"]);
    expect((await runIn(w, cmd, "apply", {})).status).toBe("failed");
    const run = w.records.get("database/restore-check")!.run;
    const failed = ann(w, RESTORE_CHECK_LAST)!;
    expect(JSON.parse(failed)).toMatchObject({ run, result: "fail", reason: "missing_db" });
    const plan = await runIn(w, cmd, "plan", {}, { abort: true });
    expect(plan.steps[0].detail).toContain("실패 기록은 그대로");
    w.writes = [];
    const a = await runIn(w, cmd, "apply", {}, { abort: true });
    expect(a.status).toBe("done");
    expect(w.writes).toEqual(["deleteRestoreObjects database", "recordDelete database/restore-check"]);
    expect(ann(w, RESTORE_CHECK_LAST)).toBe(failed);
    expect(w.records.size).toBe(0);
    expect(w.runObjects(run)).toEqual([]);
  });

  test("확인할 Database CR이 0개면 임시 클러스터를 만들지 않고 실패(no_db)로 남긴다. 남는 객체·실행 기록 없음", async () => {
    const w = checkWorld();
    for (const k of [...w.objects.keys()]) if (k.startsWith("database/")) w.objects.delete(k);
    const r = await runIn(w, cmd, "apply", {});
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("0개");
    expect(w.writes).not.toContain("pg createTmpCluster");
    expect(w.records.size).toBe(0);
    expect(lastOf(w)).toMatchObject({ result: "fail", reason: "no_db", dbs: 0, server: "pg-20261023" });
    expect(lastOf(w).target).toMatch(TARGET);
    expect(ann(w, RESTORE_CHECK_PASS)).toBeUndefined();
  });

  test("임시 클러스터 복구 뒤 Database CR이 사라졌어도 통과가 아니라 no_db 실패", async () => {
    const w = checkWorld();
    w.onGet = (kind, _ns, name) => {
      if (kind === "cluster" && name.startsWith("pg-restore-")) for (const k of [...w.objects.keys()]) if (k.startsWith("database/")) w.objects.delete(k);
    };
    const r = await runIn(w, cmd, "apply", {});
    expect(r.status).toBe("failed");
    expect(w.writes).toContain("pg createTmpCluster");
    expect(lastOf(w)).toMatchObject({ result: "fail", reason: "no_db", dbs: 0 });
    expect(ann(w, RESTORE_CHECK_PASS)).toBeUndefined();
  });

  test("실패 기록마저 실패하면 두 원인을 함께 보인다", async () => {
    const w = checkWorld();
    w.tmpDbs = new Set(["probe"]);
    w.fail.set("restoreCheckMark fail", new Error("annotate 실패(주입)"));
    const r = await runIn(w, cmd, "apply", {});
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("probe2");
    expect(r.error!.message).toContain("annotate 실패");
    expect(ann(w, RESTORE_CHECK_LAST)).toBeUndefined();
  });

  test("r1 P1-2: 임시 클러스터가 Ready가 아니면 남기고, 재실행은 그것을 다시 쓰지 않고 멈춘다. --abort 뒤 새 시험", async () => {
    const w = checkWorld();
    w.tmpReady = false;
    const r = await runIn(w, cmd, "apply", {});
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("--abort");
    expect(r.steps.find((s) => s.id === "cleanup")!.result).toBe("not-run");
    const run = w.records.get("database/restore-check")!.run;
    // 사람이 고쳤거나 다른 원본으로 바꾼 같은 이름의 Cluster가 Ready가 돼도 성공으로 보지 않는다
    w.tmpReady = true;
    const again = await runIn(w, cmd, "apply", {});
    expect(again.status).toBe("failed");
    expect(again.error!.message).toContain("다시 쓰지 않는다");
    expect(w.records.size).toBe(1);
    const a = await runIn(w, cmd, "apply", {}, { abort: true });
    expect(a.status).toBe("done");
    expect(w.records.size).toBe(0);
    expect(w.runObjects(run)).toEqual([]);
    // --abort는 last에 fail(aborted)을 남긴다. 확인 전이라 dbs 0, pass 키는 없다
    expect(lastOf(w)).toMatchObject({ run, result: "fail", reason: "aborted", dbs: 0, cluster: PG_UID });
    expect(ann(w, RESTORE_CHECK_PASS)).toBeUndefined();
    const fresh = await runIn(w, cmd, "apply", {});
    expect(fresh.status).toBe("done");
    expect(lastOf(w).result).toBe("pass");
  });

  test("--abort: 객체 0개 확인 뒤·실행 기록 삭제 전에 기록하고, 기록이 실패하면 실행 기록을 남긴다. 옛 pass는 그대로", async () => {
    const w = checkWorld();
    expect((await runIn(w, cmd, "apply", {})).status).toBe("done");
    const oldPass = ann(w, RESTORE_CHECK_PASS)!;
    w.tmpReady = false;
    expect((await runIn(w, cmd, "apply", {})).status).toBe("failed");
    const run = w.records.get("database/restore-check")!.run;
    w.fail.set("restoreCheckMark fail", new Error("annotate 실패(주입)"));
    w.writes = [];
    const a = await runIn(w, cmd, "apply", {}, { abort: true });
    expect(a.status).toBe("failed");
    expect(w.records.size).toBe(1);
    expect(w.runObjects(run)).toEqual([]);
    expect(lastOf(w).result).toBe("pass");
    w.writes = [];
    expect((await runIn(w, cmd, "apply", {}, { abort: true })).status).toBe("done");
    expect(w.writes).toEqual(["deleteRestoreObjects database", "restoreCheckMark fail", "recordDelete database/restore-check"]);
    expect(lastOf(w)).toMatchObject({ run, result: "fail", reason: "aborted" });
    expect(ann(w, RESTORE_CHECK_PASS)).toBe(oldPass);
  });

  test("--abort plan(기록 없음·있음)은 쓰기 0건", async () => {
    const w = checkWorld();
    expect((await runIn(w, cmd, "plan", {}, { abort: true })).status).toBe("same");
    w.tmpReady = false;
    await runIn(w, cmd, "apply", {});
    w.writes = [];
    expect((await runIn(w, cmd, "plan", {}, { abort: true })).status).toBe("pending");
    expect(w.writes).toEqual([]);
  });

  test("DB 하나가 임시 클러스터에 없으면 실패(정리하지 않는다)", async () => {
    const w = checkWorld();
    w.tmpDbs = new Set(["probe"]);
    const r = await runIn(w, cmd, "apply", {});
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("probe2");
    expect(w.records.size).toBe(1);
  });

  test("r2 P1-2: Ready 뒤 DB 확인에서 실패한 시험도 재실행은 그 Cluster를 다시 쓰지 않는다(바뀐 Cluster로 성공하지 않는다)", async () => {
    const w = checkWorld();
    w.tmpDbs = new Set(["probe"]);
    expect((await runIn(w, cmd, "apply", {})).status).toBe("failed");
    expect(w.records.get("database/restore-check")!.data["ok.tmp"]).toBe("1");
    // 사람이 같은 이름 Cluster를 다른 원본으로 바꾸고 DB 이름만 맞췄다
    w.tmpDbs = new Set(["probe", "probe2"]);
    w.writes = [];
    const again = await runIn(w, cmd, "apply", {});
    expect(again.status).toBe("failed");
    expect(again.error!.next).toContain("--abort");
    expect(w.writes).toEqual([]);
    expect(w.records.size).toBe(1);
    expect((await runIn(w, cmd, "apply", {}, { abort: true })).status).toBe("done");
    w.writes = [];
    expect((await runIn(w, cmd, "apply", {})).status).toBe("done");
    expect(w.writes).toContain("pg createTmpCluster");
  });

  test("확인까지 끝나고 정리만 실패한 시험은 다음 호출이 정리를 잇는다", async () => {
    const w = checkWorld();
    w.fail.set("deleteRestoreObjects database", new Error("delete 실패(주입)"));
    expect((await runIn(w, cmd, "apply", {})).status).toBe("failed");
    expect(w.records.get("database/restore-check")!.data["ok.contents"]).toBe("1");
    w.writes = [];
    const again = await runIn(w, cmd, "apply", {});
    expect(again.status).toBe("done");
    expect(w.writes).not.toContain("pg createTmpCluster");
    expect(w.records.size).toBe(0);
  });

  test("base backup이 26시간보다 오래됐으면 시작하지 않는다", async () => {
    const w = checkWorld();
    w.obj("backup", "database", "b1")!.status.stoppedAt = "2026-01-01T00:00:00Z";
    const r = await runIn(w, cmd, "apply", {});
    expect(r.status).toBe("failed");
    expect(w.writes).toEqual([]);
  });
});
