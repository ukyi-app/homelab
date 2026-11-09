import { describe, expect, test } from "bun:test";
import { expectPlanReadOnly, kubectlRule, rule, runCli, type Resp, type Rule } from "../harness";

// homelab bot(봇 관리 기능, 봇 COLLEAGUE_SPEC §4.8·AC-20). 경계 S3: 명령 엔진 + 가짜 kubectl.
// kubectl exec는 쓰기라(설계 C.7) 상태 보기까지 plan에서는 대상 파드와 argv만 보이고 --apply에서만 실행한다.
const NS = "app-homelab-bot";
const POD = "homelab-bot-6f7c9d5b8-x2k4p";
const PODS = ["-n", NS, "get", "pods", "-l", "homelab.ukyi.app/app=homelab-bot", "-o", "json"];
const exec = (...words: string[]) => ["kubectl", "-n", NS, "exec", POD, "-c", "app", "--request-timeout=20s", "--", "node", "/app/dist/src/admin-main.js", ...words];
const JOB = "0f8b5a8e-3c1d-4e2f-9a7b-1c2d3e4f5a6b";
const USER = "123456789012345678";

type Pod = { name?: string; namespace?: string; app?: string; role?: string; phase?: string; ready?: boolean; owner?: string; deleting?: boolean };
function pod(o: Pod = {}) {
  return {
    metadata: {
      name: o.name ?? POD,
      namespace: o.namespace ?? NS,
      labels: { "homelab.ukyi.app/app": o.app ?? "homelab-bot", ...(o.role ? { "homelab.ukyi.app/role": o.role } : {}) },
      ownerReferences: [{ kind: o.owner ?? "ReplicaSet", name: "homelab-bot-6f7c9d5b8" }],
      ...(o.deleting ? { deletionTimestamp: "2026-11-10T00:00:00Z" } : {}),
    },
    status: { phase: o.phase ?? "Running", conditions: [{ type: "Ready", status: o.ready === false ? "False" : "True" }] },
  };
}
const pods = (...items: object[]) => kubectlRule(PODS, { stdout: JSON.stringify({ items }) });
const report = (command: string, result: string, state?: object) => JSON.stringify({ schema: "homelab-bot-admin/v1", command, result, ...(state ? { state } : {}) }) + "\n";
const STATE = { emergency: true, paused: true, executionPending: false, taskLaneClosed: null };
const admin = (words: string[], resp: Resp): Rule => rule(exec(...words), resp);
const execCalls = (r: { calls: { argv: string[] }[] }) => r.calls.filter((c) => c.argv[0] === "kubectl" && c.argv.includes("exec")).map((c) => c.argv);

describe("bot", () => {
  test("plan: 상태 보기도 실행하지 않고 대상 파드와 argv만 보인다(쓰기 0건)", async () => {
    const r = await runCli(["bot", "status", "--json"], [pods(pod(), pod({ name: "homelab-bot-migrate-abcde", role: "migration", owner: "Job", phase: "Succeeded" }))]);
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(execCalls(r)).toEqual([]);
    expect(r.json.status).toBe("pending");
    expect(r.json.steps[0].detail).toContain(exec("status").join(" "));
    expect(r.json.next).toBe("homelab bot status --apply");
  });

  test("plan: 동작마다 정해진 argv(위치 인자, 셸 없음)를 보인다", async () => {
    const cases: [string[], string[]][] = [
      [["emergency-stop"], ["emergency-stop"]],
      [["resume", "emergency-stop"], ["resume", "emergency-stop"]],
      [["resume", JOB], ["resume", "job", JOB]],
      [["block", USER], ["block", USER]],
      [["release", JOB], ["release", JOB]],
    ];
    for (const [args, words] of cases) {
      const r = await runCli(["bot", ...args, "--json"], [pods(pod())]);
      expect([args, r.code]).toEqual([args, 0]);
      expectPlanReadOnly(r);
      expect(r.json.steps[0].detail).toContain(exec(...words).join(" "));
    }
  });

  test("apply: 비상 정지를 실행하고 봇이 낸 결과 이름과 상태 값만 보인다", async () => {
    const r = await runCli(["bot", "emergency-stop", "--apply", "--json"], [pods(pod()), admin(["emergency-stop"], { stdout: report("emergency-stop", "stopped", STATE) })]);
    expect(r.code).toBe(0);
    expect(r.json.status).toBe("done");
    expect(execCalls(r)).toEqual([exec("emergency-stop")]);
    expect(r.json.steps[0].result).toBe("applied");
    expect(r.json.notes).toEqual(["봇 관리 기능 emergency-stop: 결과 stopped (emergency=true, paused=true, executionPending=false, taskLaneClosed=none)"]);
  });

  test("apply: 상태 보기·해제·차단·unknown 해제도 같은 파드에 한 번씩만 실행한다", async () => {
    const cases: [string[], string[], string][] = [
      [["status"], ["status"], "status"],
      [["resume", "emergency-stop"], ["resume", "emergency-stop"], "not_stopped"],
      [["block", USER], ["block", USER], "unsupported"],
    ];
    for (const [args, words, result] of cases) {
      const code = result === "unsupported" ? 4 : 0;
      const r = await runCli(["bot", ...args, "--apply", "--json"], [pods(pod()), admin(words, { stdout: report(words.slice(0, 2).join(" "), result, result === "unsupported" ? undefined : STATE), code })]);
      expect(execCalls(r)).toEqual([exec(...words)]);
      expect([args, r.code]).toEqual([args, code === 0 ? 0 : 1]);
    }
  });

  test("apply: 봇이 거부하면(실행 중 작업) exit 1이고 결과 이름을 알린다", async () => {
    const r = await runCli(["bot", "resume", "emergency-stop", "--apply", "--json"], [pods(pod()), admin(["resume", "emergency-stop"], { stdout: report("resume emergency-stop", "running_jobs", STATE), code: 3 })]);
    expect(r.code).toBe(1);
    expect(r.json.error.message).toContain("running_jobs");
  });

  test("잘못된 파드 대상이면 실행 전에 멈춘다(exec 0건)", async () => {
    const wrong: [string, object[]][] = [
      ["파드 없음", []],
      ["둘", [pod(), pod({ name: "homelab-bot-6f7c9d5b8-zzzzz" })]],
      ["다른 ns", [pod({ namespace: "app-other" })]],
      ["다른 앱 라벨", [pod({ app: "other" })]],
      ["마이그레이션 Job 파드만", [pod({ role: "migration", owner: "Job" })]],
      ["Ready 아님", [pod({ ready: false })]],
      ["지우는 중", [pod({ deleting: true })]],
      ["이름 형식", [pod({ name: "homelab-bot;id" })]],
    ];
    for (const [label, items] of wrong) {
      const r = await runCli(["bot", "status", "--apply", "--json"], [pods(...items), admin(["status"], { stdout: report("status", "status", STATE) })]);
      expect([label, r.code]).toEqual([label, 1]);
      expect([label, execCalls(r)]).toEqual([label, []]);
    }
  });

  test("형식이 틀린 동작·ID는 kubectl을 부르기 전에 사용법 오류(64)다", async () => {
    for (const args of [["stop"], ["status", "x"], ["resume"], ["resume", "not-a-uuid"], ["block", "fixture-owner"], ["block", "12345"], ["release", "$(id)"], ["emergency-stop", JOB]]) {
      const r = await runCli(["bot", ...args, "--apply", "--json"], [pods(pod())]);
      expect([args, r.code]).toEqual([args, 64]);
      expect([args, r.calls.length]).toEqual([args, 0]);
    }
  });

  test("봇 출력이 정해진 꼴이 아니면 실패로 보고 원문을 옮기지 않는다", async () => {
    const r = await runCli(["bot", "status", "--apply", "--json"], [pods(pod()), admin(["status"], { stdout: "postgres://fixture-leak@db\n" })]);
    expect(r.code).toBe(1);
    expect(r.stdout + r.stderr).not.toContain("fixture-leak");
  });
});
