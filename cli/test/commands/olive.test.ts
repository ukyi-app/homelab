// homelab olive(상태·켜기·비상 정지). 실제 클러스터에 닿지 않는다: kubectl은 PATH 스텁이고 노드 읽기는 가짜를 넣는다.
import { describe, expect, test } from "bun:test";
import { parseInput } from "../../src/core/args";
import type { NodeRead, PodCgroup } from "../../src/core/command";
import { allFlags } from "../../src/core/help";
import { kubectlArgv } from "../../src/core/kubectl";
import { EXIT } from "../../src/core/result";
import { makeOlive } from "../../src/commands/olive";
import { LIMITS, type Limits } from "../../src/commands/olive-state";
import { expectNoSecrets, expectPlanReadOnly, kubectlRule, rule, runCli, testCtx, type Call, type Resp, type Rule } from "../harness";

const TARGETS = [
  { id: "supervisor", ns: "olive-control", dep: "supervisor" },
  { id: "diagnosis", ns: "olive-diagnosis", dep: "executor" },
  { id: "reader", ns: "olive-reader", dep: "executor" },
  { id: "session", ns: "olive-session", dep: "session" },
  { id: "writer", ns: "sandbox", dep: "worker-task" },
];
const NAMESPACES = TARGETS.map((t) => t.ns);
const UID_A = "8afa2150-81af-4018-9753-0183509606ad";
const UID_B = "1b5d2dd3-e830-49fd-bb90-4e93022446e8";
const DEPLOY_UID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const RS_UID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const SUP_POD = "supervisor-7c9d8f6b5-x2k4q";
const SUP_RS = "supervisor-7c9d8f6b5";

const json = (x: unknown): Resp => ({ stdout: JSON.stringify(x) });
const notFound: Resp = { code: 1, stderr: "Error from server (NotFound): not found\n" };
const denied: Resp = { code: 1, stderr: "Error from server (Forbidden): denied\n" };

const lockDoc = (ns: string, o: { deleting?: boolean } = {}) =>
  json({
    kind: "ResourceQuota",
    metadata: { name: "olive-stop", namespace: ns, uid: "0f0e0d0c-0b0a-4908-8706-050403020100", resourceVersion: "10", labels: { "homelab.ukyi.app/olive-stop": "lock" }, ...(o.deleting ? { deletionTimestamp: "2026-11-19T01:00:00Z" } : {}) },
    spec: { hard: { pods: "0" } },
  });
// 작성 작업자는 올리브 차트가 아니라 platform/sandbox가 선언해 파드 라벨이 다르다.
const podLabels = (t: (typeof TARGETS)[number]): Record<string, string> => (t.id === "writer" ? { app: "worker-task" } : { "app.kubernetes.io/name": "olive", "app.kubernetes.io/component": t.id });
const deploymentSelector = (t: (typeof TARGETS)[number]) => Object.entries(podLabels(t)).map(([k, v]) => `${k}=${v}`).sort().join(",");
const OLIVE_CHART_TARGETS = new Set(["supervisor", "diagnosis", "reader"]);
const ADMIN_SELECTOR = "app.kubernetes.io/name=olive,app.kubernetes.io/component=supervisor,homelab.ukyi.app/olive-target=supervisor";
const depDoc = (t: (typeof TARGETS)[number], replicas: number) =>
  json({
    apiVersion: "apps/v1",
    kind: "Deployment",
    metadata: { name: t.dep, namespace: t.ns, uid: DEPLOY_UID },
    spec: { replicas, selector: { matchLabels: podLabels(t) } },
  });
// replicas 1을 쓴 뒤의 모습. ready가 0이면 아직 준비되지 않았다.
const upDoc = (t: (typeof TARGETS)[number], ready = 1) =>
  json({
    apiVersion: "apps/v1",
    kind: "Deployment",
    metadata: { name: t.dep, namespace: t.ns, uid: DEPLOY_UID, generation: 2 },
    spec: { replicas: 1, selector: { matchLabels: podLabels(t) } },
    status: { observedGeneration: 2, readyReplicas: ready },
  });
const syncingApp = (app: string) => json({ kind: "Application", metadata: { name: app, namespace: "argocd" }, operation: { sync: {} }, status: {} });
type PodOpts = { uid?: string; deleting?: boolean; forced?: boolean; phase?: string; owned?: boolean };
const podDoc = (ns: string, o: PodOpts = {}) => ({
  apiVersion: "v1",
  kind: "Pod",
  metadata: {
    name: SUP_POD,
    namespace: ns,
    uid: o.uid ?? UID_A,
    labels: { "app.kubernetes.io/name": "olive", "app.kubernetes.io/component": "supervisor", "homelab.ukyi.app/olive-target": "supervisor" },
    ownerReferences: o.owned === false ? [] : [{ apiVersion: "apps/v1", kind: "ReplicaSet", name: SUP_RS, uid: RS_UID, controller: true }],
    ...(o.deleting || o.forced ? { deletionTimestamp: "2026-11-19T01:00:00Z", deletionGracePeriodSeconds: o.forced ? 0 : 30 } : {}),
  },
  spec: { containers: [{ name: "supervisor" }], terminationGracePeriodSeconds: 30 },
  status: { phase: o.phase ?? "Running", conditions: [{ type: "Ready", status: "True" }] },
});
const podList = (...items: unknown[]): Resp => json({ kind: "List", metadata: {}, items });

type World = {
  noNs?: string[];
  noDep?: string[];
  locks?: Record<string, Resp[]>;
  replicas?: Record<string, Resp[]>;
  pods?: Record<string, Resp[]>;
  create?: Record<string, Resp>;
  scale?: Record<string, Resp>;
  clear?: Record<string, Resp>;
  app?: (name: string) => Resp;
  rollout?: Resp;
  extra?: Rule[];
};

function world(o: World = {}): Rule[] {
  const rules: Rule[] = [...(o.extra ?? [])];
  for (const t of TARGETS) {
    rules.push(kubectlRule(["get", "namespaces", t.ns, "-o", "json"], o.noNs?.includes(t.ns) ? notFound : json({ kind: "Namespace", metadata: { name: t.ns } })));
    rules.push(kubectlRule(["-n", t.ns, "get", "deployments.apps", t.dep, "-o", "json"], o.noDep?.includes(t.id) ? notFound : (o.replicas?.[t.id] ?? [depDoc(t, 1), depDoc(t, 0)])));
    rules.push(kubectlRule(["-n", t.ns, "get", "resourcequotas", "olive-stop", "-o", "json"], o.locks?.[t.ns] ?? notFound));
    // 실제 API처럼 셀렉터에 맞는 파드만 돌려준다. 틀린 셀렉터는 빈 목록을 받아 남은 파드를 놓친다.
    const pods = o.pods?.[t.ns] ?? podList();
    rules.push(kubectlRule(["-n", t.ns, "get", "pods", "-l", deploymentSelector(t), "-o", "json"], pods));
    if (OLIVE_CHART_TARGETS.has(t.id)) rules.push(kubectlRule(["-n", t.ns, "get", "pods", "-l", `homelab.ukyi.app/olive-target=${t.id}`, "-o", "json"], pods));
    if (t.id === "supervisor") rules.push(kubectlRule(["-n", t.ns, "get", "pods", "-l", ADMIN_SELECTOR, "-o", "json"], pods));
    rules.push(kubectlRule(["-n", t.ns, "get", "pods", "-l", /.+/, "-o", "json"], podList()));
    rules.push(kubectlRule(["-n", t.ns, "create", "-f", "-"], o.create?.[t.ns] ?? {}));
    rules.push(kubectlRule(["-n", t.ns, "scale", "deployments.apps", t.dep, /--replicas=[01]/], o.scale?.[t.id] ?? {}));
    rules.push(kubectlRule(["delete", "--raw", `/api/v1/namespaces/${t.ns}/resourcequotas/olive-stop`, "-f", "-"], o.clear?.[t.ns] ?? {}));
    rules.push(kubectlRule(["-n", t.ns, "rollout", "status", `deploy/${t.dep}`, /--timeout=\d+s/], o.rollout ?? {}));
  }
  for (const app of ["olive", "sandbox"]) rules.push(kubectlRule(["-n", "argocd", "get", "applications.argoproj.io", app, "-o", "json"], o.app?.(app) ?? json({ kind: "Application", metadata: { name: app, namespace: "argocd" }, status: {} })));
  rules.push(kubectlRule(["get", "nodes", "-o", "json"], json({ items: [] })));
  return rules;
}

// 자물쇠가 없다가 걸리는 순서: 처음 읽기, 걸기 전 읽기, 건 뒤 읽기.
const freshLocks = (): Record<string, Resp[]> => Object.fromEntries(NAMESPACES.map((ns) => [ns, [notFound, notFound, lockDoc(ns)]]));
const heldLocks = (): Record<string, Resp[]> => Object.fromEntries(NAMESPACES.map((ns) => [ns, [lockDoc(ns)]]));
// 풀 때: 처음 읽기, 지우기 전 읽기, 지운 뒤 읽기.
const clearingLocks = (): Record<string, Resp[]> => Object.fromEntries(NAMESPACES.map((ns) => [ns, [lockDoc(ns), lockDoc(ns), notFound]]));
const zeroed = (): Record<string, Resp[]> => Object.fromEntries(TARGETS.map((t) => [t.id, [depDoc(t, 0)]]));

const line = (c: Call) => c.argv.join(" ");
const writesOf = (r: { writes: Call[] }) => r.writes.map(line);
const isLockCreate = (c: Call) => c.argv.includes("create");
const isScale = (c: Call) => c.argv.includes("scale");
const scaleOf = (t: (typeof TARGETS)[number], n: 0 | 1) => kubectlArgv(["-n", t.ns, "scale", "deployments.apps", t.dep, `--replicas=${n}`]).join(" ");
const createOf = (ns: string) => kubectlArgv(["-n", ns, "create", "-f", "-"]).join(" ");
const clearOf = (ns: string) => kubectlArgv(["delete", "--raw", `/api/v1/namespaces/${ns}/resourcequotas/olive-stop`, "-f", "-"]).join(" ");

// 상한을 줄여야 하는 시험과 노드 읽기를 바꿔야 하는 시험은 같은 프로세스에서 명령을 돌린다.
async function direct(mode: "plan" | "apply", tokens: string[], rules: Rule[], o: { limits?: Limits; node?: NodeRead } = {}) {
  const cmd = makeOlive(o.limits ?? LIMITS);
  const t = testCtx(mode, rules);
  if (o.node) t.ctx.node = o.node;
  const r = await cmd.run(t.ctx, parseInput(allFlags(cmd), cmd.args, tokens));
  return { r, code: EXIT[r.status], body: r.body ?? "", ...t.calls() };
}
const SHORT: Limits = { holdZeroSec: 1, startReadySec: 1 };

describe("plan", () => {
  test("plan: --apply 없이는 어떤 동작도 쓰기를 부르지 않는다", async () => {
    const cases: [string[], World][] = [
      [["status"], {}],
      [["start"], { replicas: zeroed() }],
      [["stop", "on"], {}],
      [["stop", "status"], { locks: heldLocks(), replicas: zeroed() }],
      [["stop", "verify"], { locks: heldLocks(), replicas: zeroed() }],
      [["stop", "off"], { locks: heldLocks(), replicas: zeroed() }],
    ];
    for (const [args, w] of cases) {
      const r = await runCli(["olive", ...args, "--json"], world(w));
      expect([args, r.code]).toEqual([args, 0]);
      expectPlanReadOnly(r);
      expect([args, r.writes.length]).toEqual([args, 0]);
    }
  }, 60_000);

  test("읽기 동작에 --apply를 주면 사용법 오류이고 stop에 동작이 없어도 사용법 오류다", async () => {
    for (const args of [["stop", "status", "--apply"], ["stop", "verify", "--apply"], ["stop"], ["start", "on"], ["status", "--deep"], ["stop", "on", "--uids", UID_A]]) {
      const r = await runCli(["olive", ...args, "--json"], []);
      expect([args, r.code]).toEqual([args, 64]);
      expect(r.calls).toEqual([]);
    }
  });
});

describe("start", () => {
  test("start: 대상 파일에서 켤 수 없음인 sandbox/worker-task에는 replicas를 쓰지 않는다", async () => {
    const r = await runCli(["olive", "start", "--apply", "--json"], world({ replicas: { ...zeroed(), supervisor: [depDoc(TARGETS[0], 0), upDoc(TARGETS[0])] } }));
    expect(r.code).toBe(0);
    expect(r.calls.filter((c) => c.argv.includes("worker-task") && !c.argv.includes("get")).map(line)).toEqual([]);
    expect(writesOf(r)).toEqual([scaleOf(TARGETS[0], 1)]);
    expect(r.json.body).toContain("켜짐: supervisor");
  });

  test("start: 정지 중이면 거절", async () => {
    const cases: Record<string, Resp[]>[] = [{ "olive-reader": [lockDoc("olive-reader")] }, { "olive-control": [lockDoc("olive-control", { deleting: true })] }];
    for (const locks of cases) {
      for (const flags of [[], ["--apply"]]) {
        const r = await runCli(["olive", "start", ...flags, "--json"], world({ locks, replicas: zeroed() }));
        expect([flags, r.code]).toEqual([flags, 1]);
        expect(r.writes).toEqual([]);
        expect(r.json.error.message).toContain("정지 중");
        expect(r.json.next).toContain("stop off");
      }
    }
  });

  test("replicas를 썼지만 준비되지 않으면 3이고 켜졌다고 하지 않는다", async () => {
    const r = await runCli(["olive", "start", "--apply", "--json"], world({ replicas: { ...zeroed(), supervisor: [depDoc(TARGETS[0], 0), upDoc(TARGETS[0], 0)] }, rollout: { code: 1, stderr: "timed out\n" } }));
    expect(r.code).toBe(3);
    expect(r.json.body).not.toContain("켜짐");
  });

  test("켤 수 있는 Deployment가 없으면 실패다", async () => {
    const r = await runCli(["olive", "start", "--apply", "--json"], world({ noDep: ["supervisor"] }));
    expect(r.code).toBe(1);
    expect(r.writes).toEqual([]);
  });

  describe("start: 다시 읽어 확인한 것만 켜졌다고 말한다", () => {
    const sup = TARGETS[0];
    const after = (...docs: Resp[]) => ({ ...zeroed(), supervisor: [depDoc(sup, 0), ...docs] });

    test("rollout이 끝나도 다시 읽은 replicas가 0이면 켜졌다고 하지 않는다", async () => {
      const r = await runCli(["olive", "start", "--apply", "--json"], world({ replicas: after(depDoc(sup, 0)) }));
      expect(r.code).toBe(1);
      expect(r.json.body).not.toContain("켜짐");
      expect(r.json.error.message).toContain("켜기 미상");
    });

    test("replicas 1이어도 준비된 파드가 없으면 3이다", async () => {
      const r = await runCli(["olive", "start", "--apply", "--json"], world({ replicas: after(upDoc(sup, 0)) }));
      expect(r.code).toBe(3);
      expect(r.json.body).not.toContain("켜짐");
    });

    test("쓰기 응답이 시간 초과면 쓰지 못했다고 단정하지 않고 미상으로 낸다", async () => {
      const r = await runCli(["olive", "start", "--apply", "--json"], world({ replicas: after(depDoc(sup, 0)), scale: { supervisor: { sleepMs: 3_500 } } }));
      expect(r.code).toBe(1);
      expect(r.json.error.message).toContain("미상");
      expect(r.json.error.message).not.toContain("쓰지 못했다");
    }, 30_000);

    test("쓰기 응답이 시간 초과여도 다시 읽어 1과 준비를 확인하면 켜짐이다", async () => {
      const r = await runCli(["olive", "start", "--apply", "--json"], world({ replicas: after(upDoc(sup)), scale: { supervisor: { sleepMs: 3_500 } } }));
      expect(r.code).toBe(0);
      expect(r.json.body).toContain("켜짐: supervisor");
    }, 30_000);
  });
});

describe("stop on", () => {
  test("stop on: 켤 수 없음 대상도 0과 자물쇠를 건다", async () => {
    const r = await runCli(["olive", "stop", "on", "--apply", "--json"], world({ locks: freshLocks() }));
    expect(r.code).toBe(0);
    const writes = writesOf(r);
    for (const ns of NAMESPACES) expect([ns, writes.includes(createOf(ns))]).toEqual([ns, true]);
    for (const t of TARGETS) expect([t.id, writes.includes(scaleOf(t, 0))]).toEqual([t.id, true]);
    expect(r.json.body).toContain("정지됨(노드 미확인)");
    expect(r.json.body).not.toContain("정지 완료");
  }, 30_000);

  test("없는 네임스페이스·Deployment는 없음으로 넘어가고 쓰지 않는다", async () => {
    const r = await runCli(["olive", "stop", "on", "--apply", "--verbose", "--json"], world({ locks: freshLocks(), noNs: ["olive-session"], noDep: ["reader"] }));
    expect(r.code).toBe(0);
    const writes = writesOf(r);
    expect(writes).not.toContain(createOf("olive-session"));
    expect(writes).not.toContain(scaleOf(TARGETS[3], 0));
    expect(writes).not.toContain(scaleOf(TARGETS[2], 0));
    expect(writes).toContain(createOf("olive-reader"));
    expect(r.json.body).toContain("없는 네임스페이스 1곳");
    expect(r.json.body).toContain("Deployment 없음");
  }, 30_000);

  test("stop on: 자물쇠가 replicas 쓰기보다 먼저다", async () => {
    const r = await runCli(["olive", "stop", "on", "--apply", "--json"], world({ locks: freshLocks() }));
    const lastLock = r.calls.findLastIndex(isLockCreate);
    const firstScale = r.calls.findIndex(isScale);
    expect(lastLock).toBeGreaterThanOrEqual(0);
    expect(firstScale).toBeGreaterThan(lastLock);
  }, 30_000);

  test("stop on: 한 대상의 실패가 다른 대상의 자물쇠와 0을 막지 않는다", async () => {
    const locks = { ...freshLocks(), "olive-reader": [notFound] };
    const r = await runCli(["olive", "stop", "on", "--apply", "--json"], world({ locks, create: { "olive-reader": denied }, scale: { diagnosis: denied } }));
    expect(r.code).toBe(1);
    const writes = writesOf(r);
    for (const ns of NAMESPACES) expect([ns, writes.includes(createOf(ns))]).toEqual([ns, true]);
    for (const t of TARGETS) expect([t.id, writes.includes(scaleOf(t, 0))]).toEqual([t.id, true]);
    expect(r.json.error.message).toContain("차단 미완");
    expect(r.json.body).toContain("olive-reader(걸지 못했다)");
  }, 30_000);

  describe("stop on: 접수만 되거나 0이 확인되지 않으면 정지 완료라고 하지 않고 0으로 끝나지 않는다", () => {
    const notClaimed = (body: string) => {
      expect(body).not.toContain("정지 완료");
      expect(body).not.toContain("정지됨(노드 미확인)");
    };

    test("unconfirmed: 차단됨, replicas 미확정이고 자물쇠를 지우지 않는다", async () => {
      const syncing = (app: string) => json({ kind: "Application", metadata: { name: app, namespace: "argocd" }, operation: { sync: {} }, status: {} });
      const d = await direct("apply", ["stop", "on", "--apply"], world({ locks: freshLocks(), app: syncing }), { limits: SHORT });
      expect(d.code).toBe(3);
      expect(d.r.status).toBe("waiting");
      expect(d.body).toContain("차단됨, replicas 미확정");
      notClaimed(d.body);
      expect(d.calls.filter((c) => c.argv.includes("--raw"))).toEqual([]);
    }, 30_000);

    test("파드가 남음: 3이고 소멸 확인 전이다", async () => {
      const pods = { "olive-control": [podList(podDoc("olive-control")), podList(podDoc("olive-control", { deleting: true }))] };
      const r = await runCli(["olive", "stop", "on", "--apply", "--json"], world({ locks: freshLocks(), pods }));
      expect(r.code).toBe(3);
      expect(r.json.body).toContain("차단됨, 소멸 확인 전");
      expect(r.json.body).toContain("삭제 중 1개");
      expect(r.json.next).toContain(`--uids ${UID_A}`);
      notClaimed(r.json.body);
    }, 30_000);

    test("강제 삭제 중: 1이고 소멸을 주장하지 않는다", async () => {
      const pods = { "olive-control": [podList(podDoc("olive-control")), podList(podDoc("olive-control", { forced: true }))] };
      const r = await runCli(["olive", "stop", "on", "--apply", "--json"], world({ locks: freshLocks(), pods }));
      expect(r.code).toBe(1);
      expect(r.json.error.message).toContain("강제 삭제 중");
      notClaimed(r.json.body);
    }, 30_000);

    test("자물쇠 하나 실패: 1이고 차단 미완이다", async () => {
      const locks = { ...freshLocks(), sandbox: [notFound] };
      const r = await runCli(["olive", "stop", "on", "--apply", "--json"], world({ locks, create: { sandbox: denied } }));
      expect(r.code).toBe(1);
      expect(r.json.error.message).toContain("차단 미완");
      notClaimed(r.json.body);
    }, 30_000);

    test("파드를 읽지 못함: 0으로 세지 않고 3이다", async () => {
      const pods = { "olive-reader": [podList(), denied] };
      const r = await runCli(["olive", "stop", "on", "--apply", "--json"], world({ locks: freshLocks(), pods }));
      expect(r.code).toBe(3);
      expect(r.json.body).toContain("읽지 못한 대상 1곳");
      notClaimed(r.json.body);
    }, 30_000);
  });

  test("stop on: 현관에 닿지 못한 것을 보고에 남긴다", async () => {
    const ok = await runCli(["olive", "stop", "on", "--apply", "--json"], world({ locks: freshLocks() }));
    const bad = await runCli(["olive", "stop", "on", "--apply", "--json"], world({ locks: { ...freshLocks(), sandbox: [notFound] }, create: { sandbox: denied } }));
    const plan = await runCli(["olive", "stop", "on", "--json"], world());
    for (const r of [ok, bad, plan]) {
      expect(r.json.body).toContain("접수: 닿지 못함");
      expect(r.json.body.split("\n")[0]).toContain("접수 닿지 못함");
    }
    for (const r of [ok, bad]) expect(r.json.body).toContain("권한 폐기·실행 종료 지시: 하지 못함");
  }, 60_000);

  describe("stop on: 끝 상태는 마지막에 읽은 증거로만 정한다", () => {
    const notClaimed = (body: string) => {
      expect(body).not.toContain("정지 완료");
      expect(body).not.toContain("정지됨(노드 미확인)");
    };

    test("마지막 자물쇠 조회가 실패하면 차단 미확정이고 1이다", async () => {
      const locks = { ...freshLocks(), "olive-reader": [notFound, notFound, lockDoc("olive-reader"), denied] };
      const r = await runCli(["olive", "stop", "on", "--apply", "--json"], world({ locks }));
      expect(r.code).toBe(1);
      expect(r.json.error.message).toContain("차단 미확정");
      expect(r.json.body).toContain("olive-reader(자물쇠를 읽지 못했다)");
      expect(r.json.body.split("\n")[0]).toContain("자물쇠 4/5곳");
      notClaimed(r.json.body);
    }, 30_000);

    test("쓰기는 됐지만 마지막 읽기에서 사라진 자물쇠는 걸린 수에 넣지 않는다", async () => {
      const locks = { ...freshLocks(), sandbox: [notFound, notFound, lockDoc("sandbox"), notFound] };
      const r = await runCli(["olive", "stop", "on", "--apply", "--json"], world({ locks }));
      expect(r.code).toBe(1);
      expect(r.json.error.message).toContain("차단 미완");
      expect(r.json.body.split("\n")[0]).toContain("자물쇠 4/5곳");
      expect(r.json.body).toContain("sandbox(다시 읽으니 걸려 있지 않다)");
    }, 30_000);

    test("다섯 네임스페이스가 전부 없으면 정지됨이 아니고 stop verify와 같은 말로 1이다", async () => {
      const on = await runCli(["olive", "stop", "on", "--apply", "--json"], world({ noNs: NAMESPACES }));
      const verify = await runCli(["olive", "stop", "verify", "--json"], world({ noNs: NAMESPACES }));
      expect(on.code).toBe(1);
      expect(verify.code).toBe(1);
      for (const r of [on, verify]) expect(r.json.error.message).toContain("확인할 네임스페이스가 하나도 없다");
      expect(on.writes).toEqual([]);
      notClaimed(on.json.body);
    }, 30_000);

    test("지켜본 뒤 마지막 읽기의 replicas가 1이면 3이고 그 대상을 적는다", async () => {
      const replicas = { supervisor: [depDoc(TARGETS[0], 1), depDoc(TARGETS[0], 0), depDoc(TARGETS[0], 1)] };
      const r = await runCli(["olive", "stop", "on", "--apply", "--json"], world({ locks: freshLocks(), replicas }));
      expect(r.code).toBe(3);
      expect(r.json.body).toContain("차단됨, replicas 미확정");
      expect(r.json.body).toContain("supervisor(replicas 1)");
      expect(r.json.next).toContain("stop on --apply");
      notClaimed(r.json.body);
    }, 30_000);

    test("마지막 읽기의 replicas를 읽지 못하면 0으로 세지 않고 3이다", async () => {
      const replicas = { reader: [depDoc(TARGETS[2], 1), depDoc(TARGETS[2], 0), denied] };
      const r = await runCli(["olive", "stop", "on", "--apply", "--json"], world({ locks: freshLocks(), replicas }));
      expect(r.code).toBe(3);
      expect(r.json.body).toContain("reader(읽지 못함)");
      notClaimed(r.json.body);
    }, 30_000);

    test("replicas 미확정이면 다음 행동은 stop on 재실행이고 미확정 대상과 Application을 적는다", async () => {
      const replicas = { diagnosis: [depDoc(TARGETS[1], 1)] };
      const d = await direct("apply", ["stop", "on", "--apply"], world({ locks: freshLocks(), replicas, app: syncingApp }), { limits: SHORT });
      expect(d.code).toBe(3);
      expect(d.body).toContain("diagnosis(replicas 1)");
      // 상한이 회차 중간에 오면 같은 Application이 읽지 못함으로 남는다. 어느 쪽이든 이름은 보여야 한다.
      expect(d.body).toMatch(/(동기화 중|읽지 못한 Application) olive/);
      expect(d.r.next).toContain("stop on --apply");
      expect(d.r.next).not.toContain("stop verify");
    }, 30_000);

    test("작성 대상의 Deployment 없이 남은 작업 파드가 있으면 파드 수를 미상으로 두고 3이다", async () => {
      const pods = { sandbox: [podList(podDoc("sandbox"))] };
      const r = await runCli(["olive", "stop", "on", "--apply", "--json"], world({ locks: freshLocks(), noDep: ["writer"], pods }));
      expect(r.code).toBe(3);
      expect(r.json.body).toContain("차단됨, 소멸 확인 전");
      expect(r.json.body).toContain("식별할 수 없는 대상 1곳");
      notClaimed(r.json.body);
    }, 30_000);

    test("작성 대상의 Deployment가 있으면 그 셀렉터로 남은 파드를 찾는다", async () => {
      const pods = { sandbox: [podList(podDoc("sandbox"))] };
      const r = await runCli(["olive", "stop", "on", "--apply", "--json"], world({ locks: freshLocks(), pods }));
      expect(r.code).toBe(3);
      expect(r.json.body).toContain("실행 파드 1개");
      expect(r.calls.some((c) => c.argv.includes("app=worker-task"))).toBe(true);
    }, 30_000);

    test("두 관측 사이에 사라진 강제 삭제 파드는 정지됨을 막고 노드 확인을 안내한다", async () => {
      const pods = { "olive-control": [podList(podDoc("olive-control", { forced: true })), podList()] };
      const r = await runCli(["olive", "stop", "on", "--apply", "--json"], world({ locks: freshLocks(), pods }));
      expect(r.code).toBe(1);
      expect(r.json.error.message).toContain("강제 삭제");
      expect(r.json.next).toContain("노드");
      expect(r.json.next).toContain(`--uids ${UID_A}`);
      expect(r.json.next).not.toContain("잠시 뒤");
      notClaimed(r.json.body);
    }, 30_000);

    test("끝난 파드라도 강제 삭제 표식을 먼저 본다", async () => {
      const pods = { "olive-control": [podList(podDoc("olive-control", { forced: true, phase: "Succeeded" })), podList()] };
      const r = await runCli(["olive", "stop", "on", "--apply", "--json"], world({ locks: freshLocks(), pods }));
      expect(r.code).toBe(1);
      expect(r.json.error.message).toContain("강제 삭제");
      notClaimed(r.json.body);
    }, 30_000);

    test("내리기 전에 일부 파드를 읽지 못하면 UID 목록이 완전하지 않다고 그 줄에 적는다", async () => {
      const pods = { "olive-control": [podList(podDoc("olive-control")), podList()], "olive-reader": [denied, podList()] };
      const r = await runCli(["olive", "stop", "on", "--apply", "--json"], world({ locks: freshLocks(), pods }));
      expect(r.json.next).toContain(`--uids ${UID_A}`);
      expect(r.json.next).toContain("완전하지 않다");
    }, 30_000);
  });

  test("파드를 지우거나 강제 삭제하는 호출이 없고 가짜 시크릿이 출력에 없다", async () => {
    const pods = { "olive-control": [podList(podDoc("olive-control")), podList()] };
    const r = await runCli(["olive", "stop", "on", "--apply"], world({ locks: freshLocks(), pods }));
    for (const c of r.calls) expect([line(c), /--force|--grace-period|\bexec\b|delete pods?\b/.test(line(c))]).toEqual([line(c), false]);
    expectNoSecrets(r);
  }, 30_000);
});

describe("stop status", () => {
  test("대상별 자물쇠·replicas·실행 파드 수를 읽기만 하고, 읽지 못하면 1이다", async () => {
    const r = await runCli(["olive", "stop", "status", "--verbose", "--json"], world({ locks: heldLocks(), replicas: zeroed() }));
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.body).toContain("정지 중: 자물쇠 5/5곳 걸림");
    expect(r.json.body).toContain("supervisor olive-control/supervisor: replicas 0, 자물쇠 걸림, 실행 파드 0개");
    const bad = await runCli(["olive", "stop", "status", "--json"], world({ locks: { ...heldLocks(), sandbox: [denied] }, replicas: zeroed() }));
    expect(bad.code).toBe(1);
    expect(bad.json.error.message).toContain("확인 실패");
  });
});

describe("stop verify", () => {
  const held = () => world({ locks: heldLocks(), replicas: zeroed() });
  const nodeWith = (state: PodCgroup): NodeRead => ({ host: () => ({ state: "node", node: "nuc" }), podCgroup: () => state });

  describe("stop verify: 노드가 아니면 노드 미확인, 노드면 cgroup까지, 읽지 못하면 확인 실패", () => {
    test("노드가 아니면 정지됨(노드 미확인)이고 cgroup을 읽지 않는다", async () => {
      let read = 0;
      const node: NodeRead = { host: () => ({ state: "not-node" }), podCgroup: () => (read++, "empty") };
      const d = await direct("plan", ["stop", "verify", "--uids", UID_A], held(), { node });
      expect(d.code).toBe(0);
      expect(d.body).toContain("정지됨(노드 미확인)");
      expect(d.body).not.toContain("정지 완료");
      expect(read).toBe(0);
    });

    for (const state of ["absent", "empty"] as const) {
      test(`${state}: 지정한 UID의 cgroup까지만 말한다`, async () => {
        const d = await direct("plan", ["stop", "verify", "--uids", `${UID_A},${UID_B}`], held(), { node: nodeWith(state) });
        expect(d.code).toBe(0);
        expect(d.body).toContain("지정한 UID 2개의 cgroup이 비었거나 사라졌다");
        expect(d.body).not.toContain("정지 완료");
      });
    }

    test("populated: 3이고 프로세스가 남았다고 말한다", async () => {
      const d = await direct("plan", ["stop", "verify", "--uids", UID_A], held(), { node: nodeWith("populated") });
      expect(d.code).toBe(3);
      expect(d.body).toContain("프로세스가 남은 파드 1개");
      expect(d.body).not.toContain("정지 완료");
    });

    test("unreadable: 1이고 확인 실패다", async () => {
      const d = await direct("plan", ["stop", "verify", "--uids", UID_A], held(), { node: nodeWith("unreadable") });
      expect(d.code).toBe(1);
      expect(d.body).toContain("확인 실패");
      expect(d.body).not.toContain("정지 완료");
    });

    test("UID가 없으면 노드여도 정지 완료라고 하지 않는다", async () => {
      const d = await direct("plan", ["stop", "verify"], held(), { node: nodeWith("empty") });
      expect(d.code).toBe(0);
      expect(d.body).toContain("정지됨(노드 미확인)");
      expect(d.body).toContain("--uids");
    });

    test("노드인지 모르면 노드 미확인이다", async () => {
      const node: NodeRead = { host: () => ({ state: "unknown", reason: "Node 목록: 시간 초과" }), podCgroup: () => "empty" };
      const d = await direct("plan", ["stop", "verify", "--uids", UID_A], held(), { node });
      expect(d.code).toBe(0);
      expect(d.body).toContain("정지됨(노드 미확인)");
    });
  });

  test("일부 UID만 넘겨도 지정한 UID의 관측까지만 말하고 정지 완료(노드 확인)를 내지 않는다", async () => {
    const d = await direct("plan", ["stop", "verify", "--uids", UID_A], held(), { node: nodeWith("absent") });
    expect(d.body).not.toContain("정지 완료");
    expect(d.code).toBe(0);
    expect(d.body).toContain("지정한 UID 1개");
    expect(d.body).toContain("지정하지 않은 파드는 확인하지 않았다");
  });

  test("기본 단계는 소멸 확인이고 replicas 유지는 보지 않는다고 말한다", async () => {
    const d = await direct("plan", ["stop", "verify"], held(), { node: nodeWith("empty") });
    expect(d.body).toContain("replicas가 0으로 유지되는지는 보지 않는다");
  });

  test("기본 단계: 자물쇠가 빠졌거나 강제 삭제 중이면 1, 파드가 남았으면 3, 읽지 못하면 1이다", async () => {
    const node = nodeWith("empty");
    const noLock = await direct("plan", ["stop", "verify"], world({ locks: { ...heldLocks(), sandbox: [notFound] }, replicas: zeroed() }), { node });
    expect([noLock.code, noLock.body.includes("차단 미완")]).toEqual([1, true]);
    const forced = await direct("plan", ["stop", "verify"], world({ locks: heldLocks(), replicas: zeroed(), pods: { "olive-control": [podList(podDoc("olive-control", { forced: true }))] } }), { node });
    expect([forced.code, forced.body.includes("강제 삭제 중")]).toEqual([1, true]);
    const left = await direct("plan", ["stop", "verify"], world({ locks: heldLocks(), replicas: zeroed(), pods: { "olive-control": [podList(podDoc("olive-control", { deleting: true }))] } }), { node });
    expect([left.code, left.body.includes("종료 대기")]).toEqual([3, true]);
    const unread = await direct("plan", ["stop", "verify"], world({ locks: heldLocks(), replicas: zeroed(), pods: { sandbox: [denied] } }), { node });
    expect([unread.code, unread.body.includes("확인 실패")]).toEqual([1, true]);
  });

  test("--deep은 낮은 단계로 낮추지 않고 런타임 대조가 없다고 실패한다", async () => {
    const r = await runCli(["olive", "stop", "verify", "--deep", "--json"], []);
    expect(r.code).toBe(1);
    expect(r.json.error.message).toContain("런타임 대조는 아직 없다");
    expect(r.json.body).not.toContain("정지됨");
    expect(r.calls).toEqual([]);
  });
});

describe("stop off", () => {
  test("stop off: 실행 파드가 남아 있으면 자물쇠를 지우지 않는다", async () => {
    for (const flags of [[], ["--apply"]]) {
      const r = await runCli(["olive", "stop", "off", ...flags, "--json"], world({ locks: heldLocks(), replicas: zeroed(), pods: { "olive-reader": [podList(podDoc("olive-reader"))] } }));
      expect([flags, r.code]).toEqual([flags, 1]);
      expect(r.writes).toEqual([]);
      expect(r.json.error.message).toContain("실행 파드가 남아 있다");
    }
  });

  test("작성 대상의 Deployment 없이 남은 작업 파드가 있으면 자물쇠를 지우지 않는다", async () => {
    const pods = { sandbox: [podList(podDoc("sandbox"))] };
    const r = await runCli(["olive", "stop", "off", "--apply", "--json"], world({ locks: heldLocks(), replicas: zeroed(), noDep: ["writer"], pods }));
    expect(r.code).toBe(1);
    expect(r.writes).toEqual([]);
    expect(r.json.error.message).toContain("식별할 수 없는");
  });

  test("자물쇠 아래의 켤 수 없는 대상이 replicas 1이면 자물쇠를 하나도 지우지 않고 stop on으로 안내한다", async () => {
    const replicas = { ...zeroed(), reader: [depDoc(TARGETS[2], 1)] };
    for (const flags of [[], ["--apply"]]) {
      const r = await runCli(["olive", "stop", "off", ...flags, "--json"], world({ locks: heldLocks(), replicas }));
      expect([flags, r.code]).toEqual([flags, 1]);
      expect(r.writes).toEqual([]);
      expect(r.json.error.message).toContain("켤 수 없는 대상");
      expect(r.json.next).toContain("stop on --apply");
    }
  });

  test("켤 수 없는 대상의 replicas를 읽지 못하면 자물쇠를 지우지 않는다", async () => {
    const r = await runCli(["olive", "stop", "off", "--apply", "--json"], world({ locks: heldLocks(), replicas: { ...zeroed(), reader: [denied] } }));
    expect(r.code).toBe(1);
    expect(r.writes).toEqual([]);
    expect(r.json.next).toContain("stop on --apply");
  });

  test("Argo CD 동기화가 진행 중이면 자물쇠를 지우지 않는다", async () => {
    for (const flags of [[], ["--apply"]]) {
      const r = await runCli(["olive", "stop", "off", ...flags, "--json"], world({ locks: heldLocks(), replicas: zeroed(), app: syncingApp }));
      expect([flags, r.code]).toEqual([flags, 1]);
      expect(r.writes).toEqual([]);
      expect(r.json.error.message).toContain("동기화");
      expect(r.json.next).toContain("stop on --apply");
    }
  });

  test("Application을 읽지 못하면 동기화가 없다고 보지 않고 자물쇠를 지우지 않는다", async () => {
    const r = await runCli(["olive", "stop", "off", "--apply", "--json"], world({ locks: heldLocks(), replicas: zeroed(), app: () => denied }));
    expect(r.code).toBe(1);
    expect(r.writes).toEqual([]);
    expect(r.json.error.message).toContain("동기화");
  });

  test("되돌리기에서 replicas 0 요청만 접수되고 파드가 남아도 되돌렸다고 단정하지 않는다", async () => {
    const locks = Object.fromEntries(NAMESPACES.map((ns) => [ns, [lockDoc(ns), lockDoc(ns), notFound, notFound, lockDoc(ns)]]));
    const pods = { "olive-control": [podList(), podList(podDoc("olive-control", { deleting: true }))] };
    const r = await runCli(["olive", "stop", "off", "--apply", "--json"], world({ locks, replicas: zeroed(), pods, rollout: { code: 1, stderr: "timed out\n" } }));
    expect(r.code).toBe(1);
    expect(r.json.error.message).not.toContain("되돌렸다");
    expect(r.json.error.message).toContain("파드 소멸은 확인하지 않았다");
    expect(r.json.body).toContain("supervisor에 replicas 0을 요청했다");
    expect(r.json.next).toContain("stop on --apply");
  }, 30_000);

  test("파드를 읽지 못하면 0으로 보지 않고 자물쇠를 지우지 않는다", async () => {
    const r = await runCli(["olive", "stop", "off", "--apply", "--json"], world({ locks: heldLocks(), replicas: zeroed(), pods: { sandbox: [denied] } }));
    expect(r.code).toBe(1);
    expect(r.writes).toEqual([]);
  });

  test("stop off: 현관이 없어 끝나지 않은 것을 성공으로 내지 않는다", async () => {
    const r = await runCli(["olive", "stop", "off", "--apply", "--json"], world({ locks: clearingLocks(), replicas: { ...zeroed(), supervisor: [depDoc(TARGETS[0], 0), upDoc(TARGETS[0])] } }));
    expect(r.code).toBe(3);
    expect(r.json.status).toBe("waiting");
    const writes = writesOf(r);
    for (const ns of NAMESPACES) expect([ns, writes.includes(clearOf(ns))]).toEqual([ns, true]);
    expect(writes.filter((w) => w.includes(" scale "))).toEqual([scaleOf(TARGETS[0], 1)]);
    expect(r.json.body).toContain("현관의 접수 열기가 끝나지 않았다");
    expect(r.json.body).toContain("정책 revision과 확정되지 않은 외부 효과는 볼 상대가 없어 확인하지 못했다");
    expect(r.json.body).toContain("새 실행 세대 적기와 현관의 접수 열기");
    expect(r.json.next).toContain("현관");
  }, 30_000);

  test("자물쇠가 없으면 바꾸지 않고 그래도 끝났다고 하지 않는다", async () => {
    const r = await runCli(["olive", "stop", "off", "--apply", "--json"], world({ replicas: zeroed() }));
    expect(r.code).toBe(3);
    expect(r.writes).toEqual([]);
  });

  test("자물쇠를 지우다 실패하면 지운 곳을 다시 걸고 켜지 않는다", async () => {
    const locks: Record<string, Resp[]> = {
      ...heldLocks(),
      "olive-control": [lockDoc("olive-control"), lockDoc("olive-control"), notFound, notFound, lockDoc("olive-control")],
      "olive-diagnosis": [lockDoc("olive-diagnosis"), lockDoc("olive-diagnosis"), notFound, notFound, lockDoc("olive-diagnosis")],
    };
    const r = await runCli(["olive", "stop", "off", "--apply", "--json"], world({ locks, replicas: zeroed(), clear: { "olive-reader": denied } }));
    expect(r.code).toBe(1);
    const writes = writesOf(r);
    expect(writes).toContain(createOf("olive-control"));
    expect(writes).toContain(createOf("olive-diagnosis"));
    expect(writes).not.toContain(clearOf("olive-session"));
    expect(writes.filter((w) => w.includes(" scale "))).toEqual([]);
    expect(r.json.error.message).toContain("자물쇠를 다시 걸었다. 파드 소멸은 확인하지 않았다");
    expect(r.json.next).toContain("stop on --apply");
  }, 30_000);

  test("올린 대상이 준비되지 않으면 자물쇠를 다시 걸고 그 대상을 0으로 내린다", async () => {
    const locks = Object.fromEntries(NAMESPACES.map((ns) => [ns, [lockDoc(ns), lockDoc(ns), notFound, notFound, lockDoc(ns)]]));
    const r = await runCli(["olive", "stop", "off", "--apply", "--json"], world({ locks, replicas: zeroed(), rollout: { code: 1, stderr: "timed out\n" } }));
    expect(r.code).toBe(1);
    const writes = writesOf(r);
    for (const ns of NAMESPACES) expect([ns, writes.includes(createOf(ns))]).toEqual([ns, true]);
    const up = writes.indexOf(scaleOf(TARGETS[0], 1));
    const relock = writes.lastIndexOf(createOf("sandbox"));
    const down = writes.indexOf(scaleOf(TARGETS[0], 0));
    expect(up).toBeGreaterThanOrEqual(0);
    expect(relock).toBeGreaterThan(up);
    expect(down).toBeGreaterThan(relock);
    expect(r.json.error.message).toContain("자물쇠를 다시 걸었다, 올린 대상에 replicas 0을 요청했다. 파드 소멸은 확인하지 않았다");
  }, 30_000);

  test("되돌리기가 실패하면 되돌렸다고 하지 않고 못 한 곳을 적는다", async () => {
    const locks: Record<string, Resp[]> = Object.fromEntries(NAMESPACES.map((ns) => [ns, [lockDoc(ns), lockDoc(ns), notFound, notFound, lockDoc(ns)]]));
    locks.sandbox = [lockDoc("sandbox"), lockDoc("sandbox"), notFound];
    const r = await runCli(["olive", "stop", "off", "--apply", "--json"], world({ locks, replicas: zeroed(), rollout: { code: 1, stderr: "timed out\n" }, create: { sandbox: denied } }));
    expect(r.code).toBe(1);
    expect(r.json.error.message).toContain("되돌리기가 끝나지 않았다");
    expect(r.json.error.message).not.toContain("다시 정지 상태로 되돌렸다");
    expect(r.json.body).toContain("자물쇠를 다시 걸지 못한 곳 sandbox");
    expect(r.json.next).toContain("stop on --apply");
  }, 30_000);
});

describe("status", () => {
  const execArgv = ["kubectl", "-n", "olive-control", "exec", SUP_POD, "-c", "supervisor", "--request-timeout=20s", "--", "bun", "src/main/admin.ts", "status"];
  const rs = json({ apiVersion: "apps/v1", kind: "ReplicaSet", metadata: { name: SUP_RS, namespace: "olive-control", uid: RS_UID, ownerReferences: [{ apiVersion: "apps/v1", kind: "Deployment", name: "supervisor", uid: DEPLOY_UID, controller: true }] } });
  const report = JSON.stringify({ schema: "olive-supervisor-status/v1", alive: true, queued: 2, running: 1, diagnosis: "active", stop: "none", stopGeneration: 4, intakeOpen: true });
  const supervisor = (resp: Resp, pod: PodOpts = {}): World => ({
    replicas: { supervisor: [depDoc(TARGETS[0], 1)] },
    pods: { "olive-control": [podList(podDoc("olive-control", pod))] },
    extra: [kubectlRule(["-n", "olive-control", "get", "replicasets.apps", SUP_RS, "-o", "json"], rs), rule(execArgv, resp)],
  });
  const execCalls = (r: { calls: Call[] }) => r.calls.filter((c) => c.argv.includes("exec"));

  test("status: plan에서는 감독에 exec하지 않고, --apply에서만 감독 줄을 낸다", async () => {
    const plan = await runCli(["olive", "status", "--json"], world(supervisor({ stdout: report })));
    expect(plan.code).toBe(0);
    expectPlanReadOnly(plan);
    expect(execCalls(plan)).toEqual([]);
    expect(plan.json.body).toContain(`대상 파드 ${SUP_POD}`);
    expect(plan.json.body).toContain(execArgv.join(" "));
    expect(plan.json.body).not.toContain("대기 2");
    expect(plan.json.next).toBe("homelab olive status --apply");

    const applied = await runCli(["olive", "status", "--apply", "--json"], world(supervisor({ stdout: report })));
    expect(applied.code).toBe(0);
    expect(execCalls(applied).map((c) => c.argv)).toEqual([execArgv]);
    expect(applied.json.body).toContain("감독: 살아 있음, 대기 2, 실행 1, 자동 진단 켜짐, 정지 none(세대 4), 접수 열림");
  });

  test("감독의 꺼짐·대조 실패·결과 미상을 서로 다른 말로 낸다", async () => {
    const off = await runCli(["olive", "status", "--apply", "--json"], world({}));
    expect(off.code).toBe(0);
    expect(off.json.body).toContain("감독: 꺼져 있음(파드 없음)");

    const stranger = await runCli(["olive", "status", "--apply", "--json"], world(supervisor({ stdout: report }, { owned: false })));
    expect(stranger.code).toBe(1);
    expect(stranger.json.body).toContain("감독: 대조 실패");
    expect(execCalls(stranger)).toEqual([]);

    const unknown = await runCli(["olive", "status", "--apply", "--json"], world(supervisor({ sleepMs: 3_500 })));
    expect(unknown.code).toBe(1);
    expect(unknown.json.body).toContain("감독: 결과 미상");
    expect(unknown.json.body).not.toContain("꺼져 있음");
  }, 30_000);

  test("status: 없는 대상은 없음이고 실패가 아니다", async () => {
    const r = await runCli(["olive", "status", "--verbose", "--json"], world({ noNs: ["olive-session", "olive-reader"], noDep: ["writer"] }));
    expect(r.code).toBe(0);
    expect(r.json.body).toContain("session olive-session/session: 네임스페이스 없음");
    expect(r.json.body).toContain("writer sandbox/worker-task: Deployment 없음");
  });

  test("status: 기본 출력에 관측한 replicas를 넣고 없는 대상과 미상을 구별한다", async () => {
    const seen = await runCli(["olive", "status", "--json"], world({ replicas: { ...zeroed(), supervisor: [depDoc(TARGETS[0], 1)] }, noNs: ["olive-session"], noDep: ["reader"] }));
    expect(seen.code).toBe(0);
    expect(seen.json.body).toContain("replicas: supervisor 1, diagnosis 0, reader 없음, session 없음, writer 0");
    const unread = await runCli(["olive", "status", "--json"], world({ replicas: { ...zeroed(), diagnosis: [denied] } }));
    expect(unread.code).toBe(1);
    expect(unread.json.body).toContain("diagnosis 미상");
  });

  test("status: Deployment가 없어 파드를 식별할 수 없는 대상은 0개로 세지 않고 미상으로 적는다", async () => {
    const r = await runCli(["olive", "status", "--json"], world({ replicas: zeroed(), noDep: ["writer"] }));
    expect(r.code).toBe(0);
    expect(r.json.body).toContain("식별할 수 없는 대상 1곳");
  });

  test("전부 읽지 못하면 0개로 시작하지 않고 개수 미상이다", async () => {
    const pods = Object.fromEntries(NAMESPACES.map((ns) => [ns, [denied]]));
    const r = await runCli(["olive", "status", "--json"], world({ replicas: zeroed(), pods }));
    expect(r.code).toBe(1);
    expect(r.json.error.message).toContain("실행 파드 개수 미상");
    expect(r.json.error.message).not.toContain("실행 파드 0개");
  });

  test("일부만 읽으면 읽은 수와 미상 수를 가른다", async () => {
    const r = await runCli(["olive", "status", "--json"], world({ replicas: zeroed(), pods: { sandbox: [denied] } }));
    expect(r.code).toBe(1);
    expect(r.json.error.message).toContain("읽은 대상 4곳의 실행 파드 0개");
    expect(r.json.error.message).toContain("읽지 못한 대상 1곳");
  });

  test("읽지 못한 대상은 없음으로 바꾸지 않고 1이다", async () => {
    const r = await runCli(["olive", "status", "--verbose", "--json"], world({ pods: { sandbox: [denied] } }));
    expect(r.code).toBe(1);
    expect(r.json.error.message).toContain("확인 실패");
    expect(r.json.body).toContain("읽지 못한 대상 1곳");
  });

  test("삭제 중과 강제 삭제 중을 구별해 센다", async () => {
    const pods = { "olive-control": [podList(podDoc("olive-control", { deleting: true }), podDoc("olive-control", { uid: UID_B, forced: true }))] };
    const r = await runCli(["olive", "status", "--json"], world({ pods }));
    expect(r.json.body).toContain("실행 파드 2개(삭제 중 1개, 강제 삭제 중 1개)");
  });

  test("끝난 파드는 실행 파드로 세지 않는다", async () => {
    const pods = { "olive-control": [podList(podDoc("olive-control", { phase: "Succeeded" }))] };
    const r = await runCli(["olive", "status", "--json"], world({ pods }));
    expect(r.json.body).toContain("실행 파드 0개");
  });
});
