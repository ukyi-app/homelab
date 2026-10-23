// 단계 엔진 시험. 02~04의 재실행·실패 주입 시험은 같은 모양(상태를 가진 가짜 단계 또는 스텁 responses)으로 쓴다.
import { describe, expect, test } from "bun:test";
import type { ReadCtx, Observation, Step, WriteCtx } from "../../src/core/command";
import { ExecTimeout, PLAN_WRITE_BLOCKED } from "../../src/core/exec";
import type { Mode } from "../../src/core/result";
import { REST, applyWith, rule, testCtx } from "../harness";

// 바깥 상태 하나를 흉내 내는 단계. applyCount로 두 번 실행을 잡는다.
function fakeStep(id: string, world: Record<string, boolean>, opts: { failApply?: boolean; timeout?: "lands" | "lost"; wait?: string; check?: boolean } = {}): Step & { applyCount: number } {
  const step = {
    id,
    target: `대상 ${id}`,
    applyCount: 0,
    async read(): Promise<Observation> {
      return world[id] ? { state: "same", action: "none", detail: "있음", wait: opts.wait } : { state: "missing", action: "create", detail: "없음 → 생성", next: `${id}를 고친다` };
    },
    apply: opts.check
      ? undefined
      : async () => {
          step.applyCount++;
          if (opts.failApply) throw new Error("주입한 실패");
          if (opts.timeout === "lands") {
            world[id] = true;
            throw new ExecTimeout("시간 초과(결과 미상)");
          }
          if (opts.timeout === "lost") throw new ExecTimeout("시간 초과(결과 미상)");
          world[id] = true;
        },
  };
  return step;
}

function ctxFor(mode: Mode): ReadCtx {
  return testCtx(mode, []).ctx;
}

describe("엔진", () => {
  test("plan: 읽기만, 차이가 있으면 pending(exit 0), apply 0회", async () => {
    const world = { a: true, b: false };
    const a = fakeStep("a", world);
    const b = fakeStep("b", world);
    const r = await ctxFor("plan").engine({ command: "t", steps: [a, b] });
    expect(r.status).toBe("pending");
    expect(r.steps.map((s) => [s.state, s.result])).toEqual([["same", "skipped"], ["missing", "planned"]]);
    expect(r.next).toBe("homelab test --apply");
    expect(a.applyCount + b.applyCount).toBe(0);
  });

  test("apply: 차이만 실행, 한 번씩, 다시 읽어 확인. 두 번째 실행은 모두 same", async () => {
    const world = { a: true, b: false, c: false };
    const steps = [fakeStep("a", world), fakeStep("b", world), fakeStep("c", world)];
    const r1 = await ctxFor("apply").engine({ command: "t", steps });
    expect(r1.status).toBe("done");
    expect(r1.steps.map((s) => s.result)).toEqual(["skipped", "applied", "applied"]);
    expect(steps.map((s) => s.applyCount)).toEqual([0, 1, 1]);
    const r2 = await ctxFor("apply").engine({ command: "t", steps });
    expect(r2.status).toBe("same");
    expect(r2.steps.every((s) => s.state === "same")).toBe(true);
    expect(steps.map((s) => s.applyCount)).toEqual([0, 1, 1]);
  });

  test("중간 실패: 뒤 단계는 안 함, 재실행하면 된 단계를 건너뛰고 이어 간다(AC-8)", async () => {
    const world = { a: false, b: false, c: false };
    const flaky = fakeStep("b", world, { failApply: true });
    const r1 = await ctxFor("apply").engine({ command: "t", steps: [fakeStep("a", world), flaky, fakeStep("c", world)] });
    expect(r1.status).toBe("failed");
    expect(r1.steps.map((s) => s.result)).toEqual(["applied", "failed", "not-run"]);
    expect(r1.error?.message).toContain("주입한 실패");
    const a = fakeStep("a", world);
    const b = fakeStep("b", world);
    const c = fakeStep("c", world);
    const r2 = await ctxFor("apply").engine({ command: "t", steps: [a, b, c] });
    expect(r2.status).toBe("done");
    expect(r2.steps.map((s) => s.result)).toEqual(["skipped", "applied", "applied"]);
    expect(a.applyCount).toBe(0);
  });

  test("타임아웃: 재시도하지 않고 다시 읽는다. 반영됐으면 applied + 주의", async () => {
    const world = { a: false };
    const a = fakeStep("a", world, { timeout: "lands" });
    const r = await ctxFor("apply").engine({ command: "t", steps: [a] });
    expect(r.status).toBe("done");
    expect(a.applyCount).toBe(1);
    expect(r.notes.join(" ")).toContain("시간 초과");
  });

  test("타임아웃 뒤에도 반영이 안 됐으면 failed, apply는 한 번뿐", async () => {
    const world = { a: false };
    const a = fakeStep("a", world, { timeout: "lost" });
    const r = await ctxFor("apply").engine({ command: "t", steps: [a] });
    expect(r.status).toBe("failed");
    expect(a.applyCount).toBe(1);
    expect(r.error?.message).toContain("결과 미상");
  });

  test("확인 단계가 막히면 아무것도 쓰기 전에 멈춘다", async () => {
    const world = { a: false, gate: false };
    const a = fakeStep("a", world);
    const r = await ctxFor("apply").engine({ command: "t", steps: [a, fakeStep("gate", world, { check: true })] });
    expect(r.status).toBe("failed");
    expect(a.applyCount).toBe(0);
    expect(r.error?.next).toBe("gate를 고친다");
  });

  test("same + wait면 waiting(exit 3). plan에서는 same", async () => {
    const world = { pr: false };
    const pr = fakeStep("pr", world, { wait: "PR #1 검토·병합 대기" });
    const r = await ctxFor("apply").engine({ command: "t", steps: [pr] });
    expect(r.status).toBe("waiting");
    expect(r.steps[0].result).toBe("waiting");
    const p = await ctxFor("plan").engine({ command: "t", steps: [pr] });
    expect(p.status).toBe("same");
  });

  test("read()가 던지면 plan도 failed, 다른 단계는 끝까지 읽는다", async () => {
    const world = { b: false };
    const broken: Step = { id: "x", target: "x", read: async () => { throw new Error("읽기 실패"); }, apply: async () => {} };
    const r = await ctxFor("plan").engine({ command: "t", steps: [broken, fakeStep("b", world)] });
    expect(r.status).toBe("failed");
    expect(r.steps[1].result).toBe("planned");
  });

  test("read 문맥에는 쓰기 함수가 없다(쓰기 어댑터는 apply 문맥에만 존재, 3라운드 구조)", async () => {
    const { ctx } = testCtx("apply", []);
    const k8s = ctx.k8s as unknown as Record<string, unknown>;
    const inf = ctx.infisical as unknown as Record<string, unknown>;
    for (const name of ["forceSync", "rolloutRestart", "createRestoreObject", "deleteRestoreObjects"]) expect(k8s[name]).toBeUndefined();
    for (const name of ["setValue", "removeKey"]) expect(inf[name]).toBeUndefined();
    expect((ctx as unknown as Record<string, unknown>).generatePassword).toBeUndefined();
    expect((ctx as unknown as Record<string, unknown>).exec).toBeUndefined();
  });

  test("붙잡아 둔 쓰기 문맥은 apply가 끝나면 쓰기·비밀번호 생성이 모두 막히고 원장 0건(P1 회귀)", async () => {
    const { ctx, calls } = testCtx("apply", [rule(["kubectl", REST])]);
    let stash: WriteCtx | undefined;
    let done = false;
    const step: Step = { id: "s", target: "s", read: async () => (done ? { state: "same", action: "none", detail: "" } : { state: "missing", action: "create", detail: "" }), apply: async (w) => ((stash = w), (done = true), undefined) };
    expect((await ctx.engine({ command: "t", steps: [step] })).status).toBe("done");
    expect(() => stash!.k8s.forceSync("app-smoke", "smoke-db")).toThrow(PLAN_WRITE_BLOCKED);
    expect(() => stash!.generatePassword()).toThrow(PLAN_WRITE_BLOCKED);
    expect(() => stash!.readSecretInput("x")).toThrow(PLAN_WRITE_BLOCKED);
    expect(calls().calls).toEqual([]);
  });

  test("Step.apply() 안에서는 쓰기 어댑터가 실행된다", async () => {
    const { ctx, calls } = testCtx("apply", [rule(["kubectl", REST])]);
    const { result } = await applyWith(ctx, (w) => w.k8s.forceSync("app-smoke", "smoke-db"));
    expect(result.status).toBe("done");
    expect(calls().writes.map((c) => c.argv[3])).toEqual(["annotate"]);
  });

  test("다른 엔진의 apply가 기다리는 동안 둘째 엔진은 돌지 않는다(2라운드 P2: 쓰기 권한 공유)", async () => {
    const { ctx, calls } = testCtx("apply", [rule(["kubectl", REST])]);
    let release: () => void = () => {};
    const gate = new Promise<void>((r) => (release = r));
    let done = false;
    const slow: Step = { id: "slow", target: "slow", read: async () => (done ? { state: "same", action: "none", detail: "" } : { state: "missing", action: "create", detail: "" }), apply: async () => (await gate, (done = true), undefined) };
    const first = ctx.engine({ command: "a", steps: [slow] });
    await Bun.sleep(10);
    await expect(ctx.engine({ command: "b", steps: [fakeStep("x", { x: false })] })).rejects.toThrow("한 번에 하나");
    release();
    expect((await first).status).toBe("done");
    expect(calls().calls).toEqual([]);
  });

  test("apply 안에서 엔진을 다시 부르면(중첩) 거부한다", async () => {
    const { ctx } = testCtx("apply", []);
    await expect(applyWith(ctx, () => ctx.engine({ command: "inner", steps: [] }))).rejects.toThrow("한 번에 하나");
  });

  test("비밀번호는 apply 문맥에서만 만든다", async () => {
    const { ctx } = testCtx("apply", []);
    const { value } = await applyWith(ctx, (w) => w.generatePassword());
    expect(value.length).toBe(40);
  });

  test("단계 id가 겹치면 거부", async () => {
    const world = { a: true };
    await expect(ctxFor("plan").engine({ command: "t", steps: [fakeStep("a", world), fakeStep("a", world)] })).rejects.toThrow();
  });
});
