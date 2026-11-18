// 올리브 감독 관리 진입점 어댑터(core/olive-admin.ts). 실제 클러스터에 닿지 않는다: kubectl은 PATH 스텁이다.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import type { OliveSupervisorTarget } from "../../src/core/command";
import { PLAN_WRITE_BLOCKED, ExecTimeout, makeExec } from "../../src/core/exec";
import { kubectlArgv } from "../../src/core/kubectl";
import { OLIVE_ADMIN_CONTAINER, OLIVE_ADMIN_DEPLOYMENT, OLIVE_ADMIN_LABELS, OLIVE_ADMIN_MAX_OUTPUT, OLIVE_ADMIN_NS, OLIVE_ADMIN_SELECTOR, OLIVE_ADMIN_STATUS_SCHEMA, parseStatus } from "../../src/core/olive-admin";
import { classify } from "../../src/core/writes";
import { applyWith, rule, stubSandbox, testCtx, type Resp } from "../harness";

const REPO = join(import.meta.dir, "..", "..", "..");
const POD = "supervisor-7c9d8f6b5-x2k4q";
const RS = "supervisor-7c9d8f6b5";
const DEPLOY_UID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const RS_UID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const OTHER_UID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const CANARY = "canary-raw-output-7f3a";
const FIXED_REPORT_ERROR = "감독 관리 진입점 출력이 정해진 꼴이 아니다";

// CLI 상수를 따라가지 않도록 차트 파일과 글자로 적은 기대값에서 만든다.
const targets = (Bun.YAML.parse(readFileSync(join(REPO, "platform/olive/targets.yaml"), "utf8")) as any).targets as { id: string; kind: string; namespace: string; deployment: string }[];
const supervisorTarget = targets.filter((t) => t.kind === "supervisor")[0];
const helpers = readFileSync(join(REPO, "platform/olive/templates/_helpers.tpl"), "utf8");
const chartDefine = (name: string): string => {
  const m = new RegExp(`\\{\\{- define "${name}" -\\}\\}\\n([\\s\\S]*?)\\{\\{- end \\}\\}`).exec(helpers);
  if (!m) throw new Error(`차트 helper ${name}를 찾지 못했다`);
  return m[1];
};
const CHART_POD_LABELS = Bun.YAML.parse(
  chartDefine("olive.labels").replace('{{ include "olive.selectorLabels" . }}', chartDefine("olive.selectorLabels")).replaceAll("{{ .kind }}", supervisorTarget.kind).replaceAll("{{ .id }}", supervisorTarget.id),
) as Record<string, string>;
const SELECTOR = "app.kubernetes.io/name=olive,app.kubernetes.io/component=supervisor,homelab.ukyi.app/olive-target=supervisor";

const podsArgv = kubectlArgv(["-n", "olive-control", "get", "pods", "-l", SELECTOR, "-o", "json"]);
const deployArgv = kubectlArgv(["-n", "olive-control", "get", "deployments.apps", "supervisor", "-o", "json"]);
const rsArgv = (name = RS) => kubectlArgv(["-n", "olive-control", "get", "replicasets.apps", name, "-o", "json"]);
const execArgv = (pod = POD) => ["kubectl", "-n", "olive-control", "exec", pod, "-c", "supervisor", "--request-timeout=20s", "--", "bun", "src/main/admin.ts", "status"];

const rsRef = (o: Record<string, unknown> = {}) => ({ apiVersion: "apps/v1", kind: "ReplicaSet", name: RS, uid: RS_UID, controller: true, ...o });
const deployRef = (o: Record<string, unknown> = {}) => ({ apiVersion: "apps/v1", kind: "Deployment", name: "supervisor", uid: DEPLOY_UID, controller: true, ...o });

type PodOpts = { name?: string; ns?: string; phase?: string; ready?: boolean; deleting?: boolean; owners?: unknown[]; labels?: Record<string, string>; kind?: string; container?: string };
const pod = (o: PodOpts = {}) => ({
  kind: o.kind ?? "Pod",
  metadata: {
    name: o.name ?? POD,
    namespace: o.ns ?? "olive-control",
    labels: o.labels ?? { ...CHART_POD_LABELS },
    ownerReferences: o.owners ?? [rsRef()],
    ...(o.deleting ? { deletionTimestamp: "2026-11-19T01:00:00Z" } : {}),
  },
  spec: { containers: [{ name: o.container ?? "supervisor" }] },
  status: { phase: o.phase ?? "Running", conditions: [{ type: "Ready", status: o.ready === false ? "False" : "True" }] },
});
const list = (...items: unknown[]): Resp => ({ stdout: JSON.stringify({ kind: "List", metadata: {}, items }) });
const json = (x: unknown): Resp => ({ stdout: JSON.stringify(x) });
const deployment = (o: Record<string, unknown> = {}) => ({ kind: "Deployment", metadata: { name: "supervisor", namespace: "olive-control", uid: DEPLOY_UID, ...o } });
const replicaSet = (o: Record<string, unknown> = {}) => ({ kind: "ReplicaSet", metadata: { name: RS, namespace: "olive-control", uid: RS_UID, ownerReferences: [deployRef()], ...o } });
const notFound = (what: string): Resp => ({ code: 1, stderr: `Error from server (NotFound): ${what} not found\n` });
// 감독 Deployment가 제어하는 정상 소유 사슬.
const chain = () => [rule(deployArgv, json(deployment())), rule(rsArgv(), json(replicaSet()))];
const owned = (pods: Resp | Resp[]) => [rule(podsArgv, pods), ...chain()];

const GOOD = { schema: OLIVE_ADMIN_STATUS_SCHEMA, alive: true, queued: 2, running: 1, diagnosis: "active", stop: "none", stopGeneration: 3, intakeOpen: true };
const GOOD_VALUE = { alive: true, queued: 2, running: 1, diagnosis: "active", stop: "none", stopGeneration: 3, intakeOpen: true };
const READY: OliveSupervisorTarget = { state: "ready", pod: POD, argv: execArgv() };
const report = (x: unknown = GOOD): Resp => ({ stdout: `${JSON.stringify(x)}\n` });
const without = (key: string) => Object.fromEntries(Object.entries(GOOD).filter(([k]) => k !== key));

const thrown = (fn: () => unknown): Error => {
  try {
    fn();
  } catch (e) {
    return e as Error;
  }
  throw new Error("던지지 않았다");
};

describe("감독 관리 진입점 argv", () => {
  test("argv: ns·컨테이너·진입점이 고정이고 동작은 타입으로 좁힌 값만 들어간다", () => {
    const { ctx, calls } = testCtx("plan", owned(list(pod())));
    for (const bad of ["queue", "runs", "watch", "account", "diagnosis", "status --all", "--help", "-h", "status\n", "status\nqueue", "", " status", "toString", "__proto__", "constructor", null, undefined, 1, ["status"], { name: "status" }]) {
      expect(() => ctx.oliveAdmin.target(bad as any)).toThrow("감독 관리 동작은 status만");
    }
    expect(calls().calls).toEqual([]);
    expect(ctx.oliveAdmin.target("status")).toEqual({ state: "ready", pod: POD, argv: ["kubectl", "-n", "olive-control", "exec", POD, "-c", "supervisor", "--request-timeout=20s", "--", "bun", "src/main/admin.ts", "status"] });
  });

  test("argv: 목록의 파드 이름이 형식에 맞지 않으면 argv를 만들지 않는다", () => {
    for (const bad of ["--all", "-c", "a b", "a\nb", "Pod", "a/b", "", "x".repeat(254), "-", null, 1]) {
      const item = pod();
      const { ctx } = testCtx("plan", owned(list({ ...item, metadata: { ...item.metadata, name: bad } })));
      expect(() => ctx.oliveAdmin.target("status")).toThrow("감독 파드 모양이 아닌 항목");
    }
  });

  test("세션·작업자 파드로 가는 exec argv를 만들 수 없다", () => {
    expect(targets.filter((t) => t.kind === "supervisor").map((t) => t.namespace)).toEqual([OLIVE_ADMIN_NS]);
    const others = targets.filter((t) => t.kind !== "supervisor");
    expect(others.length).toBeGreaterThan(0);
    for (const t of others) expect([t.kind, t.namespace === OLIVE_ADMIN_NS]).toEqual([t.kind, false]);
    // 파드 이름을 받는 공개 함수가 없고, 호출자가 대상을 더 넘겨도 ns·파드·컨테이너는 그대로다.
    const { ctx } = testCtx("plan", owned(list(pod())));
    expect(Object.keys(ctx.oliveAdmin)).toEqual(["target"]);
    const found = (ctx.oliveAdmin.target as any)("status", "session-0", { ns: "olive-session", container: "hc", argv: ["sh"] });
    expect(found).toEqual(READY);
    // 상수가 차트의 감독 Deployment와 같다.
    const template = readFileSync(join(REPO, "platform/olive/templates/supervisor-deployment.yaml"), "utf8");
    expect(template).toContain(`- name: ${OLIVE_ADMIN_CONTAINER}\n`);
    // 다른 역할의 라벨이 붙은 파드는 대상이 되지 않는다.
    const session = { ...CHART_POD_LABELS, "app.kubernetes.io/component": "session", "homelab.ukyi.app/olive-target": "session" };
    const { ctx: c2 } = testCtx("plan", [rule(podsArgv, [list(pod({ labels: session })), list(pod({ ns: "olive-session" })), list(pod({ container: "hc" }))])]);
    for (let i = 0; i < 3; i++) expect(() => c2.oliveAdmin.target("status")).toThrow("감독 파드 모양이 아닌 항목");
  });

  test("차트: CLI의 라벨 맵과 보내는 셀렉터가 차트가 감독 파드 템플릿에 붙이는 라벨과 같다", () => {
    const template = readFileSync(join(REPO, "platform/olive/templates/supervisor-deployment.yaml"), "utf8");
    expect(template).toContain('  template:\n    metadata:\n      labels:\n        {{- include "olive.labels" $t | nindent 8 }}\n');
    const want = { "app.kubernetes.io/name": "olive", "app.kubernetes.io/component": "supervisor", "homelab.ukyi.app/olive-target": "supervisor" };
    expect(CHART_POD_LABELS).toMatchObject(want);
    expect({ ...OLIVE_ADMIN_LABELS }).toEqual(want);
    expect(OLIVE_ADMIN_SELECTOR).toBe(SELECTOR);

    const { ctx, calls } = testCtx("plan", [rule(podsArgv, list())]);
    expect(ctx.oliveAdmin.target("status")).toEqual({ state: "absent", pods: 0 });
    const sent = calls().calls[0].argv;
    const pairs = sent[sent.indexOf("-l") + 1].split(",").map((p) => p.split("="));
    expect(Object.fromEntries(pairs)).toEqual(want);
    for (const [k, v] of pairs) expect([k, CHART_POD_LABELS[k]]).toEqual([k, v]);
  });

  test("차트: 소유를 대조하는 Deployment의 ns·이름이 targets.yaml의 감독 줄과 같다", () => {
    expect([OLIVE_ADMIN_NS, OLIVE_ADMIN_DEPLOYMENT]).toEqual([supervisorTarget.namespace, supervisorTarget.deployment]);
  });

  test("이 exec는 쓰기로 판정되고 읽기 exec는 실행을 막는다", () => {
    const verdict = classify(execArgv());
    expect(verdict.write).toBe(true);
    expect(verdict.reason).toStartWith("kubectl exec");
    const sb = stubSandbox([rule(execArgv(), report())]);
    expect(() => makeExec("read", { env: sb.env })(execArgv())).toThrow(PLAN_WRITE_BLOCKED);
    expect(sb.calls().calls).toEqual([]);
  });
});

describe("대상 파드", () => {
  test("pod: Running·Ready 하나일 때만 대상이고, 0개·둘·삭제 중·Ready 아님을 각각 구별해 돌려준다", () => {
    const cases: [Resp, OliveSupervisorTarget][] = [
      [list(pod()), READY],
      [list(), { state: "absent", pods: 0 }],
      [list(pod(), pod({ name: `${POD}-b` })), { state: "multiple", pods: 2 }],
      [list(pod({ deleting: true })), { state: "terminating", pods: 1 }],
      [list(pod({ ready: false })), { state: "not-ready", pods: 1 }],
      [list(pod({ phase: "Pending", ready: false })), { state: "not-ready", pods: 1 }],
      // Ready 조건이 남아 있어도 Running이 아니면 대상이 아니다.
      [list(pod({ phase: "Pending" })), { state: "not-ready", pods: 1 }],
      // 지우는 중인 파드와 새 파드가 함께 있으면 어느 쪽도 고르지 않는다.
      [list(pod({ deleting: true }), pod({ name: `${POD}-b` })), { state: "multiple", pods: 2 }],
      // 쫓겨나 끝난 파드는 세지 않는다.
      [list(pod({ phase: "Failed", ready: false, name: `${POD}-old` }), pod()), READY],
      [list(pod({ phase: "Failed", ready: false })), { state: "not-ready", pods: 1 }],
      // not-ready의 수는 끝난 파드까지 든 목록 전체다.
      [list(pod({ phase: "Failed", ready: false, name: `${POD}-old` }), pod({ phase: "Pending", ready: false })), { state: "not-ready", pods: 2 }],
      [list(pod({ phase: "Failed", ready: false, name: `${POD}-old` }), pod({ phase: "Succeeded", ready: false })), { state: "not-ready", pods: 2 }],
    ];
    const { ctx, calls } = testCtx("plan", owned(cases.map(([r]) => r)));
    for (const [, want] of cases) expect(ctx.oliveAdmin.target("status")).toEqual(want);
    expect(calls().calls.filter((c) => c.argv.includes("pods")).length).toBe(cases.length);
    expect(calls().unmatched).toEqual([]);
  });

  test("소유: 파드 → ReplicaSet → Deployment를 실제 객체로 읽어 대조한다", () => {
    const { ctx, calls } = testCtx("plan", owned(list(pod(), pod({ phase: "Failed", ready: false, name: `${POD}-old` }))));
    expect(ctx.oliveAdmin.target("status")).toEqual(READY);
    // 같은 ReplicaSet은 한 번만 읽는다.
    expect(calls().calls.map((c) => c.argv)).toEqual([podsArgv, deployArgv, rsArgv()]);
  });

  const notOwned: [string, Resp, ReturnType<typeof rule>[]][] = [
    ["같은 라벨과 컨테이너 이름을 쓴 독립 ReplicaSet의 파드", list(pod()), [rule(deployArgv, json(deployment())), rule(rsArgv(), json(replicaSet({ ownerReferences: [] })))]],
    ["ReplicaSet에 소유 참조 칸이 없는 파드", list(pod()), [rule(deployArgv, json(deployment())), rule(rsArgv(), json(replicaSet({ ownerReferences: undefined })))]],
    ["다른 Deployment의 ReplicaSet의 파드", list(pod()), [rule(deployArgv, json(deployment())), rule(rsArgv(), json(replicaSet({ ownerReferences: [deployRef({ name: "other", uid: OTHER_UID })] })))]],
    ["이름만 같고 UID가 다른 Deployment의 ReplicaSet의 파드", list(pod()), [rule(deployArgv, json(deployment())), rule(rsArgv(), json(replicaSet({ ownerReferences: [deployRef({ uid: OTHER_UID })] })))]],
    ["Deployment를 제어 참조로 두지 않은 ReplicaSet의 파드", list(pod()), [rule(deployArgv, json(deployment())), rule(rsArgv(), json(replicaSet({ ownerReferences: [deployRef({ controller: false })] })))]],
    ["제어 참조가 아닌 소유 참조만 있는 파드", list(pod({ owners: [rsRef({ controller: undefined })] })), chain()],
    ["controller가 문자열인 소유 참조만 있는 파드", list(pod({ owners: [rsRef({ controller: "true" })] })), chain()],
    ["UID가 다른 ReplicaSet", list(pod({ owners: [rsRef({ uid: OTHER_UID })] })), chain()],
    ["소유 참조가 없는 파드", list(pod({ owners: [] })), chain()],
    ["Job이 제어하는 파드", list(pod({ owners: [rsRef({ kind: "Job", apiVersion: "batch/v1" })] })), chain()],
    ["옵션 꼴 이름의 ReplicaSet을 가리키는 파드", list(pod({ owners: [rsRef({ name: "--raw" })] })), chain()],
    ["정상 파드와 섞인 다른 소유의 파드", list(pod(), pod({ name: `${POD}-b`, phase: "Failed", ready: false, owners: [] })), chain()],
    ["ReplicaSet이 없는 파드", list(pod()), [rule(deployArgv, json(deployment())), rule(rsArgv(), notFound('replicasets.apps "x"'))]],
    ["감독 Deployment가 없는데 남은 파드", list(pod()), [rule(deployArgv, notFound('deployments.apps "supervisor"'))]],
  ];

  test("소유: 감독 Deployment의 파드로 확인되지 않으면 not-owned이고 없음으로 바꾸지 않는다", () => {
    for (const [name, pods, rules] of notOwned) {
      const { ctx, calls } = testCtx("plan", [rule(podsArgv, pods), ...rules]);
      const found = ctx.oliveAdmin.target("status");
      expect([name, found.state]).toEqual([name, "not-owned"]);
      expect([name, "pods" in found ? found.pods : -1]).toEqual([name, JSON.parse(pods.stdout as string).items.length]);
      expect([name, calls().unmatched]).toEqual([name, []]);
    }
  });

  test("소유: 쓰기 문맥도 같은 대조를 다시 해서 어긋나면 실행하지 않는다", async () => {
    for (const [name, pods, rules] of notOwned) {
      const { ctx, calls } = testCtx("apply", [rule(podsArgv, pods), ...rules]);
      const { value } = await applyWith(ctx, (w) => w.oliveAdmin.run("status"));
      expect([name, value.state]).toEqual([name, "no-target"]);
      expect([name, value.state === "no-target" ? value.target.state : ""]).toEqual([name, "not-owned"]);
      expect([name, calls().calls.some((c) => c.argv.includes("exec"))]).toEqual([name, false]);
    }
  });

  test("소유: plan에서 맞았어도 실행 직전 대조가 어긋나면 실행하지 않는다", async () => {
    const { ctx, calls } = testCtx("apply", [rule(podsArgv, list(pod())), rule(deployArgv, json(deployment())), rule(rsArgv(), [json(replicaSet()), json(replicaSet({ ownerReferences: [deployRef({ uid: OTHER_UID })] }))]), rule(execArgv(), report())]);
    expect(ctx.oliveAdmin.target("status")).toEqual(READY);
    const { value } = await applyWith(ctx, (w) => w.oliveAdmin.run("status"));
    expect(value).toEqual({ state: "no-target", target: { state: "not-owned", pods: 1 } });
    expect(calls().calls.some((c) => c.argv.includes("exec"))).toBe(false);
  });

  test("소유: 소유 객체를 읽지 못한 것은 대상 아님으로 바꾸지 않고 원문 없이 던진다", () => {
    const forbidden: Resp = { code: 1, stderr: `Error from server (Forbidden): ${CANARY}\n` };
    const bad: [string, ReturnType<typeof rule>[]][] = [
      ["Deployment 권한 없음", [rule(deployArgv, forbidden)]],
      ["Deployment JSON 아님", [rule(deployArgv, { stdout: `not json ${CANARY}` })]],
      ["다른 종류의 응답", [rule(deployArgv, json({ ...deployment(), kind: "StatefulSet" }))]],
      ["다른 이름의 Deployment", [rule(deployArgv, json(deployment({ name: "other" })))]],
      ["다른 ns의 Deployment", [rule(deployArgv, json(deployment({ namespace: "olive-session" })))]],
      ["UID가 없는 Deployment", [rule(deployArgv, json(deployment({ uid: undefined })))]],
      ["ReplicaSet 권한 없음", [rule(deployArgv, json(deployment())), rule(rsArgv(), forbidden)]],
      ["ReplicaSet JSON 아님", [rule(deployArgv, json(deployment())), rule(rsArgv(), { stdout: `not json ${CANARY}` })]],
      ["다른 이름의 ReplicaSet", [rule(deployArgv, json(deployment())), rule(rsArgv(), json(replicaSet({ name: "other" })))]],
      ["UID가 없는 ReplicaSet", [rule(deployArgv, json(deployment())), rule(rsArgv(), json(replicaSet({ uid: undefined })))]],
    ];
    for (const [name, rules] of bad) {
      const { ctx } = testCtx("plan", [rule(podsArgv, list(pod())), ...rules]);
      const e = thrown(() => ctx.oliveAdmin.target("status"));
      expect([name, e.message.startsWith("감독 파드를 읽지 못했다")]).toEqual([name, true]);
      expect([name, e.message.includes(CANARY)]).toEqual([name, false]);
    }
  });

  test("소유: 소유 객체를 읽다 시간 초과면 ExecTimeout이고 쓰기 문맥은 실행 없이 결과 미상이다", async () => {
    const timeout: Resp = { code: 1, stderr: "Unable to connect to the server: net/http: TLS handshake timeout\n" };
    for (const rules of [[rule(deployArgv, timeout)], [rule(deployArgv, json(deployment())), rule(rsArgv(), timeout)]]) {
      const plan = testCtx("plan", [rule(podsArgv, list(pod())), ...rules]);
      expect(thrown(() => plan.ctx.oliveAdmin.target("status"))).toBeInstanceOf(ExecTimeout);
      const apply = testCtx("apply", [rule(podsArgv, list(pod())), ...rules]);
      const { value } = await applyWith(apply.ctx, (w) => w.oliveAdmin.run("status"));
      expect(value).toEqual({ state: "unknown" });
      expect(apply.calls().calls.some((c) => c.argv.includes("exec"))).toBe(false);
    }
  });

  test("pod: 읽지 못한 것은 없음으로 바꾸지 않고 원문 없이 던진다", () => {
    const bad: Resp[] = [
      { code: 1, stderr: `error: dial tcp: connect: connection refused ${CANARY}\n` },
      { stdout: `not json ${CANARY}` },
      { stdout: JSON.stringify({ kind: "ConfigMapList", items: [] }) },
      { stdout: JSON.stringify({ kind: "List", metadata: { continue: "abc" }, items: [] }) },
      { stdout: JSON.stringify({ kind: "List", metadata: {} }) },
      list(pod({ kind: "Secret" })),
    ];
    const { ctx } = testCtx("plan", [rule(podsArgv, bad)]);
    for (let i = 0; i < bad.length; i++) {
      const e = thrown(() => ctx.oliveAdmin.target("status"));
      expect(e.message).toStartWith("감독 파드를 읽지 못했다");
      expect(e.message).not.toContain(CANARY);
    }
  });

  test("pod: kubectl의 시간 초과는 ExecTimeout이다", () => {
    const { ctx } = testCtx("plan", [rule(podsArgv, { code: 1, stderr: "Unable to connect to the server: net/http: request canceled (Client.Timeout exceeded while awaiting headers)\n" })]);
    expect(thrown(() => ctx.oliveAdmin.target("status"))).toBeInstanceOf(ExecTimeout);
  });

  test("pod: API 서버의 Timeout·ServerTimeout 응답은 ExecTimeout이다", () => {
    for (const stderr of [
      "Error from server (Timeout): the server was unable to return a response in the time allotted, but may still be processing the request (get pods)\n",
      "Error from server (ServerTimeout): the server cannot complete the requested operation at this time, try again later (get pods)\n",
    ]) {
      const { ctx } = testCtx("plan", [rule(podsArgv, { code: 1, stderr })]);
      expect(thrown(() => ctx.oliveAdmin.target("status"))).toBeInstanceOf(ExecTimeout);
    }
  });

  test("pod: 시간 초과 문구가 kubectl의 오류 형식이 아니면 일반 읽기 오류다", () => {
    for (const r of [
      { code: 1, stdout: "context deadline exceeded\n", stderr: "error: boom\n" },
      { code: 1, stderr: "i/o timeout\nError from server (Forbidden): pods is forbidden\n" },
      { code: 1, stderr: "Error from server (Forbidden): context deadline exceeded\n" },
    ]) {
      const { ctx } = testCtx("plan", [rule(podsArgv, r)]);
      const e = thrown(() => ctx.oliveAdmin.target("status"));
      expect(e).not.toBeInstanceOf(ExecTimeout);
      expect(e.message).toBe("감독 파드를 읽지 못했다(exit 1)");
    }
  });
});

describe("읽기 문맥", () => {
  test("read: 읽기 문맥은 exec를 부르지 않는다", () => {
    const { ctx, calls } = testCtx("plan", owned(list(pod())));
    expect(ctx.oliveAdmin.target("status")).toEqual(READY);
    expect((ctx.oliveAdmin as Record<string, unknown>).run).toBeUndefined();
    const c = calls();
    expect(c.calls.map((x) => x.argv)).toEqual([podsArgv, deployArgv, rsArgv()]);
    expect(c.calls.some((x) => x.argv.includes("exec"))).toBe(false);
    expect(c.writes).toEqual([]);
  });
});

describe("쓰기 문맥의 실행", () => {
  const execs = (c: ReturnType<ReturnType<typeof testCtx>["calls"]>) => c.calls.filter((x) => x.argv.includes("exec")).map((x) => x.argv);
  const failed = (ctx: ReturnType<typeof testCtx>["ctx"]) =>
    applyWith(ctx, (w) => w.oliveAdmin.run("status")).then(
      () => null,
      (e: Error) => e,
    );

  test("맞는 문서면 파드를 다시 찾아 대조하고 한 번 실행해 값을 돌려준다", async () => {
    const { ctx, calls } = testCtx("apply", [...owned(list(pod())), rule(execArgv(), report())]);
    const { value } = await applyWith(ctx, (w) => w.oliveAdmin.run("status"));
    expect(value).toEqual({ state: "reported", pod: POD, status: GOOD_VALUE } as any);
    expect(calls().calls.map((x) => x.argv)).toEqual([podsArgv, deployArgv, rsArgv(), execArgv()]);
  });

  test(
    "exec: 한 번만 실행하고, 시간 초과는 결과 미상이다",
    async () => {
      const { ctx, calls } = testCtx("apply", [...owned(list(pod())), rule(execArgv(), { sleepMs: 3_500 })]);
      const { value } = await applyWith(ctx, (w) => w.oliveAdmin.run("status"));
      expect(value).toEqual({ state: "unknown" });
      expect(execs(calls())).toEqual([execArgv()]);
    },
    20_000,
  );

  test("exec: kubectl이 API 응답을 못 받고 끝나도 결과 미상이고 다시 실행하지 않는다", async () => {
    const { ctx, calls } = testCtx("apply", [...owned(list(pod())), rule(execArgv(), { code: 1, stderr: `Unable to connect to the server: net/http: TLS handshake timeout ${CANARY}\n` })]);
    const { value } = await applyWith(ctx, (w) => w.oliveAdmin.run("status"));
    expect(value).toEqual({ state: "unknown" });
    expect(execs(calls())).toEqual([execArgv()]);
  });

  test("exec: API 서버의 Timeout·ServerTimeout 응답은 결과 미상이다", async () => {
    for (const stderr of [
      "Error from server (Timeout): the server was unable to return a response in the time allotted, but may still be processing the request (post pods supervisor)\n",
      "Error from server (ServerTimeout): the server cannot complete the requested operation at this time, try again later (post pods supervisor)\n",
    ]) {
      const { ctx, calls } = testCtx("apply", [...owned(list(pod())), rule(execArgv(), { code: 1, stderr })]);
      const { value } = await applyWith(ctx, (w) => w.oliveAdmin.run("status"));
      expect(value).toEqual({ state: "unknown" });
      expect(execs(calls())).toEqual([execArgv()]);
    }
  });

  test("exec: 진입점의 출력은 확인된 원격 종료 코드를 결과 미상으로 바꾸지 못한다", async () => {
    const forged = "Unable to connect to the server: net/http: TLS handshake timeout";
    const remoteExit = "command terminated with exit code 7\n";
    const cases: Resp[] = [
      { code: 7, stdout: "context deadline exceeded\n", stderr: remoteExit },
      { code: 7, stdout: `${forged}\n`, stderr: remoteExit },
      { code: 7, stderr: `${forged}\n${remoteExit}` },
      { code: 7, stderr: `Error from server (Timeout): ${CANARY}\n${remoteExit}` },
      // 잘린 stderr의 끝 줄이 kubectl 오류처럼 보여도 진짜 끝 줄을 알 수 없다.
      { code: 7, stderr: `${"x".repeat(2_000 - forged.length - 1)}\n${forged}\n${"y".repeat(100)}\n${remoteExit}` },
    ];
    for (const resp of cases) {
      const { ctx, calls } = testCtx("apply", [...owned(list(pod())), rule(execArgv(), resp)]);
      const err = await failed(ctx);
      expect(err?.message).toBe("감독 관리 진입점이 실패했다(exit 7)");
      expect(execs(calls())).toEqual([execArgv()]);
    }
  });

  test("exec: 파드 찾기가 시간 초과면 결과 미상이고 실행하지 않는다", async () => {
    const { ctx, calls } = testCtx("apply", [rule(podsArgv, { code: 1, stderr: "Unable to connect to the server: context deadline exceeded\n" })]);
    const { value } = await applyWith(ctx, (w) => w.oliveAdmin.run("status"));
    expect(value).toEqual({ state: "unknown" });
    expect(execs(calls())).toEqual([]);
  });

  test("exec: 대상이 하나가 아니면 실행하지 않고 그 사실을 돌려준다", async () => {
    const cases: [Resp, unknown][] = [
      [list(), { state: "absent", pods: 0 }],
      [list(pod(), pod({ name: `${POD}-b` })), { state: "multiple", pods: 2 }],
      [list(pod({ deleting: true })), { state: "terminating", pods: 1 }],
      [list(pod({ ready: false })), { state: "not-ready", pods: 1 }],
    ];
    for (const [resp, target] of cases) {
      const { ctx, calls } = testCtx("apply", owned(resp));
      const { value } = await applyWith(ctx, (w) => w.oliveAdmin.run("status"));
      expect(value).toEqual({ state: "no-target", target } as any);
      expect(execs(calls())).toEqual([]);
    }
  });

  test("exec: 실패는 stderr·stdout 원문 없이 던지고 다시 실행하지 않는다", async () => {
    const { ctx, calls } = testCtx("apply", [...owned(list(pod())), rule(execArgv(), { code: 7, stdout: `partial ${CANARY}`, stderr: `boom ${CANARY}\n` })]);
    const err = await failed(ctx);
    expect(err?.message).toBe("감독 관리 진입점이 실패했다(exit 7)");
    expect(execs(calls())).toEqual([execArgv()]);
  });

  test("exec: 모르는 동작은 어떤 호출도 하기 전에 거부한다", async () => {
    const { ctx, calls } = testCtx("apply", owned(list(pod())));
    await expect(applyWith(ctx, (w) => w.oliveAdmin.run("queue" as any))).rejects.toThrow("감독 관리 동작은 status만");
    expect(calls().calls).toEqual([]);
  });

  test("exec: 끝난 apply의 어댑터를 붙잡아 두었다가 부르면 어떤 호출도 하기 전에 막힌다", async () => {
    for (const pods of [list(), list(pod())]) {
      const { ctx, calls } = testCtx("apply", [...owned(pods), rule(execArgv(), report())]);
      const { value: kept } = await applyWith(ctx, (w) => w.oliveAdmin);
      expect(() => kept.run("status")).toThrow(PLAN_WRITE_BLOCKED);
      expect(calls().calls).toEqual([]);
    }
  });

  test("exec: 꼴이 다른 출력은 쓰기 문맥에서도 원문 없이 던진다", async () => {
    const { ctx } = testCtx("apply", [...owned(list(pod())), rule(execArgv(), report({ ...GOOD, note: CANARY }))]);
    const err = await failed(ctx);
    expect(err?.message).toBe(FIXED_REPORT_ERROR);
  });
});

describe("감독 상태 문서", () => {
  const text = JSON.stringify(GOOD);
  const rejected = (cases: [string, string][]) => {
    for (const [name, stdout] of cases) {
      const e = thrown(() => parseStatus(stdout));
      expect([name, e.message]).toEqual([name, FIXED_REPORT_ERROR]);
      expect([name, e.message.includes(CANARY)]).toEqual([name, false]);
    }
  };

  test("report: 맞는 문서는 값으로, 모르는 schema·빠진 칸·여분의 칸·타입 불일치·너무 큰 출력·JSON 아님은 원문 없이 던진다", () => {
    expect(parseStatus(`${JSON.stringify(GOOD)}\n`)).toEqual(GOOD_VALUE as any);
    expect(parseStatus(JSON.stringify(GOOD))).toEqual(GOOD_VALUE as any);
    expect(parseStatus(JSON.stringify({ ...GOOD, alive: false, queued: 0, running: 0, diagnosis: "paused", stop: "stopped", stopGeneration: 0, intakeOpen: false }))).toEqual({ alive: false, queued: 0, running: 0, diagnosis: "paused", stop: "stopped", stopGeneration: 0, intakeOpen: false });
    expect(parseStatus(JSON.stringify({ ...GOOD, stop: "stopping" })).stop).toBe("stopping");

    const atLimit = text + " ".repeat(OLIVE_ADMIN_MAX_OUTPUT - Buffer.byteLength(text));
    expect(parseStatus(atLimit)).toEqual(GOOD_VALUE as any);

    rejected([
      ["모르는 schema(다음 판)", JSON.stringify({ ...GOOD, schema: "olive-supervisor-status/v2" })],
      ["모르는 schema(원문)", JSON.stringify({ ...GOOD, schema: CANARY })],
      ...Object.keys(GOOD).map((k): [string, string] => [`빠진 칸 ${k}`, JSON.stringify({ ...without(k), filler: CANARY })]),
      ...Object.keys(GOOD).map((k): [string, string] => [`빠진 칸만 ${k}`, JSON.stringify(without(k))]),
      ["여분의 칸", JSON.stringify({ ...GOOD, note: CANARY })],
      ["여분의 칸 __proto__", `${text.slice(0, -1)},"__proto__":{"x":"${CANARY}"}}`],
      ["alive 문자열", JSON.stringify({ ...GOOD, alive: CANARY })],
      ["queued 문자열", JSON.stringify({ ...GOOD, queued: CANARY })],
      ["queued 음수", JSON.stringify({ ...GOOD, queued: -1 })],
      ["queued 소수", JSON.stringify({ ...GOOD, queued: 1.5 })],
      ["queued 상한", JSON.stringify({ ...GOOD, queued: 1_000_000 })],
      ["running null", JSON.stringify({ ...GOOD, running: null })],
      ["diagnosis 모르는 값", JSON.stringify({ ...GOOD, diagnosis: CANARY })],
      ["stop 모르는 값", JSON.stringify({ ...GOOD, stop: CANARY })],
      ["stopGeneration 음수", JSON.stringify({ ...GOOD, stopGeneration: -1 })],
      ["stopGeneration 안전 범위 밖", `${text.slice(0, -1).replace('"stopGeneration":3', '"stopGeneration":9007199254740992')}}`],
      ["stopGeneration 문자열", JSON.stringify({ ...GOOD, stopGeneration: "3" })],
      ["intakeOpen 수", JSON.stringify({ ...GOOD, intakeOpen: 1 })],
      ["너무 큰 출력", text + " ".repeat(OLIVE_ADMIN_MAX_OUTPUT - Buffer.byteLength(text) + 1) + CANARY],
      ["너무 큰 출력(맞는 JSON)", text + " ".repeat(OLIVE_ADMIN_MAX_OUTPUT)],
      ["JSON 아님", `plain ${CANARY}`],
      ["잘린 JSON", `{"schema":"${CANARY}`],
      ["빈 출력", ""],
      ["줄바꿈만", "\n"],
      ["배열", JSON.stringify([CANARY])],
      ["null", "null"],
      ["문자열", JSON.stringify(CANARY)],
      ["수", "1"],
      ["앞에 로그 줄", `${CANARY}\n${text}`],
      ["뒤에 로그 줄", `${text}\n${CANARY}`],
      ["두 문서", `${text}\n${text}\n`],
    ]);
  });

  test("report: 최상위 키는 디코딩한 이름 기준으로 한 번씩만 받는다", () => {
    const dup = (member: string) => `{${member},${text.slice(1)}`;
    rejected([
      ["서로 다른 두 값", text.replace('"alive":true', '"alive":false,"alive":true')],
      ["같은 값이 두 번", text.replace('"alive":true', '"alive":true,"alive":true')],
      ["stop 두 상태", text.replace('"stop":"none"', '"stop":"stopped","stop":"none"')],
      ["schema 두 번", dup('"schema":"olive-supervisor-status/v2"')],
      ["이스케이프 표기가 앞", text.replace('"alive":true', '"\\u0061live":false,"alive":true')],
      ["이스케이프 표기가 뒤", text.replace('"alive":true', '"alive":false,"\\u0061live":true')],
      ["대문자 16진 이스케이프", text.replace('"stopGeneration":3', '"stopGeneratio\\u006E":4,"stopGeneration":3')],
      ["둘 다 이스케이프", text.replace('"alive":true', '"\\u0061live":false,"\\u0061\\u006cive":true')],
    ]);
    // 중복이 아니면 이스케이프 표기 자체는 JSON의 같은 키다.
    expect(parseStatus(text.replace('"alive":true', '"\\u0061live":true'))).toEqual(GOOD_VALUE as any);
  });

  test("report: 정수 칸은 숫자 토큰의 글자로 먼저 검사해 반올림된 값을 받지 않는다", () => {
    const queued = (token: string) => text.replace('"queued":2', `"queued":${token}`);
    const generation = (token: string) => text.replace('"stopGeneration":3', `"stopGeneration":${token}`);
    rejected([
      ["0으로 반올림되는 수", queued("1e-400")],
      ["지수 표기", queued("1e2")],
      ["소수점 있는 정수", queued("2.0")],
      ["앞자리 0", queued("02")],
      ["음의 0", queued("-0")],
      ["양의 부호", queued("+2")],
      ["정수로 반올림되는 소수", generation("9007199254740990.5")],
      ["안전 범위를 넘어 반올림되는 정수", generation("9007199254740993")],
      ["아주 큰 지수", generation("1e400")],
    ]);
    expect(parseStatus(queued("0")).queued).toBe(0);
    expect(parseStatus(queued("999999")).queued).toBe(999_999);
    expect(parseStatus(generation("9007199254740991")).stopGeneration).toBe(Number.MAX_SAFE_INTEGER);
  });

  test("report: 중첩·null 값과 문법이 틀린 객체는 받지 않고, JSON 공백은 받는다", () => {
    rejected([
      ["중첩 객체", text.replace('"queued":2', '"queued":{"n":2}')],
      ["배열 값", text.replace('"queued":2', '"queued":[2]')],
      ["null 값", text.replace('"alive":true', '"alive":null')],
      ["빈 객체", "{}"],
      ["끝 쉼표", `${text.slice(0, -1)},}`],
      ["닫힌 뒤 글자", `${text}x`],
      ["두 객체를 한 줄에", `${text}${text}`],
      ["BOM", `﻿${text}`],
      ["잘못된 이스케이프", text.replace('"alive":true', '"al\\ive":true')],
    ]);
    const spaced = ` \t{ "schema" : "${OLIVE_ADMIN_STATUS_SCHEMA}" , "alive" : true , "queued" : 2 , "running" : 1 , "diagnosis" : "active" , "stop" : "none" , "stopGeneration" : 3 , "intakeOpen" : true } \r\n`;
    expect(parseStatus(spaced)).toEqual(GOOD_VALUE as any);
  });
});
