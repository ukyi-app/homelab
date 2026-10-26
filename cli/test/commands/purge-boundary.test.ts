// data purge: 한 실행에서 본 워크로드를 잊지 않는지(#893 r2 재현 A·B·C)와 두 probe의 정상 폐기.
// 엔진에 넘기는 단계의 read를 가로채 그 읽기 때만 파드를 넣고 뺀다(codex 재현과 같은 방식).
import { afterAll, beforeAll, describe, expect, setSystemTime, test } from "bun:test";
import type { Observation, ReadCtx, Step } from "../../src/core/command";
import cmd from "../../src/commands/purge";
import { World, runIn } from "../fixtures/rotate-world/world";

const APP = "homelab-probe";
const NS = `app-${APP}`;
const DATA = `data/${APP}/values.yaml`;
const REC = `database/data-purge-${APP}`;
// 두 probe의 values 사본(main afc20c0, PR 1 전). 저장소 파일을 읽으면 purge PR 1·2가 그 파일을 바꾸고 지울 때 ci가 깨진다(#906).
const PROBE_VALUES: Record<string, string> = {
  "homelab-probe": [
    "# T11 시나리오 2. 공유 Cluster pg에 역할·DB homelab-probe(비밀번호 원본 /apps/homelab-probe/postgres/PASSWORD).",
    "chartVersion: 1.0.1",
    "postgres: { enabled: true }",
    "# T11 시나리오 4. 영속 Valkey(앱 ns, PVC valkey-data, 매일 R2 백업). 캐시(앱 차트)와 같은 이름이라 캐시를 먼저 끈 뒤 켠다.",
    "valkey: { persistent: true }",
    "",
  ].join("\n"),
  "homelab-probe2": [
    "# T11 시나리오 10(한 앱만 복원)의 두 번째 DB. 앱 없이 DB만 둔다(비밀번호 원본 /apps/homelab-probe2/postgres/PASSWORD).",
    "# homelab-probe를 T1로 되돌리는 동안 이 DB의 T1 뒤 쓰기가 남는지 본다.",
    "chartVersion: 1.0.0",
    "postgres: { enabled: true }",
    "",
  ].join("\n"),
};
const run = (w: World, mode: "plan" | "apply" = "apply") => runIn(w, cmd, mode, { app: APP }, mode === "apply" ? { confirm: APP } : {});

// PR 1이 반영된 PG·영속 Valkey 세계(purge: true, reclaim delete, PV Retain)
function prepared(): World {
  const w = new World({ [DATA]: "chartVersion: 1.0.2\nvalkey: { persistent: true }\npurge: true\npostgres: { enabled: true }\n" });
  w.tags.add("data-chart-v1.0.2");
  w.strictNamespaces = true;
  for (const ns of [NS, "database"]) w.put("namespace", null, ns, { metadata: { name: ns } });
  w.put("pvc", NS, "valkey-data", { metadata: { name: "valkey-data" }, spec: { volumeName: "pvc-1" } });
  w.put("pv", null, "pvc-1", { metadata: { name: "pvc-1" }, spec: { persistentVolumeReclaimPolicy: "Retain", claimRef: { namespace: NS, name: "valkey-data" } } });
  w.put("database", "database", APP, { metadata: { name: APP }, spec: { databaseReclaimPolicy: "delete" } });
  w.put("databaserole", "database", APP, { metadata: { name: APP }, spec: { databaseRoleReclaimPolicy: "delete" } });
  return w;
}
function backup(w: World, at: string) {
  w.put("job", NS, `${APP}-valkey-backup-1`, { metadata: { name: `${APP}-valkey-backup-1`, ownerReferences: [{ kind: "CronJob", name: `${APP}-valkey-backup` }] }, status: { startTime: at, conditions: [{ type: "Complete", status: "True" }] } });
  w.put("backup", "database", "b1", { spec: { cluster: { name: "pg" } }, status: { phase: "completed", stoppedAt: at } });
}
const writer = (w: World) => w.put("pod", NS, "writer", { metadata: { name: "writer", labels: { "homelab.ukyi.app/app": APP } }, status: { phase: "Running" } });
const seed = (w: World) => w.records.set(REC, { run: "seed", data: {}, created: "2026-10-25T12:00:00Z" });

// 단계 id의 read를 가로챈다. count는 그 단계의 몇 번째 읽기인지(엔진 실행을 가로질러 센다).
function hook(w: World, id: string, fn: (read: (c: ReadCtx) => Promise<Observation>, c: ReadCtx, count: number, steps: Step[]) => Promise<Observation>) {
  const original = w.read.bind(w);
  let count = 0;
  w.read = (mode) => {
    const ctx = original(mode);
    const engine = ctx.engine;
    ctx.engine = (p) => {
      const step = p.steps.find((s) => s.id === id);
      if (step) {
        const read = step.read.bind(step);
        step.read = (c) => fn(read, c, ++count, p.steps);
      }
      return engine(p);
    };
    return ctx;
  };
}

const lost = (w: World, r: { status: string }) => {
  expect(r.status).toBe("failed");
  expect(w.records.has(REC)).toBe(false);
  expect(w.obj("pv", null, "pvc-1")!.spec.persistentVolumeReclaimPolicy).toBe("Retain");
  expect(w.openPrs()).toEqual([]);
};

describe("data purge: 한 실행의 관측 표시(#893 r2)", () => {
  beforeAll(() => setSystemTime(new Date("2026-10-26T12:00:00Z")));
  afterAll(() => setSystemTime());

  test("재현 A: 전용 엔진의 첫 읽기에서만 본 파드도 기록을 지우고 실패한다", async () => {
    const w = prepared();
    seed(w);
    backup(w, "2026-10-26T06:00:00Z");
    const seen: string[] = [];
    hook(w, "workloads", async (read, c, count) => {
      if (count === 1) writer(w);
      const o = await read(c);
      if (count === 1) {
        seen.push(o.detail);
        w.objects.delete(`pod/${NS}/writer`);
      }
      return o;
    });
    const r = await run(w);
    expect(seen[0]).toContain("무효");
    lost(w, r);
    expect(r.error!.message).toContain("pod/writer");
  });

  test("재현 B: 본 엔진 사전 읽기에서 본 파드는 다른 읽기(GitHub) 실패가 있어도 기록을 지운다", async () => {
    const w = prepared();
    seed(w);
    backup(w, "2026-10-26T06:00:00Z");
    const gh = w.ghGet.bind(w);
    let broken = false;
    w.ghGet = (p) => {
      if (broken && p.includes("/contents/apps/")) throw new Error("GitHub 시간 초과(주입)");
      return gh(p);
    };
    // 전용 실행(읽기 2번)은 지나가고, 본 엔진의 workloads 사전 읽기부터 파드와 GitHub 오류
    hook(w, "workloads", async (read, c, count, steps) => {
      if (steps.length > 1 && count === 3) {
        writer(w);
        broken = true;
      }
      return read(c);
    });
    const r = await run(w);
    lost(w, r);
    expect(r.error!.message).toContain("GitHub 시간 초과");
    // 조회가 정상이 되고 파드가 사라져도 옛 기록·06:00 백업으로 진행하지 않는다
    broken = false;
    w.objects.delete(`pod/${NS}/writer`);
    const again = await run(w);
    expect(again.status).toBe("failed");
    expect(w.records.get(REC)!.created).toBe("2026-10-26T12:00:00Z");
    expect(w.obj("pv", null, "pvc-1")!.spec.persistentVolumeReclaimPolicy).toBe("Retain");
    expect(w.openPrs()).toEqual([]);
  });

  test("재현 C: 엔진의 쓰기 뒤 재조회가 본 파드도 기록을 지운다", async () => {
    const w = prepared();
    // writes-stopped 읽기: 사전 읽기 1, 재조회 2, 쓰기 뒤 재조회 3(apply 안 확인 뒤)
    hook(w, "writes-stopped", async (read, c, count) => {
      if (count === 3) writer(w);
      return read(c);
    });
    const r = await run(w);
    lost(w, r);
    expect(w.writes).toEqual([`recordCreate ${REC}`, `recordDelete ${REC}`]);
    // 12:01 백업 뒤에도 파드가 썼고 12:02에 사라졌다: 새로 잰 기록 뒤가 아니라 진행하지 않는다
    backup(w, "2026-10-26T12:01:00Z");
    w.objects.delete(`pod/${NS}/writer`);
    setSystemTime(new Date("2026-10-26T12:02:00Z"));
    try {
      const again = await run(w);
      expect(again.status).toBe("failed");
      expect(w.records.get(REC)!.created).toBe("2026-10-26T12:02:00Z");
      expect(w.obj("pv", null, "pvc-1")!.spec.persistentVolumeReclaimPolicy).toBe("Retain");
      expect(w.openPrs()).toEqual([]);
    } finally {
      setSystemTime(new Date("2026-10-26T12:00:00Z"));
    }
  });

  test("본 엔진이 예외로 끝나도(엔진 밖으로 던짐) 본 파드의 기록을 지우고 실패로 돌려준다", async () => {
    const w = prepared();
    seed(w);
    hook(w, "workloads", async (read, c, count, steps) => {
      if (steps.length > 1 && count === 3) writer(w);
      return read(c);
    });
    // 본 엔진(단계가 여럿)이 끝난 뒤 예외를 던진다
    const original = w.read.bind(w);
    w.read = (mode) => {
      const ctx = original(mode);
      const engine = ctx.engine;
      ctx.engine = async (p) => {
        const r = await engine(p);
        if (p.steps.length > 1) throw new Error("엔진 밖 예외(주입)");
        return r;
      };
      return ctx;
    };
    const r = await run(w);
    lost(w, r);
    expect(r.error!.message).toContain("엔진 밖 예외(주입)");
  });

  for (const kind of ["application", "deployment"] as const) {
    test(`#893 r3: ${kind}를 본 직후 다음 종류 조회가 실패해도 본 것을 잊지 않고 기록을 지운다(재실행은 새 백업 요구)`, async () => {
      const w = prepared();
      seed(w);
      backup(w, "2026-10-26T06:00:00Z");
      if (kind === "application") w.put("application", "argocd", APP, { metadata: { name: APP } });
      else w.put("deployment", NS, APP, { metadata: { name: APP, labels: { "homelab.ukyi.app/app": APP } }, status: { readyReplicas: 1 } });
      // 다음 종류(application 뒤 deployment, deployment 뒤 statefulset) 목록 조회가 시간 초과
      const original = w.read.bind(w);
      let broken = true;
      w.read = (mode) => {
        const c = original(mode);
        const list = c.k8s.list;
        c.k8s.list = (k, ns, sel) => {
          if (broken && k === (kind === "application" ? "deployment" : "statefulset")) throw new Error("다음 종류 kubectl 조회 시간 초과(주입)");
          return list(k, ns, sel);
        };
        return c;
      };
      const r = await run(w);
      lost(w, r);
      expect(r.error!.message).toContain(kind === "application" ? `application/${APP}` : `deployment/${APP}`);
      expect(r.steps.map((x) => x.id)).toContain("record-invalidated");
      // 조회가 정상이 되고 워크로드가 사라져도 06:00 백업으로 진행하지 않는다(새 기록 12:00 뒤 백업이 필요하다)
      broken = false;
      w.objects.delete(kind === "application" ? `application/argocd/${APP}` : `deployment/${NS}/${APP}`);
      const again = await run(w);
      expect(again.status).toBe("failed");
      expect(w.records.get(REC)!.created).toBe("2026-10-26T12:00:00Z");
      expect(w.obj("pv", null, "pvc-1")!.spec.persistentVolumeReclaimPolicy).toBe("Retain");
      expect(w.openPrs()).toEqual([]);
    });
  }

  test("plan은 표시가 켜져도 쓰기 0, 기록이 무효가 된다는 것만 보인다", async () => {
    const w = prepared();
    seed(w);
    writer(w);
    const p = await run(w, "plan");
    expect(w.writes).toEqual([]);
    expect(w.records.has(REC)).toBe(true);
    expect(p.steps.find((x) => x.id === "workloads")!.detail).toContain("무효가 된다");
  });

  test("마지막 무효화 자체가 실패하면 그 사실을 error.next에 남긴다", async () => {
    const w = prepared();
    seed(w);
    hook(w, "workloads", async (read, c, count) => {
      if (count === 1) writer(w);
      const o = await read(c);
      if (count === 1) w.objects.delete(`pod/${NS}/writer`);
      return o;
    });
    // 기록 삭제가 실패한다
    const del = w.records.delete.bind(w.records);
    w.records.delete = () => {
      throw new Error("API 서버 시간 초과(주입)");
    };
    const r = await run(w);
    w.records.delete = del;
    expect(r.status).toBe("failed");
    expect(r.error!.next).toContain("지우지 못했다");
    expect(r.error!.next).toContain(`kubectl -n database delete configmap data-purge-${APP}`);
    expect(w.openPrs()).toEqual([]);
  });
});

describe("data purge: 두 probe의 정상 폐기(values 사본)", () => {
  beforeAll(() => setSystemTime(new Date("2026-10-26T12:00:00Z")));
  afterAll(() => setSystemTime());

  for (const app of ["homelab-probe", "homelab-probe2"]) {
    test(`${app}: 기록 → 온디맨드 백업 → PR 1 → 동기화 → PR 2 → 삭제 → 키 삭제 → done, 재실행 same`, async () => {
      const ns = `app-${app}`;
      const data = `data/${app}/values.yaml`;
      const rec = `database/data-purge-${app}`;
      const persistent = app === "homelab-probe";
      const w = new World({ [data]: PROBE_VALUES[app] });
      w.tags.add("data-chart-v1.0.2");
      w.strictNamespaces = true;
      w.put("namespace", null, "database", { metadata: { name: "database" } });
      if (persistent) w.put("namespace", null, ns, { metadata: { name: ns } });
      else w.history.set(`apps/${app}/values.yaml`, []);
      const protect = { "argocd.argoproj.io/sync-options": "Prune=false,Delete=false" };
      for (const kind of ["database", "databaserole"]) w.put(kind, "database", app, { metadata: { name: app, annotations: { ...protect } }, spec: kind === "database" ? { databaseReclaimPolicy: "retain" } : { databaseRoleReclaimPolicy: "retain" } });
      w.put("application", "argocd", `${app}-data`, { metadata: { name: `${app}-data` } });
      w.setValue(`/apps/${app}/postgres`, "PASSWORD", "test-only-pg-value-0000");
      if (persistent) {
        w.put("pvc", ns, "valkey-data", { metadata: { name: "valkey-data", annotations: { ...protect } }, spec: { volumeName: "pvc-1" } });
        w.put("pv", null, "pvc-1", { metadata: { name: "pvc-1" }, spec: { persistentVolumeReclaimPolicy: "Retain", claimRef: { namespace: ns, name: "valkey-data" } } });
        // 데이터 차트의 Valkey 서버·백업 CronJob은 앱 워크로드가 아니다
        w.put("deployment", ns, `${app}-valkey`, { metadata: { name: `${app}-valkey`, labels: { "app.kubernetes.io/name": "valkey", "app.kubernetes.io/instance": app } } });
        w.put("pod", ns, `${app}-valkey-x`, { metadata: { name: `${app}-valkey-x`, labels: { "app.kubernetes.io/name": "valkey", "app.kubernetes.io/instance": app } }, status: { phase: "Running" } });
        w.put("cronjob", ns, `${app}-valkey-backup`, { metadata: { name: `${app}-valkey-backup`, labels: { "homelab.ukyi.app/data": app } } });
        w.setValue(`/apps/${app}/valkey`, "PASSWORD", "test-only-vk-value-0000");
      }
      const go = (mode: "plan" | "apply" = "apply") => runIn(w, cmd, mode, { app }, mode === "apply" ? { confirm: app } : {});
      await go("plan");
      expect(w.writes).toEqual([]);
      const first = await go();
      expect(first.status).toBe("failed");
      expect(w.writes).toEqual([`recordCreate ${rec}`]);
      w.put("backup", "database", "on-demand", { spec: { cluster: { name: "pg" } }, status: { phase: "completed", stoppedAt: "2026-10-26T12:01:00Z" } });
      if (persistent) w.put("job", ns, `${app}-valkey-backup-1`, { metadata: { name: `${app}-valkey-backup-1`, ownerReferences: [{ kind: "CronJob", name: `${app}-valkey-backup` }] }, status: { startTime: "2026-10-26T12:01:00Z", conditions: [{ type: "Complete", status: "True" }] } });
      expect((await go()).status).toBe("waiting");
      expect(w.openPrs().map((p) => p.head)).toEqual([`cli/data-purge-${app}`]);
      w.merge(900);
      expect((await go()).next).toContain("동기화");
      for (const kind of ["database", "databaserole"]) {
        const o = w.obj(kind, "database", app)!;
        delete o.metadata.annotations;
        o.spec = kind === "database" ? { databaseReclaimPolicy: "delete" } : { databaseRoleReclaimPolicy: "delete" };
      }
      if (persistent) delete w.obj("pvc", ns, "valkey-data")!.metadata.annotations;
      expect((await go()).status).toBe("waiting");
      if (persistent) expect(w.obj("pv", null, "pvc-1")!.spec.persistentVolumeReclaimPolicy).toBe("Delete");
      expect(w.openPrs().map((p) => p.head)).toEqual([`cli/data-purge-delete-${app}`]);
      w.merge(901);
      expect((await go()).next).toContain("지우는 중");
      for (const [key] of w.objects) {
        if ([`database/database/${app}`, `databaserole/database/${app}`, `application/argocd/${app}-data`].includes(key) || [`pvc/${ns}/`, "pv/", `pod/${ns}/`, `deployment/${ns}/`, `cronjob/${ns}/`].some((x) => key.startsWith(x))) w.objects.delete(key);
      }
      w.confirmAnswer = app;
      const end = await go();
      expect(end.status).toBe("done");
      expect(w.records.has(rec)).toBe(false);
      expect(w.value(`/apps/${app}/postgres`, "PASSWORD")).toBeUndefined();
      expect((await go()).status).toBe("same");
    });
  }
});
