// 올리브 감독 관리 진입점 어댑터의 자리 풀기 쪽(core/olive-admin.ts): holds·release의 답 파서, 쓰기 argv, 사유 낱말, 작업자 파드 읽기.
// 실제 클러스터·감독에 닿지 않는다: kubectl은 PATH 스텁이다.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import type { OliveReleaseCall } from "../../src/core/command";
import { kubectlArgv } from "../../src/core/kubectl";
import { OLIVE_ADMIN_HOLDS_SCHEMA, OLIVE_ADMIN_RELEASE_SCHEMA, OLIVE_LEDGER_REFUSALS, OLIVE_WORKER_CONTAINER, parseHolds, parseRelease } from "../../src/core/olive-admin";
import { applyWith, rule, testCtx, type Resp } from "../harness";

const REPO = join(import.meta.dir, "..", "..", "..");
const POD = "supervisor-7c9d8f6b5-x2k4q";
const RS = "supervisor-7c9d8f6b5";
const DEPLOY_UID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const RS_UID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const SELECTOR = "app.kubernetes.io/name=olive,app.kubernetes.io/component=supervisor,homelab.ukyi.app/olive-target=supervisor";
const ENTRY = ["kubectl", "-n", "olive-control", "exec", POD, "-c", "supervisor", "--request-timeout=20s", "--", "bun", "src/main/admin.ts"];
const RUN = "3f2a9c41-5b6d-4e7f-8a9b-0c1d2e3f4a5b";
const STOP = "7a7a7a7a-0000-4000-8000-000000000007";
const EXECUTOR = "executor/diagnosis/diagnosis/store-1a2b3c";
const CANARY = "canary-raw-output-7f3a";

const json = (x: unknown): Resp => ({ stdout: JSON.stringify(x) });
const list = (...items: unknown[]): Resp => json({ kind: "List", metadata: {}, items });
const supPod = { apiVersion: "v1", kind: "Pod", metadata: { name: POD, namespace: "olive-control", uid: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", labels: { "app.kubernetes.io/name": "olive", "app.kubernetes.io/component": "supervisor", "homelab.ukyi.app/olive-target": "supervisor" }, ownerReferences: [{ apiVersion: "apps/v1", kind: "ReplicaSet", name: RS, uid: RS_UID, controller: true }] }, spec: { containers: [{ name: "supervisor" }] }, status: { phase: "Running", conditions: [{ type: "Ready", status: "True" }] } };
const supervisor = () => [
  rule(kubectlArgv(["-n", "olive-control", "get", "pods", "-l", SELECTOR, "-o", "json"]), list(supPod)),
  rule(kubectlArgv(["-n", "olive-control", "get", "deployments.apps", "supervisor", "-o", "json"]), json({ apiVersion: "apps/v1", kind: "Deployment", metadata: { name: "supervisor", namespace: "olive-control", uid: DEPLOY_UID } })),
  rule(kubectlArgv(["-n", "olive-control", "get", "replicasets.apps", RS, "-o", "json"]), json({ apiVersion: "apps/v1", kind: "ReplicaSet", metadata: { name: RS, namespace: "olive-control", uid: RS_UID, ownerReferences: [{ apiVersion: "apps/v1", kind: "Deployment", name: "supervisor", uid: DEPLOY_UID, controller: true }] } })),
];

// 차트 파일에서 읽은 작업자 실행기 대상(CLI 상수를 따라가지 않게).
const targets = (Bun.YAML.parse(readFileSync(join(REPO, "platform/olive/targets.yaml"), "utf8")) as any).targets as { id: string; kind: string; namespace: string; deployment: string }[];
const diag = targets.find((t) => t.id === "diagnosis")!;
const W_POD = "executor-5d8f7c9b4-q7w2e";
const W_RS = "executor-5d8f7c9b4";
const W_DEPLOY_UID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
const W_RS_UID = "ffffffff-ffff-4fff-8fff-ffffffffffff";
const W_SELECTOR = "app.kubernetes.io/name=olive,app.kubernetes.io/component=executor,homelab.ukyi.app/olive-target=diagnosis";
const wPodsArgv = kubectlArgv(["-n", diag.namespace, "get", "pods", "-l", W_SELECTOR, "-o", "json"]);
const wDeployArgv = kubectlArgv(["-n", diag.namespace, "get", "deployments.apps", diag.deployment, "-o", "json"]);
const wRsArgv = kubectlArgv(["-n", diag.namespace, "get", "replicasets.apps", W_RS, "-o", "json"]);
type WPod = { created?: unknown; container?: string; labels?: Record<string, string>; ns?: string; refs?: unknown[] };
const workerPod = (o: WPod = {}) => ({
  apiVersion: "v1",
  kind: "Pod",
  metadata: {
    name: W_POD,
    namespace: o.ns ?? diag.namespace,
    uid: "12121212-1212-4212-8212-121212121212",
    creationTimestamp: o.created === undefined ? "2026-11-27T07:10:05Z" : o.created,
    labels: o.labels ?? { "app.kubernetes.io/name": "olive", "app.kubernetes.io/component": "executor", "app.kubernetes.io/part-of": "olive", "homelab.ukyi.app/olive-target": "diagnosis" },
    ownerReferences: o.refs ?? [{ apiVersion: "apps/v1", kind: "ReplicaSet", name: W_RS, uid: W_RS_UID, controller: true }],
  },
  spec: { containers: [{ name: o.container ?? "executor" }, { name: "role" }] },
  status: { phase: "Running", conditions: [{ type: "Ready", status: "True" }] },
});
const wDeploy = (uid = W_DEPLOY_UID) => json({ apiVersion: "apps/v1", kind: "Deployment", metadata: { name: diag.deployment, namespace: diag.namespace, uid } });
const wRs = (parent = W_DEPLOY_UID) => json({ apiVersion: "apps/v1", kind: "ReplicaSet", metadata: { name: W_RS, namespace: diag.namespace, uid: W_RS_UID, ownerReferences: [{ apiVersion: "apps/v1", kind: "Deployment", name: diag.deployment, uid: parent, controller: true }] } });
const workerRules = (pods: Resp = list(workerPod()), deploy: Resp = wDeploy(), rs: Resp = wRs()) => [rule(wPodsArgv, pods), rule(wDeployArgv, deploy), rule(wRsArgv, rs)];

const RUN_LINE = { runId: RUN, kind: "worker", state: "checking", executorId: EXECUTOR, runGeneration: 3, accepted: true, finalizeSent: false, closableAt: 1764227400000, stopReceiptId: STOP, next: "abandon_result" };
const HOLD_LINE = { observation: 4, executorId: EXECUTOR, runId: RUN, kind: "worker", runGeneration: 2, why: "outside_ledger", heldAt: 1764227400000, next: "release_hold" };
const holdsDoc = (o: Record<string, unknown> = {}) => ({ schema: OLIVE_ADMIN_HOLDS_SCHEMA, slotFree: false, runs: [RUN_LINE], slotHolds: [HOLD_LINE], truncated: false, ...o });
const line = (x: unknown) => `${JSON.stringify(x)}\n`;
const FIXED = "감독 관리 진입점 출력이 정해진 꼴이 아니다";

describe("holds 답 파서(olive-holds/v1)", () => {
  test("정해진 칸만 옮기고 점유 관측의 next(늘 release_hold)는 싣지 않는다", () => {
    const { next: _drop, ...hold } = HOLD_LINE;
    expect(parseHolds(line(holdsDoc()))).toEqual({ slotFree: false, runs: [RUN_LINE as any], slotHolds: [hold as any], truncated: false });
    expect(parseHolds(line(holdsDoc({ runs: [], slotHolds: [], slotFree: true })))).toEqual({ slotFree: true, runs: [], slotHolds: [], truncated: false });
    expect(parseHolds(line(holdsDoc({ runs: [{ ...RUN_LINE, closableAt: null, stopReceiptId: null, state: "unknown_running", next: "close_unconfirmed" }] }))).runs[0]!.closableAt).toBeNull();
  });

  test("모르는 판·칸·꼴은 원문 없이 던진다", () => {
    const bad: [string, string][] = [
      ["판 v2", line(holdsDoc({ schema: "olive-holds/v2" }))],
      ["모르는 칸", line(holdsDoc({ extra: 1 }))],
      ["빠진 칸", line(Object.fromEntries(Object.entries(holdsDoc()).filter(([k]) => k !== "truncated")))],
      ["같은 키 둘", `{"schema":"olive-holds/v1","slotFree":true,"slotFree":false,"runs":[],"slotHolds":[],"truncated":false}\n`],
      ["실행 줄의 같은 키 둘", line(holdsDoc()).replace('"state":"checking"', '"state":"checking","state":"running"')],
      ["17자리 수", line(holdsDoc()).replace("1764227400000", "17642274000000000")],
      ["소수", line(holdsDoc()).replace('"runGeneration":3', '"runGeneration":3.5')],
      ["음수", line(holdsDoc()).replace('"runGeneration":3', '"runGeneration":-3')],
      ["앞의 0", line(holdsDoc()).replace('"runGeneration":3', '"runGeneration":03')],
      ["지수", line(holdsDoc()).replace('"runGeneration":3', '"runGeneration":3e0')],
      ["모르는 상태", line(holdsDoc({ runs: [{ ...RUN_LINE, state: "zombie" }] }))],
      ["모르는 다음 행동", line(holdsDoc({ runs: [{ ...RUN_LINE, next: "delete_all" }] }))],
      ["대문자 실행 ID", line(holdsDoc({ runs: [{ ...RUN_LINE, runId: RUN.toUpperCase() }] }))],
      ["틀린 실행기 ID", line(holdsDoc({ runs: [{ ...RUN_LINE, executorId: "-x" }] }))],
      ["closableAt 0", line(holdsDoc({ runs: [{ ...RUN_LINE, closableAt: 0 }] }))],
      ["관측의 next", line(holdsDoc({ slotHolds: [{ ...HOLD_LINE, next: "none" }] }))],
      ["관측의 why", line(holdsDoc({ slotHolds: [{ ...HOLD_LINE, why: CANARY.toUpperCase() }] }))],
      ["truncated 문자열", line(holdsDoc({ truncated: "no" }))],
      ["두 줄", line(holdsDoc()) + line(holdsDoc())],
      ["4096바이트 넘음", line(holdsDoc({ runs: Array.from({ length: 30 }, () => RUN_LINE) }))],
      ["배열", line([holdsDoc()])],
      ["빈 줄", "\n"],
    ];
    for (const [name, stdout] of bad) {
      let message = "";
      try {
        parseHolds(stdout);
      } catch (e) {
        message = (e as Error).message;
      }
      expect([name, message]).toEqual([name, FIXED]);
    }
  });
});

describe("release 답 파서(olive-release/v1)", () => {
  test("칸 다섯, slotFree는 true·false·null", () => {
    for (const slotFree of [true, false, null]) expect(parseRelease(line({ schema: OLIVE_ADMIN_RELEASE_SCHEMA, outcome: "closed", runId: RUN, released: true, slotFree }))).toEqual({ outcome: "closed", runId: RUN, released: true, slotFree });
  });
  test("모르는 판·outcome·꼴은 던진다", () => {
    const good = { schema: OLIVE_ADMIN_RELEASE_SCHEMA, outcome: "closed", runId: RUN, released: true, slotFree: true };
    for (const doc of [{ ...good, schema: "olive-release/v2" }, { ...good, outcome: "released" }, { ...good, slotFree: "yes" }, { ...good, released: null }, { ...good, extra: true }, { ...good, runId: CANARY }]) {
      expect(() => parseRelease(line(doc))).toThrow(FIXED);
    }
  });
});

describe("자리 풀기 쓰기 argv와 답 대조", () => {
  const calls: [OliveReleaseCall, string[]][] = [
    [{ command: "close-unconfirmed", runId: RUN, fromState: "unknown_running", podName: W_POD, podStartedAt: 1764227405000 }, ["close-unconfirmed", RUN, "unknown_running", W_POD, "1764227405000"]],
    [{ command: "abandon-result", runId: RUN, reason: "not_known", stopReceiptId: STOP }, ["abandon-result", RUN, "not_known", STOP]],
    [{ command: "close-store-reset", runId: RUN, fromState: "ready_result", podName: W_POD, podStartedAt: 1764227405000 }, ["close-store-reset", RUN, "ready_result", W_POD, "1764227405000"]],
    [{ command: "release-hold", executorId: EXECUTOR, runId: RUN, runGeneration: 2, observation: 0, podName: W_POD, podStartedAt: 1764227405000 }, ["release-hold", EXECUTOR, RUN, "2", "0", W_POD, "1764227405000"]],
  ];
  const answer: Record<string, [string, boolean, boolean | null]> = { "close-unconfirmed": ["closed", true, false], "abandon-result": ["abandoned", false, null], "close-store-reset": ["closed", true, true], "release-hold": ["hold_released", true, null] };

  test("명령 이름 뒤에 감독 통로의 칸 차례로 값이 들어가고, 맞는 답이면 released다", async () => {
    for (const [call, words] of calls) {
      const [outcome, released, slotFree] = answer[call.command]!;
      const { ctx, calls: seen } = testCtx("apply", [...supervisor(), rule([...ENTRY, ...words], { stdout: line({ schema: OLIVE_ADMIN_RELEASE_SCHEMA, outcome, runId: RUN, released, slotFree }) })]);
      const { value } = await applyWith(ctx, (w) => w.oliveAdmin.release(call));
      expect([call.command, value]).toEqual([call.command, { state: "released", pod: POD, answer: { outcome, runId: RUN, released, slotFree } }] as any);
      expect(seen().calls.filter((c) => c.argv.includes("exec")).map((c) => c.argv)).toEqual([[...ENTRY, ...words]]);
    }
  });

  test("요청과 맞지 않는 답(다른 실행·다른 outcome·released·포기 뒤 slotFree true)은 적혔는지 모름이다", async () => {
    const [close] = calls[0]!;
    const [abandon, abandonWords] = calls[1]!;
    const rows: [OliveReleaseCall, string[], Record<string, unknown>][] = [
      [close, calls[0]![1], { outcome: "closed", runId: "00000000-0000-4000-8000-000000000000", released: true, slotFree: true }],
      [close, calls[0]![1], { outcome: "hold_released", runId: RUN, released: true, slotFree: true }],
      [close, calls[0]![1], { outcome: "closed", runId: RUN, released: false, slotFree: true }],
      [abandon, abandonWords, { outcome: "abandoned", runId: RUN, released: false, slotFree: true }],
    ];
    for (const [call, words, doc] of rows) {
      const { ctx } = testCtx("apply", [...supervisor(), rule([...ENTRY, ...words], { stdout: line({ schema: OLIVE_ADMIN_RELEASE_SCHEMA, ...doc }) })]);
      const { value } = await applyWith(ctx, (w) => w.oliveAdmin.release(call));
      expect(value).toEqual({ state: "unknown", pod: POD });
    }
  });

  test("꼴이 틀린 값은 어떤 호출도 하기 전에 던진다(값을 되찍지 않는다)", async () => {
    const base = calls[0]![0] as any;
    const hold = calls[3]![0] as any;
    const bad: unknown[] = [
      { ...base, runId: RUN.toUpperCase() },
      { ...base, runId: `${RUN} --all` },
      { ...base, fromState: "zombie" },
      { ...base, podName: "--all" },
      { ...base, podName: "a b" },
      { ...base, podStartedAt: 0 },
      { ...base, podStartedAt: 1.5 },
      { ...base, podStartedAt: "1764227405000" },
      { ...base, command: "close-everything" },
      { ...(calls[1]![0] as any), reason: "because" },
      { ...(calls[1]![0] as any), stopReceiptId: CANARY },
      { ...hold, executorId: "-x" },
      { ...hold, observation: -1 },
      { ...hold, runGeneration: Number.MAX_SAFE_INTEGER + 1 },
      { ...hold, executorId: "e".repeat(200), podName: "p".repeat(253) + "x".repeat(600) },
      null,
      "close-unconfirmed",
    ];
    for (const call of bad) {
      const { ctx, calls: seen } = testCtx("apply", [...supervisor()]);
      await expect(applyWith(ctx, (w) => w.oliveAdmin.release(call as any))).rejects.toThrow("자리 풀기 값이 정해진 꼴이 아니다");
      expect(seen().calls).toEqual([]);
    }
  });

  test("진입점 stderr의 사유: 장부 거절 이름과 write_unknown 까닭은 닫힌 목록일 때만 읽는다", async () => {
    const [call, words] = calls[0]!;
    const exit = (code: number, text: string): Resp => ({ code, stderr: `${text}\ncommand terminated with exit code ${code}\n` });
    const rows: [Resp, unknown][] = [
      [exit(1, "olive admin: 감독이 요청을 거절했다(ledger_refused:start_may_launch)"), { kind: "refused", word: "ledger_refused", detail: "start_may_launch" }],
      [exit(1, "olive admin: 감독이 요청을 거절했다(state_changed)"), { kind: "refused", word: "state_changed" }],
      [exit(1, "olive admin: 감독이 요청을 거절했다(pod_started_later)"), { kind: "refused", word: "pod_started_later" }],
      [exit(1, "olive admin: 자리 풀기 모름: 장부에 적혔는지 모른다(write_unknown:mismatched)"), { kind: "unknown", word: "write_unknown", detail: "mismatched" }],
      [exit(1, "olive admin: 자리 풀기 모름: 장부에 적혔는지 모른다(write_unknown)"), { kind: "unknown", word: "write_unknown" }],
      [exit(1, "olive admin: 자리 풀기 모름: 감독의 답을 받지 못했다(write_failed)"), { kind: "no-reply", word: "write_failed" }],
      [exit(3, "olive admin: 자리 풀기 모름: 감독이 복원을 마치지 않았다(restore_not_done)"), { kind: "unknown", word: "restore_not_done" }],
      [exit(1, "olive admin: 감독이 요청을 거절했다(ledger_refused:made_up)"), null],
      [exit(1, "olive admin: 감독이 요청을 거절했다(state_changed:start_may_launch)"), null],
      [exit(1, "olive admin: 자리 풀기 모름: 장부에 적혔는지 모른다(write_unknown:other)"), null],
      [exit(1, "olive admin: 자리 풀기 모름: 감독이 상태를 읽지 못했다(ledger_unreadable:closed)"), null],
      [exit(1, "olive admin: 자리 풀기 모름: 감독이 복원을 마치지 않았다(restore_not_done)"), null],
    ];
    for (const [resp, reason] of rows) {
      const { ctx } = testCtx("apply", [...supervisor(), rule([...ENTRY, ...words], resp)]);
      const { value } = await applyWith(ctx, (w) => w.oliveAdmin.release(call));
      expect(value).toEqual({ state: "exit", pod: POD, code: (resp.code as number), reason } as any);
    }
  });

  test("장부 거절 이름 목록이 olive 통로의 LEDGER_REFUSALS와 같은 수·이름이다(자리 풀기가 쓰는 이름 포함)", () => {
    for (const name of ["start_may_launch", "pod_started_too_early", "not_checking", "stop_unconfirmed", "slot_not_held", "report_pending", "outcome_unknown", "failed_at_unknown", "stop_confirmed", "run_ended", "unknown_run"]) expect(OLIVE_LEDGER_REFUSALS).toContain(name);
    expect(new Set(OLIVE_LEDGER_REFUSALS).size).toBe(48);
  });
});

describe("holds 읽기", () => {
  const HOLDS = [...ENTRY, "holds"];
  test("감독 파드에 holds 한 번, 꼴이 다르거나 시간 초과면 모름", async () => {
    const ok = testCtx("apply", [...supervisor(), rule(HOLDS, { stdout: line(holdsDoc()) })]);
    const { value } = await applyWith(ok.ctx, (w) => w.oliveAdmin.holds());
    expect((value as any).state).toBe("reported");
    expect(ok.calls().calls.filter((c) => c.argv.includes("exec")).map((c) => c.argv)).toEqual([HOLDS]);
    const bad = testCtx("apply", [...supervisor(), rule(HOLDS, { stdout: line(holdsDoc({ schema: "olive-holds/v2" })) })]);
    expect((await applyWith(bad.ctx, (w) => w.oliveAdmin.holds())).value).toEqual({ state: "unknown", pod: POD });
    const slow = testCtx("apply", [...supervisor(), rule(HOLDS, { sleepMs: 3_500 })]);
    expect((await applyWith(slow.ctx, (w) => w.oliveAdmin.holds())).value).toEqual({ state: "unknown", pod: POD });
  }, 20_000);

  test("plan의 target(holds)는 exec하지 않고 argv만 낸다", () => {
    const { ctx, calls } = testCtx("plan", supervisor());
    expect(ctx.oliveAdmin.target("holds")).toEqual({ state: "ready", pod: POD, argv: HOLDS });
    expect(calls().calls.filter((c) => c.argv.includes("exec"))).toEqual([]);
  });
});

describe("작업자 실행기 파드 읽기(workerPod)", () => {
  test("소유 사슬을 UID로 대조하고 creationTimestamp를 초 단위로 내린다. get만 하고 exec하지 않는다", () => {
    for (const [created, ms] of [["2026-11-27T07:10:05Z", Date.parse("2026-11-27T07:10:05Z")], ["2026-11-27T07:10:05.999Z", Date.parse("2026-11-27T07:10:05Z")]] as const) {
      const { ctx, calls } = testCtx("plan", workerRules(list(workerPod({ created }))));
      expect(ctx.oliveAdmin.workerPod("diagnosis")).toEqual({ state: "ready", name: W_POD, uid: "12121212-1212-4212-8212-121212121212", createdAt: ms });
      expect(calls().calls.map((c) => c.argv)).toEqual([wPodsArgv, wDeployArgv, wRsArgv]);
    }
  });

  test("차트: 셀렉터 라벨과 제어 컨테이너 이름이 실행기 템플릿과 같다", () => {
    const template = readFileSync(join(REPO, "platform/olive/templates/executor-deployments.yaml"), "utf8");
    expect(template).toContain(`        - name: ${OLIVE_WORKER_CONTAINER}\n          image:`);
    const helpers = readFileSync(join(REPO, "platform/olive/templates/_helpers.tpl"), "utf8");
    expect(helpers).toContain('{{- define "olive.selectorLabels" -}}\napp.kubernetes.io/name: olive\napp.kubernetes.io/component: {{ .kind }}\n{{- end }}');
    expect(helpers).toContain("homelab.ukyi.app/olive-target: {{ .id }}");
  });

  test("대조 실패·없음·꼴이 다른 항목", () => {
    const rsRefWith = (o: Record<string, unknown>) => [{ apiVersion: "apps/v1", kind: "ReplicaSet", name: W_RS, uid: W_RS_UID, controller: true, ...o }];
    const rows: [ReturnType<typeof workerRules>, unknown][] = [
      [workerRules(list()), { state: "absent", pods: 0 }],
      [workerRules(list(workerPod({ refs: rsRefWith({ uid: "99999999-9999-4999-8999-999999999999" }) }))), { state: "not-owned", pods: 1 }],
      [workerRules(list(workerPod({ refs: rsRefWith({ controller: false }) }))), { state: "not-owned", pods: 1 }],
      [workerRules(list(workerPod()), { code: 1, stderr: `Error from server (NotFound): deployments.apps "${diag.deployment}" not found\n` }), { state: "not-owned", pods: 1 }],
      [workerRules(list(workerPod()), wDeploy(), wRs("99999999-9999-4999-8999-999999999999")), { state: "not-owned", pods: 1 }],
    ];
    for (const [rules, want] of rows) {
      const { ctx } = testCtx("plan", rules);
      expect(ctx.oliveAdmin.workerPod("diagnosis")).toEqual(want as any);
    }
    for (const p of [workerPod({ created: "yesterday" }), workerPod({ created: null }), workerPod({ container: "role-only" }), workerPod({ ns: "olive-reader" }), workerPod({ labels: { "app.kubernetes.io/name": "olive", "app.kubernetes.io/component": "supervisor", "homelab.ukyi.app/olive-target": "diagnosis" } })]) {
      const { ctx } = testCtx("plan", workerRules(list(p)));
      expect(() => ctx.oliveAdmin.workerPod("diagnosis")).toThrow("작업자 파드 모양이 아닌 항목");
    }
  });

  test("대상 목록의 kind executor 줄 id만 받는다. 감독·세션·모르는 이름은 어떤 호출도 하기 전에 던진다", () => {
    for (const bad of ["supervisor", "session", "writer", "bogus", "diagnosis --all", "", null, 1, { id: "diagnosis" }]) {
      const { ctx, calls } = testCtx("plan", workerRules());
      expect(() => ctx.oliveAdmin.workerPod(bad as any)).toThrow("작업자 실행기 대상이 아니다");
      expect(calls().calls).toEqual([]);
    }
  });
});
