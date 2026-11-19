// homelab olive의 공통부: 대상 읽기, 보고 문구, 엔진 한 단계로 돌리기.
// 읽지 못한 것은 "unread"·null로 남긴다. 0이나 없음으로 바꾸지 않는다. 오류 원문은 출력에 싣지 않는다(kubectl stderr가 섞일 수 있다).
import type { ReadCtx, RunPod, Step, StopLockState, WriteCtx } from "../core/command";
import { oliveTargets, type OliveTarget } from "../core/names";
import type { Result, Status } from "../core/result";

export const INTAKE_UNKNOWN = "접수: 확인하지 못함. 현관의 관리 진입점이 아직 없다";

type Reader = Pick<ReadCtx, "k8s" | "olive">;
export type DeploymentView = { state: "present"; replicas: number | null; selector: string | null } | { state: "absent" } | { state: "unread" };
export type TargetView = {
  target: OliveTarget;
  namespace: "present" | "absent" | "unread";
  deployment: DeploymentView;
  lock: StopLockState | "unread";
  // null은 파드 수를 모르는 것이다. blind면 읽기가 실패한 것이 아니라 이 대상의 파드를 가려낼 방법이 없는 것이다.
  pods: RunPod[] | null;
  blind: boolean;
};

export const stopTargets = (): OliveTarget[] => oliveTargets().filter((t) => t.stop);

function attempt<T>(read: () => T): { ok: true; value: T } | { ok: false } {
  try {
    return { ok: true, value: read() };
  } catch {
    return { ok: false };
  }
}

// Deployment가 실제로 고르는 파드의 셀렉터. matchExpressions가 있으면 key=value로 옮길 수 없어 null이다.
function selectorOf(d: any): string | null {
  const sel = d?.spec?.selector;
  if (Array.isArray(sel?.matchExpressions) && sel.matchExpressions.length > 0) return null;
  const labels = sel?.matchLabels;
  if (labels === null || typeof labels !== "object") return null;
  const pairs = Object.entries(labels).map(([k, v]) => `${k}=${String(v)}`);
  return pairs.length > 0 ? pairs.sort().join(",") : null;
}

function readDeployment(c: Reader, t: OliveTarget): DeploymentView {
  const r = attempt(() => c.k8s.get("deployment", t.namespace, t.deployment));
  if (!r.ok) return { state: "unread" };
  if (r.value === null) return { state: "absent" };
  const n = r.value?.spec?.replicas;
  return { state: "present", replicas: typeof n === "number" ? n : null, selector: selectorOf(r.value) };
}

// 대상 라벨은 올리브 차트의 파드 템플릿에만 있다(platform/olive/templates/_helpers.tpl의 olive.labels).
const CHART_LABELED = "platform/olive";

function readPods(c: Reader, t: OliveTarget, d: DeploymentView): { pods: RunPod[] | null; blind: boolean } {
  if (d.state === "unread" || (d.state === "present" && d.selector === null)) return { pods: null, blind: false };
  // 함정: 다른 곳이 선언한 대상(작성 작업자는 app=worker-task)에 대상 라벨로 물으면 빈 목록이 와서 남은 파드가 없는 것처럼 보인다.
  if (d.state === "absent" && t.declaredBy !== CHART_LABELED) return { pods: null, blind: true };
  const selector = d.state === "present" ? (d.selector as string) : `homelab.ukyi.app/olive-target=${t.id}`;
  const r = attempt(() => c.olive.runPods(t.namespace, selector));
  // 끝난 파드(Succeeded·Failed)는 프로세스가 없고 Deployment가 지우기 전까지 목록에 남는다.
  // 강제 삭제 표식이 있으면 남긴다. kubelet의 확인 없이 지워지는 파드라 phase가 종료의 증거가 아니다.
  return { pods: r.ok ? r.value.filter((p) => p.forceDeleting || (p.phase !== "Succeeded" && p.phase !== "Failed")) : null, blind: false };
}

export function readTarget(c: Reader, t: OliveTarget): TargetView {
  const ns = attempt(() => c.k8s.get("namespace", null, t.namespace));
  if (ns.ok && ns.value === null) return { target: t, namespace: "absent", deployment: { state: "absent" }, lock: "absent", pods: [], blind: false };
  const deployment = readDeployment(c, t);
  const lock = attempt(() => c.olive.stopLock(t.namespace));
  return { target: t, namespace: ns.ok ? "present" : "unread", deployment, lock: lock.ok ? lock.value : "unread", ...readPods(c, t, deployment) };
}

export const readAll = (c: Reader, targets: OliveTarget[]): TargetView[] => targets.map((t) => readTarget(c, t));

// read는 파드 목록을 얻은 대상 수, unread는 읽기가 실패한 대상 수, blind는 파드를 가려낼 방법이 없는 대상 수다.
export type PodCount = { live: number; deleting: number; forced: number; read: number; unread: number; blind: number };
export function countPods(views: TargetView[]): PodCount {
  const all = views.flatMap((v) => v.pods ?? []);
  const forced = all.filter((p) => p.forceDeleting).length;
  const deleting = all.filter((p) => p.deletionTimestamp !== null && !p.forceDeleting).length;
  const blind = views.filter((v) => v.blind).length;
  return { live: all.length, deleting, forced, read: views.filter((v) => v.pods !== null).length, unread: views.filter((v) => v.pods === null).length - blind, blind };
}

export function podWords(n: PodCount): string {
  const unknown = [...(n.unread > 0 ? [`읽지 못한 대상 ${n.unread}곳`] : []), ...(n.blind > 0 ? [`파드를 식별할 수 없는 대상 ${n.blind}곳`] : [])].join(", ");
  if (unknown && n.read === 0) return `실행 파드 개수 미상(${unknown})`;
  const base = `실행 파드 ${n.live}개(삭제 중 ${n.deleting}개, 강제 삭제 중 ${n.forced}개)`;
  return unknown ? `읽은 대상 ${n.read}곳의 ${base}, ${unknown}` : base;
}

// 강제 삭제 표식을 본 파드. 사람이 노드에서 찾을 수 있게 네임스페이스·이름·UID를 함께 적고 UID로 겹침을 없앤다.
export function forcedPods(views: TargetView[]): string[] {
  const seen = new Map<string, string>();
  for (const v of views) for (const p of v.pods ?? []) if (p.forceDeleting && !seen.has(p.uid)) seen.set(p.uid, `${v.target.namespace}/${p.name}(UID ${p.uid})`);
  return [...seen.values()];
}

const LOCK_WORD: Record<TargetView["lock"], string> = { absent: "없음", same: "걸림", different: "다른 모양", deleting: "지우는 중", unread: "읽지 못함" };

// 네임스페이스 하나에 대상이 여럿이어도 자물쇠는 하나다.
export function uniqueNamespaces(views: TargetView[]): TargetView[] {
  const seen = new Set<string>();
  return views.filter((v) => !seen.has(v.target.namespace) && seen.add(v.target.namespace));
}

export function targetLine(v: TargetView): string {
  const head = `${v.target.id} ${v.target.namespace}/${v.target.deployment}`;
  if (v.namespace === "absent") return `${head}: 네임스페이스 없음`;
  const d = v.deployment;
  const replicas = d.state === "absent" ? "Deployment 없음" : d.state === "unread" || d.replicas === null ? "replicas 읽지 못함" : `replicas ${d.replicas}`;
  return `${head}: ${replicas}, 자물쇠 ${LOCK_WORD[v.lock]}, ${podWords(countPods([v]))}`;
}

// held·present는 판정에 쓰고, words는 네임스페이스나 자물쇠를 읽지 못한 곳을 걸리지 않은 곳으로 세지 않고 미상으로 따로 센다.
export function lockSummary(views: TargetView[]): { held: number; present: number; words: string } {
  const spaces = uniqueNamespaces(views).filter((v) => v.namespace !== "absent");
  const held = spaces.filter((v) => v.lock === "same").length;
  const absent = uniqueNamespaces(views).length - spaces.length;
  const known = spaces.filter((v) => v.namespace !== "unread" && v.lock !== "unread");
  const unknown = spaces.length - known.length;
  const counted = unknown === 0 ? `${held}/${spaces.length}곳 걸림` : known.length === 0 ? `상태 미상 ${unknown}곳` : `읽은 ${known.length}곳 중 ${known.filter((v) => v.lock === "same").length}곳 걸림, 미상 ${unknown}곳`;
  return { held, present: spaces.length, words: `자물쇠 ${counted}${absent > 0 ? `(없는 네임스페이스 ${absent}곳)` : ""}` };
}

function replicasValue(d: DeploymentView): string {
  if (d.state === "absent") return "없음";
  return d.state === "unread" || d.replicas === null ? "미상" : String(d.replicas);
}

export const replicasWords = (views: TargetView[]): string => `replicas: ${views.map((v) => `${v.target.id} ${replicasValue(v.deployment)}`).join(", ")}`;

// 읽기가 실패한 대상이 있는지. 파드를 가려낼 방법이 없는 대상(blind)은 읽기 실패가 아니다.
export const readFailed = (views: TargetView[]): boolean => views.some((v) => v.namespace === "unread" || v.deployment.state === "unread" || (v.deployment.state === "present" && v.deployment.replicas === null) || v.lock === "unread" || (v.pods === null && !v.blind));

// 확인하지 못한 것이 하나라도 있는지. stop status·stop verify의 판정은 이쪽을 쓴다.
export const anyUnread = (views: TargetView[]): boolean => readFailed(views) || views.some((v) => v.blind);

export const unreadWhy = (views: TargetView[]): string => (readFailed(views) ? "읽지 못한 대상이 있다" : "파드를 식별할 수 없는 대상이 있다");

export type Outcome = {
  status: Status;
  // 단계 줄의 짧은 말과 요약 한 줄.
  label: string;
  headline: string;
  lines: string[];
  // undefined면 엔진의 기본 다음 행동(plan이면 같은 명령에 --apply).
  next?: string | null;
};

export type Action = {
  command: string;
  target: string;
  // 읽기 동작의 머리. 없으면 엔진의 기본 머리(계획·실행)다.
  title?: string;
  plan(c: ReadCtx): Outcome;
  // 없으면 읽기 동작이다.
  apply?(w: WriteCtx): Outcome;
};

// 대상별 실패가 다른 대상을 막지 않도록 한 번의 apply 안에서 끝까지 돌고, 끝 상태는 엔진이 아니라 Outcome이 정한다.
// 엔진의 waiting은 plan 모드에서 나오지 않고, 단계 실패는 뒤를 끊기 때문이다.
export async function runAction(ctx: ReadCtx, a: Action): Promise<Result> {
  let done = null as Outcome | null;
  let planned = null as Outcome | null;
  const step: Step = {
    id: "olive",
    target: a.target,
    async read(c) {
      if (done) return { state: "same", action: "none", detail: done.label };
      // apply는 읽기 실패로 시작을 막지 않는다. 실제 읽기는 apply 안에서 대상마다 한다.
      if (c.mode === "apply") return { state: "differs", action: "update", detail: "실행" };
      planned = a.plan(c);
      return a.apply ? { state: "differs", action: "update", detail: planned.label } : { state: "same", action: "none", detail: planned.label };
    },
  };
  const applyFn = a.apply;
  if (applyFn) {
    step.apply = async (w) => {
      done = applyFn(w);
    };
  }
  const r = await ctx.engine({ command: a.command, steps: [step] });
  const o: Outcome | null = done ?? planned;
  if (o === null || r.status === "failed") return r;
  const steps = r.steps.map((s) => ({ ...s, detail: o.label, result: o.status === "failed" ? ("failed" as const) : o.status === "waiting" ? ("waiting" as const) : s.result }));
  const next = o.next === undefined ? r.next : o.next;
  const result: Result = { ...r, status: o.status, steps, body: [o.headline, ...o.lines].join("\n"), next };
  if (a.title !== undefined) result.title = a.title;
  if (o.status === "failed") result.error = { message: o.headline, next: next ?? "원인을 고친 뒤 같은 명령을 다시 실행한다" };
  return result;
}
