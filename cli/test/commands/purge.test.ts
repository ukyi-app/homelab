import { describe, expect, test } from "bun:test";
import { FAKE_SECRETS, FAKE_SHA, expectPlanReadOnly, ghGet, infisicalList, kubectlRule, rule, runCli, type Rule } from "../harness";
import { argvFor as infisicalArgv } from "../../src/core/infisical";
import cmd from "../../src/commands/purge";
import { World, runIn } from "../fixtures/rotate-world/world";

const APP = "gone";
const NS = `app-${APP}`;
const DATA = `data/${APP}/values.yaml`;
const PROJECT = "00000000-0000-4000-8000-000000000000";
const contents = (path: string, ref = "main") => `repos/ukyi-app/homelab/contents/${path}?ref=${ref}`;
const fileResp = (text: string) => ({ type: "file", encoding: "base64", content: Buffer.from(text).toString("base64") });
const notFound = { code: 1, stderr: 'Error from server (NotFound): x "y" not found\n' };
const dataText = "chartVersion: 1.0.1\npostgres: { enabled: true }\n";

function planRules(opts: { backupAfter?: boolean } = {}): Rule[] {
  return [
    ghGet(contents(`data/${APP}`), 200, [{ type: "file", path: DATA, name: "values.yaml" }]),
    ghGet(contents(`apps/${APP}`), 404, { message: "Not Found" }),
    kubectlRule(["-n", "argocd", "get", "applications.argoproj.io", APP, "-o", "json"], notFound),
    ghGet(contents(DATA), 200, fileResp(dataText)),
    ghGet(`repos/ukyi-app/homelab/commits?path=apps%2F${APP}%2Fvalues.yaml&sha=main&per_page=1`, 200, [{ commit: { committer: { date: "2026-10-20T00:00:00Z" } } }]),
    kubectlRule(["-n", "database", "get", "backups.postgresql.cnpg.io", "-o", "json"], { stdout: JSON.stringify({ items: [{ spec: { cluster: { name: "pg" } }, status: { phase: "completed", stoppedAt: opts.backupAfter === false ? "2026-10-19T18:00:00Z" : "2026-10-20T18:00:00Z" } }] }) }),
    ghGet("repos/ukyi-app/homelab/git/ref/tags/data-chart-v1.0.2", 200, { object: { sha: FAKE_SHA } }),
    ghGet("repos/ukyi-app/homelab/git/ref/heads/main", 200, { object: { sha: FAKE_SHA } }),
    ghGet(contents(DATA, FAKE_SHA), 200, fileResp(dataText)),
    ghGet(`repos/ukyi-app/homelab/pulls?head=ukyi-app%3Acli%2Fdata-purge-${APP}&state=open`, 200, []),
    ghGet(`repos/ukyi-app/homelab/pulls?head=ukyi-app%3Acli%2Fdata-purge-delete-${APP}&state=open`, 200, []),
    kubectlRule(["-n", NS, "get", "persistentvolumeclaims", "valkey-data", "-o", "json"], notFound),
    rule(infisicalArgv.folders(PROJECT, `/apps/${APP}`), { stdout: JSON.stringify([{ folderId: "f1", folderName: "postgres", folderPath: `/apps/${APP}/postgres` }]) }),
    rule(infisicalArgv.folders(PROJECT, "/apps"), { stdout: JSON.stringify([{ folderId: "f2", folderName: APP, folderPath: `/apps/${APP}` }]) }),
    infisicalList(`/apps/${APP}/postgres`, { PASSWORD: FAKE_SECRETS[0] }),
    infisicalList(`/apps/${APP}`, { API_KEY: FAKE_SECRETS[1] }),
  ];
}

describe("data purge: plan(PATH 스텁)", () => {
  test("plan은 --confirm 없이도 읽기만 하고 지울 키 이름을 보인다(값은 없다)", async () => {
    const r = await runCli(["data", "purge", APP, "--json"], planRules());
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.status).toBe("pending");
    expect(r.json.next).toBe(`homelab data purge ${APP} --confirm ${APP} --apply`);
    expect(JSON.stringify(r.json)).toContain(`/apps/${APP}/postgres/PASSWORD`);
  });

  test("앱 삭제 뒤 백업이 없으면 실패", async () => {
    const r = await runCli(["data", "purge", APP, "--json"], planRules({ backupAfter: false }));
    expect(r.code).toBe(1);
    expectPlanReadOnly(r);
    expect(r.json.error.message).toContain("completed base backup");
  });

  test("--apply에 --confirm이 없거나 다르면 64(아무것도 부르지 않는다)", async () => {
    for (const args of [["data", "purge", APP, "--apply"], ["data", "purge", APP, "--confirm", "other", "--apply"], ["data", "purge", APP, "--confirm", APP, "--confirm", APP, "--apply"]]) {
      const r = await runCli(args, planRules());
      expect(r.code).toBe(64);
      expectPlanReadOnly(r, { allowNoCalls: true });
      expect(r.calls).toEqual([]);
    }
  });
});

function purgeWorld(): World {
  const w = new World({ [DATA]: "chartVersion: 1.0.1\n# 사람이 쓴 주석\npostgres: { enabled: true }\nvalkey: { persistent: true }\n" });
  const protect = { "argocd.argoproj.io/sync-options": "Prune=false,Delete=false" };
  w.put("database", "database", APP, { metadata: { name: APP, annotations: { ...protect } }, spec: { databaseReclaimPolicy: "retain" } });
  w.put("databaserole", "database", APP, { metadata: { name: APP, annotations: { ...protect } }, spec: { databaseRoleReclaimPolicy: "retain" } });
  w.put("pvc", NS, "valkey-data", { metadata: { name: "valkey-data", annotations: { ...protect } }, spec: { volumeName: "pvc-9" } });
  w.put("pv", null, "pvc-9", { metadata: { name: "pvc-9" }, spec: { storageClassName: "local-retain", persistentVolumeReclaimPolicy: "Retain", claimRef: { namespace: NS, name: "valkey-data" } } });
  w.put("application", "argocd", `${APP}-data`, { metadata: { name: `${APP}-data` } });
  w.put("backup", "database", "b1", { spec: { cluster: { name: "pg" } }, status: { phase: "completed", stoppedAt: "2026-10-21T18:00:00Z" } });
  w.put("cronjob", NS, `${APP}-valkey-backup`, { status: { lastSuccessfulTime: "2026-10-21T18:30:00Z" } });
  w.tags.add("data-chart-v1.0.2");
  w.setValue(`/apps/${APP}/postgres`, "PASSWORD", "x".repeat(20));
  w.setValue(`/apps/${APP}/valkey`, "PASSWORD", "y".repeat(20));
  w.setValue(`/apps/${APP}`, "API_KEY", "z".repeat(20));
  return w;
}

describe("data purge: 흐름(가짜 세계)", () => {
  test("PR 1 → 동기화 대기 → PV reclaim·PR 2 → 삭제 대기 → 확인 뒤 키 삭제, 재실행 same", async () => {
    const w = purgeWorld();
    const flags = { confirm: APP };

    const r1 = await runIn(w, cmd, "apply", { app: APP }, flags);
    expect(r1.status).toBe("waiting");
    expect(w.openPrs().map((p) => p.head)).toEqual([`cli/data-purge-${APP}`]);
    // PR 1은 purge: true와 차트 1.0.2만 바꾸고 주석은 둔다
    const branch = w.commits.get(w.refs.get(`cli/data-purge-${APP}`)!)!.files.get(DATA)!;
    expect(branch).toContain("purge: true");
    expect(branch).toContain("chartVersion: 1.0.2");
    expect(branch).toContain("# 사람이 쓴 주석");
    // PR 1을 기다리는 동안 PV·PR 2는 건드리지 않는다
    expect(w.writes.some((x) => x.startsWith("setPvReclaimDelete"))).toBe(false);

    w.merge(900);
    w.writes = [];
    const r2 = await runIn(w, cmd, "apply", { app: APP }, flags);
    expect(r2.status).toBe("waiting");
    expect(r2.next).toContain("Argo CD 동기화 대기");
    expect(w.writes).toEqual([]);

    // Argo CD가 PR 1을 반영
    for (const k of ["database", "databaserole"]) {
      const o = w.obj(k, "database", APP)!;
      delete o.metadata.annotations;
      o.spec = k === "database" ? { databaseReclaimPolicy: "delete" } : { databaseRoleReclaimPolicy: "delete" };
    }
    delete w.obj("pvc", NS, "valkey-data")!.metadata.annotations;
    const r3 = await runIn(w, cmd, "apply", { app: APP }, flags);
    expect(r3.status).toBe("waiting");
    expect(w.obj("pv", null, "pvc-9")!.spec.persistentVolumeReclaimPolicy).toBe("Delete");
    expect(w.openPrs().map((p) => p.head)).toEqual([`cli/data-purge-delete-${APP}`]);

    w.merge(901);
    expect(w.main().has(DATA)).toBe(false);
    const r4 = await runIn(w, cmd, "apply", { app: APP }, flags);
    expect(r4.status).toBe("waiting");
    expect(r4.next).toContain("지우는 중");
    expect(w.value(`/apps/${APP}`, "API_KEY")).toBeDefined();

    // Argo CD·CNPG가 지움
    for (const k of ["database/database/" + APP, "databaserole/database/" + APP, `pvc/${NS}/valkey-data`, "pv/-/pvc-9", `application/argocd/${APP}-data`]) w.objects.delete(k);
    // tty에서 확인하지 않으면 지우지 않는다
    const r5 = await runIn(w, cmd, "apply", { app: APP }, flags);
    expect(r5.status).toBe("failed");
    expect(w.value(`/apps/${APP}`, "API_KEY")).toBeDefined();

    w.confirmAnswer = APP;
    const r6 = await runIn(w, cmd, "apply", { app: APP }, flags);
    expect(r6.status).toBe("done");
    expect(w.writes.filter((x) => x.startsWith("infisical delete"))).toHaveLength(3);

    w.writes = [];
    const r7 = await runIn(w, cmd, "apply", { app: APP }, flags);
    expect(r7.status).toBe("same");
    expect(w.writes).toEqual([]);
  });

  test("앱이 아직 등록돼 있으면 아무것도 쓰지 않고 실패", async () => {
    const w = purgeWorld();
    w.put("application", "argocd", APP, { metadata: { name: APP } });
    const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    expect(r.status).toBe("failed");
    expect(r.error!.next).toBe(`homelab status ${APP}`);
    expect(w.writes).toEqual([]);
  });

  test("차트 1.0.2 태그가 없으면 PR 1을 열지 않는다", async () => {
    const w = purgeWorld();
    w.tags.clear();
    const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    expect(r.status).toBe("failed");
    expect(w.openPrs()).toEqual([]);
  });

  test("r1 P1-2: 앱 이력을 못 읽거나 모양이 다르면 백업 검사를 통과시키지 않는다(PR 없음)", async () => {
    for (const broken of ["broken", []] as const) {
      const w = purgeWorld();
      w.history.set(`apps/${APP}/values.yaml`, broken as any);
      if (Array.isArray(broken)) w.history.set(DATA, []);
      const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
      expect(r.status).toBe("failed");
      expect(r.steps.find((x) => x.id === "backup")!.result).toBe("failed");
      expect(w.openPrs()).toEqual([]);
      expect(w.writes).toEqual([]);
    }
  });

  test("r1 P1-2: 앱 없이 등록한 데이터는 data 첫 커밋 뒤 백업을 요구한다(이력이 길면 멈춘다)", async () => {
    const w = purgeWorld();
    w.history.set(`apps/${APP}/values.yaml`, []);
    // 새것부터: PR 1이 같은 파일을 고쳐도 첫 커밋(2026-10-22)은 그대로다
    w.history.set(DATA, ["2026-10-25T00:00:00Z", "2026-10-22T00:00:00Z"]);
    const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("데이터 등록(앱 이력 없음)(2026-10-22T00:00:00Z) 뒤");
    expect(w.openPrs()).toEqual([]);
    w.obj("backup", "database", "b1")!.status.stoppedAt = "2026-10-23T18:00:00Z";
    w.obj("cronjob", NS, `${APP}-valkey-backup`)!.status.lastSuccessfulTime = "2026-10-23T18:30:00Z";
    expect((await runIn(w, cmd, "apply", { app: APP }, { confirm: APP })).status).toBe("waiting");

    const long = purgeWorld();
    long.history.set(`apps/${APP}/values.yaml`, []);
    long.history.set(DATA, Array.from({ length: 100 }, () => "2026-10-22T00:00:00Z"));
    expect((await runIn(long, cmd, "apply", { app: APP }, { confirm: APP })).status).toBe("failed");
  });

  test("PR 1 뒤 Database CR이 없으면 반영으로 보지 않고 PR 2를 열지 않는다", async () => {
    const w = purgeWorld();
    await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    w.merge(900);
    w.objects.delete(`database/database/${APP}`);
    const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    expect(r.status).toBe("waiting");
    expect(r.next).toContain("Database gone(없음)");
    expect(w.openPrs()).toEqual([]);
  });

  test("PVC에 묶인 PV를 못 찾으면 reclaim을 확인할 수 없어 PR 2를 열지 않는다", async () => {
    const w = purgeWorld();
    await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    w.merge(900);
    for (const k of ["database", "databaserole"]) {
      const o = w.obj(k, "database", APP)!;
      delete o.metadata.annotations;
      o.spec = k === "database" ? { databaseReclaimPolicy: "delete" } : { databaseRoleReclaimPolicy: "delete" };
    }
    delete w.obj("pvc", NS, "valkey-data")!.metadata.annotations;
    w.objects.delete("pv/-/pvc-9");
    const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    expect(r.status).toBe("failed");
    expect(w.openPrs()).toEqual([]);
  });

  test("PR 쓰기 시간 초과는 재조회 뒤 결과 미상 실패, 재실행이 같은 PR로 이어 간다", async () => {
    const w = purgeWorld();
    w.fail.set("gh POST pulls", "timeout");
    const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    expect(r.status).toBe("failed");
    const again = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    expect(again.status).toBe("waiting");
    expect(w.openPrs()).toHaveLength(1);
  });
});
