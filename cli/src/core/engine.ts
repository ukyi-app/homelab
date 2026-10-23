// 단계 엔진(설계 C.7 "재실행 안전").
// 여러 시스템의 변경은 원자적이지 않다. 그래서 단계마다 실행 직전에 현재 상태를 읽고 이미 된 단계는 건너뛴다.
// apply 순서: 전체 읽기 한 번(확인 단계가 막히면 아무것도 쓰기 전에 멈춤) → 단계마다 다시 읽기 → 차이만 apply 한 번 → 다시 읽어 확인.
// apply가 타임아웃이면 재시도하지 않고 다시 읽는다(B.8 E7: 타임아웃 뒤 재시도는 두 번 실행이다).
import type { Ctx, Observation, Plan } from "./command";
import { ExecTimeout } from "./exec";
import type { Result, Status, StepReport } from "./result";
import { allowGeneration } from "./secret";

const RERUN = "같은 명령을 다시 실행하면 된 단계는 건너뛰고 이어 간다";

function normalize(o: Observation): Observation {
  return o.state === "same" ? { ...o, action: "none" } : o;
}

function detailOf(o: Observation): string {
  return o.wait ? `${o.detail} (${o.wait})` : o.detail;
}

function planLine(line: string): string {
  return line.replace(/ --apply(?= |$)/, "");
}

export async function runEngine(ctx: Ctx, plan: Plan): Promise<Result> {
  const ids = new Set<string>();
  for (const s of plan.steps) {
    if (ids.has(s.id)) throw new Error(`단계 id가 겹친다: ${s.id}`);
    ids.add(s.id);
  }
  const reports: StepReport[] = plan.steps.map((s) => ({ id: s.id, target: s.target, state: "missing", action: "none", detail: "", result: "not-run" }));
  const notes = [...(plan.notes ?? [])];

  const finish = (status: Status, error?: { message: string; next: string }): Result => {
    let next: string | null;
    const custom = plan.next?.(status);
    if (custom !== undefined) next = custom;
    else if (status === "pending") next = `${ctx.line} --apply`;
    else if (status === "waiting") next = `대기가 끝나면 확인: ${planLine(ctx.line)}`;
    else if (status === "failed") next = error?.next ?? RERUN;
    else next = null;
    const result: Result = { command: plan.command, app: plan.app, mode: ctx.mode, status, steps: reports, notes, next, title: plan.title };
    if (error) result.error = error;
    return result;
  };

  // 1. 전체 읽기. plan·read는 여기서 끝난다. 읽기 실패가 있어도 나머지를 읽어 전체를 보여 준다.
  let blocked: { message: string; next: string } | undefined;
  for (let i = 0; i < plan.steps.length; i++) {
    const s = plan.steps[i];
    try {
      const o = normalize(await s.read(ctx));
      reports[i] = { ...reports[i], state: o.state, action: o.action, detail: detailOf(o), result: ctx.mode === "apply" ? "not-run" : o.state === "same" ? "skipped" : "planned" };
      if (!s.apply && o.state !== "same") {
        reports[i].result = "failed";
        blocked ??= { message: `${s.target}: ${o.detail}`, next: o.next ?? `원인을 고친 뒤 다시: ${planLine(ctx.line)}` };
      }
    } catch (e) {
      reports[i] = { ...reports[i], detail: "읽지 못함", result: "failed" };
      blocked ??= { message: `${s.target}: ${(e as Error).message}`, next: `원인을 고친 뒤 다시: ${planLine(ctx.line)}` };
    }
  }
  if (blocked) return finish("failed", blocked);
  if (ctx.mode !== "apply") return finish(reports.some((r) => r.state !== "same") ? "pending" : "same");

  // 2. apply.
  let changed = false;
  const waits: string[] = [];
  for (let i = 0; i < plan.steps.length; i++) {
    const s = plan.steps[i];
    let seen: Observation;
    try {
      seen = normalize(await s.read(ctx));
    } catch (e) {
      reports[i] = { ...reports[i], detail: "읽지 못함", result: "failed" };
      return finish("failed", { message: `${s.target}: ${(e as Error).message}`, next: RERUN });
    }
    reports[i] = { ...reports[i], state: seen.state, action: seen.action, detail: detailOf(seen) };
    if (seen.state === "same") {
      reports[i].result = seen.wait ? "waiting" : "skipped";
      if (seen.wait) waits.push(seen.wait);
      continue;
    }
    if (!s.apply) {
      reports[i].result = "failed";
      return finish("failed", { message: `${s.target}: ${seen.detail}`, next: seen.next ?? RERUN });
    }
    ctx.progress(`${i + 1}/${plan.steps.length} ${s.id}: ${seen.detail}`);
    let timedOut = false;
    try {
      // 비밀번호는 apply 안에서만 만든다. read()에서 만들면 plan이 부수효과를 갖는다.
      allowGeneration(true);
      try {
        await s.apply(ctx, seen);
      } finally {
        allowGeneration(false);
      }
    } catch (e) {
      if (!(e instanceof ExecTimeout)) {
        reports[i].result = "failed";
        return finish("failed", { message: `${s.target}: ${(e as Error).message}`, next: `원인을 고친 뒤 다시: ${ctx.line}` });
      }
      timedOut = true;
    }
    let after: Observation;
    try {
      after = normalize(await s.read(ctx));
    } catch (e) {
      reports[i].result = "failed";
      return finish("failed", { message: `${s.target}: 실행 뒤 상태를 읽지 못했다(결과 미상): ${(e as Error).message}`, next: RERUN });
    }
    if (after.state !== "same") {
      reports[i].result = "failed";
      const message = timedOut ? `${s.target}: 시간 초과 뒤 다시 읽었지만 아직 반영되지 않았다(결과 미상, 재시도하지 않았다)` : `${s.target}: 실행했지만 다시 읽은 상태가 다르다: ${after.detail}`;
      return finish("failed", { message, next: RERUN });
    }
    changed = true;
    if (timedOut) notes.push(`${s.id}: 시간 초과 뒤 다시 읽어 반영된 것을 확인했다`);
    if (after.wait) waits.push(after.wait);
    reports[i].result = after.wait ? "waiting" : "applied";
    if (after.wait) reports[i].detail = `${seen.detail} (${after.wait})`;
  }
  return finish(waits.length > 0 ? "waiting" : changed ? "done" : "same");
}
