// 올리브 감독 관리 진입점 어댑터(core/olive-admin.ts). 실제 클러스터에 닿지 않는다: kubectl은 PATH 스텁이다.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import type { OliveSupervisorPod } from "../../src/core/command";
import { PLAN_WRITE_BLOCKED, ExecTimeout, makeExec } from "../../src/core/exec";
import { kubectlArgv } from "../../src/core/kubectl";
import { OLIVE_ADMIN_CONTAINER, OLIVE_ADMIN_ENTRY, OLIVE_ADMIN_LABELS, OLIVE_ADMIN_MAX_OUTPUT, OLIVE_ADMIN_NS, OLIVE_ADMIN_SELECTOR, OLIVE_ADMIN_STATUS_SCHEMA, parseStatus } from "../../src/core/olive-admin";
import { classify } from "../../src/core/writes";
import { applyWith, rule, stubSandbox, testCtx, type Resp } from "../harness";

const REPO = join(import.meta.dir, "..", "..", "..");
const POD = "supervisor-7c9d8f6b5-x2k4q";
const CANARY = "canary-raw-output-7f3a";
const FIXED_REPORT_ERROR = "감독 관리 진입점 출력이 정해진 꼴이 아니다";

const podsArgv = kubectlArgv(["-n", OLIVE_ADMIN_NS, "get", "pods", "-l", OLIVE_ADMIN_SELECTOR, "-o", "json"]);
const execArgv = (pod = POD) => ["kubectl", "-n", OLIVE_ADMIN_NS, "exec", pod, "-c", OLIVE_ADMIN_CONTAINER, "--request-timeout=20s", "--", ...OLIVE_ADMIN_ENTRY, "status"];

type PodOpts = { name?: string; ns?: string; phase?: string; ready?: boolean; deleting?: boolean; owner?: string | null; labels?: Record<string, string>; kind?: string; container?: string };
const pod = (o: PodOpts = {}) => ({
  kind: o.kind ?? "Pod",
  metadata: {
    name: o.name ?? POD,
    namespace: o.ns ?? OLIVE_ADMIN_NS,
    labels: o.labels ?? { ...OLIVE_ADMIN_LABELS },
    ownerReferences: o.owner === null ? [] : [{ kind: o.owner ?? "ReplicaSet", name: "supervisor-7c9d8f6b5" }],
    ...(o.deleting ? { deletionTimestamp: "2026-11-19T01:00:00Z" } : {}),
  },
  spec: { containers: [{ name: o.container ?? OLIVE_ADMIN_CONTAINER }] },
  status: { phase: o.phase ?? "Running", conditions: [{ type: "Ready", status: o.ready === false ? "False" : "True" }] },
});
const list = (...items: unknown[]): Resp => ({ stdout: JSON.stringify({ kind: "List", metadata: {}, items }) });

const GOOD = { schema: OLIVE_ADMIN_STATUS_SCHEMA, alive: true, queued: 2, running: 1, diagnosis: "active", stop: "none", stopGeneration: 3, intakeOpen: true };
const GOOD_VALUE = { alive: true, queued: 2, running: 1, diagnosis: "active", stop: "none", stopGeneration: 3, intakeOpen: true };
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
    const { ctx, calls } = testCtx("plan", []);
    expect(ctx.oliveAdmin.argv(POD, "status")).toEqual(["kubectl", "-n", "olive-control", "exec", POD, "-c", "supervisor", "--request-timeout=20s", "--", "bun", "src/main/admin.ts", "status"]);
    for (const bad of ["queue", "runs", "watch", "account", "diagnosis", "status --all", "--help", "-h", "status\n", "status\nqueue", "", " status", "toString", "__proto__", "constructor", null, undefined, 1, ["status"], { name: "status" }]) {
      expect(() => ctx.oliveAdmin.argv(POD, bad as any)).toThrow("감독 관리 동작은 status만");
    }
    for (const bad of ["--all", "-c", "a b", "a\nb", "Pod", "a/b", "", "x".repeat(254), "-", null, 1]) {
      expect(() => ctx.oliveAdmin.argv(bad as any, "status")).toThrow("감독 파드 이름 형식이 아니다");
    }
    expect(calls().calls).toEqual([]);
  });

  test("세션·작업자 파드로 가는 exec argv를 만들 수 없다", () => {
    const { ctx } = testCtx("plan", []);
    const targets = (Bun.YAML.parse(readFileSync(join(REPO, "platform/olive/targets.yaml"), "utf8")) as any).targets as { kind: string; namespace: string }[];
    expect(targets.filter((t) => t.kind === "supervisor").map((t) => t.namespace)).toEqual([OLIVE_ADMIN_NS]);
    const others = targets.filter((t) => t.kind !== "supervisor");
    expect(others.length).toBeGreaterThan(0);
    for (const t of others) expect([t.kind, t.namespace === OLIVE_ADMIN_NS]).toEqual([t.kind, false]);
    // 호출자가 대상을 더 넘겨도 ns·컨테이너는 상수 그대로다.
    const argv = (ctx.oliveAdmin.argv as any)("session-0", "status", { ns: "olive-session", container: "hc", argv: ["sh"] });
    expect(argv.slice(1, 7)).toEqual(["-n", "olive-control", "exec", "session-0", "-c", "supervisor"]);
    expect(argv.slice(8)).toEqual(["--", "bun", "src/main/admin.ts", "status"]);
    // 상수가 차트의 감독 Deployment와 같다.
    const deployment = readFileSync(join(REPO, "platform/olive/templates/supervisor-deployment.yaml"), "utf8");
    const helpers = readFileSync(join(REPO, "platform/olive/templates/_helpers.tpl"), "utf8");
    expect(deployment).toContain(`- name: ${OLIVE_ADMIN_CONTAINER}\n`);
    expect(helpers).toContain("app.kubernetes.io/name: olive");
    expect(helpers).toContain("app.kubernetes.io/component: {{ .kind }}");
    expect(helpers).toContain("homelab.ukyi.app/olive-target: {{ .id }}");
    // 다른 역할의 라벨이 붙은 파드는 대상이 되지 않는다.
    const session = { ...OLIVE_ADMIN_LABELS, "app.kubernetes.io/component": "session", "homelab.ukyi.app/olive-target": "session" };
    const { ctx: c2 } = testCtx("plan", [rule(podsArgv, [list(pod({ labels: session })), list(pod({ ns: "olive-session" })), list(pod({ container: "hc" }))])]);
    for (let i = 0; i < 3; i++) expect(() => c2.oliveAdmin.pod()).toThrow("감독 파드 모양이 아닌 항목");
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
    const cases: [Resp, OliveSupervisorPod][] = [
      [list(pod()), { state: "ready", pod: POD }],
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
      [list(pod({ phase: "Failed", ready: false, name: `${POD}-old` }), pod()), { state: "ready", pod: POD }],
      [list(pod({ phase: "Failed", ready: false })), { state: "not-ready", pods: 1 }],
    ];
    const { ctx, calls } = testCtx("plan", [rule(podsArgv, cases.map(([r]) => r))]);
    for (const [, want] of cases) expect(ctx.oliveAdmin.pod()).toEqual(want);
    expect(calls().calls.length).toBe(cases.length);
    expect(calls().unmatched).toEqual([]);
  });

  test("pod: 읽지 못한 것은 없음으로 바꾸지 않고 원문 없이 던진다", () => {
    const bad: Resp[] = [
      { code: 1, stderr: `error: dial tcp: connect: connection refused ${CANARY}\n` },
      { stdout: `not json ${CANARY}` },
      { stdout: JSON.stringify({ kind: "ConfigMapList", items: [] }) },
      { stdout: JSON.stringify({ kind: "List", metadata: { continue: "abc" }, items: [] }) },
      { stdout: JSON.stringify({ kind: "List", metadata: {} }) },
      list(pod({ owner: null })),
      list(pod({ owner: "Job" })),
      list(pod({ kind: "Secret" })),
    ];
    const { ctx } = testCtx("plan", [rule(podsArgv, bad)]);
    for (let i = 0; i < bad.length; i++) {
      const e = thrown(() => ctx.oliveAdmin.pod());
      expect(e.message).toStartWith("감독 파드를 읽지 못했다");
      expect(e.message).not.toContain(CANARY);
    }
  });

  test("pod: kubectl의 시간 초과는 ExecTimeout이다", () => {
    const { ctx } = testCtx("plan", [rule(podsArgv, { code: 1, stderr: "Unable to connect to the server: net/http: request canceled (Client.Timeout exceeded while awaiting headers)\n" })]);
    expect(thrown(() => ctx.oliveAdmin.pod())).toBeInstanceOf(ExecTimeout);
  });
});

describe("읽기 문맥", () => {
  test("read: 읽기 문맥은 exec를 부르지 않는다", () => {
    const { ctx, calls } = testCtx("plan", [rule(podsArgv, list(pod()))]);
    const target = ctx.oliveAdmin.pod();
    expect(target).toEqual({ state: "ready", pod: POD });
    ctx.oliveAdmin.argv(POD, "status");
    expect((ctx.oliveAdmin as Record<string, unknown>).run).toBeUndefined();
    const c = calls();
    expect(c.calls.map((x) => x.argv)).toEqual([podsArgv]);
    expect(c.calls.some((x) => x.argv.includes("exec"))).toBe(false);
    expect(c.writes).toEqual([]);
  });
});

describe("쓰기 문맥의 실행", () => {
  const execs = (c: ReturnType<ReturnType<typeof testCtx>["calls"]>) => c.calls.filter((x) => x.argv.includes("exec")).map((x) => x.argv);

  test("맞는 문서면 파드를 다시 찾아 한 번 실행하고 값을 돌려준다", async () => {
    const { ctx, calls } = testCtx("apply", [rule(podsArgv, list(pod())), rule(execArgv(), report())]);
    const { value } = await applyWith(ctx, (w) => w.oliveAdmin.run("status"));
    expect(value).toEqual({ state: "reported", pod: POD, status: GOOD_VALUE } as any);
    expect(calls().calls.map((x) => x.argv)).toEqual([podsArgv, execArgv()]);
  });

  test(
    "exec: 한 번만 실행하고, 시간 초과는 결과 미상이다",
    async () => {
      const { ctx, calls } = testCtx("apply", [rule(podsArgv, list(pod())), rule(execArgv(), { sleepMs: 3_500 })]);
      const { value } = await applyWith(ctx, (w) => w.oliveAdmin.run("status"));
      expect(value).toEqual({ state: "unknown" });
      expect(execs(calls())).toEqual([execArgv()]);
    },
    20_000,
  );

  test("exec: kubectl이 API 응답을 못 받고 끝나도 결과 미상이고 다시 실행하지 않는다", async () => {
    const { ctx, calls } = testCtx("apply", [rule(podsArgv, list(pod())), rule(execArgv(), { code: 1, stderr: `Unable to connect to the server: net/http: TLS handshake timeout ${CANARY}\n` })]);
    const { value } = await applyWith(ctx, (w) => w.oliveAdmin.run("status"));
    expect(value).toEqual({ state: "unknown" });
    expect(execs(calls())).toEqual([execArgv()]);
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
      const { ctx, calls } = testCtx("apply", [rule(podsArgv, resp)]);
      const { value } = await applyWith(ctx, (w) => w.oliveAdmin.run("status"));
      expect(value).toEqual({ state: "no-target", target } as any);
      expect(execs(calls())).toEqual([]);
    }
  });

  test("exec: 실패는 stderr·stdout 원문 없이 던지고 다시 실행하지 않는다", async () => {
    const { ctx, calls } = testCtx("apply", [rule(podsArgv, list(pod())), rule(execArgv(), { code: 7, stdout: `partial ${CANARY}`, stderr: `boom ${CANARY}\n` })]);
    const err = await applyWith(ctx, (w) => w.oliveAdmin.run("status")).then(
      () => null,
      (e: Error) => e,
    );
    expect(err?.message).toBe("감독 관리 진입점이 실패했다(exit 7)");
    expect(execs(calls())).toEqual([execArgv()]);
  });

  test("exec: 모르는 동작은 어떤 호출도 하기 전에 거부한다", async () => {
    const { ctx, calls } = testCtx("apply", [rule(podsArgv, list(pod()))]);
    await expect(applyWith(ctx, (w) => w.oliveAdmin.run("queue" as any))).rejects.toThrow("감독 관리 동작은 status만");
    expect(calls().calls).toEqual([]);
  });

  test("exec: 꼴이 다른 출력은 쓰기 문맥에서도 원문 없이 던진다", async () => {
    const { ctx } = testCtx("apply", [rule(podsArgv, list(pod())), rule(execArgv(), report({ ...GOOD, note: CANARY }))]);
    const err = await applyWith(ctx, (w) => w.oliveAdmin.run("status")).then(
      () => null,
      (e: Error) => e,
    );
    expect(err?.message).toBe(FIXED_REPORT_ERROR);
  });
});

describe("감독 상태 문서", () => {
  test("report: 맞는 문서는 값으로, 모르는 schema·빠진 칸·여분의 칸·타입 불일치·너무 큰 출력·JSON 아님은 원문 없이 던진다", () => {
    expect(parseStatus(`${JSON.stringify(GOOD)}\n`)).toEqual(GOOD_VALUE as any);
    expect(parseStatus(JSON.stringify(GOOD))).toEqual(GOOD_VALUE as any);
    expect(parseStatus(JSON.stringify({ ...GOOD, alive: false, queued: 0, running: 0, diagnosis: "paused", stop: "stopped", stopGeneration: 0, intakeOpen: false }))).toEqual({ alive: false, queued: 0, running: 0, diagnosis: "paused", stop: "stopped", stopGeneration: 0, intakeOpen: false });
    expect(parseStatus(JSON.stringify({ ...GOOD, stop: "stopping" })).stop).toBe("stopping");

    const text = JSON.stringify(GOOD);
    const atLimit = text + " ".repeat(OLIVE_ADMIN_MAX_OUTPUT - Buffer.byteLength(text));
    expect(parseStatus(atLimit)).toEqual(GOOD_VALUE as any);

    const bad: [string, string][] = [
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
    ];
    for (const [name, stdout] of bad) {
      const e = thrown(() => parseStatus(stdout));
      expect([name, e.message]).toEqual([name, FIXED_REPORT_ERROR]);
      expect([name, e.message.includes(CANARY)]).toEqual([name, false]);
    }
  });
});
