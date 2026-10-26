import { afterAll, beforeAll, describe, expect, setSystemTime, test } from "bun:test";
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

// 하위 프로세스는 시계를 묶을 수 없어 지금 기준 상대 시각을 쓴다(백업 보존 12일 판정).
const ago = (days: number) => new Date(Date.now() - days * 86_400_000).toISOString().replace(/\.\d{3}Z$/, "Z");
const empty = JSON.stringify({ items: [] });

function planRules(opts: { backupAfter?: boolean } = {}): Rule[] {
  const gone = { metadata: { name: `data-purge-${APP}`, labels: { "homelab.ukyi.app/restore": "seed" }, resourceVersion: "1", creationTimestamp: ago(2.5) }, data: { run: "seed" } };
  return [
    ...["deployments.apps", "statefulsets.apps", "cronjobs.batch", "jobs.batch", "pods"].map((r) => kubectlRule(["-n", NS, "get", r, "-o", "json"], { stdout: empty })),
    kubectlRule(["-n", "database", "get", "configmaps", `data-purge-${APP}`, "-o", "json"], { stdout: JSON.stringify(gone) }),
    ghGet(contents(`data/${APP}`), 200, [{ type: "file", path: DATA, name: "values.yaml" }]),
    ghGet(contents(`apps/${APP}`), 404, { message: "Not Found" }),
    kubectlRule(["-n", "argocd", "get", "applications.argoproj.io", APP, "-o", "json"], notFound),
    ghGet(contents(DATA), 200, fileResp(dataText)),
    ghGet(`repos/ukyi-app/homelab/commits?path=apps%2F${APP}%2Fvalues.yaml&sha=main&per_page=1`, 200, [{ sha: "1".repeat(40), commit: { committer: { date: ago(3) } } }]),
    ghGet(`repos/ukyi-app/homelab/commits?path=data%2F${APP}%2Fvalues.yaml&sha=main&per_page=30`, 200, [{ sha: "2".repeat(40), commit: { committer: { date: ago(30) } } }]),
    ghGet(`repos/ukyi-app/homelab/commits/${"2".repeat(40)}`, 200, { files: [{ filename: DATA, status: "added" }] }),
    kubectlRule(["-n", "database", "get", "backups.postgresql.cnpg.io", "-o", "json"], { stdout: JSON.stringify({ items: [{ spec: { cluster: { name: "pg" } }, status: { phase: "completed", stoppedAt: opts.backupAfter === false ? ago(2.6) : ago(1) } }] }) }),
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
  test("plan은 --confirm 없이도 읽기만 하고, PR 2 전에는 Infisical을 부르지 않는다(#893 r1 P1-2)", async () => {
    const r = await runCli(["data", "purge", APP, "--json"], planRules());
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.status).toBe("pending");
    expect(r.json.next).toBe(`homelab data purge ${APP} --confirm ${APP} --apply`);
    expect(r.json.steps.find((x: { id: string }) => x.id === "secrets").detail).toContain("PR 2 뒤 키 삭제");
    expect(r.calls.some((c) => c.argv[0] === "infisical")).toBe(false);
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

// 백업 CronJob이 만든 성공 Job 하나(successfulJobsHistoryLimit 1이라 마지막 것만 남는다). start는 Job 시작 시각.
function valkeyBackup(w: World, start: string, opts: { complete?: boolean; owner?: string } = {}) {
  w.put("job", NS, "gone-valkey-backup-1", {
    metadata: { name: "gone-valkey-backup-1", ownerReferences: [{ kind: "CronJob", name: opts.owner ?? `${APP}-valkey-backup` }] },
    status: { startTime: start, conditions: [{ type: opts.complete === false ? "Failed" : "Complete", status: "True" }] },
  });
}

// 앞 실행이 앱 워크로드 없음을 보고 만든 기록. at은 그 creationTimestamp(API 서버 시계)다.
function goneRecord(w: World, at: string) {
  w.records.set(`database/data-purge-${APP}`, { run: "seed", data: {}, created: at });
}

function purgeWorld(): World {
  const w = new World({ [DATA]: "chartVersion: 1.0.1\n# 사람이 쓴 주석\npostgres: { enabled: true }\nvalkey: { persistent: true }\n" });
  const protect = { "argocd.argoproj.io/sync-options": "Prune=false,Delete=false" };
  // 실제 API처럼 없는 ns에는 기록을 만들지 못하게 한다(#889 r2 P2-4)
  w.strictNamespaces = true;
  w.put("namespace", null, NS, { metadata: { name: NS } });
  w.put("namespace", null, "database", { metadata: { name: "database" } });
  w.put("database", "database", APP, { metadata: { name: APP, annotations: { ...protect } }, spec: { databaseReclaimPolicy: "retain" } });
  w.put("databaserole", "database", APP, { metadata: { name: APP, annotations: { ...protect } }, spec: { databaseRoleReclaimPolicy: "retain" } });
  w.put("pvc", NS, "valkey-data", { metadata: { name: "valkey-data", annotations: { ...protect } }, spec: { volumeName: "pvc-9" } });
  w.put("pv", null, "pvc-9", { metadata: { name: "pvc-9" }, spec: { storageClassName: "local-retain", persistentVolumeReclaimPolicy: "Retain", claimRef: { namespace: NS, name: "valkey-data" } } });
  w.put("application", "argocd", `${APP}-data`, { metadata: { name: `${APP}-data` } });
  w.put("backup", "database", "b1", { spec: { cluster: { name: "pg" } }, status: { phase: "completed", stoppedAt: "2026-10-21T18:00:00Z" } });
  w.put("cronjob", NS, `${APP}-valkey-backup`, { status: { lastSuccessfulTime: "2026-10-21T18:31:00Z" } });
  valkeyBackup(w, "2026-10-21T18:30:00Z");
  // 앞 실행이 앱 워크로드 없음을 본 시각(앱 삭제 10/20 00:00 뒤, 백업 10/21 전)
  goneRecord(w, "2026-10-20T06:00:00Z");
  w.tags.add("data-chart-v1.0.2");
  w.setValue(`/apps/${APP}/postgres`, "PASSWORD", "x".repeat(20));
  w.setValue(`/apps/${APP}/valkey`, "PASSWORD", "y".repeat(20));
  w.setValue(`/apps/${APP}`, "API_KEY", "z".repeat(20));
  return w;
}

describe("data purge: 흐름(가짜 세계)", () => {
  // Valkey 백업 보존 기간(14일) 판정이 지금 시각을 쓴다. 고정 날짜 세계가 시간이 지나도 같은 결과를 내게 시계를 묶는다.
  beforeAll(() => setSystemTime(new Date("2026-10-26T00:00:00Z")));
  afterAll(() => setSystemTime());

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
    expect(w.records.has(`database/data-purge-${APP}`)).toBe(true);
    const r6 = await runIn(w, cmd, "apply", { app: APP }, flags);
    expect(r6.status).toBe("done");
    // 앱 쓰기 종료 기록도 마지막에 지운다
    expect(w.records.has(`database/data-purge-${APP}`)).toBe(false);
    expect(w.writes.filter((x) => x.startsWith("infisical delete"))).toHaveLength(3);

    w.writes = [];
    const r7 = await runIn(w, cmd, "apply", { app: APP }, flags);
    expect(r7.status).toBe("same");
    expect(w.writes).toEqual([]);
  });

  test("앱 Application이 남아 있으면 워크로드로 보고 종료 기록을 지운 뒤 실패(PR·PV 쓰기 없음)", async () => {
    const w = purgeWorld();
    w.put("application", "argocd", APP, { metadata: { name: APP } });
    const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain(`application/${APP}`);
    expect(w.writes).toEqual([`recordDelete database/data-purge-${APP}`]);
    expect(w.openPrs()).toEqual([]);
    // main에 apps/<app>/가 있으면 그 전에(쓰기 없이) 멈춘다
    const g = purgeWorld();
    g.main().set(`apps/${APP}/values.yaml`, "kind: web\n");
    const a = await runIn(g, cmd, "apply", { app: APP }, { confirm: APP });
    expect(a.status).toBe("failed");
    expect(a.error!.next).toBe(`homelab app remove ${APP}`);
    expect(g.writes).toEqual([]);
  });

  test("차트 1.0.2 태그가 없으면 PR 1을 열지 않는다", async () => {
    const w = purgeWorld();
    w.tags.clear();
    const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    expect(r.status).toBe("failed");
    expect(w.openPrs()).toEqual([]);
  });

  test("r1 P1-2: 앱 이력을 못 읽거나 모양이 다르면 백업 검사를 통과시키지 않는다(PR 없음)", async () => {
    for (const broken of ["broken" as const, []]) {
      const w = purgeWorld();
      w.history.set(`apps/${APP}/values.yaml`, broken);
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
    // 새것부터: PR 1이 같은 파일을 고쳐도(modified) 생긴 커밋(2026-10-22)은 그대로다
    w.history.set(DATA, [
      { date: "2026-10-25T00:00:00Z", status: "modified" },
      { date: "2026-10-22T00:00:00Z", status: "added" },
    ]);
    goneRecord(w, "2026-10-22T06:00:00Z");
    const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("데이터 등록(앱 이력 없음)(2026-10-22T00:00:00Z)");
    expect(w.openPrs()).toEqual([]);
    w.obj("backup", "database", "b1")!.status.stoppedAt = "2026-10-23T18:00:00Z";
    valkeyBackup(w, "2026-10-23T18:30:00Z");
    expect((await runIn(w, cmd, "apply", { app: APP }, { confirm: APP })).status).toBe("waiting");

    const long = purgeWorld();
    long.history.set(`apps/${APP}/values.yaml`, []);
    long.history.set(DATA, Array.from({ length: 100 }, () => ({ date: "2026-10-22T00:00:00Z", status: "modified" as const })));
    expect((await runIn(long, cmd, "apply", { app: APP }, { confirm: APP })).status).toBe("failed");
  });

  test("r2 P1-2: 폐기 뒤 다시 등록한 데이터는 재등록 뒤 백업만 인정한다", async () => {
    for (const apps of [[], [{ date: "2026-10-10T00:00:00Z", status: "removed" as const }]]) {
      const w = purgeWorld();
      w.history.set(`apps/${APP}/values.yaml`, apps);
      // 10/1 처음 등록 → 10/24 삭제 → 10/25 재등록. 성공 백업은 10/21(옛 데이터)뿐이다
      w.history.set(DATA, [
        { date: "2026-10-25T00:00:00Z", status: "added" },
        { date: "2026-10-24T00:00:00Z", status: "removed" },
        { date: "2026-10-01T00:00:00Z", status: "added" },
      ]);
      const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
      expect(r.status).toBe("failed");
      expect(r.error!.message).toContain("2026-10-25T00:00:00Z");
      expect(w.openPrs()).toEqual([]);
    }
  });

  test("r2 P1-2: 앱 삭제 뒤 데이터를 다시 등록했으면 늦은 쪽(재등록)이 기준이다", async () => {
    const w = purgeWorld();
    w.history.set(DATA, [{ date: "2026-10-22T12:00:00Z", status: "added" }]);
    const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("데이터 재등록(앱 삭제 뒤)");
  });

  test("r2 P1-2: 커밋의 파일 목록을 못 읽거나 상태가 이상하면 멈춘다", async () => {
    const w = purgeWorld();
    // 파일이 지금 있는데 가장 최근 상태가 removed: 이력이 맞지 않는다. 더 오래된 added로 넘어가 옛 백업을 인정하지 않는다
    w.history.set(DATA, [
      { date: "2026-10-22T00:00:00Z", status: "removed" },
      { date: "2026-10-01T00:00:00Z", status: "added" },
    ]);
    const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    expect(r.status).toBe("failed");
    expect(w.openPrs()).toEqual([]);
  });

  test("r3 P1-1: 마지막 Valkey 백업이 R2 보존 기간(14일, 여유 2일)을 넘으면 PR을 열지 않는다", async () => {
    // 데이터 등록 9/1 → 앱 삭제 10/1 → 마지막 성공 백업 10/2, 지금 10/26
    const w = purgeWorld();
    w.history.set(`apps/${APP}/values.yaml`, [{ date: "2026-10-01T00:00:00Z", status: "removed" }]);
    w.history.set(DATA, [{ date: "2026-09-01T00:00:00Z", status: "added" }]);
    goneRecord(w, "2026-10-01T06:00:00Z");
    w.obj("backup", "database", "b1")!.status.stoppedAt = "2026-10-25T18:00:00Z";
    valkeyBackup(w, "2026-10-02T18:30:00Z");
    const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("12일보다 오래됐다");
    expect(w.openPrs()).toEqual([]);
    expect(w.writes).toEqual([]);
    // 경계: 12일 안이면 통과, 12일을 넘으면 멈춘다
    valkeyBackup(w, "2026-10-14T00:00:01Z");
    expect((await runIn(w, cmd, "apply", { app: APP }, { confirm: APP })).status).toBe("waiting");
    valkeyBackup(w, "2026-10-13T23:59:59Z");
    expect((await runIn(w, cmd, "apply", { app: APP }, { confirm: APP })).status).toBe("failed");
  });

  test("r3 P1-1: PR 1 병합 뒤 백업이 오래되면 PV reclaim·PR 2로 가지 않는다", async () => {
    const w = purgeWorld();
    await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    w.merge(900);
    for (const k of ["database", "databaserole"]) {
      const o = w.obj(k, "database", APP)!;
      delete o.metadata.annotations;
      o.spec = k === "database" ? { databaseReclaimPolicy: "delete" } : { databaseRoleReclaimPolicy: "delete" };
    }
    delete w.obj("pvc", NS, "valkey-data")!.metadata.annotations;
    // 그사이 백업이 멈춰 마지막 성공(10/21)이 12일을 넘었다
    setSystemTime(new Date("2026-11-03T00:00:00Z"));
    try {
      w.writes = [];
      const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
      expect(r.status).toBe("failed");
      expect(w.writes).toEqual([]);
      expect(w.obj("pv", null, "pvc-9")!.spec.persistentVolumeReclaimPolicy).toBe("Retain");
      expect(w.openPrs()).toEqual([]);
    } finally {
      setSystemTime(new Date("2026-10-26T00:00:00Z"));
    }
  });

  test("r3 P1-1: 마지막 성공 시각이 지금보다 미래면(시계를 믿을 수 없다) 멈춘다", async () => {
    const w = purgeWorld();
    valkeyBackup(w, "2026-10-27T00:00:00Z");
    const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("미래");
    expect(w.openPrs()).toEqual([]);
  });

  test("Connector P1: 앱 워크로드 없음 확인 전에 시작한 백업(스냅샷은 그 전)은 완료가 늦어도 인정하지 않는다", async () => {
    // 확인 10/20 06:00. 05:59에 시작한 Job이 스냅샷을 찍고 06:10에 업로드를 마쳤다
    const w = purgeWorld();
    w.obj("cronjob", NS, `${APP}-valkey-backup`)!.status.lastSuccessfulTime = "2026-10-20T06:10:00Z";
    valkeyBackup(w, "2026-10-20T05:59:00Z");
    const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("시작한 Valkey 백업");
    expect(w.openPrs()).toEqual([]);
    expect(w.writes).toEqual([]);
    // 기록 생성 시각과 백업 시작은 둘 다 클러스터 시계다. 같은 초는 인정하지 않고 그 뒤만
    valkeyBackup(w, "2026-10-20T06:00:00Z");
    expect((await runIn(w, cmd, "apply", { app: APP }, { confirm: APP })).status).toBe("failed");
    expect(w.openPrs()).toEqual([]);
    valkeyBackup(w, "2026-10-20T06:00:01Z");
    expect((await runIn(w, cmd, "apply", { app: APP }, { confirm: APP })).status).toBe("waiting");
    expect(w.openPrs().map((p) => p.head)).toEqual([`cli/data-purge-${APP}`]);
  });

  test("r1 P1-2: 삭제 커밋 뒤에도 앱이 쓰던 동안의 백업은 인정하지 않는다(쓰기 종료는 워크로드가 사라진 것을 본 시각)", async () => {
    // 리뷰 재현: 삭제 커밋 10/20 00:00, Argo CD가 늦어 앱이 03:00까지 썼고 02:00 백업이 성공했다. 기록은 아직 없다
    setSystemTime(new Date("2026-10-20T03:30:00Z"));
    try {
      const w = purgeWorld();
      w.records.delete(`database/data-purge-${APP}`);
      w.obj("backup", "database", "b1")!.status.stoppedAt = "2026-10-20T02:10:00Z";
      valkeyBackup(w, "2026-10-20T02:00:00Z");
      // 앱이 아직 떠 있으면 기록도 하지 않고 멈춘다
      w.put("deployment", NS, APP, { metadata: { name: APP, labels: { "homelab.ukyi.app/app": APP } } });
      const a = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
      expect(a.status).toBe("failed");
      expect(a.error!.message).toContain(`deployment/${APP}`);
      // 어디를 볼지 알려 준다
      expect(a.error!.message).toContain("kubectl");
      expect(w.writes).toEqual([]);
      // 앱 라벨이 없어도 데이터 차트 것으로 알 수 없는 살아 있는 파드가 있으면 멈춘다
      w.objects.delete(`deployment/${NS}/${APP}`);
      w.put("pod", NS, "stray", { metadata: { name: "stray", labels: {} }, status: { phase: "Running" } });
      w.put("pod", NS, `${APP}-valkey-x`, { metadata: { name: `${APP}-valkey-x`, labels: { "app.kubernetes.io/name": "valkey", "app.kubernetes.io/instance": APP } }, status: { phase: "Running" } });
      expect((await runIn(w, cmd, "apply", { app: APP }, { confirm: APP })).status).toBe("failed");
      expect(w.writes).toEqual([]);
      // 03:30 앱이 사라졌다(서버 파드만 남음): 확인 시각을 남기고, 그 전의 02:00 백업으로는 진행하지 않는다
      w.objects.delete(`pod/${NS}/stray`);
      const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
      expect(r.status).toBe("failed");
      expect(w.records.get(`database/data-purge-${APP}`)!.created).toBe("2026-10-20T03:30:00Z");
      expect(w.writes).toEqual([`recordCreate database/data-purge-${APP}`]);
      expect(w.openPrs()).toEqual([]);
      // 재실행도 같은 기록으로 멈춘다(기록을 새로 쓰지 않는다)
      w.writes = [];
      expect((await runIn(w, cmd, "apply", { app: APP }, { confirm: APP })).status).toBe("failed");
      expect(w.writes).toEqual([]);
      expect(w.openPrs()).toEqual([]);
      // 다음 정기 백업(확인 뒤 시작)이 생기면 진행한다
      setSystemTime(new Date("2026-10-21T00:00:00Z"));
      w.obj("backup", "database", "b1")!.status.stoppedAt = "2026-10-20T18:10:00Z";
      valkeyBackup(w, "2026-10-20T18:30:00Z");
      expect((await runIn(w, cmd, "apply", { app: APP }, { confirm: APP })).status).toBe("waiting");
      expect(w.openPrs().map((p) => p.head)).toEqual([`cli/data-purge-${APP}`]);
    } finally {
      setSystemTime(new Date("2026-10-26T00:00:00Z"));
    }
  });

  test("r1 P1-2: 읽은 뒤 기록 직전에 앱 파드가 살아나면 확인 시각을 남기지 않는다", async () => {
    const w = purgeWorld();
    w.records.delete(`database/data-purge-${APP}`);
    // 앞의 두 번 읽기(전체 읽기, 단계 다시 읽기)에서는 끝난 파드, 기록 직전 apply에서는 살아 있는 파드
    let seen = 0;
    w.put("pod", NS, APP, { metadata: { name: APP, labels: { "homelab.ukyi.app/app": APP } }, status: { get phase() { return seen++ < 2 ? "Succeeded" : "Running"; } } });
    const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain(`pod/${APP}`);
    expect(w.records.has(`database/data-purge-${APP}`)).toBe(false);
    expect(w.writes).toEqual([]);
  });

  test("r1 P1-2: 기준(앱 삭제·재등록)보다 앞선 기록은 옛 실행의 것이라 지금 다시 확인해 새로 쓴다", async () => {
    const w = purgeWorld();
    // 10/22 재등록. 기록은 10/20(옛 데이터 때)
    w.history.set(DATA, [{ date: "2026-10-22T12:00:00Z", status: "added" }]);
    valkeyBackup(w, "2026-10-23T18:30:00Z");
    w.obj("backup", "database", "b1")!.status.stoppedAt = "2026-10-23T18:00:00Z";
    const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    // 새 기록(지금 10/26) 뒤의 백업이 없다
    expect(r.status).toBe("failed");
    expect(w.records.get(`database/data-purge-${APP}`)!.created).toBe("2026-10-26T00:00:00Z");
    expect(w.openPrs()).toEqual([]);
  });

  test("r2 P1-3: 종료 기록 뒤 앱 파드가 다시 보이면 기록을 지우고, 사라진 뒤 새로 잰 시각 뒤의 백업만 인정한다", async () => {
    // 리뷰 재현: 기록 10/25 12:00, 백업 시작 10/25 18:30, 10/26 12:00에 앱 라벨의 실행 중 파드
    setSystemTime(new Date("2026-10-26T12:00:00Z"));
    try {
      const w = purgeWorld();
      goneRecord(w, "2026-10-25T12:00:00Z");
      w.obj("backup", "database", "b1")!.status.stoppedAt = "2026-10-25T18:00:00Z";
      valkeyBackup(w, "2026-10-25T18:30:00Z");
      w.put("pod", NS, "writer", { metadata: { name: "writer", labels: { "homelab.ukyi.app/app": APP } }, status: { phase: "Running" } });
      // plan은 읽기만 하고 "기록을 지운다"를 보인다
      const p = await runIn(w, cmd, "plan", { app: APP });
      expect(p.steps.find((x) => x.id === "workloads")!.detail).toContain("폐기 확인 기록이 무효가 된다");
      expect(w.writes).toEqual([]);
      expect(w.records.has(`database/data-purge-${APP}`)).toBe(true);
      const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
      expect(r.status).toBe("failed");
      expect(w.records.has(`database/data-purge-${APP}`)).toBe(false);
      expect(w.writes).toEqual([`recordDelete database/data-purge-${APP}`]);
      expect(w.openPrs()).toEqual([]);
      // 파드가 끝난 뒤: 지금(12:00) 새로 기록하고, 그 전의 18:30 백업으로는 진행하지 않는다
      w.objects.delete(`pod/${NS}/writer`);
      const again = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
      expect(again.status).toBe("failed");
      expect(w.records.get(`database/data-purge-${APP}`)!.created).toBe("2026-10-26T12:00:00Z");
      expect(w.openPrs()).toEqual([]);
      expect(w.writes.some((x) => x.startsWith("setPvReclaimDelete"))).toBe(false);
      // 그 뒤 정기 백업이 생기면 진행한다
      setSystemTime(new Date("2026-10-27T00:00:00Z"));
      w.obj("backup", "database", "b1")!.status.stoppedAt = "2026-10-26T18:00:00Z";
      valkeyBackup(w, "2026-10-26T18:30:00Z");
      expect((await runIn(w, cmd, "apply", { app: APP }, { confirm: APP })).status).toBe("waiting");
      expect(w.openPrs().map((x) => x.head)).toEqual([`cli/data-purge-${APP}`]);
    } finally {
      setSystemTime(new Date("2026-10-26T00:00:00Z"));
    }
  });

  test("r3 P1-1: 첫 백업을 기다리는 동안 워크로드가 다시 보이면, 백업 부재·태그 없음·이력 문제가 있어도 종료 기록을 지운다", async () => {
    const cases: [string, (w: World) => void][] = [
      ["백업 없음", () => {}],
      ["차트 태그 없음", (w) => w.tags.clear()],
      ["앱 이력 읽기 실패", (w) => w.history.set(`apps/${APP}/values.yaml`, "broken")],
    ];
    for (const [what, extra] of cases) {
      setSystemTime(new Date("2026-10-26T12:00:00Z"));
      try {
        // 리뷰 재현: 기록 10/25 12:00, 그 뒤 성공 백업 없음(10/21 것뿐), 실행 중 앱 파드
        const w = purgeWorld();
        goneRecord(w, "2026-10-25T12:00:00Z");
        extra(w);
        w.put("pod", NS, "writer", { metadata: { name: "writer", labels: { "homelab.ukyi.app/app": APP } }, status: { phase: "Running" } });
        await runIn(w, cmd, "plan", { app: APP });
        expect([what, w.writes]).toEqual([what, []]);
        const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
        expect([what, r.status]).toEqual([what, "failed"]);
        expect([what, w.records.has(`database/data-purge-${APP}`)]).toEqual([what, false]);
        if (what !== "백업 없음") continue;
        // 파드가 쓰던 10/26 06:00에 백업이 끝나고 파드가 사라졌다: 새 기록(12:00) 뒤가 아니라 PR을 열지 않는다
        w.obj("backup", "database", "b1")!.status.stoppedAt = "2026-10-26T06:00:00Z";
        valkeyBackup(w, "2026-10-26T06:00:00Z");
        w.objects.delete(`pod/${NS}/writer`);
        const again = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
        expect(again.status).toBe("failed");
        expect(w.records.get(`database/data-purge-${APP}`)!.created).toBe("2026-10-26T12:00:00Z");
        expect(w.openPrs()).toEqual([]);
        expect(w.obj("pv", null, "pvc-9")!.spec.persistentVolumeReclaimPolicy).toBe("Retain");
      } finally {
        setSystemTime(new Date("2026-10-26T00:00:00Z"));
      }
    }
  });

  // PR 1이 병합·반영된 상태(보호 주석 없음, reclaim delete, PV Retain)
  async function prepared(): Promise<World> {
    const w = purgeWorld();
    await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    w.merge(900);
    for (const k of ["database", "databaserole"]) {
      const o = w.obj(k, "database", APP)!;
      delete o.metadata.annotations;
      o.spec = k === "database" ? { databaseReclaimPolicy: "delete" } : { databaseRoleReclaimPolicy: "delete" };
    }
    delete w.obj("pvc", NS, "valkey-data")!.metadata.annotations;
    return w;
  }

  test("r1 P1-1(#893): writes-stopped가 기록하는 사이·그 뒤 backup 재조회 때 앱 파드가 나타나면 기록을 지우고 멈춘다(PV·PR 2 없음)", async () => {
    // 리뷰 재현: PR 1 반영 뒤, 기록 없음(앞 무효화 뒤), 성공 백업 없음
    for (const when of ["기록하는 사이", "backup 재조회"] as const) {
      const w = await prepared();
      w.records.delete(`database/data-purge-${APP}`);
      w.obj("backup", "database", "b1")!.status.stoppedAt = "2026-10-19T00:00:00Z";
      valkeyBackup(w, "2026-10-19T00:00:00Z");
      // 기록이 생기면 파드를 켠다. backup 재조회: 쓰기 직후 확인·쓰기 뒤 재조회에서는 아직 끝난 파드, 그다음(backup의 읽기)부터 실행 중
      let armed = false;
      let reads = 0;
      const phase = () => (armed && (when === "기록하는 사이" || ++reads > 2) ? "Running" : "Succeeded");
      w.put("pod", NS, "writer", { metadata: { name: "writer", labels: { "homelab.ukyi.app/app": APP } }, status: { get phase() { return phase(); } } });
      const set = w.records.set.bind(w.records);
      w.records.set = (k, v) => {
        if (k === `database/data-purge-${APP}`) armed = true;
        return set(k, v);
      };
      w.writes = [];
      const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
      expect([when, r.status]).toEqual([when, "failed"]);
      expect(r.steps.find((x) => x.id === (when === "기록하는 사이" ? "writes-stopped" : "backup"))!.result).toBe("failed");
      expect(w.records.has(`database/data-purge-${APP}`)).toBe(false);
      expect(w.writes).toEqual([`recordCreate database/data-purge-${APP}`, `recordDelete database/data-purge-${APP}`]);
      expect(w.obj("pv", null, "pvc-9")!.spec.persistentVolumeReclaimPolicy).toBe("Retain");
      expect(w.openPrs()).toEqual([]);
    }
  });

  test("r1 P1-1(#893): 읽을 때 본 파드가 apply 때 사라졌어도 무효화한다(본 엔진 단계·워크로드 전용 실행)", async () => {
    // 본 엔진: 기록 직후 두 번(쓰기 직후 확인·재조회)은 끝난 파드, backup 재조회 한 번만 실행 중, apply 때는 다시 끝남
    const w = await prepared();
    w.records.delete(`database/data-purge-${APP}`);
    let armed = false;
    let reads = 0;
    w.put("pod", NS, "blip", { metadata: { name: "blip", labels: { "homelab.ukyi.app/app": APP } }, status: { get phase() { if (!armed) return "Succeeded"; reads++; return reads === 3 || reads === 4 ? "Running" : "Succeeded"; } } });
    const set = w.records.set.bind(w.records);
    w.records.set = (k, v) => {
      if (k === `database/data-purge-${APP}`) armed = true;
      return set(k, v);
    };
    const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("읽을 때 본 워크로드");
    expect(w.records.has(`database/data-purge-${APP}`)).toBe(false);
    expect(w.openPrs()).toEqual([]);

    // 워크로드 전용 실행: 전체 읽기·재조회에서 보이고(읽기 2번씩 4번) apply 때 사라짐
    const v = purgeWorld();
    let n = 0;
    v.put("pod", NS, "blip", { metadata: { name: "blip", labels: { "homelab.ukyi.app/app": APP } }, status: { get phase() { return ++n <= 4 ? "Running" : "Succeeded"; } } });
    const q = await runIn(v, cmd, "apply", { app: APP }, { confirm: APP });
    expect(q.status).toBe("failed");
    expect(q.steps.map((x) => x.id)).toEqual(["workloads", "record-invalidated"]);
    expect(v.records.has(`database/data-purge-${APP}`)).toBe(false);
  });

  test("r1 P1-2(#893): PR 2 병합 뒤 리소스가 남아 있는 동안은 Infisical이 깨져 있어도 대기로 끝난다", async () => {
    const w = await prepared();
    expect((await runIn(w, cmd, "apply", { app: APP }, { confirm: APP })).status).toBe("waiting");
    w.merge(901);
    w.infisical.has = () => {
      throw new Error("Infisical: 시간 초과(주입)");
    };
    const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    expect(r.status).toBe("waiting");
    expect(r.next).toContain("지우는 중");
  });

  test("r1 P1-1(#893): PV를 바꾸기 직전에 파드가 보이면(그 단계 읽기 뒤) 쓰지 않고 기록을 지운다", async () => {
    const w = await prepared();
    // pv-reclaim이 PV 정책을 두 번째로 읽는 때(apply 중 재조회)가 끝나면 파드가 생긴다. 그 뒤는 apply의 쓰기 직전 확인뿐이다
    const spec = w.obj("pv", null, "pvc-9")!.spec;
    let policy = spec.persistentVolumeReclaimPolicy;
    let reads = 0;
    Object.defineProperty(spec, "persistentVolumeReclaimPolicy", {
      get() {
        if (++reads === 2) w.put("pod", NS, "late", { metadata: { name: "late", labels: { "homelab.ukyi.app/app": APP } }, status: { phase: "Running" } });
        return policy;
      },
      set(v) {
        policy = v;
      },
    });
    w.writes = [];
    const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("pod/late");
    expect(w.writes).toEqual([`recordDelete database/data-purge-${APP}`]);
    expect(policy).toBe("Retain");
    expect(w.openPrs()).toEqual([]);
  });

  test("r1 P1-2(#893): Infisical·GitHub 조회가 실패해도 apply는 먼저 워크로드를 보고 기록을 지운다(plan은 쓰기 0)", async () => {
    setSystemTime(new Date("2026-10-26T12:00:00Z"));
    try {
      // 리뷰 재현: 기록 10/25 12:00, 백업 없음, 앱 파드, Infisical 폴더 조회 오류(+ GitHub 이력 오류)
      const w = purgeWorld();
      goneRecord(w, "2026-10-25T12:00:00Z");
      w.put("pod", NS, "writer", { metadata: { name: "writer", labels: { "homelab.ukyi.app/app": APP } }, status: { phase: "Running" } });
      const broken = () => {
        throw new Error("Infisical: 시간 초과(주입)");
      };
      const has = w.infisical.has.bind(w.infisical);
      w.infisical.has = broken;
      w.history.set(`apps/${APP}/values.yaml`, "broken");
      const p = await runIn(w, cmd, "plan", { app: APP });
      expect(p.steps.find((x) => x.id === "workloads")!.detail).toContain("무효가 된다");
      expect(w.writes).toEqual([]);
      const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
      expect(r.status).toBe("failed");
      // 워크로드 전용 실행에서 멈추고, 마지막 무효화 단계만 더 돈다(본 엔진은 돌지 않는다)
      expect(r.steps.map((x) => x.id)).toEqual(["workloads", "record-invalidated"]);
      expect(w.records.has(`database/data-purge-${APP}`)).toBe(false);
      expect(w.writes).toEqual([`recordDelete database/data-purge-${APP}`]);
      // 이어서: 조회가 정상이 되고, 파드가 쓰던 10/26 06:00의 백업 뒤 파드가 사라졌다 → 새 기록(12:00) 뒤가 아니라 PR 없음
      w.infisical.has = has;
      w.history.delete(`apps/${APP}/values.yaml`);
      w.obj("backup", "database", "b1")!.status.stoppedAt = "2026-10-26T06:00:00Z";
      valkeyBackup(w, "2026-10-26T06:00:00Z");
      w.objects.delete(`pod/${NS}/writer`);
      const again = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
      expect(again.status).toBe("failed");
      expect(w.records.get(`database/data-purge-${APP}`)!.created).toBe("2026-10-26T12:00:00Z");
      expect(w.openPrs()).toEqual([]);
    } finally {
      setSystemTime(new Date("2026-10-26T00:00:00Z"));
    }
  });

  test("r1 P1-2(#893): PR 2 병합·리소스 소멸 전에는 Infisical이 깨져 있어도 사전 읽기가 막히지 않는다", async () => {
    const w = purgeWorld();
    w.infisical.has = () => {
      throw new Error("Infisical: 시간 초과(주입)");
    };
    const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    expect(r.status).toBe("waiting");
    expect(w.openPrs().map((x) => x.head)).toEqual([`cli/data-purge-${APP}`]);
  });

  test("r2 P2-5: 종료 시각은 기록의 생성 시각(클러스터 시계)이라 이 기기 시계가 늦어도 그 전 백업을 인정하지 않는다", async () => {
    // 리뷰 재현: 이 기기 12:00, 클러스터는 20분 앞(12:20). 백업 시작 12:10(클러스터 시계)은 확인보다 앞이다
    setSystemTime(new Date("2026-10-26T12:00:00Z"));
    try {
      const w = purgeWorld();
      w.records.delete(`database/data-purge-${APP}`);
      w.clusterSkewMs = 20 * 60_000;
      w.obj("backup", "database", "b1")!.status.stoppedAt = "2026-10-26T12:10:00Z";
      valkeyBackup(w, "2026-10-26T12:10:00Z");
      const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
      expect(r.status).toBe("failed");
      expect(w.records.get(`database/data-purge-${APP}`)!.created).toBe("2026-10-26T12:20:00Z");
      expect(w.openPrs()).toEqual([]);
    } finally {
      setSystemTime(new Date("2026-10-26T00:00:00Z"));
    }
  });

  function pgOnlyWorld(): World {
    // 앱 없이 PostgreSQL만 등록한 데이터(T12-05의 homelab-probe2). 앱 ns가 없다
    const w = new World({ [DATA]: "chartVersion: 1.0.1\npostgres: { enabled: true }\n" });
    w.strictNamespaces = true;
    w.put("namespace", null, "database", { metadata: { name: "database" } });
    w.put("database", "database", APP, { metadata: { name: APP, creationTimestamp: "2026-10-22T03:00:00Z", annotations: { "argocd.argoproj.io/sync-options": "Prune=false,Delete=false" } }, spec: { databaseReclaimPolicy: "retain" } });
    w.put("databaserole", "database", APP, { metadata: { name: APP }, spec: { databaseRoleReclaimPolicy: "retain" } });
    w.put("application", "argocd", `${APP}-data`, { metadata: { name: `${APP}-data` } });
    w.put("backup", "database", "b1", { spec: { cluster: { name: "pg" } }, status: { phase: "completed", stoppedAt: "2026-10-21T18:00:00Z" } });
    w.tags.add("data-chart-v1.0.2");
    w.history.set(`apps/${APP}/values.yaml`, []);
    w.history.set(DATA, [{ date: "2026-10-20T00:00:00Z", status: "added" }]);
    return w;
  }

  test("r3 P1-2: 앱 ns가 없는 PostgreSQL 전용도 폐기 확인 시각을 database ns에 기록하고, 그 뒤 완료한 Backup만 인정한다", async () => {
    // 리뷰 재현: 등록 10/20, completed Backup 10/21 18:00, DB 생성 10/22 03:00(백업에 DB가 없다)
    const w = pgOnlyWorld();
    const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    expect(r.status).toBe("failed");
    expect(w.records.get(`database/data-purge-${APP}`)!.created).toBe("2026-10-26T00:00:00Z");
    expect(w.writes).toEqual([`recordCreate database/data-purge-${APP}`]);
    expect(w.openPrs()).toEqual([]);
    // 재실행도 같은 기록으로 멈춘다
    w.writes = [];
    expect((await runIn(w, cmd, "apply", { app: APP }, { confirm: APP })).status).toBe("failed");
    expect(w.writes).toEqual([]);
    // T12-05: 기록 뒤 온디맨드 Backup CR 하나가 끝나면 PR 1을 연다
    setSystemTime(new Date("2026-10-26T01:00:00Z"));
    try {
      w.put("backup", "database", "ondemand", { spec: { cluster: { name: "pg" } }, status: { phase: "completed", stoppedAt: "2026-10-26T00:10:00Z" } });
      expect((await runIn(w, cmd, "apply", { app: APP }, { confirm: APP })).status).toBe("waiting");
      expect(w.openPrs().map((x) => x.head)).toEqual([`cli/data-purge-${APP}`]);
    } finally {
      setSystemTime(new Date("2026-10-26T00:00:00Z"));
    }
  });

  test("r3 P1-2: 기록 생성과 같은 초에 끝난 Backup은 인정하지 않는다(완료가 기록보다 뒤여야 한다)", async () => {
    const w = pgOnlyWorld();
    w.records.set(`database/data-purge-${APP}`, { run: "seed", data: {}, created: "2026-10-25T00:00:00Z" });
    w.obj("backup", "database", "b1")!.status.stoppedAt = "2026-10-25T00:00:00Z";
    expect((await runIn(w, cmd, "apply", { app: APP }, { confirm: APP })).status).toBe("failed");
    w.obj("backup", "database", "b1")!.status.stoppedAt = "2026-10-25T00:00:01Z";
    expect((await runIn(w, cmd, "apply", { app: APP }, { confirm: APP })).status).toBe("waiting");
  });

  test("r1 P1-4: PostgreSQL base backup이 ObjectStore 보존(14일, 여유 2일)을 넘으면 PR을 열지 않는다", async () => {
    const w = purgeWorld();
    w.history.set(`apps/${APP}/values.yaml`, [{ date: "2026-10-01T00:00:00Z", status: "removed" }]);
    w.history.set(DATA, [{ date: "2026-09-01T00:00:00Z", status: "added" }]);
    goneRecord(w, "2026-10-01T06:00:00Z");
    w.obj("backup", "database", "b1")!.status.stoppedAt = "2026-10-02T18:00:00Z";
    valkeyBackup(w, "2026-10-25T18:30:00Z");
    const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("base backup");
    expect(r.error!.message).toContain("12일보다 오래됐다");
    expect(w.openPrs()).toEqual([]);
    expect(w.writes).toEqual([]);
    // 새 base backup이 있으면(옛 CR이 남아 있어도) 가장 최근 것으로 본다
    w.put("backup", "database", "b2", { spec: { cluster: { name: "pg" } }, status: { phase: "completed", stoppedAt: "2026-10-14T00:00:01Z" } });
    expect((await runIn(w, cmd, "apply", { app: APP }, { confirm: APP })).status).toBe("waiting");
    // 경계: 12일 + 1초 → 멈춤
    w.obj("backup", "database", "b2")!.status.stoppedAt = "2026-10-13T23:59:59Z";
    expect((await runIn(w, cmd, "apply", { app: APP }, { confirm: APP })).status).toBe("failed");
    // 미래 시각 → 멈춤
    w.obj("backup", "database", "b2")!.status.stoppedAt = "2026-10-27T00:00:00Z";
    expect((await runIn(w, cmd, "apply", { app: APP }, { confirm: APP })).status).toBe("failed");
  });

  test("Connector P1: 성공한 백업 Job을 확인할 수 없으면 완료 시각이 새로워도 멈춘다", async () => {
    const cases: [string, (w: World) => void][] = [
      ["Job 이력 없음", (w) => w.objects.delete(`job/${NS}/gone-valkey-backup-1`)],
      ["실패한 Job뿐", (w) => valkeyBackup(w, "2026-10-25T18:30:00Z", { complete: false })],
      ["다른 CronJob의 Job", (w) => valkeyBackup(w, "2026-10-25T18:30:00Z", { owner: "other-valkey-backup" })],
      ["시작 시각 없음", (w) => delete w.obj("job", NS, "gone-valkey-backup-1")!.status.startTime],
    ];
    for (const [what, change] of cases) {
      const w = purgeWorld();
      w.obj("cronjob", NS, `${APP}-valkey-backup`)!.status.lastSuccessfulTime = "2026-10-25T18:31:00Z";
      change(w);
      const r = await runIn(w, cmd, "apply", { app: APP }, { confirm: APP });
      expect([what, r.status]).toEqual([what, "failed"]);
      expect(w.openPrs()).toEqual([]);
      expect(w.writes).toEqual([]);
    }
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
