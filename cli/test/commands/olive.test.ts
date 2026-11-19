// homelab olive(상태 보기·정지 상태 확인). 실제 클러스터에 닿지 않는다: kubectl은 PATH 스텁이다.
import { describe, expect, test } from "bun:test";
import { parseInput } from "../../src/core/args";
import { allFlags } from "../../src/core/help";
import { EXIT } from "../../src/core/result";
import { makeOlive } from "../../src/commands/olive";
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
  }
  return rules;
}

const heldLocks = (): Record<string, Resp[]> => Object.fromEntries(NAMESPACES.map((ns) => [ns, [lockDoc(ns)]]));
const zeroed = (): Record<string, Resp[]> => Object.fromEntries(TARGETS.map((t) => [t.id, [depDoc(t, 0)]]));

const line = (c: Call) => c.argv.join(" ");

// 결과 객체를 직접 보는 시험은 같은 프로세스에서 명령을 돌린다.
async function direct(mode: "plan" | "apply", tokens: string[], rules: Rule[]) {
  const cmd = makeOlive();
  const t = testCtx(mode, rules);
  const r = await cmd.run(t.ctx, parseInput(allFlags(cmd), cmd.args, tokens));
  return { r, code: EXIT[r.status], body: r.body ?? "", ...t.calls() };
}

describe("plan", () => {
  test("plan: --apply 없이는 어떤 동작도 쓰기를 부르지 않는다", async () => {
    const cases: [string[], World][] = [
      [["status"], {}],
      [["stop", "status"], { locks: heldLocks(), replicas: zeroed() }],
      [["stop", "verify"], { locks: heldLocks(), replicas: zeroed() }],
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

  test("정지 풀기, 노드 확인, 런타임 대조는 없는 동작·플래그라 사용법 오류이고 아무것도 읽지 않는다", async () => {
    for (const args of [["stop", "off"], ["stop", "off", "--apply"], ["stop", "verify", "--deep"], ["stop", "verify", "--uids", UID_A]]) {
      const r = await runCli(["olive", ...args, "--json"], []);
      expect([args, r.code]).toEqual([args, 64]);
      expect(r.calls).toEqual([]);
    }
  });

  test("켜기(start)와 정지 걸기(stop on)는 없는 동작이라 사용법 오류이고 아무것도 읽지 않는다", async () => {
    for (const args of [["start"], ["start", "--apply"], ["stop", "on"], ["stop", "on", "--apply"], ["status", "--uids", UID_A], ["stop", "status", "--deep"]]) {
      const r = await runCli(["olive", ...args, "--json"], []);
      expect([args, r.code]).toEqual([args, 64]);
      expect(r.calls).toEqual([]);
    }
  });

  test("남은 동작의 출력·다음 행동과 도움말은 없는 명령·플래그를 안내하지 않는다", async () => {
    const gone = /olive start|stop on|stop off|--uids|--deep/;
    const runs = [
      await runCli(["olive", "status", "--json"], world()),
      await runCli(["olive", "status", "--apply", "--json"], world()),
      await runCli(["olive", "stop", "status", "--verbose", "--json"], world({ locks: { ...heldLocks(), sandbox: [notFound] }, replicas: zeroed() })),
      await runCli(["olive", "stop", "verify", "--json"], world({ locks: { ...heldLocks(), "olive-reader": [notFound] }, replicas: { ...zeroed(), reader: [depDoc(TARGETS[2], 1)] } })),
      await runCli(["olive", "stop", "verify", "--json"], world({ locks: heldLocks(), replicas: { ...zeroed(), reader: [depDoc(TARGETS[2], 1)] }, pods: { "olive-control": [podList(podDoc("olive-control", { deleting: true }))] } })),
      await runCli(["olive", "stop", "verify", "--json"], world({ locks: heldLocks(), replicas: zeroed(), pods: { "olive-control": [podList(podDoc("olive-control", { forced: true }))] } })),
      await runCli(["olive", "stop", "verify", "--json"], world({ noNs: NAMESPACES })),
    ];
    for (const [i, r] of runs.entries()) {
      const text = `${r.json.body ?? ""}\n${r.json.next ?? ""}\n${r.json.error?.next ?? ""}`;
      expect([i, text.match(gone)]).toEqual([i, null]);
    }
    const help = (await runCli(["olive", "-h"], [])).stdout.replace(/\s+/g, " ");
    expect(help.match(gone)).toBeNull();
    expect(help).toContain("정지를 걸거나 푸는 명령은 이 CLI에 아직 없습니다");
    expect(help).toContain("stop verify는 밖에서 실제로 걸린 자물쇠만 판독합니다");
  }, 60_000);
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

  test("기본 단계를 모두 확인하면 정지됨(노드 미확인)이고 노드 확인이 없다고 말한다", async () => {
    const r = await runCli(["olive", "stop", "verify", "--json"], held());
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.body).toContain("정지됨(노드 미확인)");
    expect(r.json.body).toContain("노드에서의 확인은 이 CLI에 아직 없다");
    expect(r.json.body).not.toContain("정지 완료");
  });

  test("기본 단계는 소멸 확인이고 replicas 유지는 보지 않는다고 말한다", async () => {
    const d = await direct("plan", ["stop", "verify"], held());
    expect(d.body).toContain("replicas가 0으로 유지되는지는 보지 않는다");
  });

  test("기본 단계: 자물쇠가 빠졌거나 강제 삭제 중이면 1, 파드가 남았으면 3, 읽지 못하면 1이다", async () => {
    const noLock = await direct("plan", ["stop", "verify"], world({ locks: { ...heldLocks(), sandbox: [notFound] }, replicas: zeroed() }));
    expect([noLock.code, noLock.body.includes("차단 미완")]).toEqual([1, true]);
    const forced = await direct("plan", ["stop", "verify"], world({ locks: heldLocks(), replicas: zeroed(), pods: { "olive-control": [podList(podDoc("olive-control", { forced: true }))] } }));
    expect([forced.code, forced.body.includes("강제 삭제 중")]).toEqual([1, true]);
    const left = await direct("plan", ["stop", "verify"], world({ locks: heldLocks(), replicas: zeroed(), pods: { "olive-control": [podList(podDoc("olive-control", { deleting: true }))] } }));
    expect([left.code, left.body.includes("종료 대기")]).toEqual([3, true]);
    const unread = await direct("plan", ["stop", "verify"], world({ locks: heldLocks(), replicas: zeroed(), pods: { sandbox: [denied] } }));
    expect([unread.code, unread.body.includes("확인 실패")]).toEqual([1, true]);
  });

  test("강제 삭제 중인 파드를 보면 1이고 그 파드를 적은 채 노드에서 직접 확인하라고 한다", async () => {
    const r = await runCli(["olive", "stop", "verify", "--json"], world({ locks: heldLocks(), replicas: zeroed(), pods: { "olive-control": [podList(podDoc("olive-control", { forced: true }))] } }));
    expect(r.code).toBe(1);
    expect(r.json.body).toContain(`강제 삭제 중인 파드: olive-control/${SUP_POD}(UID ${UID_A})`);
    expect(r.json.next).toContain("이 CLI에는 아직 노드에서의 확인이 없다. 노드에서 직접 확인한다");
    expect(r.json.body).not.toContain("정지됨");
  });

  test("자물쇠가 없는 대상에는 자물쇠가 새 파드를 막고 있다고 쓰지 않는다", async () => {
    const replicas = { ...zeroed(), reader: [depDoc(TARGETS[2], 1)] };
    const open = await runCli(["olive", "stop", "verify", "--json"], world({ locks: { ...heldLocks(), "olive-reader": [notFound] }, replicas }));
    expect(open.code).toBe(1);
    expect(open.json.error.message).toContain("차단 미완");
    expect(open.json.body).toContain("주의: replicas가 0이 아닌 대상 reader");
    expect(open.json.body).not.toContain("자물쇠가 새 파드만 막고 있다");
    const locked = await runCli(["olive", "stop", "verify", "--json"], world({ locks: heldLocks(), replicas }));
    expect(locked.json.body).toContain("이 가운데 reader는 자물쇠가 새 파드만 막고 있다");
  });

  test("다섯 네임스페이스가 전부 없으면 정지됨이 아니고 1이다", async () => {
    const verify = await runCli(["olive", "stop", "verify", "--json"], world({ noNs: NAMESPACES }));
    expect(verify.code).toBe(1);
    expect(verify.json.error.message).toContain("확인할 네임스페이스가 하나도 없다");
    expect(verify.json.body).not.toContain("정지됨(노드 미확인)");
  });

  test("작성 대상의 Deployment가 있으면 그 셀렉터로 남은 파드를 찾는다", async () => {
    const r = await runCli(["olive", "stop", "verify", "--json"], world({ locks: heldLocks(), replicas: zeroed(), pods: { sandbox: [podList(podDoc("sandbox"))] } }));
    expect(r.code).toBe(3);
    expect(r.json.body).toContain("실행 파드 1개");
    expect(r.calls.some((c) => c.argv.includes("app=worker-task"))).toBe(true);
  });

  test("끝난 파드라도 강제 삭제 표식을 먼저 본다", async () => {
    const r = await runCli(["olive", "stop", "verify", "--json"], world({ locks: heldLocks(), replicas: zeroed(), pods: { "olive-control": [podList(podDoc("olive-control", { forced: true, phase: "Succeeded" }))] } }));
    expect(r.code).toBe(1);
    expect(r.json.error.message).toContain("강제 삭제");
    expect(r.json.body).not.toContain("정지됨(노드 미확인)");
  });
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

  test("status --apply는 감독 exec 하나 말고 쓰기·삭제 호출이 없고 가짜 시크릿이 출력에 없다", async () => {
    const r = await runCli(["olive", "status", "--apply"], world(supervisor({ stdout: report })));
    for (const c of r.calls) expect([line(c), /--force|--grace-period|delete pods?\b|\bscale\b|\bcreate\b/.test(line(c))]).toEqual([line(c), false]);
    expect(r.writes.map((c) => c.argv)).toEqual([execArgv]);
    expectNoSecrets(r);
  }, 30_000);
});
