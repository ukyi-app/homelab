import { describe, expect, test } from "bun:test";
import { FAKE_SHA, expectPlanReadOnly, ghGet, kubectlRule, runCli, type Rule } from "../harness";
import cmd from "../../src/commands/restore-cache";
import { World, runIn, valkeyWorld } from "../fixtures/rotate-world/world";

const APP = "probe";
const NS = `app-${APP}`;
const DATA = `data/${APP}/values.yaml`;
const GOT = `r2:homelab-backups/valkey/${APP}/dump-20261026T000000Z.rdb`;
const notFound = { code: 1, stderr: 'Error from server (NotFound): x "y" not found\n' };
const contents = (path: string, ref = "main") => `repos/ukyi-app/homelab/contents/${path}?ref=${ref}`;
const fileResp = (text: string) => ({ type: "file", encoding: "base64", content: Buffer.from(text).toString("base64") });
const dataText = "chartVersion: 1.0.1\nvalkey: { persistent: true }\n";
const cronjob = { spec: { suspend: false, jobTemplate: { spec: { template: { spec: { containers: [{ name: "upload", image: "docker.io/rclone/rclone:1.75.2@sha256:2687085f718d3c628f7fdfb77c52a1d344332aed543110bb88088f2c70d43eb5", env: [{ name: "BUCKET", value: "homelab-backups" }] }] } } } } } };

function planRules(): Rule[] {
  return [
    ghGet(contents(DATA), 200, fileResp(dataText)),
    kubectlRule(["-n", NS, "get", "cronjobs.batch", `${APP}-valkey-backup`, "-o", "json"], { stdout: JSON.stringify(cronjob) }),
    kubectlRule(["-n", NS, "get", "configmaps", "restore-vk", "-o", "json"], notFound),
    kubectlRule(["-n", NS, "get", "jobs.batch", "restore-vk", "-o", "json"], notFound),
    kubectlRule(["-n", NS, "get", "deployments.apps", `${APP}-valkey`, "-o", "json"], { stdout: JSON.stringify({ spec: { replicas: 1 }, status: { updatedReplicas: 1, readyReplicas: 1 } }) }),
    kubectlRule(["-n", NS, "get", "pods", "-o", "json"], { stdout: JSON.stringify({ items: [] }) }),
    kubectlRule(["-n", NS, "get", "jobs.batch", "-o", "json"], { stdout: JSON.stringify({ items: [] }) }),
    ghGet("repos/ukyi-app/homelab/git/ref/heads/main", 200, { object: { sha: FAKE_SHA } }),
    ghGet(contents(DATA, FAKE_SHA), 200, fileResp(dataText)),
    ghGet(`repos/ukyi-app/homelab/pulls?head=ukyi-app%3Acli%2Fcache-restore-${APP}&state=open`, 200, []),
  ];
}

describe("cache restore: plan(PATH 스텁)", () => {
  test("처음 plan은 쓰기 0건, 서버 내림 PR부터 순서를 보인다", async () => {
    const r = await runCli(["cache", "restore", APP, "--json"], planRules());
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.status).toBe("pending");
    expect(r.json.steps.map((s: { id: string }) => s.id)).toEqual(["registered", "other-runs", "lock", "pr-down", "down", "restore-job", "pr-mode", "loaded", "aof", "pr-normal", "reloaded", "cleanup"]);
  });

  test("--finish·--abort 함께, 또는 --finish와 --object는 64", async () => {
    for (const args of [["cache", "restore", APP, "--finish", "--abort"], ["cache", "restore", APP, "--finish", "--object", "latest"], ["cache", "restore", APP, "--object", "../x"]]) {
      const r = await runCli(args, planRules());
      expect(r.code).toBe(64);
      expectPlanReadOnly(r, { allowNoCalls: true });
    }
  });
});

function restoreWorld(): World {
  const w = valkeyWorld(APP, "persistent");
  w.obj("deployment", NS, `${APP}-valkey`)!.status = { updatedReplicas: 1, readyReplicas: 1 };
  // 데이터 Application의 source는 차트 태그라 revision은 main SHA가 아니다(#883 r1 P2). values는 valuesObject로 들어간다.
  const mode = { chartVersion: "1.0.1", valkey: { persistent: true, running: true, restoreMode: true } };
  w.put("application", "argocd", `${APP}-data`, { spec: { source: { targetRevision: "data-chart-v1.0.1", helm: { valuesObject: mode } } }, status: { sync: { status: "Synced", revision: "c".repeat(40), comparedTo: { source: { helm: { valuesObject: mode } } } } } });
  w.jobLogs.set("restore-vk", `받음: ${GOT}\n-rw-r--r-- dump.rdb\n`);
  return w;
}

describe("cache restore: 흐름(가짜 세계)", () => {
  test("restore.md 1절 순서대로, PR마다 멈추고 이어 간다. 끝나면 모두 same, --finish가 기록을 지운다", async () => {
    const w = restoreWorld();
    const vk = w.valkeys.get(`${NS}/${APP}-valkey`)!;

    const r1 = await runIn(w, cmd, "apply", { app: APP });
    expect(r1.status).toBe("waiting");
    expect(w.records.get(`${NS}/restore-vk`)!.data.object).toBe("latest");
    expect(w.commits.get(w.refs.get(`cli/cache-restore-${APP}`)!)!.files.get(DATA)).toContain("valkey: { persistent: true, running: false }");

    w.merge(900);
    const r2 = await runIn(w, cmd, "apply", { app: APP });
    expect(r2.status).toBe("waiting");
    expect(r2.next).toContain("서버 내림");
    // 서버가 아직 떠 있는 동안 복원 Job을 만들지 않는다
    expect(w.obj("job", NS, "restore-vk")).toBeUndefined();

    // Argo CD가 서버를 내림
    w.objects.delete(`deployment/${NS}/${APP}-valkey`);
    w.obj("cronjob", NS, `${APP}-valkey-backup`)!.spec.suspend = true;
    const r3 = await runIn(w, cmd, "apply", { app: APP });
    expect(r3.status).toBe("waiting");
    const job = w.obj("job", NS, "restore-vk")!;
    const run = w.records.get(`${NS}/restore-vk`)!.run;
    expect(job.metadata.labels["homelab.ukyi.app/restore"]).toBe(run);
    expect(job.spec.template.spec.volumes[0].persistentVolumeClaim.claimName).toBe("valkey-data");
    expect(JSON.stringify(job)).not.toContain('"kind":"Secret"');
    expect(w.records.get(`${NS}/restore-vk`)!.data.got).toBe(GOT);
    expect(w.openPrs().map((p) => p.head)).toEqual([`cli/cache-restore-mode-${APP}`]);

    // 복원 모드로 뜸(appendonly no, RDB의 키 5개)
    w.merge(901);
    w.put("deployment", NS, `${APP}-valkey`, { metadata: { generation: 2 }, spec: { replicas: 1 }, status: { observedGeneration: 2, updatedReplicas: 1, readyReplicas: 1 } });
    w.obj("cronjob", NS, `${APP}-valkey-backup`)!.spec.suspend = false;
    vk.appendonly = false;
    vk.aof = false;
    vk.keys = 5;
    const r4 = await runIn(w, cmd, "apply", { app: APP });
    expect(r4.status).toBe("waiting");
    expect(w.records.get(`${NS}/restore-vk`)!.data.dbsize).toBe("5");
    expect(vk.appendonly).toBe(true);
    expect(w.openPrs().map((p) => p.head)).toEqual([`cli/cache-restore-normal-${APP}`]);

    w.merge(902);
    expect(w.main().get(DATA)).toContain("valkey: { persistent: true }");
    const r5 = await runIn(w, cmd, "apply", { app: APP });
    expect(r5.status).toBe("waiting");
    expect(r5.next).toContain("복원 모드 끄기");

    // ApplicationSet이 새 values를 spec에 넣었지만 Argo CD가 아직 비교하지 않았다 → 아직 대기
    const argo = w.obj("application", "argocd", `${APP}-data`)!;
    const clean = { chartVersion: "1.0.1", valkey: { persistent: true } };
    argo.spec.source.helm.valuesObject = clean;
    expect((await runIn(w, cmd, "apply", { app: APP })).status).toBe("waiting");
    argo.status.sync.comparedTo.source.helm.valuesObject = clean;
    w.writes = [];
    const r6 = await runIn(w, cmd, "apply", { app: APP });
    expect(r6.status).toBe("done");
    expect(r6.next).toBe(`homelab cache restore ${APP} --finish`);
    expect(w.writes).toContain(`rolloutRestart ${NS}/${APP}-valkey`);
    expect(w.obj("job", NS, "restore-vk")).toBeUndefined();

    w.writes = [];
    const r7 = await runIn(w, cmd, "apply", { app: APP });
    expect(r7.status).toBe("same");
    expect(w.writes).toEqual([]);

    const f = await runIn(w, cmd, "apply", { app: APP }, { finish: true });
    expect(f.status).toBe("done");
    expect(w.records.size).toBe(0);
    const f2 = await runIn(w, cmd, "apply", { app: APP }, { finish: true });
    expect(f2.status).toBe("same");
  });

  test("복원 모드가 반영되지 않아 appendonly yes로 떴으면 멈춘다(빈 데이터, U18)", async () => {
    const w = restoreWorld();
    await runIn(w, cmd, "apply", { app: APP });
    w.merge(900);
    w.objects.delete(`deployment/${NS}/${APP}-valkey`);
    w.obj("cronjob", NS, `${APP}-valkey-backup`)!.spec.suspend = true;
    await runIn(w, cmd, "apply", { app: APP });
    w.merge(901);
    w.put("deployment", NS, `${APP}-valkey`, { spec: { replicas: 1 }, status: { updatedReplicas: 1, readyReplicas: 1 } });
    const r = await runIn(w, cmd, "apply", { app: APP });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("복원 모드가 아니다");
    expect(w.records.get(`${NS}/restore-vk`)!.data["ok.loaded"]).toBeUndefined();
  });

  test("valkey-data를 쓰는 다른 파드가 남아 있으면 복원 Job을 만들지 않는다", async () => {
    const w = restoreWorld();
    await runIn(w, cmd, "apply", { app: APP });
    w.merge(900);
    w.objects.delete(`deployment/${NS}/${APP}-valkey`);
    w.obj("cronjob", NS, `${APP}-valkey-backup`)!.spec.suspend = true;
    w.put("pod", NS, "old-vk", { metadata: { name: "old-vk" }, status: { phase: "Running" }, spec: { volumes: [{ persistentVolumeClaim: { claimName: "valkey-data" } }] } });
    const r = await runIn(w, cmd, "apply", { app: APP });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("pod/old-vk");
    expect(w.obj("job", NS, "restore-vk")).toBeUndefined();
  });

  test("다른 객체로 진행 중인 복원이 있으면 쓰기 없이 멈춘다", async () => {
    const w = restoreWorld();
    w.records.set(`${NS}/restore-vk`, { run: "20261026000000abcdef", data: { object: "latest" } });
    const r = await runIn(w, cmd, "apply", { app: APP }, { object: "dump-20261020T000000Z.rdb" });
    expect(r.status).toBe("failed");
    expect(w.writes).toEqual([]);
  });

  test("--backup-first: 수동 백업 Job이 끝나야 서버 내림 PR을 연다", async () => {
    const w = restoreWorld();
    const orig = w.read.bind(w);
    let fail = true;
    w.read = (mode) => {
      const ctx = orig(mode);
      const base = (ctx.k8s as any).waitCondition;
      (ctx.k8s as any).waitCondition = (...a: any[]) => (fail && String(a[2]?.name).startsWith("backup-") ? false : base(...a));
      return ctx;
    };
    const r = await runIn(w, cmd, "apply", { app: APP }, { "backup-first": true });
    expect(r.status).toBe("failed");
    expect(w.openPrs()).toEqual([]);
    fail = false;
    const again = await runIn(w, cmd, "apply", { app: APP }, { "backup-first": true });
    expect(again.status).toBe("waiting");
    expect(w.records.get(`${NS}/restore-vk`)!.data.backup).toContain("dump-");
    expect(w.openPrs()).toHaveLength(1);
  });

  // 서버를 내리고 복원 Job 단계까지 간 세계. 복원 Job의 결과는 outcome으로 정한다.
  async function toRestoreJob(outcome: "complete" | "failed", logs = `받음: ${GOT}\n`): Promise<World> {
    const w = restoreWorld();
    await runIn(w, cmd, "apply", { app: APP });
    w.merge(900);
    w.objects.delete(`deployment/${NS}/${APP}-valkey`);
    w.obj("cronjob", NS, `${APP}-valkey-backup`)!.spec.suspend = true;
    w.jobOutcome.set("restore-vk", outcome);
    w.jobLogs.set("restore-vk", logs);
    return w;
  }

  test("r1 P1-1: 복원 Job이 실패해 사람이 지웠어도 --abort는 거부한다(PVC가 이미 바뀌었을 수 있다)", async () => {
    const w = await toRestoreJob("failed");
    const r = await runIn(w, cmd, "apply", { app: APP });
    expect(r.status).toBe("failed");
    w.objects.delete(`job/${NS}/restore-vk`);
    const a = await runIn(w, cmd, "apply", { app: APP }, { abort: true });
    expect(a.status).toBe("failed");
    expect(a.error!.message).toContain("PVC가 바뀌었을 수 있다");
    expect(w.openPrs()).toEqual([]);
    expect(w.records.size).toBe(1);
  });

  test("r1 P1-1: Job은 끝났지만 로그를 못 읽어 표식이 없어도 --abort는 거부한다", async () => {
    const w = await toRestoreJob("complete", "");
    const r = await runIn(w, cmd, "apply", { app: APP });
    expect(r.status).toBe("failed");
    expect(w.records.get(`${NS}/restore-vk`)!.data["ok.job"]).toBeUndefined();
    w.objects.delete(`job/${NS}/restore-vk`);
    const a = await runIn(w, cmd, "apply", { app: APP }, { abort: true });
    expect(a.status).toBe("failed");
    expect(w.openPrs()).toEqual([]);
  });

  test("r1 P1-1: 기록 전 복원 Job 파드가 valkey-data를 쓰고 있으면 --abort는 거부한다", async () => {
    const w = restoreWorld();
    await runIn(w, cmd, "apply", { app: APP });
    w.put("pod", NS, "restore-vk-abc", { metadata: { name: "restore-vk-abc", labels: { "job-name": "restore-vk" } }, status: { phase: "Running" }, spec: { volumes: [{ persistentVolumeClaim: { claimName: "valkey-data" } }] } });
    const a = await runIn(w, cmd, "apply", { app: APP }, { abort: true });
    expect(a.status).toBe("failed");
    expect(w.records.size).toBe(1);
  });

  async function finished(): Promise<World> {
    const w = await toRestoreJob("complete");
    const vk = w.valkeys.get(`${NS}/${APP}-valkey`)!;
    await runIn(w, cmd, "apply", { app: APP });
    w.merge(901);
    w.put("deployment", NS, `${APP}-valkey`, { spec: { replicas: 1 }, status: { updatedReplicas: 1, readyReplicas: 1 } });
    w.obj("cronjob", NS, `${APP}-valkey-backup`)!.spec.suspend = false;
    vk.appendonly = false;
    vk.aof = false;
    await runIn(w, cmd, "apply", { app: APP });
    w.merge(902);
    const argo = w.obj("application", "argocd", `${APP}-data`)!;
    const clean = { chartVersion: "1.0.1", valkey: { persistent: true } };
    argo.spec.source.helm.valuesObject = clean;
    argo.status.sync.comparedTo.source.helm.valuesObject = clean;
    const done = await runIn(w, cmd, "apply", { app: APP });
    expect(done.status).toBe("done");
    return w;
  }

  test("r1 P1-3: 끝난 실행에 --backup-first를 붙여 다시 치면 새 Job을 만들지 않고 멈춘다", async () => {
    const w = await finished();
    w.writes = [];
    const r = await runIn(w, cmd, "apply", { app: APP }, { "backup-first": true });
    expect(r.status).toBe("failed");
    expect(w.writes).toEqual([]);
  });

  test("r1 P1-3: --finish는 기록을 지우기 직전에 이 실행의 Job·파드를 다시 보고, 남아 있으면 지우지 않는다", async () => {
    const w = await finished();
    const run = w.records.get(`${NS}/restore-vk`)!.run;
    w.put("pod", NS, "late", { metadata: { name: "late", labels: { "homelab.ukyi.app/restore": run } }, status: { phase: "Running" } });
    const f = await runIn(w, cmd, "apply", { app: APP }, { finish: true });
    expect(f.status).toBe("failed");
    expect(f.error!.message).toContain("pod/late");
    expect(w.records.size).toBe(1);
    w.objects.delete(`pod/${NS}/late`);
    expect((await runIn(w, cmd, "apply", { app: APP }, { finish: true })).status).toBe("done");
  });

  test("기록만 지워진 진행 중 복원(서버 내려감)은 새 실행으로 다시 시작하지 않는다", async () => {
    const w = await toRestoreJob("complete");
    await runIn(w, cmd, "apply", { app: APP });
    w.records.clear();
    // 사람이 끝난 restore-vk Job도 지웠다. 남은 흔적은 서버가 내려간 것과 values의 running뿐이다
    w.objects.delete(`job/${NS}/restore-vk`);
    w.writes = [];
    const r = await runIn(w, cmd, "apply", { app: APP });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("복원 흔적");
    expect(w.writes).toEqual([]);
  });

  test("r2 P1-1: 실행 기록이 사라져도 복원 흔적(Job, values의 running)이 있으면 --abort는 PR을 열지 않는다", async () => {
    const w = await toRestoreJob("failed");
    await runIn(w, cmd, "apply", { app: APP });
    w.records.clear();
    const a = await runIn(w, cmd, "apply", { app: APP }, { abort: true });
    expect(a.status).toBe("failed");
    expect(a.error!.message).toContain("복원 흔적");
    expect(w.openPrs()).toEqual([]);
    // Job까지 지워도 values의 running: false가 남아 있다
    w.objects.delete(`job/${NS}/restore-vk`);
    const b = await runIn(w, cmd, "apply", { app: APP }, { abort: true });
    expect(b.status).toBe("failed");
    expect(w.openPrs()).toEqual([]);
  });

  test("r2 P1-1: 기록도 흔적도 없으면 --abort는 할 일 없음(same)", async () => {
    const w = restoreWorld();
    const a = await runIn(w, cmd, "apply", { app: APP }, { abort: true });
    expect(a.status).toBe("same");
    expect(w.writes).toEqual([]);
  });

  test("r2 P2-3: 라벨 없는 수동 백업 파드가 남아 있으면 --abort·--finish는 기록을 지우지 않는다", async () => {
    const w = restoreWorld();
    const orig = w.read.bind(w);
    w.read = (mode) => {
      const ctx = orig(mode);
      const base = (ctx.k8s as any).waitCondition;
      (ctx.k8s as any).waitCondition = (...a: any[]) => (String(a[2]?.name).startsWith("backup-") ? false : base(...a));
      return ctx;
    };
    const r = await runIn(w, cmd, "apply", { app: APP }, { "backup-first": true });
    expect(r.status).toBe("failed");
    const job = w.records.get(`${NS}/restore-vk`)!.data["backup.jobs"];
    expect(job).toMatch(/^backup-[a-z0-9]+-[0-9a-f]{4}$/);
    // 실제 백업 파드는 Job 라벨(job-name)만 있고 실행 라벨이 없다
    w.put("pod", NS, `${job}-xyz`, { metadata: { name: `${job}-xyz`, labels: { "job-name": job } }, status: { phase: "Running" } });
    const a = await runIn(w, cmd, "apply", { app: APP }, { abort: true });
    expect(a.status).toBe("failed");
    expect(a.error!.message).toContain(`pod/${job}-xyz`);
    expect(w.records.size).toBe(1);
    w.objects.delete(`pod/${NS}/${job}-xyz`);
    expect((await runIn(w, cmd, "apply", { app: APP }, { abort: true })).status).toBe("done");
    expect(w.records.size).toBe(0);
  });

  test("r2 P2-4: 서버가 Ready가 아니어도(AOF 손상 등) 복원 흔적이 없으면 복원을 시작한다", async () => {
    const w = restoreWorld();
    w.obj("deployment", NS, `${APP}-valkey`)!.status = { updatedReplicas: 1, readyReplicas: 0 };
    const r = await runIn(w, cmd, "apply", { app: APP });
    expect(r.status).toBe("waiting");
    expect(w.openPrs().map((p) => p.head)).toEqual([`cli/cache-restore-${APP}`]);
  });

  test("r2 P2-5: 복원 Job 전 사전 검사에서 멈추면 touched를 남기지 않아 --abort가 된다", async () => {
    const w = restoreWorld();
    await runIn(w, cmd, "apply", { app: APP });
    w.merge(900);
    w.objects.delete(`deployment/${NS}/${APP}-valkey`);
    w.obj("cronjob", NS, `${APP}-valkey-backup`)!.spec.suspend = true;
    // 아직 끝나는 중인 옛 서버 파드(PVC를 마운트)
    w.put("pod", NS, "old-server", { metadata: { name: "old-server" }, status: { phase: "Running" }, spec: { volumes: [{ persistentVolumeClaim: { claimName: "valkey-data" } }] } });
    const r = await runIn(w, cmd, "apply", { app: APP });
    expect(r.status).toBe("failed");
    expect(w.obj("job", NS, "restore-vk")).toBeUndefined();
    expect(w.records.get(`${NS}/restore-vk`)!.data.touched).toBeUndefined();
    w.objects.delete(`pod/${NS}/old-server`);
    const a = await runIn(w, cmd, "apply", { app: APP }, { abort: true });
    // 서버를 다시 올리는 PR을 열고 병합을 기다린다(거부가 아니다)
    expect(a.status).toBe("waiting");
    expect(w.openPrs().map((p) => p.head)).toEqual([`cli/cache-restore-abort-${APP}`]);
  });

  // 서버 내림을 확인(ok.down)한 뒤 옛 서버 파드 때문에 사전 검사에서 멈춘 상태. 파드는 이제 없다.
  async function downThenBlocked(): Promise<World> {
    const w = restoreWorld();
    await runIn(w, cmd, "apply", { app: APP });
    w.merge(900);
    w.objects.delete(`deployment/${NS}/${APP}-valkey`);
    w.obj("cronjob", NS, `${APP}-valkey-backup`)!.spec.suspend = true;
    w.put("pod", NS, "old-server", { metadata: { name: "old-server" }, status: { phase: "Running" }, spec: { volumes: [{ persistentVolumeClaim: { claimName: "valkey-data" } }] } });
    expect((await runIn(w, cmd, "apply", { app: APP })).status).toBe("failed");
    expect(w.records.get(`${NS}/restore-vk`)!.data["ok.down"]).toBe("1");
    w.objects.delete(`pod/${NS}/old-server`);
    return w;
  }
  const noNewJob = (w: World) => {
    expect(w.obj("job", NS, "restore-vk")).toBeUndefined();
    expect(w.writes).not.toContain(`create Job ${NS}/restore-vk`);
  };

  test("r3 P1-2: --abort PR 병합 뒤 Deployment만 다시 생기고 파드가 없어도 기본 복원은 Job을 만들지 않는다", async () => {
    const w = await downThenBlocked();
    const a = await runIn(w, cmd, "apply", { app: APP }, { abort: true });
    expect(a.status).toBe("waiting");
    w.merge(901);
    // Argo CD가 Deployment만 다시 만들고 아직 파드는 없다. CronJob suspend도 풀렸다
    w.put("deployment", NS, `${APP}-valkey`, { metadata: { name: `${APP}-valkey` }, spec: { replicas: 1 }, status: {} });
    w.obj("cronjob", NS, `${APP}-valkey-backup`)!.spec.suspend = false;
    w.writes = [];
    const r = await runIn(w, cmd, "apply", { app: APP });
    expect(r.status).toBe("waiting");
    noNewJob(w);
    const rec = w.records.get(`${NS}/restore-vk`)!;
    expect(rec.data.touched).toBeUndefined();
    expect(rec.data["ok.down"]).toBeUndefined();
    // 다음 실행은 서버 내림 PR부터 다시 연다(옛 표식을 믿지 않는다)
    const again = await runIn(w, cmd, "apply", { app: APP });
    expect(again.status).toBe("waiting");
    expect(w.openPrs().map((p) => p.head)).toEqual([`cli/cache-restore-${APP}`]);
    noNewJob(w);
    // 그만두기는 여전히 된다(touched 없음)
    const b = await runIn(w, cmd, "apply", { app: APP }, { abort: true });
    expect(b.status).not.toBe("failed");
  });

  test("r3 P1-2: 서버 내림 조건이 하나라도 풀리면 재시도에서 Job을 만들지 않고, 다시 내린 뒤에 잇는다", async () => {
    const changes: [string, (w: World) => void][] = [
      ["Deployment 다시 생김", (w) => w.put("deployment", NS, `${APP}-valkey`, { metadata: { name: `${APP}-valkey` }, status: {} })],
      ["CronJob suspend 풀림", (w) => (w.obj("cronjob", NS, `${APP}-valkey-backup`)!.spec.suspend = false)],
      ["PVC 없음", (w) => w.objects.delete(`pvc/${NS}/valkey-data`)],
      // 클러스터는 아직 내려가 있지만 main이 서버를 다시 올리라고 한다(그만두기 PR 병합 직후, Argo CD 반영 전)
      ["main에 running: false 없음", (w) => w.main().set(DATA, w.main().get(DATA)!.replace(", running: false", ""))],
    ];
    for (const [what, change] of changes) {
      const w = await downThenBlocked();
      change(w);
      w.writes = [];
      const r = await runIn(w, cmd, "apply", { app: APP });
      expect([what, r.status]).toEqual([what, "waiting"]);
      noNewJob(w);
      expect(w.records.get(`${NS}/restore-vk`)!.data.touched).toBeUndefined();
    }
    // 되돌리면(서버 내림 반영) 같은 실행이 Job으로 잇는다
    const w = await downThenBlocked();
    w.obj("cronjob", NS, `${APP}-valkey-backup`)!.spec.suspend = false;
    expect((await runIn(w, cmd, "apply", { app: APP })).status).toBe("waiting");
    w.obj("cronjob", NS, `${APP}-valkey-backup`)!.spec.suspend = true;
    const r = await runIn(w, cmd, "apply", { app: APP });
    expect(r.status).toBe("waiting");
    expect(w.obj("job", NS, "restore-vk")).toBeDefined();
    expect(w.records.get(`${NS}/restore-vk`)!.data["ok.down"]).toBe("1");
  });

  test("r3 P1-2: 실패한 복원 Job을 지운 뒤 재시도도 서버가 다시 떠 있으면 새 Job을 만들지 않는다", async () => {
    const w = await toRestoreJob("failed");
    expect((await runIn(w, cmd, "apply", { app: APP })).status).toBe("failed");
    expect(w.records.get(`${NS}/restore-vk`)!.data.touched).toBe("1");
    w.objects.delete(`job/${NS}/restore-vk`);
    w.put("deployment", NS, `${APP}-valkey`, { metadata: { name: `${APP}-valkey` }, status: {} });
    w.writes = [];
    const r = await runIn(w, cmd, "apply", { app: APP });
    expect(r.status).toBe("waiting");
    noNewJob(w);
  });

  // 복원 모드로 떠 키 5개를 읽고 AOF를 켠 뒤, 복원 모드 끄기 PR(903)이 열린 상태.
  async function toNormalPr(): Promise<{ w: World; vk: { appendonly: boolean; aof: boolean; keys: number; markers?: Set<string> } }> {
    const w = restoreWorld();
    const vk = w.valkeys.get(`${NS}/${APP}-valkey`)!;
    await runIn(w, cmd, "apply", { app: APP });
    w.merge(900);
    w.objects.delete(`deployment/${NS}/${APP}-valkey`);
    w.obj("cronjob", NS, `${APP}-valkey-backup`)!.spec.suspend = true;
    await runIn(w, cmd, "apply", { app: APP });
    w.merge(901);
    w.put("deployment", NS, `${APP}-valkey`, { metadata: { generation: 2 }, spec: { replicas: 1 }, status: { observedGeneration: 2, updatedReplicas: 1, readyReplicas: 1 } });
    w.obj("cronjob", NS, `${APP}-valkey-backup`)!.spec.suspend = false;
    vk.appendonly = false;
    vk.aof = false;
    vk.keys = 5;
    expect((await runIn(w, cmd, "apply", { app: APP })).status).toBe("waiting");
    expect(w.records.get(`${NS}/restore-vk`)!.data["ok.aof"]).toBe("1");
    expect(w.openPrs().map((p) => p.head)).toEqual([`cli/cache-restore-normal-${APP}`]);
    return { w, vk };
  }
  function mergeNormal(w: World) {
    w.merge(902);
    const clean = { chartVersion: "1.0.1", valkey: { persistent: true } };
    const argo = w.obj("application", "argocd", `${APP}-data`)!;
    argo.spec.source.helm.valuesObject = clean;
    argo.status.sync.comparedTo.source.helm.valuesObject = clean;
  }

  test("Connector P1: 복원 모드 끄기 PR을 기다리는 동안 서버가 재시작돼 AOF가 꺼졌으면 재시작하지 않고 AOF부터 다시 켠다", async () => {
    const { w, vk } = await toNormalPr();
    // 복원 모드 ConfigMap 그대로 재시작: appendonly no로 RDB를 읽고 뜬다
    vk.appendonly = false;
    vk.aof = false;
    mergeNormal(w);
    w.writes = [];
    const r = await runIn(w, cmd, "apply", { app: APP });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("AOF부터 다시 켠다");
    expect(w.writes).not.toContain(`rolloutRestart ${NS}/${APP}-valkey`);
    expect(w.records.get(`${NS}/restore-vk`)!.data["ok.aof"]).toBeUndefined();
    // 다음 실행: AOF를 다시 켜고(rewrite) 그 뒤에야 재시작한다
    w.writes = [];
    const again = await runIn(w, cmd, "apply", { app: APP });
    expect(again.status).toBe("done");
    const on = w.writes.indexOf(`valkey appendonly ${NS}/${APP}-valkey`);
    const restart = w.writes.indexOf(`rolloutRestart ${NS}/${APP}-valkey`);
    expect(on).toBeGreaterThanOrEqual(0);
    expect(restart).toBeGreaterThan(on);
    // rewrite가 끝나지 않은(aof_enabled는 됐지만 진행 중) 서버도 재시작하지 않는다
    const b = await toNormalPr();
    b.vk.aof = false;
    mergeNormal(b.w);
    b.w.writes = [];
    expect((await runIn(b.w, cmd, "apply", { app: APP })).status).toBe("failed");
    expect(b.w.writes).not.toContain(`rolloutRestart ${NS}/${APP}-valkey`);
  });

  test("Connector P2: 복원 뒤 앱이 키를 바꿔도(추가·만료) 정상 완료하고, 0개가 되면 멈춘다", async () => {
    const { w, vk } = await toNormalPr();
    vk.keys = 9;
    mergeNormal(w);
    const r = await runIn(w, cmd, "apply", { app: APP });
    expect(r.status).toBe("done");
    expect(w.records.get(`${NS}/restore-vk`)!.data["dbsize.after"]).toBe("9");
    expect((await runIn(w, cmd, "apply", { app: APP })).status).toBe("same");
    expect((await runIn(w, cmd, "apply", { app: APP }, { finish: true })).status).toBe("done");

    // 재시작 뒤 빈 데이터(AOF에서 못 읽음)는 멈춘다
    const e = await toNormalPr();
    mergeNormal(e.w);
    const restart = e.w.restart.bind(e.w);
    e.w.restart = (id: string) => {
      restart(id);
      e.vk.keys = 0;
    };
    const f = await runIn(e.w, cmd, "apply", { app: APP });
    expect(f.status).toBe("failed");
    expect(f.error!.message).toContain("키가 0개");
    expect(e.w.records.get(`${NS}/restore-vk`)!.data["ok.reloaded"]).toBeUndefined();
  });

  test("r1 P1-3: 재시작 뒤 0개로 멈춘 실행은 재실행해도 성공으로 넘어가지 않는다(두 번째 실행까지)", async () => {
    const { w, vk } = await toNormalPr();
    mergeNormal(w);
    const restart = w.restart.bind(w);
    w.restart = (id: string) => {
      restart(id);
      vk.keys = 0;
    };
    const first = await runIn(w, cmd, "apply", { app: APP });
    expect(first.status).toBe("failed");
    const rec = () => w.records.get(`${NS}/restore-vk`)!.data;
    expect(rec()["suspect.empty"]).toBe("1");
    expect(rec()["dbsize.pre"]).toBe("5");
    // 두 번째 실행: 빈 서버(pre 0)를 새 기준으로 받지 않고, 다시 재시작하지도 않는다
    w.writes = [];
    const second = await runIn(w, cmd, "apply", { app: APP });
    expect(second.status).toBe("failed");
    expect(second.error!.message).toContain("--accept-empty");
    expect(w.writes).not.toContain(`rolloutRestart ${NS}/${APP}-valkey`);
    expect(rec()["ok.reloaded"]).toBeUndefined();
    expect(rec()["ok.cleanup"]).toBeUndefined();
    expect((await runIn(w, cmd, "apply", { app: APP }, { finish: true })).status).toBe("failed");
    expect(w.records.size).toBe(1);
  });

  test("r1 P1-3: 첫 재시작 뒤 확인 전에 끊긴 실행도 재실행이 첫 재시작 전 키 수로 본다", async () => {
    const { w, vk } = await toNormalPr();
    mergeNormal(w);
    const dep = w.deploys.get(`${NS}/${APP}-valkey`)!;
    const restart = w.restart.bind(w);
    w.restart = (id: string) => {
      restart(id);
      vk.keys = 0;
      dep.rolledOut = false;
    };
    // rollout이 끝나지 않아 키 수 확인 전에 멈춘다(빈 데이터 표식은 아직 없다)
    expect((await runIn(w, cmd, "apply", { app: APP })).status).toBe("failed");
    expect(w.records.get(`${NS}/restore-vk`)!.data["suspect.empty"]).toBeUndefined();
    expect(w.records.get(`${NS}/restore-vk`)!.data["dbsize.pre"]).toBe("5");
    w.restart = (id: string) => {
      restart(id);
      vk.keys = 0;
      dep.rolledOut = true;
    };
    dep.rolledOut = true;
    const again = await runIn(w, cmd, "apply", { app: APP });
    expect(again.status).toBe("failed");
    expect(again.error!.message).toContain("첫 재시작 전 5개");
    expect(w.records.get(`${NS}/restore-vk`)!.data["ok.reloaded"]).toBeUndefined();
  });

  test("r1 P2-5: 키가 정상적으로 0개가 됐으면 사람이 --accept-empty로 받아들여 끝낸다(표식 없이는 쓰이지 않는다)", async () => {
    // 복원 모드 PR 대기 중 앱이 키를 모두 지웠고, 서버가 재시작돼 AOF를 다시 켜야 하는 경로(리뷰 재현)
    const { w, vk } = await toNormalPr();
    vk.keys = 0;
    vk.appendonly = false;
    vk.aof = false;
    mergeNormal(w);
    expect((await runIn(w, cmd, "apply", { app: APP })).status).toBe("failed");
    const fail = await runIn(w, cmd, "apply", { app: APP });
    expect(fail.status).toBe("failed");
    expect(fail.error!.message).toContain("--accept-empty");
    expect(w.records.get(`${NS}/restore-vk`)!.data["suspect.empty"]).toBe("1");
    const ok = await runIn(w, cmd, "apply", { app: APP }, { "accept-empty": true });
    expect(ok.status).toBe("done");
    expect(w.records.get(`${NS}/restore-vk`)!.data["empty.accepted"]).toBe("1");
    // 받아들인 뒤에는 플래그 없이도 same, --finish로 정리된다
    expect((await runIn(w, cmd, "apply", { app: APP })).status).toBe("same");
    expect((await runIn(w, cmd, "apply", { app: APP }, { finish: true })).status).toBe("done");
    expect(w.records.size).toBe(0);

    // 표식 없이 미리 붙인 --accept-empty는 검사를 끄지 않는다
    const e = await toNormalPr();
    mergeNormal(e.w);
    const restart = e.w.restart.bind(e.w);
    e.w.restart = (id: string) => {
      restart(id);
      e.vk.keys = 0;
    };
    const pre = await runIn(e.w, cmd, "apply", { app: APP }, { "accept-empty": true });
    expect(pre.status).toBe("failed");
    expect(e.w.records.get(`${NS}/restore-vk`)!.data["empty.accepted"]).toBeUndefined();
    // --finish·--abort와는 함께 쓰지 않는다
    for (const f of ["finish", "abort"]) {
      await expect(runIn(e.w, cmd, "apply", { app: APP }, { [f]: true, "accept-empty": true })).rejects.toThrow("--accept-empty");
    }
  });

  // 재시작 때 일어날 일을 정한다. lose: 앱 키 수를 이 값으로, marker false면 표식 키도 사라진다(복원 데이터 전부 손실)
  function onRestart(w: World, vk: { keys: number; markers?: Set<string> }, lose: { keys: number; marker: boolean }) {
    const restart = w.restart.bind(w);
    w.restart = (id: string) => {
      restart(id);
      vk.keys = lose.keys;
      if (!lose.marker) vk.markers?.clear();
    };
  }
  const rec = (w: World) => w.records.get(`${NS}/restore-vk`)!.data;

  test("r2 P1-1: 빈 상태 승인은 그 관측에만 쓰인다. 승인 뒤 생긴 키가 재시작에서 사라지면 다시 멈춘다", async () => {
    for (const marker of [false, true]) {
      // 복원 직후 5개 → AOF를 켜는 사이 0개(정상 만료라 사람이 승인)
      const { w, vk } = await toNormalPr();
      // 서버가 복원 모드로 재시작돼 AOF부터 다시 켜야 하는 상태(앞 시험의 P1 경로와 같다)
      delete rec(w)["ok.aof"];
      vk.keys = 0;
      vk.appendonly = false;
      vk.aof = false;
      expect((await runIn(w, cmd, "apply", { app: APP })).status).toBe("failed");
      expect(rec(w)["suspect.empty"]).toBe("1");
      expect((await runIn(w, cmd, "apply", { app: APP }, { "accept-empty": true })).status).toBe("waiting");
      expect(rec(w)["ok.aof"]).toBe("1");
      expect(rec(w)["suspect.empty"]).toBeUndefined();
      // PR 대기 중 앱이 7개를 쓰고, 재시작에서 다 잃는다
      vk.keys = 7;
      mergeNormal(w);
      onRestart(w, vk, { keys: 0, marker });
      const r = await runIn(w, cmd, "apply", { app: APP });
      expect([marker, r.status]).toEqual([marker, "failed"]);
      expect(rec(w)["ok.reloaded"]).toBeUndefined();
      expect(rec(w)["ok.cleanup"]).toBeUndefined();
      expect(w.obj("job", NS, "restore-vk")).toBeDefined();
    }
  });

  test("r2 P1-2: 첫 재시작 전 0개가 기준으로 남아도, 이번 재시작 직전에 본 양수가 0이 되면 멈춘다", async () => {
    for (const marker of [false, true]) {
      const { w, vk } = await toNormalPr();
      mergeNormal(w);
      // 키가 정상적으로 0개인 채 첫 재시작, rollout 실패
      vk.keys = 0;
      const dep = w.deploys.get(`${NS}/${APP}-valkey`)!;
      const restart = w.restart.bind(w);
      w.restart = (id: string) => {
        restart(id);
        dep.rolledOut = false;
      };
      expect((await runIn(w, cmd, "apply", { app: APP })).status).toBe("failed");
      expect(rec(w)["dbsize.pre"]).toBe("0");
      expect(rec(w)["suspect.empty"]).toBeUndefined();
      // 앱이 7개를 쓴 뒤 두 번째 재시작에서 다 잃는다
      w.restart = restart;
      dep.rolledOut = true;
      vk.keys = 7;
      onRestart(w, vk, { keys: 0, marker });
      const r = await runIn(w, cmd, "apply", { app: APP });
      expect([marker, r.status]).toEqual([marker, "failed"]);
      expect(rec(w)["ok.cleanup"]).toBeUndefined();
    }
  });

  test("r2 6: 재시작 뒤 복원 키가 다 사라지고 앱이 새 키 하나만 써도 표식 키가 없으면 멈춘다(--accept-empty로 못 넘긴다)", async () => {
    const { w, vk } = await toNormalPr();
    // 복원 모드로 읽은 직후 표식 키가 들어가 있다
    expect(vk.markers?.size).toBe(1);
    expect(rec(w).marker).toBe("1");
    mergeNormal(w);
    onRestart(w, vk, { keys: 1, marker: false });
    const r = await runIn(w, cmd, "apply", { app: APP });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("복원 표식 키");
    expect(rec(w)["suspect.marker"]).toBe("1");
    expect(rec(w)["ok.reloaded"]).toBeUndefined();
    // 다시 쳐도, --accept-empty를 붙여도 재시작하지 않고 멈춘다
    for (const flags of [{}, { "accept-empty": true }] as Record<string, true>[]) {
      w.writes = [];
      const again = await runIn(w, cmd, "apply", { app: APP }, flags);
      expect(again.status).toBe("failed");
      expect(w.writes).not.toContain(`rolloutRestart ${NS}/${APP}-valkey`);
    }
    expect((await runIn(w, cmd, "apply", { app: APP }, { abort: true })).status).toBe("failed");
    // 누가 표식 키를 다시 넣어도 멈춤은 남는다(기록의 suspect.marker)
    vk.markers!.add(w.records.get(`${NS}/restore-vk`)!.run);
    w.writes = [];
    expect((await runIn(w, cmd, "apply", { app: APP })).status).toBe("failed");
    expect(w.writes).not.toContain(`rolloutRestart ${NS}/${APP}-valkey`);
  });

  test("r2 P1-2: AOF를 켜기 직전에 본 양수가 켠 뒤 0이 되면(저장 기준이 승인된 0이어도) 멈춘다", async () => {
    const w = restoreWorld();
    const vk = w.valkeys.get(`${NS}/${APP}-valkey`)!;
    await runIn(w, cmd, "apply", { app: APP });
    w.merge(900);
    w.objects.delete(`deployment/${NS}/${APP}-valkey`);
    w.obj("cronjob", NS, `${APP}-valkey-backup`)!.spec.suspend = true;
    await runIn(w, cmd, "apply", { app: APP });
    w.merge(901);
    w.put("deployment", NS, `${APP}-valkey`, { metadata: { generation: 2 }, spec: { replicas: 1 }, status: { observedGeneration: 2, updatedReplicas: 1, readyReplicas: 1 } });
    vk.appendonly = false;
    vk.aof = false;
    vk.keys = 5;
    // loaded 뒤 AOF 단계 전에 멈추도록: CONFIG SET이 처음 불릴 때 키를 0으로(첫 실행은 0개 감지 → 승인)
    let on = false;
    let lose = 0;
    Object.defineProperty(vk, "appendonly", {
      get: () => on,
      set: (v: boolean) => {
        if (v && !on) vk.keys = lose;
        on = v;
      },
    });
    expect((await runIn(w, cmd, "apply", { app: APP })).status).toBe("failed");
    expect(rec(w)["suspect.empty"]).toBe("1");
    // 승인하는 실행: 켜기 직전 앱이 7개를 썼고, 켜는 사이 다 사라진다
    on = false;
    vk.keys = 7;
    lose = 0;
    const r = await runIn(w, cmd, "apply", { app: APP }, { "accept-empty": true });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("켜기 직전 7개");
    expect(rec(w)["ok.aof"]).toBeUndefined();
  });

  test("r2 6: 재시작 전에 표식 키가 이미 없으면(복원 모드에서 재시작돼 RDB로 되돌아감) 재시작하지 않는다", async () => {
    const { w, vk } = await toNormalPr();
    vk.markers!.clear();
    mergeNormal(w);
    w.writes = [];
    const r = await runIn(w, cmd, "apply", { app: APP });
    expect(r.status).toBe("failed");
    expect(r.error!.message).toContain("재시작 전에");
    expect(w.writes).not.toContain(`rolloutRestart ${NS}/${APP}-valkey`);
  });

  test("r2 6: 정상 완료면 정리 단계가 표식 키를 지운다(앱 키 수에는 표식을 세지 않는다)", async () => {
    const { w, vk } = await toNormalPr();
    expect(rec(w).dbsize).toBe("5");
    mergeNormal(w);
    const r = await runIn(w, cmd, "apply", { app: APP });
    expect(r.status).toBe("done");
    expect(w.writes).toContain(`valkey marker del ${NS}/${APP}-valkey`);
    expect(vk.markers?.size).toBe(0);
    expect(rec(w)["dbsize.after"]).toBe("5");
    expect(rec(w).marker).toBeUndefined();
  });

  test("Connector P2: AOF를 켜는 사이 키가 줄어도 통과하고, 0개가 되면 멈춘다", async () => {
    for (const [keys, want] of [[3, "waiting"], [0, "failed"]] as const) {
      const w = restoreWorld();
      const vk = w.valkeys.get(`${NS}/${APP}-valkey`)!;
      await runIn(w, cmd, "apply", { app: APP });
      w.merge(900);
      w.objects.delete(`deployment/${NS}/${APP}-valkey`);
      w.obj("cronjob", NS, `${APP}-valkey-backup`)!.spec.suspend = true;
      await runIn(w, cmd, "apply", { app: APP });
      w.merge(901);
      w.put("deployment", NS, `${APP}-valkey`, { metadata: { generation: 2 }, spec: { replicas: 1 }, status: { observedGeneration: 2, updatedReplicas: 1, readyReplicas: 1 } });
      vk.appendonly = false;
      vk.aof = false;
      vk.keys = 5;
      // loaded가 키 5개를 적은 뒤, CONFIG SET appendonly yes 사이에 앱이 키를 바꾼다
      let on = false;
      Object.defineProperty(vk, "appendonly", {
        get: () => on,
        set: (v: boolean) => {
          if (v && !on) vk.keys = keys;
          on = v;
        },
      });
      const r = await runIn(w, cmd, "apply", { app: APP });
      expect([keys, r.status]).toEqual([keys, want]);
      if (keys === 0) expect(w.records.get(`${NS}/restore-vk`)!.data["ok.aof"]).toBeUndefined();
      else expect(w.records.get(`${NS}/restore-vk`)!.data["ok.aof"]).toBe("1");
    }
  });

  test("--abort: 복원 Job 전이면 기록을 지우고, 복원 Job 뒤면 거부한다", async () => {
    const w = restoreWorld();
    await runIn(w, cmd, "apply", { app: APP });
    const a = await runIn(w, cmd, "apply", { app: APP }, { abort: true });
    expect(a.status).toBe("done");
    expect(w.records.size).toBe(0);

    const w2 = restoreWorld();
    await runIn(w2, cmd, "apply", { app: APP });
    w2.merge(900);
    w2.objects.delete(`deployment/${NS}/${APP}-valkey`);
    w2.obj("cronjob", NS, `${APP}-valkey-backup`)!.spec.suspend = true;
    await runIn(w2, cmd, "apply", { app: APP });
    const b = await runIn(w2, cmd, "apply", { app: APP }, { abort: true });
    expect(b.status).toBe("failed");
    expect(w2.records.size).toBe(1);
  });
});
