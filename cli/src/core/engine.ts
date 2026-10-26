// 단계 엔진(설계 C.7 "재실행 안전").
// 여러 시스템의 변경은 원자적이지 않다. 그래서 단계마다 실행 직전에 현재 상태를 읽고 이미 된 단계는 건너뛴다.
// apply 순서: 전체 읽기 한 번(확인 단계가 막히면 아무것도 쓰기 전에 멈춤) → 단계마다 다시 읽기 → 차이만 apply 한 번 → 다시 읽어 확인.
// apply가 타임아웃이면 재시도하지 않고 다시 읽는다(B.8 E7: 타임아웃 뒤 재시도는 두 번 실행이다).
// Step.read는 ReadCtx(쓰기 함수 없음), Step.apply는 그 apply만의 WriteCtx를 받는다.
import type { Observation, Plan, ReadCtx, WriteCtx } from "./command";
import { ExecTimeout } from "./exec";
import type { Result, Status, StepReport } from "./result";

const RERUN = "같은 명령을 다시 실행하면 된 단계는 건너뛰고 이어 간다";

function normalize(o: Observation): Observation {
  // hold는 "이 단계는 됐고 바깥을 기다린다"다. 아직 안 된 단계가 뒤를 막으려면 그 단계가 실패해야 한다.
  if (o.hold !== undefined && o.state !== "same") throw new Error("hold는 same 관찰에만 둔다(엔진 계약)");
  return o.state === "same" ? { ...o, action: "none" } : o;
}

function detailOf(o: Observation): string {
  const extra = o.hold ?? o.wait;
  return extra ? `${o.detail} (${extra})` : o.detail;
}

// --apply는 `--`(뒤는 위치 인자만) 앞에 둔다. 끝에 붙이면 재실행이 위치 인자로 읽어 64로 끝난다(Connector 4360754469).
export function applyLine(line: string): string {
  const withApply = line.replace(/ --(?= |$)/, " --apply --");
  return withApply === line ? `${line} --apply` : withApply;
}

function planLine(line: string): string {
  return line.replace(/ --apply(?= |$)/, "");
}

// newWrite: 이 apply 한 번의 쓰기 문맥을 만든다(runtime.ts). plan·read에서는 부르지 않는다.
export async function runEngine(ctx: ReadCtx, plan: Plan, newWrite: () => { w: WriteCtx; revoke: () => void }): Promise<Result> {
  const ids = new Set<string>();
  for (const s of plan.steps) {
    if (ids.has(s.id)) throw new Error(`단계 id가 겹친다: ${s.id}`);
    ids.add(s.id);
  }
  const reports: StepReport[] = plan.steps.map((s) => ({ id: s.id, target: s.target, state: "missing", action: "none", detail: "", result: "not-run" }));
  const notes = [...(plan.notes ?? [])];

  const finish = (status: Status, error?: { message: string; next: string }, held?: string): Result => {
    let next: string | null;
    const custom = plan.next?.(status);
    // hold로 멈추면 뒤 단계가 남아 있다. 같은 apply를 다시 치는 것이 다음 행동이다(확인만 하는 plan이 아니다).
    if (held !== undefined) next = `${held}. 끝나면 다시: ${ctx.line}`;
    else if (custom !== undefined) next = custom;
    else if (status === "pending") next = applyLine(ctx.line);
    else if (status === "waiting") next = `대기가 끝나면 확인: ${planLine(ctx.line)}`;
    else if (status === "failed") next = error?.next ?? RERUN;
    else next = null;
    const result: Result = { command: plan.command, app: plan.app, mode: ctx.mode, status, steps: reports, notes, next, title: plan.title };
    if (plan.body !== undefined) result.body = plan.body;
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
      if (o.warn) notes.push(`${s.target}: ${o.warn}`);
      if (o.hold) notes.push(`${s.target}: ${o.hold}. 뒤 단계는 대기가 끝난 뒤 실행한다`);
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
    if (seen.state === "same" && seen.hold) {
      reports[i].result = "waiting";
      return finish("waiting", undefined, seen.hold);
    }
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
      // 쓰기 문맥은 이 apply 한 번에만 있다. read()·재조회는 읽기 문맥이라 쓰기 함수가 없다.
      const { w, revoke } = newWrite();
      try {
        await s.apply(w, seen);
      } finally {
        revoke();
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
    if (after.hold) {
      reports[i].result = "waiting";
      reports[i].detail = `${seen.detail} (${after.hold})`;
      return finish("waiting", undefined, after.hold);
    }
    if (after.wait) waits.push(after.wait);
    reports[i].result = after.wait ? "waiting" : "applied";
    if (after.wait) reports[i].detail = `${seen.detail} (${after.wait})`;
  }
  return finish(waits.length > 0 ? "waiting" : changed ? "done" : "same");
}
