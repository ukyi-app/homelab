// homelab olive release(관리자 자리 풀기). 실제 클러스터·감독에 닿지 않는다: kubectl은 PATH 스텁이고 감독 진입점의 답은 가짜다.
import { describe, expect, test } from "bun:test";
import { expectNoSecrets, expectPlanReadOnly, kubectlRule, rule, runCli, type Call, type Resp, type Rule } from "../harness";

const POD = "supervisor-7c9d8f6b5-x2k4q";
const RS = "supervisor-7c9d8f6b5";
const DEPLOY_UID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const RS_UID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const POD_UID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const SELECTOR = "app.kubernetes.io/name=olive,app.kubernetes.io/component=supervisor,homelab.ukyi.app/olive-target=supervisor";
const ENTRY = ["kubectl", "-n", "olive-control", "exec", POD, "-c", "supervisor", "--request-timeout=20s", "--", "bun", "src/main/admin.ts"];
const HOLDS_EXEC = [...ENTRY, "holds"];

// 작업자 실행기(대상 목록의 diagnosis 줄).
const W_NS = "olive-diagnosis";
const W_POD = "executor-5d8f7c9b4-q7w2e";
const W_RS = "executor-5d8f7c9b4";
const W_DEPLOY_UID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
const W_RS_UID = "ffffffff-ffff-4fff-8fff-ffffffffffff";
const W_POD_UID = "12121212-1212-4212-8212-121212121212";
const W_SELECTOR = "app.kubernetes.io/name=olive,app.kubernetes.io/component=executor,homelab.ukyi.app/olive-target=diagnosis";
const EXECUTOR = "executor/diagnosis/diagnosis/store-1a2b3c";

const RUN = "3f2a9c41-5b6d-4e7f-8a9b-0c1d2e3f4a5b";
const STOP = "7a7a7a7a-0000-4000-8000-000000000007";
const CLOSABLE = Date.parse("2026-11-27T07:10:00Z");
const CREATED = "2026-11-27T07:10:05Z";
const CREATED_MS = Date.parse(CREATED);
const CANARY = "canary-raw-output-7f3a";

const json = (x: unknown): Resp => ({ stdout: JSON.stringify(x) });
const list = (...items: unknown[]): Resp => json({ kind: "List", metadata: {}, items });
const supPod = { apiVersion: "v1", kind: "Pod", metadata: { name: POD, namespace: "olive-control", uid: POD_UID, labels: { "app.kubernetes.io/name": "olive", "app.kubernetes.io/component": "supervisor", "homelab.ukyi.app/olive-target": "supervisor" }, ownerReferences: [{ apiVersion: "apps/v1", kind: "ReplicaSet", name: RS, uid: RS_UID, controller: true }] }, spec: { containers: [{ name: "supervisor" }] }, status: { phase: "Running", conditions: [{ type: "Ready", status: "True" }] } };

type WPod = { created?: string; phase?: string; deleting?: boolean; rsUid?: string };
const workerPod = (o: WPod = {}) => ({
  apiVersion: "v1",
  kind: "Pod",
  metadata: {
    name: W_POD,
    namespace: W_NS,
    uid: W_POD_UID,
    creationTimestamp: o.created ?? CREATED,
    labels: { "app.kubernetes.io/name": "olive", "app.kubernetes.io/component": "executor", "app.kubernetes.io/part-of": "olive", "homelab.ukyi.app/olive-target": "diagnosis" },
    ownerReferences: [{ apiVersion: "apps/v1", kind: "ReplicaSet", name: W_RS, uid: o.rsUid ?? W_RS_UID, controller: true }],
    ...(o.deleting ? { deletionTimestamp: "2026-11-27T07:11:00Z" } : {}),
  },
  spec: { containers: [{ name: "executor" }, { name: "role" }] },
  status: { phase: o.phase ?? "Running", conditions: [{ type: "Ready", status: "True" }] },
});

function supervisor(): Rule[] {
  return [
    kubectlRule(["-n", "olive-control", "get", "pods", "-l", SELECTOR, "-o", "json"], list(supPod)),
    kubectlRule(["-n", "olive-control", "get", "deployments.apps", "supervisor", "-o", "json"], json({ apiVersion: "apps/v1", kind: "Deployment", metadata: { name: "supervisor", namespace: "olive-control", uid: DEPLOY_UID } })),
    kubectlRule(["-n", "olive-control", "get", "replicasets.apps", RS, "-o", "json"], json({ apiVersion: "apps/v1", kind: "ReplicaSet", metadata: { name: RS, namespace: "olive-control", uid: RS_UID, ownerReferences: [{ apiVersion: "apps/v1", kind: "Deployment", name: "supervisor", uid: DEPLOY_UID, controller: true }] } })),
  ];
}

function worker(pods: Resp = list(workerPod())): Rule[] {
  return [
    kubectlRule(["-n", W_NS, "get", "pods", "-l", W_SELECTOR, "-o", "json"], pods),
    kubectlRule(["-n", W_NS, "get", "deployments.apps", "executor", "-o", "json"], json({ apiVersion: "apps/v1", kind: "Deployment", metadata: { name: "executor", namespace: W_NS, uid: W_DEPLOY_UID } })),
    kubectlRule(["-n", W_NS, "get", "replicasets.apps", W_RS, "-o", "json"], json({ apiVersion: "apps/v1", kind: "ReplicaSet", metadata: { name: W_RS, namespace: W_NS, uid: W_RS_UID, ownerReferences: [{ apiVersion: "apps/v1", kind: "Deployment", name: "executor", uid: W_DEPLOY_UID, controller: true }] } })),
  ];
}

type Run = { runId?: string; kind?: string; state: string; executorId?: string; runGeneration?: number; accepted?: boolean; finalizeSent?: boolean; closableAt?: number | null; stopReceiptId?: string | null; next: string };
const run = (o: Run) => ({ runId: o.runId ?? RUN, kind: o.kind ?? "worker", state: o.state, executorId: o.executorId ?? EXECUTOR, runGeneration: o.runGeneration ?? 1, accepted: o.accepted ?? true, finalizeSent: o.finalizeSent ?? false, closableAt: o.closableAt === undefined ? CLOSABLE : o.closableAt, stopReceiptId: o.stopReceiptId ?? null, next: o.next });
const hold = (o: { observation?: number; runId?: string; heldAt?: number } = {}) => ({ observation: o.observation ?? 4, executorId: EXECUTOR, runId: o.runId ?? RUN, kind: "worker", runGeneration: 2, why: "outside_ledger", heldAt: o.heldAt ?? CLOSABLE, next: "release_hold" });
const holdsLine = (runs: unknown[], slotHolds: unknown[] = [], slotFree = false, truncated = false): Resp => ({ stdout: `${JSON.stringify({ schema: "olive-holds/v1", slotFree, runs, slotHolds, truncated })}\n` });
const releaseLine = (outcome: string, released: boolean, slotFree: boolean | null, runId = RUN): Resp => ({ stdout: `${JSON.stringify({ schema: "olive-release/v1", outcome, runId, released, slotFree })}\n` });
const entryExit = (code: number, line: string): Resp => ({ code, stderr: `${line}\ncommand terminated with exit code ${code}\n` });
const execCalls = (r: { calls: Call[] }) => r.calls.filter((c) => c.argv.includes("exec")).map((c) => c.argv);
const writeExec = (r: { calls: Call[] }) => execCalls(r).filter((a) => a.join(" ") !== HOLDS_EXEC.join(" "));
const workerReads = (r: { calls: Call[] }) => r.calls.filter((c) => c.argv.includes(W_NS));

const CLOSE_EXEC = (from = "unknown_running") => [...ENTRY, "close-unconfirmed", RUN, from, W_POD, String(CREATED_MS)];
const STORE_EXEC = (from: string) => [...ENTRY, "close-store-reset", RUN, from, W_POD, String(CREATED_MS)];
const ABANDON_EXEC = (reason: string) => [...ENTRY, "abandon-result", RUN, reason, STOP];
const HOLD_EXEC = [...ENTRY, "release-hold", EXECUTOR, RUN, "2", "4", W_POD, String(CREATED_MS)];

const cli = (argv: string[], rules: Rule[]) => runCli(["olive", "release", ...argv, "--json"], rules);

describe("plan: --apply 없이는 쓰지 않는다", () => {
  test("목록 plan은 대상 파드와 holds argv만 보이고 exec하지 않는다", async () => {
    const r = await cli([], [...supervisor(), rule(HOLDS_EXEC, holdsLine([]))]);
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(execCalls(r)).toEqual([]);
    expect(r.json.body).toContain(`대상 파드 ${POD}`);
    expect(r.json.body).toContain(`실행: ${HOLDS_EXEC.join(" ")}`);
    expect(r.json.next).toBe("homelab olive release --apply");
  });

  test("실행 ID와 확인 플래그가 있어도 plan은 exec하지 않고 작업자 파드도 읽지 않는다", async () => {
    for (const flags of [["--pod-replaced"], ["--abandon-result", "no_answer"], ["--store-reset"], ["--pod-replaced", "--observation", "4"]]) {
      const r = await cli([RUN, ...flags], [...supervisor(), ...worker(), rule(HOLDS_EXEC, holdsLine([])), rule(CLOSE_EXEC(), releaseLine("closed", true, true))]);
      expect([flags.join(" "), r.code]).toEqual([flags.join(" "), 0]);
      expectPlanReadOnly(r);
      expect(execCalls(r)).toEqual([]);
      expect(workerReads(r)).toEqual([]);
      expect(r.json.next).toBe(`homelab olive release ${RUN} ${flags.join(" ")} --apply`);
    }
  });
});

describe("사용법(64): 아무것도 부르지 않는다", () => {
  const rows: [string[], string][] = [
    [["--pod-replaced", "--store-reset", RUN], "하나만"],
    [["--pod-replaced"], "실행 ID와 함께"],
    [[RUN, "--observation", "4"], "--pod-replaced와 함께"],
    [["3F2A9C41-5B6D-4E7F-8A9B-0C1D2E3F4A5B"], "형식"],
    [[RUN, "--abandon-result", "because"], "no_answer"],
    [[RUN, "--pod-replaced", "--observation", "01"], "형식"],
  ];
  test("표의 각 줄", async () => {
    for (const [argv, text] of rows) {
      const r = await cli([...argv, "--apply"], [...supervisor(), rule(HOLDS_EXEC, holdsLine([]))]);
      expect([argv.join(" "), r.code]).toEqual([argv.join(" "), 64]);
      expect(JSON.stringify(r.json)).toContain(text);
      expect(r.calls).toEqual([]);
    }
  });
});

describe("--apply 목록: 읽기만 한다", () => {
  test("다음 행동마다 쉬운 말 안내와 붙여 쓸 명령, 경고를 보이고 exec는 holds 한 번이다", async () => {
    const R = (n: number) => `3f2a9c41-5b6d-4e7f-8a9b-0c1d2e3f4a5${n}`;
    const runs = [
      run({ runId: R(1), state: "unknown_running", next: "close_unconfirmed", accepted: false }),
      run({ runId: R(2), state: "checking", next: "abandon_result", stopReceiptId: STOP }),
      run({ runId: R(3), state: "ready_result", next: "wait_cleanup", finalizeSent: true }),
      run({ runId: R(4), state: "failed_stopped", next: "close_store_reset" }),
      run({ runId: R(6), state: "failed_stopped", next: "none" }),
      run({ runId: R(7), state: "stopping", next: "close_unconfirmed", closableAt: null }),
    ];
    const r = await cli(["--apply"], [...supervisor(), rule(HOLDS_EXEC, holdsLine(runs, [hold({ runId: R(8) })]))]);
    expect(r.code).toBe(0);
    expect(execCalls(r)).toEqual([HOLDS_EXEC]);
    expect(workerReads(r)).toEqual([]);
    const body: string = r.json.body;
    expect(body.split("\n")[0]).toBe("자리 풀기: 자리를 쥔 실행 6, 점유 관측 1. 작업자 자리 사용 가능: 아니오");
    expect(body).toContain(`실행 ${R(1)}(diagnosis 실행기): 끝났는지 모름(unknown_running)`);
    expect(body).toContain("절차 1) 실행기 olive-diagnosis/executor를 replicas 0으로 줄이고");
    expect(body).toContain("절차 2) 새 파드는 2026-11-27 16:10:00 KST 뒤에 떠야 한다");
    expect(body).toContain(`절차 3) homelab olive release ${R(1)} --apply --pod-replaced`);
    expect(body).toContain("주의: 실행기가 이 실행을 받았다고 알린 적이 없다");
    expect(body).toContain(`명령: homelab olive release ${R(2)} --apply --abandon-result <no_answer|not_known|unstorable>`);
    expect(body).toContain("경고: 이 실행의 결과를 버린다");
    expect(body).toContain("result_check_alert(result_wait_overdue)");
    expect(body).toContain(`명령: homelab olive release ${R(3)} --apply --store-reset`);
    expect(body).toContain("다음: 기다린다. 실행기가 확정과 정리 영수증을 내면 저절로 풀린다");
    expect(body).toContain("다음: 기다려도 풀리지 않는다(확정 결과를 장부 사실로 정할 수 없다)");
    expect(body).toContain("경고: 저장소를 비우면 그 실행기의 다른 기록도 모두 잃는다");
    expect(body).toContain("실패 시각이 없는 옛 줄이라 이 명령으로 풀 수 없다");
    expect(body).toContain("관리자 닫기로 닫히지 않는다(기다려도 풀리지 않는다, 남은 길은 장부 초기화)");
    expect(body).toContain(`절차 3) homelab olive release ${R(8)} --apply --pod-replaced --observation 4`);
    expect(body).toContain("실행기 쪽: 감독 장부의 자리가 풀려도");
    expect(body).not.toContain(EXECUTOR);
  });

  test("자리가 없으면 한 줄, --verbose는 실행기 ID·시각을 더한다", async () => {
    const empty = await cli(["--apply"], [...supervisor(), rule(HOLDS_EXEC, holdsLine([], [], true))]);
    expect([empty.code, empty.json.body]).toEqual([0, "자리 풀기: 자리를 쥔 실행 없음. 작업자 자리 사용 가능: 예"]);
    const v = await cli(["--apply", "--verbose"], [...supervisor(), rule(HOLDS_EXEC, holdsLine([run({ state: "unknown_running", next: "close_unconfirmed" })], [], false, true))]);
    expect(v.json.body).toContain(`실행기 ${EXECUTOR}, 세대 1`);
    expect(v.json.body).toContain(`(${CLOSABLE})`);
    expect(v.json.body).toContain("목록이 잘렸다");
  });

  test("모르는 판·꼴이 다른 답은 해석하지 않고 1, 복원 전은 3, 진입점 64는 1(판 어긋남)", async () => {
    const v2 = { stdout: `${JSON.stringify({ schema: "olive-holds/v2", slotFree: true, runs: [], slotHolds: [], truncated: false })}\n` };
    const rows: [Resp, number, string][] = [
      [v2, 1, "판이 다를 수 있다"],
      [{ stdout: `{"schema":"olive-holds/v1","slotFree":true,"slotFree":false,"runs":[],"slotHolds":[],"truncated":false}\n` }, 1, "판이 다를 수 있다"],
      [entryExit(3, "olive admin: 자리 목록 모름: 감독이 복원을 마치지 않았다(restore_not_done)"), 3, "감독이 복원을 마치지 않았다(restore_not_done)"],
      [entryExit(64, "olive admin: 사용법: bun src/main/admin.ts status"), 1, "종료 코드 64"],
      [entryExit(1, "olive admin: 자리 목록 모름: 감독이 상태를 읽지 못했다(ledger_unreadable)"), 1, "(ledger_unreadable)"],
      [entryExit(1, `olive admin: ${CANARY}`), 1, "(종료 코드 1)"],
    ];
    for (const [resp, code, text] of rows) {
      const r = await cli(["--apply"], [...supervisor(), rule(HOLDS_EXEC, resp)]);
      expect([text, r.code]).toEqual([text, code]);
      expect(r.json.body).toContain(text);
      expect(r.stdout + r.stderr).not.toContain(CANARY);
    }
  });
});

describe("--apply 쓰기: 앞 상태를 다시 읽고 맞는 쓰기 하나", () => {
  const closeRules = (resp: Resp, runs = [run({ state: "unknown_running", next: "close_unconfirmed" })], pods?: Resp) => [...supervisor(), ...worker(pods), rule(HOLDS_EXEC, holdsLine(runs)), rule(CLOSE_EXEC(runs[0]!.state), resp)];

  test("--pod-replaced: 소유 사슬로 확인한 새 파드의 이름과 creationTimestamp(초 단위 내림)를 fromState와 함께 넘긴다", async () => {
    const r = await cli([RUN, "--apply", "--pod-replaced"], closeRules(releaseLine("closed", true, false)));
    expect(r.code).toBe(0);
    expect(execCalls(r)).toEqual([HOLDS_EXEC, CLOSE_EXEC()]);
    const body: string = r.json.body;
    expect(body.split("\n")).toEqual([
      `자리 풀기: 실행 ${RUN}를 실패로 닫았다`,
      "그 실행의 자리를 놓았다: 예",
      "작업자 자리 사용 가능: 아니오",
      "실행기 쪽: 감독 장부의 자리가 풀려도 실행기 저장소에 그 기록이 남아 있으면 실행기가 새 시작을 거절할 수 있다(이 명령은 실행기 저장소를 보지 않는다)",
    ]);
    expect(r.json.next).toBe("homelab olive release --apply로 남은 자리를 본다");
    expectNoSecrets(r);
    // stopping도 같은 길이다(fromState는 읽은 값 그대로).
    const stopping = [run({ state: "stopping", next: "close_unconfirmed" })];
    const s = await cli([RUN, "--apply", "--pod-replaced"], closeRules(releaseLine("closed", true, true), stopping));
    expect([s.code, execCalls(s).at(-1)]).toEqual([0, CLOSE_EXEC("stopping")]);
    expect(s.json.next).toBeNull();
  });

  test("밀리초가 붙은 creationTimestamp는 초 단위로 내린다", async () => {
    const pods = list(workerPod({ created: "2026-11-27T07:10:05.987Z" }));
    const r = await cli([RUN, "--apply", "--pod-replaced"], closeRules(releaseLine("closed", true, true), undefined, pods));
    expect([r.code, execCalls(r).at(-1)]).toEqual([0, CLOSE_EXEC()]);
  });

  test("접수 영수증이 없는 실행은 D-94 경고를 함께 보인다", async () => {
    const r = await cli([RUN, "--apply", "--pod-replaced"], closeRules(releaseLine("closed", true, true), [run({ state: "unknown_running", next: "close_unconfirmed", accepted: false })]));
    expect(r.code).toBe(0);
    expect(r.json.body).toContain("주의: 실행기가 이 실행을 받았다고 알린 적이 없다");
  });

  test("새 파드가 한도 전에 떴거나, 준비 전·내려가는 중·여럿·없음·대조 실패면 쓰지 않는다", async () => {
    const rows: [Resp, number, string][] = [
      [list(workerPod({ created: "2026-11-27T07:09:59Z" })), 1, "새 파드가 닫을 수 있는 시각(2026-11-27 16:10:00 KST) 전에 떴다(2026-11-27 16:09:59 KST)"],
      [list(workerPod({ phase: "Pending" })), 3, "새 파드가 아직 준비되지 않았다(olive-diagnosis/executor)"],
      [list(workerPod({ deleting: true })), 3, "옛 파드가 아직 내려가는 중이다"],
      [list(workerPod(), { ...workerPod(), metadata: { ...workerPod().metadata, name: "executor-5d8f7c9b4-zzzzz" } }), 3, "작업자 파드가 여럿이다"],
      [list(), 1, "작업자 파드가 없다(olive-diagnosis/executor)"],
      [list(workerPod({ rsUid: "99999999-9999-4999-8999-999999999999" })), 1, "그 실행기 Deployment의 것으로 확인되지 않았다"],
    ];
    for (const [pods, code, text] of rows) {
      const r = await cli([RUN, "--apply", "--pod-replaced"], closeRules(releaseLine("closed", true, true), undefined, pods));
      expect([text, r.code]).toEqual([text, code]);
      expect(r.json.body).toContain(text);
      expect(writeExec(r)).toEqual([]);
    }
    const early = await cli([RUN, "--apply", "--pod-replaced"], closeRules(releaseLine("closed", true, true), undefined, list(workerPod({ created: "2026-11-27T07:09:59Z" }))));
    expect(early.json.next).toBe("2026-11-27 16:10:00 KST 뒤에 작업자 파드를 다시 바꾼 뒤 같은 명령을 다시 실행한다");
  });

  test("닫을 수 있는 시각이 없으면(시작 이력) 파드를 읽지 않고 쓰지 않는다", async () => {
    const r = await cli([RUN, "--apply", "--pod-replaced"], closeRules(releaseLine("closed", true, true), [run({ state: "unknown_running", next: "close_unconfirmed", closableAt: null })]));
    expect(r.code).toBe(1);
    expect(r.json.body).toContain("관리자 닫기로 닫히지 않는다");
    expect(writeExec(r)).toEqual([]);
    expect(workerReads(r)).toEqual([]);
  });

  test("--abandon-result: 종료 영수증 ID는 holds 값 그대로, 사유는 사람이 고른 값, 파드는 읽지 않는다", async () => {
    for (const reason of ["no_answer", "not_known", "unstorable"]) {
      const runs = [run({ state: "checking", next: "abandon_result", stopReceiptId: STOP })];
      const r = await cli([RUN, "--apply", "--abandon-result", reason], [...supervisor(), ...worker(), rule(HOLDS_EXEC, holdsLine(runs)), rule(ABANDON_EXEC(reason), releaseLine("abandoned", false, false))]);
      expect([reason, r.code]).toEqual([reason, 0]);
      expect(execCalls(r)).toEqual([HOLDS_EXEC, ABANDON_EXEC(reason)]);
      expect(workerReads(r)).toEqual([]);
      const body: string = r.json.body;
      expect(body).toContain(`자리 풀기: 실행 ${RUN}의 결과를 버렸다(실패로 옮김)`);
      expect(body).toContain("그 실행의 자리를 놓았다: 아니오(실패 확정과 실행기의 정리 영수증 뒤에 놓는다)");
      expect(body).toContain(`(${reason})`);
      expect(body).toContain("경고: 이 실행의 결과를 버린다");
    }
  });

  test("--store-reset: checking·ready_result·확정 가능한 failed_stopped에서 새 파드 근거와 함께 저장소 비움 닫기", async () => {
    for (const [state, next] of [["ready_result", "wait_cleanup"], ["checking", "abandon_result"], ["failed_stopped", "close_store_reset"], ["failed_stopped", "wait_cleanup"]] as const) {
      const runs = [run({ state, next, stopReceiptId: state === "checking" ? STOP : null })];
      const r = await cli([RUN, "--apply", "--store-reset"], [...supervisor(), ...worker(), rule(HOLDS_EXEC, holdsLine(runs)), rule(STORE_EXEC(state), releaseLine("closed", true, true))]);
      expect([state, next, r.code]).toEqual([state, next, 0]);
      expect(execCalls(r)).toEqual([HOLDS_EXEC, STORE_EXEC(state)]);
      expect(r.json.body).toContain("경고: 그 실행기 저장소를 비우고 작업자 파드를 새로 띄운 뒤에만 쓴다");
    }
  });

  test("점유 관측 풀기: --observation의 관측을 holds에서 찾아 그 세대·번호 그대로, 관측 시각 뒤에 뜬 파드로", async () => {
    const r = await cli([RUN, "--apply", "--pod-replaced", "--observation", "4"], [...supervisor(), ...worker(), rule(HOLDS_EXEC, holdsLine([], [hold()])), rule(HOLD_EXEC, releaseLine("hold_released", true, true))]);
    expect(r.code).toBe(0);
    expect(execCalls(r)).toEqual([HOLDS_EXEC, HOLD_EXEC]);
    expect(r.json.body).toContain(`자리 풀기: 점유 관측 4(실행 ${RUN})을 풀었다`);
    const late = await cli([RUN, "--apply", "--pod-replaced", "--observation", "4"], [...supervisor(), ...worker(), rule(HOLDS_EXEC, holdsLine([], [hold({ heldAt: CREATED_MS + 1000 })])), rule(HOLD_EXEC, releaseLine("hold_released", true, true))]);
    expect(late.code).toBe(1);
    expect(late.json.body).toContain("새 파드가 관측을 적은 시각(2026-11-27 16:10:06 KST) 전에 떴다");
    expect(writeExec(late)).toEqual([]);
  });
});

describe("확인 플래그와 앞 상태 대조: 맞지 않으면 64, 쓰기 없음", () => {
  // [holds의 줄, 준 플래그, 안내에 들어갈 글]
  const rows: [ReturnType<typeof run> | null, ReturnType<typeof hold>[], string[], string][] = [
    [run({ state: "checking", next: "abandon_result", stopReceiptId: STOP }), [], ["--pod-replaced"], "--abandon-result <no_answer|not_known|unstorable>"],
    [run({ state: "unknown_running", next: "close_unconfirmed" }), [], ["--abandon-result", "no_answer"], "--pod-replaced"],
    [run({ state: "unknown_running", next: "close_unconfirmed" }), [], ["--store-reset"], "--pod-replaced"],
    [run({ state: "cleanup_pending", next: "wait_cleanup" }), [], ["--store-reset"], "다음: 기다린다"],
    [run({ state: "failed_stopped", next: "none" }), [], ["--store-reset"], "실패 시각이 없는 옛 줄"],
    [run({ state: "running", next: "none" }), [], ["--pod-replaced"], "진행 중"],
    [run({ state: "unknown_running", next: "close_unconfirmed", kind: "session" }), [], ["--pod-replaced"], "세션 실행"],
    [run({ state: "checking", next: "abandon_result", stopReceiptId: STOP }), [], [], "확인 플래그가 없다"],
    [null, [hold()], ["--pod-replaced"], "--observation 4"],
    [null, [hold()], ["--pod-replaced", "--observation", "5"], "점유 관측 5이 없다"],
  ];
  test("표의 각 줄", async () => {
    for (const [line, holds, flags, text] of rows) {
      const r = await cli([RUN, "--apply", ...flags], [...supervisor(), ...worker(), rule(HOLDS_EXEC, holdsLine(line ? [line] : [], holds))]);
      expect([flags.join(" "), text, r.code]).toEqual([flags.join(" "), text, 64]);
      expect(r.json.body).toContain(text);
      expect(execCalls(r)).toEqual([HOLDS_EXEC]);
      expect(workerReads(r)).toEqual([]);
      expect(r.json.next).toBe("homelab olive release --apply");
    }
  });

  test("목록에 없는 실행은 1(잘린 목록이면 그 말을 한다)", async () => {
    const r = await cli([RUN, "--apply", "--pod-replaced"], [...supervisor(), rule(HOLDS_EXEC, holdsLine([]))]);
    expect([r.code, r.json.body]).toEqual([1, "자리 풀기: 쓰지 않았다. 그 실행은 지금 자리를 쥐고 있지 않다"]);
    const t = await cli([RUN, "--apply", "--pod-replaced"], [...supervisor(), rule(HOLDS_EXEC, holdsLine([], [], false, true))]);
    expect(t.json.body).toContain("목록이 잘려 빠졌을 수 있다");
  });
});

describe("쓰기 진입점의 종료 코드 옮기기", () => {
  const refusedLine = (word: string) => entryExit(1, `olive admin: 감독이 요청을 거절했다(${word})`);
  const unknownLine = (head: string, word: string, code = 1) => entryExit(code, `olive admin: 자리 풀기 모름: ${head}(${word})`);
  const REREAD = "다시 쓰기 전에 homelab olive release --apply로 자리를 다시 읽는다";
  // [진입점의 결과, CLI 종료 코드, 머리 줄, 다음 행동]
  const rows: [string, Resp, number, string, string | null][] = [
    ["장부 거절 pod_started_too_early", refusedLine("ledger_refused:pod_started_too_early"), 1, "자리 풀기 거절(ledger_refused:pod_started_too_early): 새 파드가 닫을 수 있는 시각 전에 떴다. 적힌 것 없음, 자리는 그대로", "그 시각 뒤에 작업자 파드를 한 번 더 바꾼 뒤 같은 명령을 다시 실행한다"],
    ["장부 거절 start_may_launch", refusedLine("ledger_refused:start_may_launch"), 1, "자리 풀기 거절(ledger_refused:start_may_launch): 아직 시작이 새로 뜰 수 있는 때이거나, 시작 이력 때문에 닫을 수 없다. 적힌 것 없음, 자리는 그대로", "2026-11-27 16:10:00 KST 뒤에 작업자 파드를 다시 바꾼 뒤 같은 명령을 다시 실행한다"],
    ["장부 거절 목록 밖 쉬운 말", refusedLine("ledger_refused:slot_busy"), 1, "자리 풀기 거절(ledger_refused:slot_busy): 장부가 거절했다. 적힌 것 없음, 자리는 그대로", "원인을 고친 뒤 같은 명령을 다시 실행한다"],
    ["state_changed", refusedLine("state_changed"), 1, "자리 풀기 거절(state_changed): 앞 상태가 바뀌었다. 적힌 것 없음", "homelab olive release --apply로 다시 읽고 절차를 다시 고른다"],
    ["pod_started_later", refusedLine("pod_started_later"), 1, "자리 풀기 거절(pod_started_later): 넘긴 파드 시각이 감독 시계보다 늦다(시계가 어긋났을 수 있다). 적힌 것 없음", "원인을 고친 뒤 같은 명령을 다시 실행한다"],
    ["write_unknown:closed", unknownLine("장부에 적혔는지 모른다", "write_unknown:closed"), 1, "자리 풀기: 결과 모름. 장부에 적혔는지 모른다(write_unknown:closed). 장부에 적혔을 수 있다", REREAD],
    ["write_unknown", unknownLine("장부에 적혔는지 모른다", "write_unknown"), 1, "자리 풀기: 결과 모름. 장부에 적혔는지 모른다(write_unknown). 장부에 적혔을 수 있다", REREAD],
    ["restore_not_done", unknownLine("감독이 복원을 마치지 않았다", "restore_not_done", 3), 3, "자리 풀기: 쓰지 않았다. 감독이 복원을 마치지 않았다(restore_not_done)", "감독이 복원을 마친 뒤 같은 명령을 다시 실행한다"],
    ["no_socket", unknownLine("감독에 닿지 못했다", "no_socket"), 1, "자리 풀기: 쓰지 않았다. 감독에 닿지 못했다(no_socket)", "homelab olive status --apply로 감독을 확인한다"],
    ["ledger_unreadable", unknownLine("감독이 상태를 읽지 못했다", "ledger_unreadable"), 1, "자리 풀기: 쓰지 않았다. 감독이 쓰기 전에 멈췄다(ledger_unreadable)", "원인을 고친 뒤 같은 명령을 다시 실행한다"],
    ["진입점 64", entryExit(64, "olive admin: 사용법: bun src/main/admin.ts status"), 1, "자리 풀기: 쓰지 않았다. 감독 진입점이 요청을 받지 않았다(종료 코드 64, CLI와 감독 이미지의 판이 다를 수 있다)", "감독 이미지가 자리 풀기를 아는 판인지 확인한다"],
    ["모르는 장부 거절 이름", refusedLine("ledger_refused:made_up_refusal"), 1, "자리 풀기: 결과 모름. 감독 진입점이 종료 코드 1로 끝났다. 장부에 적혔을 수 있다", REREAD],
    ["모르는 write_unknown 까닭", unknownLine("장부에 적혔는지 모른다", "write_unknown:other"), 1, "자리 풀기: 결과 모름. 감독 진입점이 종료 코드 1로 끝났다. 장부에 적혔을 수 있다", REREAD],
    ["사유 꼴이 다름", entryExit(1, `olive admin: ${CANARY}`), 1, "자리 풀기: 결과 모름. 감독 진입점이 종료 코드 1로 끝났다. 장부에 적혔을 수 있다", REREAD],
    ["다른 실행의 답", releaseLine("closed", true, true, "00000000-0000-4000-8000-000000000000"), 1, "자리 풀기: 결과 모름. 실행했지만 감독의 답을 확인하지 못했다. 장부에 적혔을 수 있다", REREAD],
    ["모르는 판의 답", { stdout: `${JSON.stringify({ schema: "olive-release/v2", outcome: "closed", runId: RUN, released: true, slotFree: true })}\n` }, 1, "자리 풀기: 결과 모름. 실행했지만 감독의 답을 확인하지 못했다. 장부에 적혔을 수 있다", REREAD],
    ["kubectl 실패(원격 코드 없음)", { code: 1, stderr: `Error from server (Forbidden): ${CANARY}\n` }, 1, "자리 풀기: 결과 모름. 실행했지만 감독의 답을 확인하지 못했다. 장부에 적혔을 수 있다", REREAD],
  ];
  test("표의 각 줄: 종료 코드·머리 줄·다음 행동, 쓰기 exec는 한 번, 원문 없음", async () => {
    for (const [name, resp, code, head, next] of rows) {
      const r = await cli([RUN, "--apply", "--pod-replaced"], [...supervisor(), ...worker(), rule(HOLDS_EXEC, holdsLine([run({ state: "unknown_running", next: "close_unconfirmed" })])), rule(CLOSE_EXEC(), resp)]);
      expect([name, r.code]).toEqual([name, code]);
      expect([name, r.json.body.split("\n")[0]]).toEqual([name, head]);
      expect([name, r.json.next]).toEqual([name, next]);
      expect(writeExec(r)).toEqual([CLOSE_EXEC()]);
      expect(r.stdout + r.stderr).not.toContain(CANARY);
    }
  });

  test("결과 포기의 outcome_unknown·report_pending은 기다림과 저장소 비움 닫기를 안내한다", async () => {
    const runs = [run({ state: "checking", next: "abandon_result", stopReceiptId: STOP })];
    for (const [name, next] of [["outcome_unknown", "--store-reset"], ["report_pending", "결과 검사가 그 보고를 판정하기를 기다린 뒤"]] as const) {
      const r = await cli([RUN, "--apply", "--abandon-result", "no_answer"], [...supervisor(), rule(HOLDS_EXEC, holdsLine(runs)), rule(ABANDON_EXEC("no_answer"), refusedLine(`ledger_refused:${name}`))]);
      expect([name, r.code]).toEqual([name, 1]);
      expect(r.json.body).toContain(`(ledger_refused:${name})`);
      expect(r.json.next).toContain(next);
    }
  });

  test("결과 포기의 답이 slotFree true면(포기한 실행은 자리를 쥔다) 적혔는지 모름으로 본다", async () => {
    const runs = [run({ state: "checking", next: "abandon_result", stopReceiptId: STOP })];
    const r = await cli([RUN, "--apply", "--abandon-result", "no_answer"], [...supervisor(), rule(HOLDS_EXEC, holdsLine(runs)), rule(ABANDON_EXEC("no_answer"), releaseLine("abandoned", false, true))]);
    expect(r.code).toBe(1);
    expect(r.json.body).toContain("결과 모름");
  });

  test("쓰기의 kubectl 시간 초과는 결과 모름이다", async () => {
    const r = await cli([RUN, "--apply", "--pod-replaced"], [...supervisor(), ...worker(), rule(HOLDS_EXEC, holdsLine([run({ state: "unknown_running", next: "close_unconfirmed" })])), rule(CLOSE_EXEC(), { sleepMs: 5_000 })]);
    expect(r.code).toBe(1);
    expect(r.json.body).toContain("결과 모름");
    expect(r.json.next).toBe(REREAD);
  }, 20_000);
});
