// 올리브 비상 정지 어댑터(core/olive.ts·core/node.ts). 실제 클러스터·노드·sudo에 닿지 않는다:
// kubectl은 PATH 스텁, cgroup·machine-id는 시험 임시 폴더를 뿌리로 준 nodeRead로만 읽는다.
import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { ExecTimeout, makeExec } from "../../src/core/exec";
import { kubectlArgv } from "../../src/core/kubectl";
import { nodeRead, podCgroupDirs } from "../../src/core/node";
import { STOP_LOCK_LABEL, STOP_LOCK_NAME, stopLockManifest } from "../../src/core/olive";
import { classify } from "../../src/core/writes";
import { applyWith, expectPlanReadOnly, rule, stubSandbox, testCtx, testRoot, type Call, type Resp } from "../harness";

const NS = "olive-run";
const DEP = "session";
const APP = "olive";
const UID_A = "8afa2150-81af-4018-9753-0183509606ad";
const UID_B = "1b5d2dd3-e830-49fd-bb90-4e93022446e8";
const QUOTA_UID = "0f0e0d0c-0b0a-4908-8706-050403020100";

const k = (args: string[]) => kubectlArgv(args);
const json = (x: unknown): Resp => ({ stdout: JSON.stringify(x) });
const notFound = (what: string): Resp => ({ code: 1, stderr: `Error from server (NotFound): ${what} not found\n` });
const failed: Resp = { code: 1, stderr: "error: dial tcp 127.0.0.1:6443: connect: connection refused\n" };
// 스텁이 HOMELAB_TEST_TIMEOUT_MS(3초)보다 오래 자면 exec가 시간 초과로 끝낸다.
const hang: Resp = { sleepMs: 3_500 };
const conflict: Resp = { code: 1, stderr: "Error from server (Conflict): Operation cannot be fulfilled on resourcequotas \"olive-stop\": Precondition failed: ResourceVersion in precondition: 10, ResourceVersion in object meta: 11\n" };

const deployArgv = (dep = DEP) => k(["-n", NS, "get", "deployments.apps", dep, "-o", "json"]);
const scaleArgv = (n: 0 | 1, dep = DEP) => k(["-n", NS, "scale", "deployments.apps", dep, `--replicas=${n}`]);
const appArgv = (app = APP) => k(["-n", "argocd", "get", "applications.argoproj.io", app, "-o", "json"]);
const lockGet = (ns = NS) => k(["-n", ns, "get", "resourcequotas", STOP_LOCK_NAME, "-o", "json"]);
const lockCreate = (ns = NS) => k(["-n", ns, "create", "-f", "-"]);
const lockDelete = (ns = NS) => k(["delete", "--raw", `/api/v1/namespaces/${ns}/resourcequotas/${STOP_LOCK_NAME}`, "-f", "-"]);
const podsArgv = (sel: string) => k(["-n", NS, "get", "pods", "-l", sel, "-o", "json"]);

const deployment = (replicas: number | undefined, o: { kind?: string; name?: string; ns?: string } = {}) =>
  json({ kind: o.kind ?? "Deployment", metadata: { name: o.name ?? DEP, namespace: o.ns ?? NS }, spec: replicas === undefined ? {} : { replicas } });
const app = (o: { operation?: unknown; phase?: string }) =>
  json({ kind: "Application", metadata: { name: APP, namespace: "argocd" }, ...(o.operation ? { operation: o.operation } : {}), status: o.phase ? { operationState: { phase: o.phase } } : {} });
const lockDoc = (patch: { hard?: Record<string, string>; scopes?: string[]; label?: string | null; rv?: string | null; deleting?: boolean } = {}) =>
  json({
    kind: "ResourceQuota",
    metadata: {
      name: STOP_LOCK_NAME,
      namespace: NS,
      uid: QUOTA_UID,
      ...(patch.rv === null ? {} : { resourceVersion: patch.rv ?? "10" }),
      labels: patch.label === null ? {} : { [STOP_LOCK_LABEL]: patch.label ?? "lock" },
      ...(patch.deleting ? { deletionTimestamp: "2026-11-17T11:00:00Z", finalizers: ["example.com/hold"] } : {}),
    },
    spec: { hard: patch.hard ?? { pods: "0" }, ...(patch.scopes ? { scopes: patch.scopes } : {}) },
  });

// 어떤 호출에도 강제 삭제·파드 삭제·exec가 없다.
function expectNoForce(calls: Call[]): void {
  for (const c of calls) {
    const line = c.argv.join(" ");
    expect([line, /--force|--grace-period|--now\b|\bexec\b|delete pods?\b|delete pod\//.test(line)]).toEqual([line, false]);
  }
}

describe("replicas 쓰기", () => {
  test("0과 1만 받고 argv는 scale --replicas=0|1 그대로다. 그 밖의 값·이름은 호출 전에 거부한다", async () => {
    const { ctx, calls } = testCtx("apply", [rule(scaleArgv(0)), rule(scaleArgv(1))]);
    await applyWith(ctx, (w) => {
      w.olive.setReplicas(NS, DEP, 0);
      w.olive.setReplicas(NS, DEP, 1);
      for (const bad of [2, -1, 0.5, Number.NaN, "0", "1", "--force", "--grace-period=0", null, undefined, true, [0]]) {
        expect(() => w.olive.setReplicas(NS, DEP, bad as any)).toThrow("replicas는 0·1만");
      }
      for (const [ns, dep] of [["--force", DEP], [NS, "--grace-period=0"], [NS, "x --force"], ["Olive", DEP], [NS, "a.b"], [NS, "-n"], ["", DEP], [NS, "x".repeat(64)]]) {
        expect(() => w.olive.setReplicas(ns, dep, 0)).toThrow("이름 형식이 아니다");
      }
    });
    const c = calls();
    expect(c.calls.map((x) => x.argv)).toEqual([scaleArgv(0), scaleArgv(1)]);
    expect(c.unmatched).toEqual([]);
    expectNoForce(c.calls);
  });

  test("읽기 문맥에는 쓰기 함수가 없다", () => {
    const { ctx } = testCtx("plan", []);
    const o = ctx.olive as Record<string, unknown>;
    for (const name of ["setReplicas", "stopLockSet", "stopLockClear", "holdZero"]) expect([name, o[name]]).toEqual([name, undefined]);
  });

  test("kubectl 실패·시간 초과는 던진다(성공으로 보지 않는다)", async () => {
    const { ctx } = testCtx("apply", [rule(scaleArgv(0), [failed, hang])]);
    await expect(applyWith(ctx, (w) => w.olive.setReplicas(NS, DEP, 0))).rejects.toThrow("connection refused");
    await expect(applyWith(ctx, (w) => w.olive.setReplicas(NS, DEP, 0))).rejects.toBeInstanceOf(ExecTimeout);
  });
});

describe("자물쇠(ResourceQuota)", () => {
  test("이름·모양이 고정이다: olive-stop, pods 0, 범위 없음, 라벨. 호출자가 넘긴 것은 쓰지 않는다", async () => {
    const { ctx, calls } = testCtx("apply", [rule(lockGet(), [notFound("resourcequotas \"olive-stop\""), lockDoc()]), rule(lockCreate(), {}, { captureStdin: true })]);
    const { value } = await applyWith(ctx, (w) => (w.olive.stopLockSet as any)(NS, { spec: { hard: { pods: "5" } } }, "other-name"));
    expect(value).toBe("created");
    const create = calls().calls.find((c) => c.argv.includes("create"))!;
    expect(JSON.parse(create.stdin!)).toEqual({
      apiVersion: "v1",
      kind: "ResourceQuota",
      metadata: { name: "olive-stop", namespace: NS, labels: { "homelab.ukyi.app/olive-stop": "lock" } },
      spec: { hard: { pods: "0" } },
    });
    expect(stopLockManifest("other")).toMatchObject({ metadata: { name: "olive-stop" }, spec: { hard: { pods: "0" } } });
    expectNoForce(calls().calls);
  });

  test("이미 같은 것이 있으면 same이고 만들지 않는다(다시 실행해도 안전)", async () => {
    const { ctx, calls } = testCtx("apply", [rule(lockGet(), lockDoc())]);
    expect((await applyWith(ctx, (w) => w.olive.stopLockSet(NS))).value).toBe("same");
    expect((await applyWith(ctx, (w) => w.olive.stopLockSet(NS))).value).toBe("same");
    expect(calls().calls.every((c) => c.argv.includes("get"))).toBe(true);
  });

  test("같은 이름의 다른 모양이면 덮어쓰지도 지우지도 않고 different다", async () => {
    for (const other of [lockDoc({ hard: { pods: "1" } }), lockDoc({ hard: { pods: "0", cpu: "0" } }), lockDoc({ scopes: ["Terminating"] }), lockDoc({ label: null }), lockDoc({ label: "x" })]) {
      const { ctx, calls } = testCtx("apply", [rule(lockGet(), other)]);
      expect(ctx.olive.stopLock(NS)).toBe("different");
      expect((await applyWith(ctx, (w) => w.olive.stopLockSet(NS))).value).toBe("different");
      expect((await applyWith(ctx, (w) => w.olive.stopLockClear(NS))).value).toBe("different");
      expect(calls().writes).toEqual([]);
    }
  });

  test("삭제 시각이 붙은 quota는 모양이 같아도 걸린 자물쇠가 아니다: 읽기·걸기·풀기 모두 deleting이고 쓰지 않는다", async () => {
    for (const doc of [lockDoc({ deleting: true }), lockDoc({ deleting: true, hard: { pods: "1" } })]) {
      const { ctx, calls } = testCtx("apply", [rule(lockGet(), doc)]);
      expect(ctx.olive.stopLock(NS)).toBe("deleting");
      expect((await applyWith(ctx, (w) => w.olive.stopLockSet(NS))).value).toBe("deleting");
      expect((await applyWith(ctx, (w) => w.olive.stopLockClear(NS))).value).toBe("deleting");
      expect(calls().writes).toEqual([]);
    }
    // 만드는 사이 지우는 중인 것과 부딪혀도 created·same이 아니다.
    const raced = testCtx("apply", [rule(lockGet(), [notFound("resourcequotas"), lockDoc({ deleting: true })]), rule(lockCreate(), { code: 1, stderr: "Error from server (AlreadyExists): resourcequotas \"olive-stop\" already exists\n" })]);
    expect((await applyWith(raced.ctx, (w) => w.olive.stopLockSet(NS))).value).toBe("deleting");
    // 만든 뒤 다시 읽었더니 지우는 중이면 던진다.
    const after = testCtx("apply", [rule(lockGet(), [notFound("resourcequotas"), lockDoc({ deleting: true })]), rule(lockCreate())]);
    await expect(applyWith(after.ctx, (w) => w.olive.stopLockSet(NS))).rejects.toThrow("걸린 자물쇠가 아니다");
  });

  test("만드는 사이 누가 먼저 만들었으면(AlreadyExists) 그 모양으로 답한다", async () => {
    const { ctx } = testCtx("apply", [rule(lockGet(), [notFound("resourcequotas"), lockDoc({ hard: { pods: "3" } })]), rule(lockCreate(), { code: 1, stderr: "Error from server (AlreadyExists): resourcequotas \"olive-stop\" already exists\n" })]);
    expect((await applyWith(ctx, (w) => w.olive.stopLockSet(NS))).value).toBe("different");
  });

  test("풀기는 같은 모양만 확인한 uid·resourceVersion으로 지우고, 지운 뒤 없음을 다시 본다", async () => {
    const { ctx, calls } = testCtx("apply", [rule(lockGet(), [lockDoc(), notFound("resourcequotas")]), rule(lockDelete(), {}, { captureStdin: true })]);
    expect((await applyWith(ctx, (w) => w.olive.stopLockClear(NS))).value).toBe("deleted");
    const del = calls().calls.find((c) => c.argv.includes("delete"))!;
    expect(JSON.parse(del.stdin!)).toEqual({ kind: "DeleteOptions", apiVersion: "v1", preconditions: { uid: QUOTA_UID, resourceVersion: "10" } });
    expectNoForce(calls().calls);
  });

  test("확인 뒤 같은 uid가 다른 모양으로 고쳐지면 지우지 않는다(버전 충돌 → 다시 읽어 different)", async () => {
    const changed = lockDoc({ rv: "11", hard: { pods: "0", cpu: "1" } });
    const { ctx, calls } = testCtx("apply", [rule(lockGet(), [lockDoc(), changed]), rule(lockDelete(), [conflict], { captureStdin: true })]);
    expect((await applyWith(ctx, (w) => w.olive.stopLockClear(NS))).value).toBe("different");
    const dels = calls().calls.filter((c) => c.argv.includes("delete"));
    expect(dels.map((c) => JSON.parse(c.stdin!).preconditions)).toEqual([{ uid: QUOTA_UID, resourceVersion: "10" }]);
    // 라벨만 바뀐 경우도 같다.
    const relabeled = testCtx("apply", [rule(lockGet(), [lockDoc(), lockDoc({ rv: "11", label: "x" })]), rule(lockDelete(), [conflict])]);
    expect((await applyWith(relabeled.ctx, (w) => w.olive.stopLockClear(NS))).value).toBe("different");
    expect(relabeled.calls().calls.filter((c) => c.argv.includes("delete")).length).toBe(1);
  });

  test("버전만 바뀌고 모양이 같으면 새 버전으로 다시 지운다. 충돌이 거듭되면 지우지 않고 던진다", async () => {
    const { ctx, calls } = testCtx("apply", [rule(lockGet(), [lockDoc(), lockDoc({ rv: "11" }), notFound("resourcequotas")]), rule(lockDelete(), [conflict, {}], { captureStdin: true })]);
    expect((await applyWith(ctx, (w) => w.olive.stopLockClear(NS))).value).toBe("deleted");
    expect(calls().calls.filter((c) => c.argv.includes("delete")).map((c) => JSON.parse(c.stdin!).preconditions.resourceVersion)).toEqual(["10", "11"]);
    const busy = testCtx("apply", [rule(lockGet(), lockDoc()), rule(lockDelete(), [conflict])]);
    await expect(applyWith(busy.ctx, (w) => w.olive.stopLockClear(NS))).rejects.toThrow("지우지 않았다");
    expect(busy.calls().calls.filter((c) => c.argv.includes("delete")).length).toBe(3);
  });

  test("없으면 absent, resourceVersion을 못 읽거나 지운 뒤에도 있으면 던진다. finalizer로 남았으면 deleting", async () => {
    const { ctx } = testCtx("apply", [rule(lockGet(), notFound("resourcequotas"))]);
    expect(ctx.olive.stopLock(NS)).toBe("absent");
    expect((await applyWith(ctx, (w) => w.olive.stopLockClear(NS))).value).toBe("absent");
    const noRv = testCtx("apply", [rule(lockGet(), lockDoc({ rv: null })), rule(lockDelete())]);
    await expect(applyWith(noRv.ctx, (w) => w.olive.stopLockClear(NS))).rejects.toThrow("resourceVersion");
    expect(noRv.calls().writes).toEqual([]);
    const still = testCtx("apply", [rule(lockGet(), lockDoc()), rule(lockDelete())]);
    await expect(applyWith(still.ctx, (w) => w.olive.stopLockClear(NS))).rejects.toThrow("지운 뒤에도 있다");
    const held = testCtx("apply", [rule(lockGet(), [lockDoc(), lockDoc({ rv: "12", deleting: true })]), rule(lockDelete())]);
    expect((await applyWith(held.ctx, (w) => w.olive.stopLockClear(NS))).value).toBe("deleting");
  });

  test("읽기 실패·시간 초과·모르는 출력은 absent가 아니라 던진다", async () => {
    for (const resp of [failed, { stdout: "not json" }, json({ kind: "ConfigMap", metadata: { name: STOP_LOCK_NAME, namespace: NS } }), json({ kind: "ResourceQuota", metadata: { name: "other", namespace: NS } }), json({ kind: "ResourceQuota", metadata: { name: STOP_LOCK_NAME, namespace: "other" } })]) {
      const { ctx } = testCtx("plan", [rule(lockGet(), resp)]);
      expect(() => ctx.olive.stopLock(NS)).toThrow();
    }
    const t = testCtx("plan", [rule(lockGet(), hang)]);
    expect(() => t.ctx.olive.stopLock(NS)).toThrow(ExecTimeout);
    const c = testCtx("apply", [rule(lockGet(), notFound("resourcequotas")), rule(lockCreate(), [failed])]);
    await expect(applyWith(c.ctx, (w) => w.olive.stopLockSet(NS))).rejects.toThrow("걸기");
  });
});

describe("replicas 지켜보기", () => {
  const one = { targets: [{ ns: NS, deployment: DEP }], apps: [APP] };

  test("1로 돌아오면 그 읽기 바로 다음에 0을 쓰고, 다음 회차에 0을 읽어야 zero다", async () => {
    // 이미 0이고 동기화가 없으면 쓰지 않고 바로 zero다.
    const { ctx, calls } = testCtx("apply", [rule(appArgv(), app({ phase: "Succeeded" })), rule(deployArgv(), deployment(0)), rule(scaleArgv(0))]);
    const { value } = await applyWith(ctx, (w) => w.olive.holdZero({ ...one, timeoutSec: 30 }));
    expect(value.result).toBe("zero");
    expect(calls().calls.filter((c) => c.argv.includes("scale"))).toEqual([]);

    // 동기화 중 1로 돌아옴 → 같은 회차에 0 쓰기 → 다음 회차에 동기화 끝·0 읽기.
    const back = testCtx("apply", [rule(appArgv(), [app({ phase: "Running" }), app({ phase: "Succeeded" })]), rule(deployArgv(), [deployment(1), deployment(0)]), rule(scaleArgv(0))]);
    const r = await applyWith(back.ctx, (w) => w.olive.holdZero({ ...one, timeoutSec: 30 }));
    expect(r.value).toEqual({ result: "zero", targets: [{ ns: NS, deployment: DEP, last: 0, rezeroed: 1, writeFailed: 0 }], syncing: [], unreadApps: [], missingApps: [] });
    const argv = back.calls().calls.map((c) => c.argv);
    expect(argv).toEqual([appArgv(), deployArgv(), scaleArgv(0), appArgv(), deployArgv()]);
    expectNoForce(back.calls().calls);
  });

  test("상한이 지나도 1이 계속 돌아오면 unconfirmed다(다시 쓴 횟수와 마지막 값을 낸다)", async () => {
    const { ctx, calls } = testCtx("apply", [rule(appArgv(), app({})), rule(deployArgv(), deployment(1)), rule(scaleArgv(0))]);
    const { value } = await applyWith(ctx, (w) => w.olive.holdZero({ ...one, timeoutSec: 1 }));
    expect(value.result).toBe("unconfirmed");
    expect(value.targets[0].last).toBe(1);
    expect(value.targets[0].rezeroed).toBeGreaterThanOrEqual(1);
    expect(value.targets[0].rezeroed).toBe(calls().calls.filter((c) => c.argv.includes("scale")).length);
  });

  test("0이어도 동기화가 끝나지 않았거나 Application을 못 읽으면 unconfirmed다", async () => {
    const syncing = testCtx("apply", [rule(appArgv(), app({ operation: { sync: {} }, phase: "Succeeded" })), rule(deployArgv(), deployment(0))]);
    const a = await applyWith(syncing.ctx, (w) => w.olive.holdZero({ ...one, timeoutSec: 1 }));
    expect([a.value.result, a.value.syncing]).toEqual(["unconfirmed", [APP]]);
    const unread = testCtx("apply", [rule(appArgv(), failed), rule(deployArgv(), deployment(0))]);
    const b = await applyWith(unread.ctx, (w) => w.olive.holdZero({ ...one, timeoutSec: 1 }));
    expect([b.value.result, b.value.unreadApps]).toEqual(["unconfirmed", [APP]]);
  });

  test("넘겨받은 Application이 없으면(NotFound) 대상이 0이어도 zero가 아니고 missingApps에 드러난다", async () => {
    const { ctx } = testCtx("apply", [rule(appArgv(), notFound("applications.argoproj.io")), rule(deployArgv(), deployment(0))]);
    const { value } = await applyWith(ctx, (w) => w.olive.holdZero({ ...one, timeoutSec: 1 }));
    expect([value.result, value.missingApps, value.syncing, value.unreadApps]).toEqual(["unconfirmed", [APP], [], []]);
    // 상한에 걸려 끊긴 마지막 회차면 대상은 unread로 남는다. 어느 쪽이든 0이 아닌 값은 아니다.
    expect([0, "unread"]).toContain(value.targets[0].last);
    // 다음 회차에 다시 나타나 끝났으면 zero다.
    const back = testCtx("apply", [rule(appArgv(), [notFound("applications.argoproj.io"), app({ phase: "Succeeded" })]), rule(deployArgv(), deployment(0))]);
    expect((await applyWith(back.ctx, (w) => w.olive.holdZero({ ...one, timeoutSec: 30 }))).value).toMatchObject({ result: "zero", missingApps: [] });
  });

  test("대상을 못 읽음·없음·replicas 없음·0 쓰기 실패는 zero가 아니다", async () => {
    for (const [resp, last] of [[failed, "unread"], [notFound("deployments.apps"), "absent"], [deployment(undefined), "unread"], [{ stdout: "{" }, "unread"]] as const) {
      const { ctx } = testCtx("apply", [rule(deployArgv(), resp)]);
      const { value } = await applyWith(ctx, (w) => w.olive.holdZero({ targets: [{ ns: NS, deployment: DEP }], apps: [], timeoutSec: 1 }));
      expect([value.result, value.targets[0].last]).toEqual(["unconfirmed", last]);
    }
    const { ctx } = testCtx("apply", [rule(deployArgv(), deployment(1)), rule(scaleArgv(0), failed)]);
    const { value } = await applyWith(ctx, (w) => w.olive.holdZero({ targets: [{ ns: NS, deployment: DEP }], apps: [], timeoutSec: 1 }));
    expect(value.result).toBe("unconfirmed");
    expect(value.targets[0].rezeroed).toBe(0);
    expect(value.targets[0].writeFailed).toBeGreaterThanOrEqual(1);
    // 경우마다 상한(1초)을 다 기다린다.
  }, 20_000);

  test("다른 종류·다른 이름·다른 ns의 응답이 replicas 0이어도 대상의 0으로 보지 않는다", async () => {
    for (const resp of [deployment(0, { kind: "StatefulSet" }), deployment(0, { name: "other" }), deployment(0, { ns: "other" })]) {
      const { ctx } = testCtx("apply", [rule(deployArgv(), resp)]);
      const { value } = await applyWith(ctx, (w) => w.olive.holdZero({ targets: [{ ns: NS, deployment: DEP }], apps: [], timeoutSec: 1 }));
      expect([value.result, value.targets[0].last]).toEqual(["unconfirmed", "unread"]);
    }
  }, 10_000);

  test("상한을 넘긴 응답으로 zero를 내지 않는다: 느린 Application 읽기는 남은 시간에 끊긴다", async () => {
    // 호출에 남은 시간을 걸지 않으면 1.5초 뒤 정상 응답을 받고 이어 0을 읽어 상한 뒤에 zero를 낸다.
    const { ctx, calls } = testCtx("apply", [rule(appArgv(), { ...app({ phase: "Succeeded" }), sleepMs: 1_500 }), rule(deployArgv(), deployment(0))]);
    const t0 = Date.now();
    const { value } = await applyWith(ctx, (w) => w.olive.holdZero({ ...one, timeoutSec: 1 }));
    const took = Date.now() - t0;
    expect(value.result).toBe("unconfirmed");
    expect(value.unreadApps).toEqual([APP]);
    expect(took).toBeLessThan(1_400);
    // 상한 뒤에는 Deployment도 읽지 않는다.
    expect(calls().calls.filter((c) => c.argv.includes("deployments.apps"))).toEqual([]);
  });

  test("상한 뒤에는 새 쓰기를 시작하지 않는다: 앞 대상의 읽기가 상한을 다 쓰면 뒤 대상은 읽지도 쓰지도 않는다", async () => {
    const DEP2 = "worker";
    const { ctx, calls } = testCtx("apply", [rule(deployArgv(), { ...deployment(1), sleepMs: 1_500 }), rule(deployArgv(DEP2), deployment(1)), rule(scaleArgv(0)), rule(scaleArgv(0, DEP2))]);
    const t0 = Date.now();
    const { value } = await applyWith(ctx, (w) => w.olive.holdZero({ targets: [{ ns: NS, deployment: DEP }, { ns: NS, deployment: DEP2 }], apps: [], timeoutSec: 1 }));
    expect(Date.now() - t0).toBeLessThan(1_400);
    expect(value.result).toBe("unconfirmed");
    expect(value.targets.map((t) => t.last)).toEqual(["unread", "unread"]);
    expect(calls().calls.filter((c) => c.argv.includes("scale"))).toEqual([]);
    expect(calls().calls.filter((c) => c.argv.includes(DEP2))).toEqual([]);
  });

  test("운영 기본 간격(2초)에서도 짧은 상한 안에 0 쓰기 뒤 한 번 더 읽어 zero를 낸다", async () => {
    // 다음 회차까지 poll 간격을 통째로 기다리면 "지금 + 2초 > 상한"이라 0 쓰기 뒤 확인 없이 unconfirmed로 끝난다.
    const { ctx, calls } = testCtx("apply", [rule(appArgv(), app({ phase: "Succeeded" })), rule(deployArgv(), [deployment(1), deployment(0)]), rule(scaleArgv(0))], { env: { HOMELAB_TEST_POLL_MS: "2000" } });
    const t0 = Date.now();
    const { value } = await applyWith(ctx, (w) => w.olive.holdZero({ ...one, timeoutSec: 2 }));
    expect(Date.now() - t0).toBeLessThan(2_000);
    expect(value).toMatchObject({ result: "zero", targets: [{ last: 0, rezeroed: 1 }] });
    expect(calls().calls.map((c) => c.argv)).toEqual([appArgv(), deployArgv(), scaleArgv(0), appArgv(), deployArgv()]);
  });

  test("상한·대상·이름은 호출 전에 검사한다", async () => {
    const { ctx, calls } = testCtx("apply", []);
    await applyWith(ctx, (w) => {
      for (const t of [0, -1, 1.5, 3601, "30", Number.NaN]) expect(() => w.olive.holdZero({ targets: [{ ns: NS, deployment: DEP }], apps: [], timeoutSec: t as any })).toThrow("상한");
      expect(() => w.olive.holdZero({ targets: [], apps: [], timeoutSec: 5 })).toThrow("대상");
      expect(() => w.olive.holdZero({ targets: [{ ns: NS, deployment: "--force" }], apps: [], timeoutSec: 5 })).toThrow("이름 형식");
      expect(() => w.olive.holdZero({ targets: [{ ns: NS, deployment: DEP }], apps: ["../x"], timeoutSec: 5 })).toThrow("이름 형식");
    });
    expect(calls().calls).toEqual([]);
  });
});

describe("Argo CD 동기화 진행", () => {
  test("operation이 있거나 Running·Terminating이면 진행 중, 끝 단계면 아니다, 없으면 null", () => {
    const cases: [Resp, unknown][] = [
      [app({ phase: "Running" }), { inProgress: true, phase: "Running" }],
      [app({ phase: "Terminating" }), { inProgress: true, phase: "Terminating" }],
      [app({ operation: { sync: { revision: "x" } }, phase: "Succeeded" }), { inProgress: true, phase: "Succeeded" }],
      [app({ phase: "Succeeded" }), { inProgress: false, phase: "Succeeded" }],
      [app({ phase: "Failed" }), { inProgress: false, phase: "Failed" }],
      [app({}), { inProgress: false, phase: null }],
      [notFound("applications.argoproj.io"), null],
    ];
    for (const [resp, want] of cases) {
      const { ctx, calls } = testCtx("plan", [rule(appArgv(), resp)]);
      expect(ctx.olive.appOperation(APP)).toEqual(want as any);
      expectPlanReadOnly(calls());
    }
  });

  test("실패·시간 초과·모르는 단계·다른 객체는 던진다", () => {
    for (const resp of [failed, app({ phase: "Paused" }), json({ kind: "Application", metadata: { name: "other", namespace: "argocd" } }), json({ kind: "Application", metadata: { name: APP, namespace: "default" } }), json({ kind: "Application", metadata: { name: APP, namespace: "argocd" }, operation: "x" })]) {
      const { ctx } = testCtx("plan", [rule(appArgv(), resp)]);
      expect(() => ctx.olive.appOperation(APP)).toThrow();
    }
    const t = testCtx("plan", [rule(appArgv(), hang)]);
    expect(() => t.ctx.olive.appOperation(APP)).toThrow(ExecTimeout);
  });
});

describe("실행 파드 목록", () => {
  const SEL = "app.kubernetes.io/part-of=olive,homelab.ukyi.app/run=1";
  const pod = (o: Record<string, unknown>, extra: Record<string, unknown> = {}) => ({ kind: "Pod", metadata: { name: "session-0", namespace: NS, uid: UID_A, ...o }, spec: { nodeName: "nuc", terminationGracePeriodSeconds: 30 }, status: { phase: "Running" }, ...extra });
  // kubectl get -l -o json이 내는 꼴(kind List, 항목마다 kind Pod).
  const list = (items: unknown[], metadata: Record<string, unknown> = { resourceVersion: "" }) => json({ apiVersion: "v1", kind: "List", metadata, items });

  test("UID·단계·노드·삭제 시각·유예를 읽고, 유예 0초 삭제는 forceDeleting이다", () => {
    const items = [pod({}), pod({ name: "session-1", uid: UID_B, deletionTimestamp: "2026-11-17T11:00:00Z", deletionGracePeriodSeconds: 30 }), pod({ name: "session-2", uid: UID_B, deletionTimestamp: "2026-11-17T11:00:00Z", deletionGracePeriodSeconds: 0 })];
    const { ctx, calls } = testCtx("plan", [rule(podsArgv(SEL), list(items))]);
    const pods = ctx.olive.runPods(NS, SEL);
    expect(pods.map((p) => [p.name, p.uid, p.phase, p.nodeName, p.deletionTimestamp, p.deletionGracePeriodSeconds, p.terminationGracePeriodSeconds, p.forceDeleting])).toEqual([
      ["session-0", UID_A, "Running", "nuc", null, null, 30, false],
      ["session-1", UID_B, "Running", "nuc", "2026-11-17T11:00:00Z", 30, 30, false],
      ["session-2", UID_B, "Running", "nuc", "2026-11-17T11:00:00Z", 0, 30, true],
    ]);
    expectPlanReadOnly(calls());
  });

  test("빈 List는 0개, API의 PodList 원문(항목에 kind 없음)도 읽는다", () => {
    expect(testCtx("plan", [rule(podsArgv(SEL), list([]))]).ctx.olive.runPods(NS, SEL)).toEqual([]);
    const { kind: _, ...bare } = pod({});
    expect(testCtx("plan", [rule(podsArgv(SEL), json({ kind: "PodList", metadata: {}, items: [bare] }))]).ctx.olive.runPods(NS, SEL).map((p) => p.uid)).toEqual([UID_A]);
  });

  test("items 없음·실패·시간 초과·uid 꼴 틀림은 던진다", () => {
    for (const resp of [failed, json({ kind: "List" }), list([pod({ uid: "../x" })]), list([pod({ deletionTimestamp: "yesterday" })]), { stdout: "" }]) {
      const { ctx } = testCtx("plan", [rule(podsArgv(SEL), resp)]);
      expect(() => ctx.olive.runPods(NS, SEL)).toThrow();
    }
    const t = testCtx("plan", [rule(podsArgv(SEL), hang)]);
    expect(() => t.ctx.olive.runPods(NS, SEL)).toThrow(ExecTimeout);
  });

  test("다른 종류의 목록·남은 페이지가 있는 부분 목록·Pod가 아닌 항목·다른 ns 항목은 0개나 목록으로 바꾸지 않고 던진다", () => {
    const cases: [Resp, string][] = [
      [json({ apiVersion: "v1", kind: "NodeList", items: [] }), "파드 목록 응답이 아니다"],
      [json({ items: [] }), "파드 목록 응답이 아니다"],
      [list([], { continue: "eyJ2IjoibWV0YS5rOHMuaW8vdjEifQ" }), "부분 목록"],
      [json({ kind: "PodList", metadata: { continue: "x", remainingItemCount: 3 }, items: [] }), "부분 목록"],
      [list([pod({}, { kind: "Node" })]), "Pod가 아니다"],
      [list([pod({ namespace: "other" })]), "다른 ns"],
    ];
    for (const [resp, msg] of cases) {
      const { ctx } = testCtx("plan", [rule(podsArgv(SEL), resp)]);
      expect(() => ctx.olive.runPods(NS, SEL)).toThrow(msg);
    }
  });

  test("selector는 key=value 꼴만", () => {
    const { ctx, calls } = testCtx("plan", []);
    for (const s of ["", "app", "app!=x", "app in (a,b)", "a=b;c", "a=b --all", "a=b,"]) expect(() => ctx.olive.runPods(NS, s)).toThrow("selector");
    expect(calls().calls).toEqual([]);
  });
});

// 노드 쪽 시험 장치. 임시 폴더를 cgroup 뿌리·machine-id로 주고, kubectl은 스텁 PATH로 부른다.
function nodeWorld(rules: Parameters<typeof stubSandbox>[0], opts: { machineId?: string | null } = {}) {
  const sb = stubSandbox(rules);
  const root = mkdtempSync(join(testRoot(), "node-"));
  const cgroup = join(root, "cgroup");
  mkdirSync(join(cgroup, "kubepods.slice"), { recursive: true });
  const machineId = join(root, "machine-id");
  if (opts.machineId !== null) writeFileSync(machineId, `${opts.machineId ?? "0123456789abcdef0123456789abcdef"}\n`);
  const exec = makeExec("read", { env: sb.env });
  return { node: nodeRead(exec, { cgroup, machineId }), cgroup, calls: sb.calls, events: (uid: string, qos: 0 | 1 | 2, text: string | null) => {
    const dir = podCgroupDirs(cgroup, uid)[qos];
    mkdirSync(dir, { recursive: true });
    if (text !== null) writeFileSync(join(dir, "cgroup.events"), text);
  } };
}

const nodesArgv = () => k(["get", "nodes", "-o", "json"]);
const nodes = (...ids: string[]) => json({ items: ids.map((id, i) => ({ metadata: { name: `n${i}` }, status: { nodeInfo: { machineID: id } } })) });

describe("노드의 파드 cgroup(sudo 없이)", () => {
  test("경로 꼴이 고정이다(QoS 셋, UID의 -는 _)", () => {
    expect(podCgroupDirs("/sys/fs/cgroup", UID_A)).toEqual([
      "/sys/fs/cgroup/kubepods.slice/kubepods-pod8afa2150_81af_4018_9753_0183509606ad.slice",
      "/sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod8afa2150_81af_4018_9753_0183509606ad.slice",
      "/sys/fs/cgroup/kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod8afa2150_81af_4018_9753_0183509606ad.slice",
    ]);
  });

  test("경로 없음·비었음·남아 있음·읽지 못함을 가른다", () => {
    const w = nodeWorld([]);
    expect(w.node.podCgroup(UID_A)).toBe("absent");
    w.events(UID_A, 1, "populated 0\nfrozen 0\n");
    expect(w.node.podCgroup(UID_A)).toBe("empty");
    w.events(UID_A, 1, "populated 1\nfrozen 0\n");
    expect(w.node.podCgroup(UID_A)).toBe("populated");
    w.events(UID_B, 0, "populated 0\n");
    expect(w.node.podCgroup(UID_B)).toBe("empty");
    // 읽지 못함: cgroup.events가 없음, 꼴이 다름, QoS 두 곳에 같은 UID
    const x = nodeWorld([]);
    x.events(UID_A, 2, null);
    expect(x.node.podCgroup(UID_A)).toBe("unreadable");
    x.events(UID_A, 2, "frozen 0\n");
    expect(x.node.podCgroup(UID_A)).toBe("unreadable");
    x.events(UID_A, 2, "populated 2\n");
    expect(x.node.podCgroup(UID_A)).toBe("unreadable");
    x.events(UID_A, 2, "populated 0\npopulated 1\n");
    expect(x.node.podCgroup(UID_A)).toBe("unreadable");
    x.events(UID_A, 2, "populated 0\n");
    x.events(UID_A, 1, "populated 0\n");
    expect(x.node.podCgroup(UID_A)).toBe("unreadable");
  });

  test("kubepods.slice가 없으면(노드가 아니거나 꼴이 다름) absent가 아니라 unreadable이다", () => {
    const sb = stubSandbox([]);
    const root = mkdtempSync(join(testRoot(), "node-"));
    const n = nodeRead(makeExec("read", { env: sb.env }), { cgroup: join(root, "none"), machineId: join(root, "machine-id") });
    expect(n.podCgroup(UID_A)).toBe("unreadable");
  });

  test("UID 검증: 경로 탈출·대문자·다른 꼴은 읽기 전에 거절한다", () => {
    const w = nodeWorld([]);
    for (const bad of ["../../../etc", `${UID_A}/../x`, UID_A.toUpperCase(), `${UID_A}\n`, ` ${UID_A}`, UID_A.replaceAll("-", "_"), "8afa2150-81af-4018-9753-0183509606a", "", "*", null, 1]) {
      expect(() => w.node.podCgroup(bad as any)).toThrow("파드 UID");
    }
  });
});

describe("노드 판별", () => {
  test("machine-id가 Node 하나와 맞고 kubepods.slice가 있으면 node", () => {
    const w = nodeWorld([rule(nodesArgv(), nodes("ffffffffffffffffffffffffffffffff", "0123456789abcdef0123456789abcdef"))]);
    expect(w.node.host()).toEqual({ state: "node", node: "n1" });
    expectPlanReadOnly(w.calls());
  });

  test("맞는 Node가 없거나 machine-id 파일이 없으면 not-node", () => {
    expect(nodeWorld([rule(nodesArgv(), nodes("ffffffffffffffffffffffffffffffff"))]).node.host()).toEqual({ state: "not-node" });
    expect(nodeWorld([rule(nodesArgv(), nodes("0123456789abcdef0123456789abcdef"))], { machineId: null }).node.host()).toEqual({ state: "not-node" });
  });

  test("kubectl 실패·items 없음·중복·꼴 틀린 machine-id·cgroup 뿌리 없음은 unknown이다(not-node로 바꾸지 않는다)", () => {
    const id = "0123456789abcdef0123456789abcdef";
    for (const resp of [failed, json({}), { stdout: "x" }, nodes(id, id)]) expect(nodeWorld([rule(nodesArgv(), resp)]).node.host().state).toBe("unknown");
    expect(nodeWorld([rule(nodesArgv(), nodes(id))], { machineId: "not-an-id" }).node.host().state).toBe("unknown");
    const sb = stubSandbox([rule(nodesArgv(), nodes(id))]);
    const root = mkdtempSync(join(testRoot(), "node-"));
    writeFileSync(join(root, "machine-id"), `${id}\n`);
    expect(nodeRead(makeExec("read", { env: sb.env }), { cgroup: join(root, "none"), machineId: join(root, "machine-id") }).host().state).toBe("unknown");
  });
});

describe("컨테이너 런타임 목록(--deep)은 없다", () => {
  test("읽기·쓰기 문맥 어디에도 런타임 어댑터가 없고, k3s crictl을 부르는 sudo는 어떤 꼴도 쓰기로 판정된다", async () => {
    const { ctx } = testCtx("plan", []);
    expect(Object.keys(ctx.node).sort()).toEqual(["host", "podCgroup"]);
    const w = testCtx("apply", []);
    expect((await applyWith(w.ctx, (x) => Object.keys(x.node).sort())).value).toEqual(["host", "podCgroup"]);
    for (const argv of [["sudo", "-n", "/usr/local/bin/k3s", "crictl", "ps", "-a", "-o", "json"], ["sudo", "-n", "/usr/local/bin/crictl", "ps", "-a", "-o", "json"], ["/usr/local/bin/crictl", "ps"], ["k3s", "crictl", "ps"]]) {
      expect([argv.join(" "), classify(argv).write]).toEqual([argv.join(" "), true]);
    }
  });
});
