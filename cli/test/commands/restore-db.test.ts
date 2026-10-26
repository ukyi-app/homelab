import { describe, expect, test } from "bun:test";
import { expectPlanReadOnly, ghGet, kubectlRule, runCli, type Rule } from "../harness";
import cmd, { normalizeTo } from "../../src/commands/restore-db";
import { T1_INPUT, T1_NORMAL, World, dbWorld, runIn } from "../fixtures/restore-db-world/world";

const APP = "probe";
const NS = `app-${APP}`;
const APPS = `apps/${APP}/values.yaml`;
const LABEL = "homelab.ukyi.app/restore";
const notFound = { code: 1, stderr: 'Error from server (NotFound): x "y" not found\n' };
const contents = (path: string) => `repos/ukyi-app/homelab/contents/${path}?ref=main`;
const fileResp = (text: string) => ({ type: "file", encoding: "base64", content: Buffer.from(text).toString("base64") });
const items = (x: unknown[]) => ({ stdout: JSON.stringify({ items: x }) });

function planRules(): Rule[] {
  const pg = {
    spec: { imageName: `ghcr.io/cloudnative-pg/postgresql:18.6@sha256:${"a".repeat(64)}`, storage: { size: "8Gi" }, plugins: [{ name: "barman-cloud.cloudnative-pg.io", parameters: { serverName: "pg-20261023" } }] },
    status: { conditions: [{ type: "ContinuousArchiving", status: "True" }] },
  };
  return [
    ghGet(contents(`data/${APP}/values.yaml`), 200, fileResp("chartVersion: 1.0.1\npostgres: { enabled: true }\n")),
    ghGet(contents(APPS), 200, fileResp("chartVersion: 1.1.0\nport: 8080\nuses: { postgres: true }\n")),
    kubectlRule(["-n", "database", "get", "databases.postgresql.cnpg.io", APP, "-o", "json"], { stdout: JSON.stringify({ status: { applied: true } }) }),
    kubectlRule(["-n", NS, "get", "deployments.apps", APP, "-o", "json"], { stdout: JSON.stringify({ spec: { replicas: 1 } }) }),
    kubectlRule(["-n", NS, "get", "configmaps", "restore-pg", "-o", "json"], notFound),
    kubectlRule(["-n", "database", "get", "clusters.postgresql.cnpg.io", "pg", "-o", "json"], { stdout: JSON.stringify(pg) }),
    kubectlRule(["-n", "database", "get", "backups.postgresql.cnpg.io", "-o", "json"], items([{ spec: { cluster: { name: "pg" } }, status: { phase: "completed", stoppedAt: "2026-10-19T18:05:00Z" } }, { spec: { cluster: { name: "pg" } }, status: { phase: "completed", stoppedAt: "2026-10-20T18:05:00Z" } }])),
    kubectlRule(["-n", "database", "get", "objectstores.barmancloud.cnpg.io", "r2", "-o", "json"], { stdout: JSON.stringify({ status: { serverRecoveryWindow: { "pg-20261023": { firstRecoverabilityPoint: "2026-10-19T18:00:00Z" } } } }) }),
    ...["database", NS].flatMap((ns) => ["clusters.postgresql.cnpg.io", "jobs.batch", "persistentvolumeclaims", "pods"].map((r) => kubectlRule(["-n", ns, "get", r, "-l", LABEL, "-o", "json"], items([])))),
  ];
}

describe("db restore: 입력", () => {
  test("--to는 오프셋 필수, UTC로 정규화, 없는 날짜 거부", () => {
    expect(normalizeTo("2026-11-02T10:00:00+09:00")?.t1).toBe("2026-11-02 01:00:00+00");
    expect(normalizeTo("2026-11-02 10:00:00+09")?.t1).toBe("2026-11-02 01:00:00+00");
    expect(normalizeTo("2026-11-02T01:00:00Z")?.t1).toBe("2026-11-02 01:00:00+00");
    expect(normalizeTo("2026-02-30T01:00:00Z")).toBeNull();
    expect(normalizeTo("2026-11-02T10:00:00")).toBeNull();
    expect(normalizeTo("2026-11-02T25:00:00Z")).toBeNull();
    // r1 P2-5: 오프셋 분은 00~59, 시는 14까지
    expect(normalizeTo("2026-10-20T10:00:00+09:60")).toBeNull();
    expect(normalizeTo("2026-10-20T10:00:00+09:99")).toBeNull();
    expect(normalizeTo("2026-10-20T10:00:00+15:00")).toBeNull();
    expect(normalizeTo("2026-10-20T10:00:00-09:59")?.t1).toBe("2026-10-20 19:59:00+00");
  });

  test("사용법 오류는 64(아무것도 부르지 않는다)", async () => {
    for (const args of [["db", "restore", APP], ["db", "restore", APP, "--to", "2026-11-02T10:00:00"], ["db", "restore", APP, "--to", "2026-02-30T01:00:00Z"], ["db", "restore", APP, "--finish", "--to", T1_INPUT], ["db", "restore", APP, "--finish", "--abort"], ["db", "restore", APP, "--to", T1_INPUT, "--to", T1_INPUT], ["db", "restore", APP, "--to", "2026-10-20T10:00:00+09:60"]]) {
      const r = await runCli(args, []);
      expect(r.code).toBe(64);
      expectPlanReadOnly(r, { allowNoCalls: true });
      expect(r.calls).toEqual([]);
    }
  });
});

describe("db restore: plan(PATH 스텁)", () => {
  test("처음 plan은 쓰기 0건, 단계 순서를 보인다", async () => {
    const r = await runCli(["db", "restore", APP, "--to", T1_INPUT, "--json"], planRules());
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.status).toBe("pending");
    expect(r.json.steps.map((s: { id: string }) => s.id)).toEqual(["app", "target-time", "other-runs", "lock", "predump", "tmp", "auth", "list", "pr-suspend", "suspended", "db", "main", "acl", "verify", "cache-flush", "pr-resume", "running", "cleanup"]);
    expect(r.json.next).toBe(`homelab db restore ${APP} --to ${T1_INPUT} --apply`);
  });
});

// 앱 멈춤 PR을 병합하고 Argo CD가 replicas 0으로 만든 상태로
function suspendApplied(w: World) {
  w.merge(w.openPrs()[0].number);
  w.obj("deployment", NS, APP)!.spec.replicas = 0;
  w.obj("deployment", NS, APP)!.status = { observedGeneration: 2, replicas: 0 };
}

const dropped = (w: World) => w.writes.filter((x) => x.includes("DROP")).length;

describe("db restore: 흐름(가짜 세계)", () => {
  test("restore.md 2절 순서대로, PR마다 멈추고 이어 간다. 끝나면 모두 same, --finish가 잠금을 지운다", async () => {
    const w = dbWorld(APP, { cache: true });
    const r1 = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(r1.status).toBe("waiting");
    const rec = w.records.get(`${NS}/restore-pg`)!;
    expect(rec.data.to).toBe(T1_NORMAL);
    expect(rec.data.srv).toBe("pg-20261023");
    // 앱 멈춤을 기다리는 동안 1·2·4-1·4-2는 끝냈고 DB는 그대로다
    expect(["ok.predump", "ok.tmp", "ok.auth", "ok.list"].every((k) => rec.data[k] === "1")).toBe(true);
    expect(w.r2.size).toBe(1);
    expect(dropped(w)).toBe(0);
    expect(w.commits.get(w.refs.get(`cli/db-restore-${APP}`)!)!.files.get(APPS)).toContain("suspended: true");

    suspendApplied(w);
    const r2 = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(r2.status).toBe("waiting");
    expect(w.db).toBe("t1");
    expect(dropped(w)).toBe(1);
    expect(w.writes).toContain(`rolloutRestart ${NS}/${APP}-valkey`);
    expect(w.openPrs().map((p) => p.head)).toEqual([`cli/db-restore-resume-${APP}`]);

    w.merge(w.openPrs()[0].number);
    w.obj("deployment", NS, APP)!.spec.replicas = 1;
    w.obj("deployment", NS, APP)!.status = { observedGeneration: 3, replicas: 1, updatedReplicas: 1, readyReplicas: 1 };
    const r3 = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(r3.status).toBe("done");
    expect(r3.next).toBe(`homelab db restore ${APP} --finish`);
    expect(w.runObjects(rec.run)).toEqual([]);
    expect(w.records.size).toBe(1);

    w.writes = [];
    const again = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(again.status).toBe("same");
    expect(w.writes).toEqual([]);

    const fin = await runIn(w, cmd, "apply", { app: APP }, { finish: true });
    expect(fin.status).toBe("done");
    expect(w.records.size).toBe(0);
    expect((await runIn(w, cmd, "apply", { app: APP }, { finish: true })).status).toBe("same");
  });

  // 앱 멈춤까지 끝난 세계(DB 다시 만들기 바로 앞)
  async function readyToDrop(): Promise<World> {
    const w = dbWorld(APP);
    await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    suspendApplied(w);
    return w;
  }

  test("확인 실패면 DROP 0건: 되돌림 사본이 R2에 없다", async () => {
    const w = await readyToDrop();
    w.r2.clear();
    const r = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("되돌림 사본이 R2에 없다");
    expect(dropped(w)).toBe(0);
    expect(w.db).toBe("live");
  });

  test("확인 실패면 DROP 0건: 4-2 입력이 바뀌었다", async () => {
    const w = await readyToDrop();
    w.inputsValid = false;
    const r = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(r.status).toBe("failed");
    expect(dropped(w)).toBe(0);
  });

  test("확인 실패면 DROP 0건: 앞 표식(되돌림 사본)이 없다", async () => {
    const w = await readyToDrop();
    delete w.records.get(`${NS}/restore-pg`)!.data["ok.predump"];
    // predump는 db보다 앞이라 이 실행이 다시 확인한다(사본이 있으니 검증만). 사본 검증이 실패하면 db는 시작하지 않는다.
    w.fail.set("pg r2DumpReadable", new Error("rclone cat 실패(주입)"));
    const r = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(r.status).toBe("failed");
    expect(r.steps.find((s) => s.id === "db")!.result).toBe("not-run");
    expect(dropped(w)).toBe(0);
  });

  test("확인 실패면 DROP 0건: 앞 단계를 지난 뒤 그 표식이 사라졌다(need)", async () => {
    const w = await readyToDrop();
    // db 단계가 시작하며 자기 표식을 지우는 순간, 이미 지나간 되돌림 사본 표식도 사라진다(사람이 기록을 고친 경우)
    w.onUpdate = (set, data) => {
      if ("ok.db" in set && set["ok.db"] === null) delete data["ok.predump"];
    };
    const r = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("앞 단계(predump)");
    expect(dropped(w)).toBe(0);
  });

  test("확인 실패면 DROP 0건: 표식 뒤 앱이 다시 떴다", async () => {
    const w = await readyToDrop();
    // suspended 표식을 남긴 채(앞 실행) 다른 PR로 앱이 다시 뜸
    const rec = w.records.get(`${NS}/restore-pg`)!;
    rec.data["ok.suspended"] = "1";
    w.obj("deployment", NS, APP)!.spec.replicas = 1;
    const r = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("앱이 멈춰 있지 않다");
    expect(dropped(w)).toBe(0);
  });

  test("확인 실패면 DROP 0건: 되돌림 사본 올리기 실패면 뒤 단계 not-run", async () => {
    const w = dbWorld(APP);
    w.fail.set("pg dumpToR2", new Error("rcat 실패(주입)"));
    const r = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(r.status).toBe("failed");
    expect(r.steps.find((s) => s.id === "tmp")!.result).toBe("not-run");
    expect(dropped(w)).toBe(0);
    const again = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(again.status).toBe("waiting");
  });

  test("임시 클러스터가 Ready가 아니면 DROP 0건, --abort가 정리하고 잠금을 지운다", async () => {
    const w = dbWorld(APP);
    w.tmpReady = false;
    const r = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("--abort");
    expect(dropped(w)).toBe(0);
    const run = w.records.get(`${NS}/restore-pg`)!.run;
    const a = await runIn(w, cmd, "apply", { app: APP }, { abort: true });
    expect(a.status).toBe("done");
    expect(w.records.size).toBe(0);
    expect(w.runObjects(run)).toEqual([]);
  });

  test("DB를 지운 뒤에는 --abort를 거부한다", async () => {
    const w = await readyToDrop();
    w.aclSame = false;
    const r = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("ACL이 원본과 다르다");
    // ACL이 다르면 확인(4-6)·재개 PR로 가지 않는다
    expect(w.openPrs()).toEqual([]);
    w.writes = [];
    const a = await runIn(w, cmd, "apply", { app: APP }, { abort: true });
    expect(a.status).toBe("failed");
    expect(a.error!.message).toContain("DB를 지운 뒤");
    // 읽기 단계에서 멈추고 이어 가기·손 복원 길을 알려 준다(정리 쓰기 없음)
    expect(a.error!.next).toContain("pre-restore-");
    expect(w.writes.filter((x) => x.startsWith("delete"))).toEqual([]);
    expect(w.records.size).toBe(1);
  });

  test("역할이 승격돼 있으면 재개하지 않는다", async () => {
    const w = await readyToDrop();
    w.flags = "t|f|f|f|f";
    const r = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(r.status).toBe("failed");
    expect(w.openPrs()).toEqual([]);
  });

  test("실행 기록이 사라져도 복원 흔적이 있으면 새 실행을 만들지 않고, --abort도 거부한다", async () => {
    const w = await readyToDrop();
    w.records.clear();
    w.writes = [];
    const r = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(r.status).toBe("failed");
    // 남은 복원 Job 파드(다른 실행으로 보인다)나 suspended·임시 Cluster 흔적, 어느 쪽으로든 쓰기 전에 멈춘다
    expect(r.error!.message).toMatch(/복원 흔적|다른 실행/);
    expect(w.writes).toEqual([]);
    const a = await runIn(w, cmd, "apply", { app: APP }, { abort: true });
    expect(a.status).toBe("failed");
    expect(w.openPrs()).toEqual([]);
  });

  test("기록과 복원 Job이 사라져도 suspended·임시 Cluster가 남아 있으면 새 실행을 만들지 않는다", async () => {
    const w = await readyToDrop();
    const run = w.records.get(`${NS}/restore-pg`)!.run;
    w.records.clear();
    for (const k of [...w.objects.keys()]) if (k.startsWith("job/") || k.startsWith("pod/")) w.objects.delete(k);
    w.writes = [];
    const r = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("복원 흔적");
    expect(r.error!.message).toContain(`pg-restore-${run}`);
    expect(w.writes).toEqual([]);
  });

  test("다른 --to로 진행 중인 복원이 있으면 쓰기 없이 멈춘다", async () => {
    const w = dbWorld(APP);
    await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    w.writes = [];
    const r = await runIn(w, cmd, "apply", { app: APP }, { to: "2026-10-20T11:00:00+09:00" });
    expect(r.status).toBe("failed");
    expect(w.writes).toEqual([]);
  });

  test("범위 밖 시각: base backup 전, 복구 가능 범위 전, 너무 최근", async () => {
    for (const to of ["2026-10-19T00:00:00Z", new Date(Date.now() - 60_000).toISOString().replace(/\.[0-9]{3}Z$/, "Z")]) {
      const w = dbWorld(APP);
      const r = await runIn(w, cmd, "apply", { app: APP }, { to });
      expect(r.status).toBe("failed");
      expect(w.writes).toEqual([]);
    }
    // r1 P1-3: 복구 가능 범위를 확인할 수 없으면(필드 없음) 경고가 아니라 멈춘다
    const nb = dbWorld(APP);
    nb.objects.delete("objectstore/database/r2");
    const rb = await runIn(nb, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(rb.status).toBe("failed");
    expect(rb.error!.message).toContain("복구 가능 범위");
    expect(nb.writes).toEqual([]);
    // T1 앞에 끝난 base backup이 없다
    const nf = dbWorld(APP);
    nf.objects.delete("backup/database/b1");
    nf.obj("objectstore", "database", "r2")!.status.serverRecoveryWindow["pg-20261023"].firstRecoverabilityPoint = "2026-10-19T00:00:00Z";
    const rf = await runIn(nf, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(rf.status).toBe("failed");
    expect(rf.error!.message).toContain("앞에 끝난 completed base backup이 없다");
    const w = dbWorld(APP);
    w.obj("objectstore", "database", "r2")!.status.serverRecoveryWindow["pg-20261023"].firstRecoverabilityPoint = "2026-10-20T02:00:00Z";
    const r = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("복구 가능한 가장 이른 시각");
  });

  test("r1 P1-3: T1 뒤에 끝난 base backup이 없으면(WAL 범위를 확인할 수 없으면) 쓰기 없이 멈추고 온디맨드 백업을 안내한다", async () => {
    const w = dbWorld(APP);
    w.objects.delete("backup/database/b2");
    const r = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("뒤에 끝난 completed base backup이 없어");
    expect(r.error!.next).toContain("온디맨드 base backup");
    expect(w.writes).toEqual([]);
  });

  test("r1 P1-1: 같은 실행을 다른 호출이 함께 돌리면 lease에 막혀 DROP은 한 번뿐이다", async () => {
    const w = await readyToDrop();
    let second: Awaited<ReturnType<typeof runIn>> | undefined;
    w.duringDrop = async () => {
      w.duringDrop = undefined;
      second = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    };
    const first = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(second!.status).toBe("failed");
    expect(second!.error!.message).toContain("다른 호출이 이 복원");
    expect(dropped(w)).toBe(1);
    expect(first.status).toBe("waiting");
    // 첫 호출이 끝나면 lease는 남지 않는다
    expect([...w.objects.keys()].filter((k) => k.endsWith("-lease"))).toEqual([]);
  });

  test("r1 P1-1: 단계를 읽은 뒤 lease를 쥐기 전에 앞 호출이 그 단계를 끝냈으면 다시 하지 않는다(DROP 0건)", async () => {
    const w = await readyToDrop();
    w.onCreate = (m) => {
      if (m.metadata?.annotations?.["homelab.ukyi.app/lease"] !== "db restore db") return;
      w.onCreate = undefined;
      // 앞 호출이 DB를 다시 만들고 표식을 남긴 뒤 lease를 놓았다
      const rec = w.records.get(`${NS}/restore-pg`)!;
      rec.data["ok.db"] = "1";
      rec.data.dropped = "1";
      w.db = "empty";
    };
    const r = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(r.status).toBe("waiting");
    expect(dropped(w)).toBe(0);
    expect(w.db).toBe("t1");
  });

  test("r1 P1-1: 앞 호출이 비정상 종료해 lease가 남으면 다음 호출은 멈춘다(DROP 0건)", async () => {
    const w = await readyToDrop();
    const run = w.records.get(`${NS}/restore-pg`)!.run;
    w.put("job", NS, `restore-${run}-lease`, { metadata: { labels: { [LABEL]: run } } });
    const r = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain(`kubectl -n ${NS} delete job restore-${run}-lease`);
    expect(dropped(w)).toBe(0);
  });

  test("r1 P2-4: 본 복원이 중간에 끊기면 다음 실행은 빈 DB로 다시 만들고 처음부터 복원한다", async () => {
    const w = await readyToDrop();
    w.fail.set("pg restoreMain partial", new Error("x"));
    const r = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(r.status).toBe("failed");
    expect(w.db).toBe("partial");
    expect(dropped(w)).toBe(1);
    const again = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(again.status).toBe("waiting");
    expect(w.db).toBe("t1");
    expect(dropped(w)).toBe(2);
  });

  test("r1 P2-4: 본 복원은 됐는데 끝 표식만 못 썼어도 다음 실행은 4-3부터 다시 한다(already exists로 막히지 않는다)", async () => {
    const w = await readyToDrop();
    w.onUpdate = (set) => {
      if (set["ok.main"] === "1") {
        w.onUpdate = undefined;
        throw new Error("기록 쓰기 실패(주입)");
      }
    };
    const r = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(r.status).toBe("failed");
    expect(w.db).toBe("t1");
    const again = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(again.status).toBe("waiting");
    expect(w.db).toBe("t1");
    expect(dropped(w)).toBe(2);
  });

  test("--finish는 이 실행의 객체가 남아 있으면 잠금을 지우지 않는다", async () => {
    const w = dbWorld(APP);
    await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    const rec = w.records.get(`${NS}/restore-pg`)!;
    rec.data["ok.cleanup"] = "1";
    const f = await runIn(w, cmd, "apply", { app: APP }, { finish: true });
    expect(f.status).toBe("failed");
    expect(w.records.size).toBe(1);
  });

  test("앱 멈춤 PR 쓰기 시간 초과는 재시도 없이 결과 미상 실패, 재실행이 같은 PR로 잇는다", async () => {
    const w = dbWorld(APP);
    w.fail.set("gh POST pulls", "timeout");
    const r = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(r.status).toBe("failed");
    const again = await runIn(w, cmd, "apply", { app: APP }, { to: T1_INPUT });
    expect(again.status).toBe("waiting");
    expect(w.openPrs()).toHaveLength(1);
  });
});
