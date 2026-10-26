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
