// homelab db restore <app> --to <시각> | --finish | --abort: 공유 PostgreSQL에서 앱 하나의 DB만 시각 T1로 되돌린다
// (설계 C.5.7, restore.md 2절, G 시나리오 10).
//
// 흐름·SQL·Job·임시 Cluster 매니페스트와 파괴 단계 앞의 재확인(잠금, 앱 멈춤, 4-2 입력 고정, 복원 원본, 덤프 읽기)은
// core(w.pgRestore)가 갖는다. 이 명령은 단계 순서와 표식, 그리고 런북의 need(앞 단계 표식이 모두 있어야 다음 단계)를 맡는다.
// 실행 기록은 앱 ns의 ConfigMap restore-pg(런북 $W를 클러스터에, REPORT-ops 2절). 이 명령이 쓰는 키는 to·srv·img·size·ok.*이고
// bucket·tmp·in.*·dropped는 core가 쓴다. 끝나도 기록은 남고(다시 쳐도 모두 same) --finish가 지운다.
// 확인할 수 없으면 멈춘다. 지금 DB를 지우는 단계(db)는 앞 표식이 모두 있고 되돌림 사본이 지금도 R2에 있을 때만 시작한다.
import { defineCommand, type Observation, type ReadCtx, type RestoreRecord, type Step, type WriteCtx } from "../core/command";
import { APP_NAME, newRunId } from "../core/names";
import { prStep } from "../core/pr";
import { UsageError } from "../core/result";
import { parseYaml, setTopLevel } from "../core/values";

const RECORD = "restore-pg";
const LABEL = "homelab.ukyi.app/restore";
// 런북 fit 정규식(restore.md 2절 vars). core pgrestore.ts에도 같은 것이 있고 매니페스트를 만들 때 다시 본다(명령은 core 내부를 import하지 못한다).
const T1 = /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}([+-][0-9]{2}(:?[0-9]{2})?)?$/;
const SRV = /^[a-z0-9-]+$/;
const IMG = /^[a-z0-9./_-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$/;
const SIZE = /^[0-9]+(Mi|Gi|Ti)$/;
const PLUGIN = "barman-cloud.cloudnative-pg.io";
// 오프셋 필수(로컬 시각의 모호함을 받지 않는다). RFC 3339 또는 런북 꼴, 소수 초 없음.
export const TO = /[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}(:?[0-9]{2})?)/;
const KEEP = undefined as unknown as string | null;

const same = (detail: string, extra: Partial<Observation> = {}): Observation => ({ state: "same", action: "none", detail, ...extra });
const later = (detail: string): Observation => ({ state: "missing", action: "none", detail });

// 단계 의존(restore.md 2절 deps). begin(x)는 x와 x에 기대는 단계의 표식을 지운다(같은 실행으로 다시 돌릴 때 옛 표식이 통과처럼 보이지 않게).
const DEPS: Record<string, string[]> = {
  predump: [],
  tmp: [],
  auth: [],
  suspended: [],
  list: ["tmp", "auth"],
  db: ["predump", "tmp", "suspended", "auth", "list"],
  main: ["db", "list"],
  acl: ["main"],
  verify: ["acl"],
};

function dependents(step: string): string[] {
  const out = new Set<string>([step]);
  let grew = true;
  while (grew) {
    grew = false;
    for (const [k, deps] of Object.entries(DEPS)) if (!out.has(k) && deps.some((d) => out.has(d))) (out.add(k), (grew = true));
  }
  return [...out];
}

// inv: 이 호출이 받아들인 실행. to는 요청한 시각(--finish·--abort는 null), run은 처음 받아들인 기록의 실행 id.
// 쓰기마다 지금 기록이 이것과 같은지 본다. 사전 검사 뒤 다른 --to의 기록이 생겨도 이어받지 않는다(#886 r2 P1-1).
type Names = { app: string; ns: string; appsFile: string; dataFile: string; dbJob: (run: string) => string; r2Job: (run: string) => string; tmp: (run: string) => string; inv: { to: string | null; run: string | null } };

function namesOf(app: string, to: string | null): Names {
  return { app, ns: `app-${app}`, appsFile: `apps/${app}/values.yaml`, dataFile: `data/${app}/values.yaml`, dbJob: (r) => `restore-${r}-db`, r2Job: (r) => `restore-${r}-r2`, tmp: (r) => `pg-restore-${r}`, inv: { to, run: null } };
}

function values(ctx: ReadCtx | WriteCtx, path: string): any | null {
  const text = ctx.repo.readFile(path);
  return text === null ? null : parseYaml(text);
}

const record = (ctx: ReadCtx | WriteCtx, n: Names): RestoreRecord | null => ctx.k8s.restoreRecord(n.ns, RECORD);
const ok = (r: RestoreRecord | null, step: string) => r?.data[`ok.${step}`] === "1";

function mine(w: WriteCtx, n: Names): RestoreRecord {
  const r = record(w, n);
  if (!r) throw new Error(`실행 기록 ${n.ns}/${RECORD}이 없다`);
  if (n.inv.to !== null && r.data.to !== n.inv.to) throw new Error(`멈춤: 잠금의 시각(${r.data.to})이 요청(${n.inv.to})과 다르다. 다른 호출의 복원을 이어받지 않는다`);
  if (n.inv.run === null) n.inv.run = r.run;
  else if (n.inv.run !== r.run) throw new Error(`멈춤: 잠금의 실행이 이 호출이 받아들인 것(${n.inv.run})이 아니다(${r.run})`);
  return r;
}

function begin(w: WriteCtx, n: Names, step: string): RestoreRecord {
  const r = mine(w, n);
  w.k8s.restoreRecordUpdate(n.ns, RECORD, r.run, Object.fromEntries(dependents(step).map((s) => [`ok.${s}`, null])));
  return mine(w, n);
}

function need(r: RestoreRecord, step: string): void {
  const missing = DEPS[step].filter((d) => !ok(r, d));
  if (missing.length) throw new Error(`멈춤: 앞 단계(${missing.join(", ")}) 확인이 끝나지 않았다`);
}

function done(w: WriteCtx, n: Names, step: string, extra: Record<string, string> = {}): void {
  w.k8s.restoreRecordUpdate(n.ns, RECORD, mine(w, n).run, { [`ok.${step}`]: "1", ...extra });
}

// 기록의 고정 값. 형식이 틀리면 멈춘다(기록은 클러스터의 ConfigMap이라 사람이 고칠 수 있다).
function fixed(r: RestoreRecord): { t1: string; srv: string; img: string; size: string } {
  const v = { t1: r.data.to, srv: r.data.srv, img: r.data.img, size: r.data.size };
  if (!T1.test(v.t1 ?? "") || !SRV.test(v.srv ?? "") || !IMG.test(v.img ?? "") || !SIZE.test(v.size ?? "")) throw new Error("실행 기록의 to·srv·img·size 형식이 아니다");
  return v as { t1: string; srv: string; img: string; size: string };
}

// --to를 UTC "YYYY-MM-DD HH:MM:SS+00"(런북에서 검증된 CNPG targetTime 꼴)으로. 없는 날짜(2월 30일)는 거부한다.
export function normalizeTo(s: string): { t1: string; ms: number } | null {
  const m = /^([0-9]{4})-([0-9]{2})-([0-9]{2})[T ]([0-9]{2}):([0-9]{2}):([0-9]{2})(Z|([+-])([0-9]{2}):?([0-9]{2})?)$/.exec(s);
  if (!m) return null;
  const [y, mo, d, h, mi, se] = m.slice(1, 7).map(Number);
  const offH = Number(m[9] ?? "0");
  const offM = Number(m[10] ?? "0");
  // 오프셋의 시·분도 범위를 본다(+09:60은 없는 시각이다. 받으면 다른 유효한 시각으로 바뀐다, #886 r1 P2-5).
  if (m[7] !== "Z" && (offH > 14 || offM > 59)) return null;
  const off = m[7] === "Z" ? 0 : (m[8] === "-" ? -1 : 1) * (offH * 60 + offM);
  if (mo < 1 || mo > 12 || d < 1 || h > 23 || mi > 59 || se > 59 || Math.abs(off) > 14 * 60) return null;
  const local = Date.UTC(y, mo - 1, d, h, mi, se);
  const back = new Date(local);
  if (back.getUTCFullYear() !== y || back.getUTCMonth() !== mo - 1 || back.getUTCDate() !== d) return null;
  const ms = local - off * 60_000;
  const t1 = new Date(ms).toISOString().replace("T", " ").replace(/\.000Z$/, "+00");
  return { t1, ms };
}

const hasTrue = (o: any, type: string) => (o?.status?.conditions ?? []).some((c: any) => c?.type === type && c?.status === "True");

function srvOf(pg: any): string | null {
  const p = (pg?.spec?.plugins ?? []).find((x: any) => x?.name === PLUGIN);
  const v = p?.parameters?.serverName;
  return typeof v === "string" && SRV.test(v) ? v : null;
}

// 앱이 멈췄는지(restore.md 2절 stopped). 판단은 core도 파괴 단계 앞에서 다시 한다.
function stopped(ctx: ReadCtx | WriteCtx, n: Names): boolean {
  const d = ctx.k8s.get("deployment", n.ns, n.app);
  if (!d) throw new Error(`Deployment ${n.ns}/${n.app}을 읽지 못했다`);
  const live = ctx.k8s.list("pod", n.ns, `homelab.ukyi.app/app=${n.app}`).filter((p) => p?.status?.phase !== "Succeeded" && p?.status?.phase !== "Failed");
  return d.spec?.replicas === 0 && (d.status?.replicas ?? 0) === 0 && live.length === 0;
}

function rolledOut(d: any): boolean {
  const want = d?.spec?.replicas;
  return Number.isInteger(want) && want >= 1 && d?.status?.updatedReplicas === want && d?.status?.readyReplicas === want && (d?.status?.observedGeneration ?? 0) >= (d?.metadata?.generation ?? 0);
}

// 이 실행의 복원 객체(두 ns, 지우는 중 포함). 기록을 지우기 직전에 0개여야 한다.
function runObjects(ctx: ReadCtx | WriteCtx, n: Names, run: string): string[] {
  const sel = `${LABEL}=${run}`;
  const out: string[] = [];
  for (const ns of ["database", n.ns]) for (const kind of ["cluster", "job", "pvc", "pod"] as const) for (const o of ctx.k8s.list(kind, ns, sel)) out.push(`${ns}/${kind}/${o.metadata?.name}`);
  return out;
}

// 기록이 없을 때 남은 복원 흔적. 기록만 지워진 진행 중 복원을 새 실행으로 다시 시작하지 않는다(새 되돌림 사본이 지워진 DB를 담게 된다).
function traces(ctx: ReadCtx | WriteCtx, n: Names): string[] {
  const left: string[] = [];
  if (values(ctx, n.appsFile)?.suspended === true) left.push(`${n.appsFile}에 suspended`);
  for (const ns of ["database", n.ns]) for (const kind of ["cluster", "job", "pvc"] as const) for (const o of ctx.k8s.list(kind, ns, LABEL)) left.push(`${ns}/${kind}/${o.metadata?.name}`);
  return left;
}

function holdPr(id: string, step: Step): Step {
  return {
    ...step,
    id,
    async read(ctx) {
      const o = await step.read(ctx);
      return o.state === "same" && o.wait ? { ...o, hold: o.wait, wait: undefined } : o;
    },
  };
}

// 기록의 pre가 있어야 시작하고 doneKey가 있으면 끝난 PR 단계(멈춤 PR을 재개 뒤 main과 다시 비교하지 않게).
function gatedPr(n: Names, id: string, pre: string[], doneKey: string, step: Step): Step {
  const inner = holdPr(id, step);
  return {
    ...inner,
    async read(ctx) {
      const r = record(ctx, n);
      if (r?.data[doneKey] === "1") return same("끝남");
      if (!r || pre.some((p) => r.data[p] !== "1")) return later(`앞 단계 뒤 ${step.target}`);
      return inner.read(ctx);
    },
  };
}

function suspendEdit(n: Names, on: boolean) {
  return (cur: Record<string, string | null>) => {
    const text = cur[n.appsFile];
    if (text === null) throw new Error(`${n.appsFile}가 없다`);
    return { [n.appsFile]: setTopLevel(text, { suspended: on ? true : undefined }) };
  };
}

// 되돌림 사본을 다룰 도우미 Job(rclone). 약 2시간 뒤 끝나므로 쓰기 전에 살아 있게 한다(데이터 없음, 다시 만들어도 된다).
function ensureHelper(w: WriteCtx, n: Names, run: string): void {
  const ready = w.k8s.list("pod", "database", `job-name=${n.r2Job(run)}`).some((p) => hasTrue(p, "Ready"));
  if (!ready) {
    w.pgRestore.createR2Helper(run);
    if (!w.k8s.waitCondition("job", "database", { jobPods: n.r2Job(run) }, "ready", 300)) throw new Error("되돌림 사본 도우미 Job이 5분 안에 Ready가 되지 않았다");
  }
}

// 같은 실행을 두 프로세스가 함께 진행하지 않게 하는 단계별 lease(#886 r1 P1-1). 기록 ConfigMap은 실행 id만 test하므로 같은 RUN의
// 두 호출을 가르지 못한다. 앱 ns에 고정 이름 Job restore-<run>-lease를 만들어(API 서버의 이름 유일성이 원자적 잠금) 쥐고 단계를
// 실행한 뒤 지운다. suspend: true라 파드는 생기지 않는다. 쥔 뒤 그 단계의 표식을 다시 본다: 앞 프로세스가 그사이 끝냈으면
// 다시 하지 않는다(읽기와 lease 사이에 끝낸 경우). 프로세스가 비정상 종료하면 lease가 남아 다음 실행이 멈춘다(안전한 쪽).
const leaseName = (run: string) => `restore-${run}-lease`;

function leaseJob(n: Names, r: RestoreRecord, step: string): Record<string, unknown> {
  return {
    apiVersion: "batch/v1",
    kind: "Job",
    metadata: { name: leaseName(r.run), namespace: n.ns, labels: { [LABEL]: r.run }, annotations: { "homelab.ukyi.app/lease": `db restore ${step}` } },
    spec: {
      suspend: true,
      backoffLimit: 0,
      template: {
        metadata: { labels: { [LABEL]: r.run } },
        spec: {
          restartPolicy: "Never",
          automountServiceAccountToken: false,
          securityContext: { runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, seccompProfile: { type: "RuntimeDefault" } },
          containers: [{ name: "lease", image: fixed(r).img, command: ["true"], resources: { requests: { cpu: "1m", memory: "1Mi" } }, securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } } }],
        },
      },
    },
  };
}

async function withLease(w: WriteCtx, n: Names, step: string, body: (r: RestoreRecord) => Promise<void>, isDone: (r: RestoreRecord) => boolean = (r) => ok(r, step)): Promise<void> {
  const r0 = mine(w, n);
  try {
    w.k8s.createRestoreObject(n.ns, leaseJob(n, r0, step));
  } catch (e) {
    if (/AlreadyExists|already exists/.test((e as Error).message)) throw new Error(`다른 호출이 이 복원(실행 ${r0.run})을 진행 중이다(Job ${leaseName(r0.run)}). 그 호출이 없는데 남았으면 kubectl -n ${n.ns} delete job ${leaseName(r0.run)} 뒤 다시`);
    throw e;
  }
  let failure: unknown;
  try {
    const r = mine(w, n);
    if (isDone(r)) return;
    await body(r);
  } catch (e) {
    failure = e;
    throw e;
  } finally {
    try {
      w.k8s.deleteRestoreObject(n.ns, "job", leaseName(r0.run), r0.run);
    } catch (e) {
      if (failure === undefined) throw e;
    }
  }
}

// 캐시 Valkey 비우기(5단계 앞). 파드를 지우는 대신 Deployment 업데이트(restore.md 1절 5의 겹침 함정과 같은 이유로 rollout만 쓴다).
function cacheFlush(w: WriteCtx, n: Names, r: RestoreRecord): void {
  if (!ok(r, "verify")) throw new Error("멈춤: 확인(4-6)이 끝나지 않았다");
  w.k8s.rolloutRestart(n.ns, `${n.app}-valkey`);
  if (!w.k8s.rolloutStatus(n.ns, `${n.app}-valkey`, 300)) throw new Error("캐시 Valkey rollout이 끝나지 않았다");
  w.k8s.restoreRecordUpdate(n.ns, RECORD, r.run, { "ok.cacheflush": "1" });
}

function stepOf(n: Names, id: string, target: string, readyDetail: string, todo: string, apply: (w: WriteCtx, r: RestoreRecord) => Promise<void>, alive?: (ctx: ReadCtx | WriteCtx, r: RestoreRecord) => boolean): Step {
  return {
    id,
    target,
    async read(ctx) {
      const r = record(ctx, n);
      if (ok(r, id) && (!alive || alive(ctx, r!))) return same(readyDetail);
      if (!r) return later(todo);
      return { state: "missing", action: "update", detail: todo };
    },
    async apply(w) {
      await withLease(
        w,
        n,
        id,
        async () => {
          const r = begin(w, n, id);
          need(r, id);
          await apply(w, r);
          done(w, n, id);
        },
        (r) => ok(r, id) && (!alive || alive(w, r)),
      );
    },
  };
}

function mainSteps(n: Names, to: { t1: string; ms: number } | null): Step[] {
  const app = n.app;
  return [
    {
      id: "app",
      target: `postgres ${app}`,
      async read(ctx) {
        if (values(ctx, n.dataFile)?.postgres?.enabled !== true) return { state: "missing", action: "none", detail: `data/${app}에 postgres가 없다`, next: `homelab db add ${app}` };
        if (values(ctx, n.appsFile)?.uses?.postgres !== true) return { state: "missing", action: "none", detail: `apps/${app}에 uses.postgres가 없다(앱을 멈출 수 없는 DB는 이 명령이 복원하지 않는다)`, next: "restore.md 2절" };
        const db = ctx.k8s.get("database", "database", app);
        if (db?.status?.applied !== true) return { state: "missing", action: "none", detail: "Database CR이 없거나 applied가 아니다", next: `homelab status ${app}` };
        if (!ctx.k8s.get("deployment", n.ns, app)) return { state: "missing", action: "none", detail: `Deployment ${n.ns}/${app} 없음`, next: `homelab status ${app}` };
        return same("등록됨");
      },
    },
    {
      id: "target-time",
      target: "복원 시각",
      async read(ctx) {
        const r = record(ctx, n);
        if (!to) throw new Error("--to가 없다");
        if (r && r.data.to !== to.t1) return { state: "differs", action: "none", detail: `다른 시각(${r.data.to})으로 진행 중인 복원(실행 ${r.run})이 있다`, next: `같은 --to로 잇거나 homelab db restore ${app} --finish 또는 --abort` };
        const pg = ctx.k8s.get("cluster", "database", "pg");
        const srv = srvOf(pg);
        if (!srv) return { state: "differs", action: "none", detail: "Cluster pg의 serverName을 읽지 못했다", next: "kubectl -n database get cluster pg -o yaml" };
        const bad = (detail: string, next = "--to를 고친다"): Observation => ({ state: "differs", action: "none", detail, next });
        if (!hasTrue(pg, "ContinuousArchiving")) return bad("Cluster pg의 WAL 아카이브(ContinuousArchiving)가 True가 아니다", "kubectl -n database get cluster pg");
        const first = ctx.k8s.get("objectstore", "database", "r2")?.status?.serverRecoveryWindow?.[srv]?.firstRecoverabilityPoint;
        // 복구 범위를 확인할 수 없으면 멈춘다(경고로 넘기지 않는다, #886 r1 P1-3).
        if (typeof first !== "string" || !Number.isFinite(Date.parse(first))) return bad(`ObjectStore r2에 ${srv}의 복구 가능 범위(firstRecoverabilityPoint)가 없다`, "kubectl -n database get objectstore r2 -o yaml");
        if (Date.parse(first) > to.ms) return bad(`복구 가능한 가장 이른 시각(${first})보다 앞이다`);
        const ends = ctx.k8s.list("backup", "database").filter((b) => b?.spec?.cluster?.name === "pg" && b?.status?.phase === "completed").map((b) => Date.parse(b?.status?.stoppedAt ?? "")).filter(Number.isFinite);
        if (!ends.some((t) => t <= to.ms)) return bad(`${to.t1} 앞에 끝난 completed base backup이 없다`);
        // WAL이 T1까지 있다는 근거: T1 뒤에 끝난 completed base backup. pg_backup_stop은 기본으로 끝 WAL이 아카이브될 때까지
        // 기다리므로(wait_for_archive) 그 백업이 끝났으면 그 시각까지의 WAL이 R2에 있다. CNPG 1.30.1 Cluster에는 마지막 아카이브
        // 시각 필드가 없고(lastArchivedWALTime은 없다), pg_stat_archiver를 읽는 어댑터도 아직 없다(REPORT-ops 14절). 그래서
        // 마지막 base backup 뒤의 시각은 확인할 수 없어 멈춘다. 그때는 온디맨드 base backup을 하나 만든 뒤 다시 한다.
        // (경과 시간 기준 "지금 − 5분"은 아카이브가 밀리면 근거가 되지 않아 쓰지 않는다, #886 r1 P1-3.)
        if (!ends.some((t) => t >= to.ms)) return bad(`${to.t1} 뒤에 끝난 completed base backup이 없어 WAL이 그 시각까지 있는지 확인할 수 없다`, "온디맨드 base backup(restore.md 3절 4단계의 Backup)을 만들고 completed가 된 뒤 다시 실행한다");
        return same(`${to.t1}: 앞뒤로 completed base backup, 복구 가능 범위 안`);
      },
    },
    {
      id: "other-runs",
      target: "다른 복원",
      async read(ctx) {
        const r = record(ctx, n);
        // 잠금이 없던 문서로 시작한 다른 실행(런북 lock 블록): 앱 ns의 끝나지 않은 restore-*-db Job·파드
        const others = [
          ...ctx.k8s.list("job", n.ns, LABEL).filter((j) => /^restore-.*-db$/.test(j.metadata?.name ?? "") && j.metadata?.labels?.[LABEL] !== r?.run && !hasTrue(j, "Complete") && !hasTrue(j, "Failed")).map((j) => `job/${j.metadata?.name}`),
          ...ctx.k8s.list("pod", n.ns, LABEL).filter((p) => /^restore-.*-db$/.test(p.metadata?.labels?.["job-name"] ?? "") && p.metadata?.labels?.[LABEL] !== r?.run && p.status?.phase !== "Succeeded" && p.status?.phase !== "Failed").map((p) => `pod/${p.metadata?.name}`),
        ];
        if (others.length) return { state: "differs", action: "none", detail: `다른 실행의 복원 Job·파드가 있다(${others.join(", ")})`, next: `kubectl -n ${n.ns} get configmap,job -L ${LABEL}` };
        if (r) return same(`이 복원(실행 ${r.run})을 잇는다`);
        const left = traces(ctx, n);
        if (left.length) return { state: "differs", action: "none", detail: `실행 기록 없이 복원 흔적이 있다(${left.join(", ")})`, next: "restore.md 2절로 손으로 확인한다" };
        return same("없음");
      },
    },
    {
      id: "lock",
      target: `잠금 ${n.ns}/${RECORD}`,
      async read(ctx) {
        const r = record(ctx, n);
        if (r && r.data.to !== to!.t1) return { state: "differs", action: "none", detail: `잠금의 시각(${r.data.to})이 요청과 다르다(실행 ${r.run})`, next: `같은 --to로 잇거나 homelab db restore ${app} --finish 또는 --abort` };
        if (r && n.inv.run !== null && r.run !== n.inv.run) return { state: "differs", action: "none", detail: `잠금의 실행이 이 호출이 받아들인 것이 아니다(${r.run})`, next: "다시 실행해 상태를 읽는다" };
        return r ? same(`실행 ${r.run}`) : { state: "missing", action: "create", detail: "없음 → 새 실행, 값 고정(T1·serverName·이미지·크기)" };
      },
      async apply(w) {
        // 그사이 생긴 기록이면 만들지 않고 대조만 한다(시각이 다르면 mine이 멈춘다, 같으면 그 실행을 받아들인다).
        if (record(w, n)) {
          mine(w, n);
          return;
        }
        const pg = w.k8s.get("cluster", "database", "pg");
        const v = { to: to!.t1, srv: srvOf(pg) ?? "", img: pg?.spec?.imageName ?? "", size: pg?.spec?.storage?.size ?? "" };
        // 조회한 값을 런북 fit 정규식으로 본 뒤에만 기록한다(core도 매니페스트를 만들 때 다시 본다).
        if (!T1.test(v.to) || !SRV.test(v.srv) || !IMG.test(v.img) || !SIZE.test(v.size)) throw new Error("Cluster pg에서 읽은 serverName·이미지·크기 형식이 아니다");
        const run = newRunId();
        if (runObjects(w, n, run).length) throw new Error("실행 id가 겹친다. 다시 실행한다");
        if (w.k8s.restoreRecordCreate(n.ns, RECORD, run, v) === "exists") throw new Error("그사이 다른 실행이 잠금을 잡았다. 다시 실행해 상태를 읽는다");
        n.inv.run = run;
      },
    },
    stepOf(n, "predump", "되돌림 사본(1단계)", "R2 pgdump/<앱>/pre-restore-<실행>.dump 끝까지 읽힘", "지금 DB 덤프 → R2, 끝까지 읽기(한 실행에 한 번, 덮어쓰지 않음)", async (w, r) => {
      ensureHelper(w, n, r.run);
      // 같은 실행 재시도면 이미 있는 사본을 검증만 한다. dropped 뒤에는 core가 새로 만들기를 거부한다.
      if (!w.pgRestore.r2DumpExists(n.app, r.run)) await w.pgRestore.dumpToR2(n.app, r.run);
      await w.pgRestore.r2DumpReadable(n.app, r.run);
    }),
    stepOf(n, "tmp", "임시 클러스터(2단계)", "T1로 복구, Ready, 주 파드 고정", "임시 Cluster → T1로 복구, Ready 대기(최대 30분)", async (w, r) => {
      const v = fixed(r);
      w.pgRestore.createTmpCluster(r.run, v);
      if (!w.k8s.waitCondition("cluster", "database", { name: n.tmp(r.run) }, "Ready", 1800)) throw new Error(`임시 클러스터가 30분 안에 Ready가 되지 않았다. homelab db restore ${n.app} --abort 뒤 새 실행으로(같은 실행의 임시 클러스터는 다시 쓰지 않는다)`);
      w.pgRestore.pinTmpPrimary(n.app, r.run);
      if (w.pgRestore.tmpDbCount(r.run, n.app) !== 1) throw new Error(`임시 클러스터에 DB ${n.app}이 없다(T1에 DB가 없었다?)`);
    }),
    stepOf(
      n,
      "auth",
      "앱 역할 복원 Job(4-1)",
      "Job Ready, 앱 역할로 접속",
      "앱 ns 복원 Job → 앱 역할 접속 확인",
      async (w, r) => {
        w.pgRestore.createDbJob(n.app, r.run, fixed(r).img);
        if (!w.k8s.waitCondition("job", n.ns, { jobPods: n.dbJob(r.run) }, "ready", 300)) throw new Error("복원 Job이 5분 안에 Ready가 되지 않았다(비밀번호에 줄바꿈이 있으면 시작하지 않는다)");
        w.pgRestore.jobAuth(n.app, r.run, w.pgRestore.dbCount(n.app) === 1 ? "app" : "postgres");
      },
      // Job은 약 2시간 뒤 끝난다. 복원이 끝나기(4-6) 전에 끝났으면 표식이 있어도 다시 만든다(그러면 4-2도 다시 돈다).
      // 4-6 뒤에는 Job이 필요 없고 정리가 지운다(그때 다시 만들면 끝난 복원을 처음부터 다시 돈다).
      (ctx, r) => ok(r, "verify") || ctx.k8s.list("pod", n.ns, `job-name=${n.dbJob(r.run)}`).some((p) => hasTrue(p, "Ready")),
    ),
    stepOf(n, "list", "목록·확장·ACL(4-2)", "검증해 기록에 고정함", "덤프 목록·확장·ACL SQL을 만들고 검증해 고정(DB는 그대로)", async (w, r) => {
      await w.pgRestore.prepareInputs(n.app, r.run);
    }),
    gatedPr(
      n,
      "pr-suspend",
      ["ok.list"],
      "ok.suspended",
      prStep({
        command: "db restore",
        app,
        title: `db restore ${app}: 앱 멈춤`,
        body: `\`homelab db restore ${app}\` 3단계(restore.md 2절). \`suspended: true\`: replicas 0, 마이그레이션 Job 없음. 병합 뒤 같은 명령이 DB를 T1로 되돌린다(지금 DB는 되돌림 사본으로 R2에 있다).`,
        files: [n.appsFile],
        edit: suspendEdit(n, true),
      }),
    ),
    {
      id: "suspended",
      target: `앱 ${app} 멈춤(3단계)`,
      async read(ctx) {
        const r = record(ctx, n);
        if (ok(r, "suspended")) return same("멈춤 확인");
        if (!r) return later("멈춤 PR 병합 뒤 확인");
        if (values(ctx, n.appsFile)?.suspended !== true) return same("PR 대기", { hold: "앱 멈춤 PR 병합 대기" });
        return stopped(ctx, n) ? { state: "differs", action: "update", detail: "replicas 0, 앱 파드 없음 → 기록" } : same("main에 suspended", { hold: "앱 멈춤 반영 대기(Argo CD)" });
      },
      async apply(w) {
        await withLease(w, n, "suspended", async () => {
          begin(w, n, "suspended");
          if (!stopped(w, n)) throw new Error("앱이 멈춰 있지 않다");
          done(w, n, "suspended");
        });
      },
    },
    stepOf(
      n,
      "db",
      "DB 다시 만들기(4-3)",
      "지우고 다시 만듦, 확장 만듦",
      "앞 확인이 모두 끝나고 되돌림 사본이 R2에 있으면 지금 DB를 지우고 다시 만든다",
      async (w, r) => {
      // core는 잠금·앱 멈춤·입력·원본·덤프 읽기를 다시 본다. 되돌림 사본이 지금도 있는지는 여기서 본다(DROP 뒤 되돌릴 길).
      // 앱 멈춤은 표식이 아니라 지금 클러스터로 다시 본다(표식 뒤 다른 PR로 다시 떴을 수 있다. core도 한 번 더 본다).
      if (!stopped(w, n)) throw new Error("멈춤: 앱이 멈춰 있지 않다. DB를 지우지 않는다");
      ensureHelper(w, n, r.run);
      if (!w.pgRestore.r2DumpExists(n.app, r.run)) throw new Error("멈춤: 되돌림 사본이 R2에 없다. DB를 지우지 않는다");
      if (!w.pgRestore.inputsOk(n.app, r.run)) throw new Error("멈춤: 4-2 입력이 바뀌었다. 4-2를 다시 돈다");
      await w.pgRestore.recreateDatabase(n.app, r.run, fixed(r));
      w.pgRestore.createExtensions(n.app, r.run);
      w.k8s.restoreRecordUpdate(n.ns, RECORD, r.run, { "try.main": null });
    },
    // 본 복원(4-4)을 한 번 시작했는데 끝 표식이 없으면 DB가 일부만 복원됐을 수 있다(pg_restore는 문장마다 커밋한다). 그때는
    // 표식이 있어도 이 단계부터 다시 한다: 빈 DB로 다시 만들고 본 복원을 처음부터(#886 r1 P2-4). 복원은 됐는데 표식만 못 쓴
    // 경우도 같은 길로 간다(다시 하면 같은 결과다).
    (_ctx, r) => ok(r, "main") || r.data["try.main"] !== "1",
    ),
    stepOf(n, "main", "본 복원(4-4)", "앱 역할로 넣음", "임시 클러스터 덤프 → 앱 역할 pg_restore(--no-owner --no-privileges)", async (w, r) => {
      // 시작 표시를 먼저 남긴다. 실패하면 다음 실행이 4-3(빈 DB로 다시 만들기)부터 한다.
      w.k8s.restoreRecordUpdate(n.ns, RECORD, r.run, { "try.main": "1" });
      await w.pgRestore.restoreMain(n.app, r.run);
    }),
    stepOf(n, "acl", "ACL 복원·대조(4-5)", "원본과 같음", "ACL을 넣고 임시 클러스터와 대조", async (w, r) => {
      await w.pgRestore.restoreAcl(n.app, r.run);
      const c = w.pgRestore.aclCompare(n.app, r.run);
      if (!c.same) throw new Error(`ACL이 원본과 다르다(${c.diff.length}줄): ${c.diff.slice(0, 5).join(" | ")}. 원본대로 GRANT·REVOKE한 뒤 다시`);
    }),
    stepOf(n, "verify", "확인(4-6)", "Database applied, 역할 승격 없음", "Database CR applied, 앱 역할 rolsuper 등 모두 f", async (w) => {
      if (w.k8s.get("database", "database", n.app)?.status?.applied !== true) throw new Error("Database CR이 applied가 아니다");
      const flags = w.pgRestore.roleFlags(n.app);
      if (flags !== "f|f|f|f|f") throw new Error(`앱 역할 권한이 이상하다(${flags})`);
    }),
    {
      id: "cache-flush",
      target: `캐시 Valkey ${app}-valkey`,
      async read(ctx) {
        const r = record(ctx, n);
        if (values(ctx, n.appsFile)?.cache?.enabled !== true) return same("캐시 없음");
        if (r?.data["ok.cacheflush"] === "1") return same("비움");
        if (!ok(r, "verify")) return later("확인 뒤 다시 띄워 비움");
        return { state: "missing", action: "update", detail: "다시 띄워 비움(emptyDir, T1 뒤 값이 남지 않게)" };
      },
      async apply(w) {
        await withLease(w, n, "cacheflush", async (r) => cacheFlush(w, n, r));
      },
    },
    gatedPr(
      n,
      "pr-resume",
      ["ok.verify"],
      "ok.resumed",
      prStep({
        command: "db restore resume",
        app,
        title: `db restore ${app}: 앱 재개`,
        body: `\`homelab db restore ${app}\` 5단계(restore.md 2절). \`suspended\` 줄을 지운다. 마이그레이션 Job이 다시 돌고 앱이 뜬다. DB는 T1로 되돌렸고 ACL·역할 확인을 마쳤다.`,
        files: [n.appsFile],
        edit: suspendEdit(n, false),
      }),
    ),
    {
      id: "running",
      target: `앱 ${app} 재개`,
      async read(ctx) {
        const r = record(ctx, n);
        if (r?.data["ok.resumed"] === "1") return same("떠 있음");
        if (!ok(r, "verify")) return later("재개 PR 병합 뒤 확인");
        if (values(ctx, n.appsFile)?.suspended === true) return same("PR 대기", { hold: "앱 재개 PR 병합 대기" });
        const d = ctx.k8s.get("deployment", n.ns, app);
        return rolledOut(d) ? { state: "differs", action: "update", detail: "앱 Ready → 기록" } : same("main에서 suspended 지움", { hold: "앱 재개 반영 대기(Argo CD)" });
      },
      async apply(w) {
        await withLease(w, n, "resumed", async (r) => w.k8s.restoreRecordUpdate(n.ns, RECORD, r.run, { "ok.resumed": "1" }));
      },
    },
    {
      id: "cleanup",
      target: "이 실행의 복원 객체",
      async read(ctx) {
        const r = record(ctx, n);
        if (r?.data["ok.cleanup"] === "1") return same("0개(잠금만 남음)");
        if (r?.data["ok.resumed"] !== "1") return later("임시 Cluster·PVC·도우미 Job 둘 지우고 0개 확인");
        return { state: "missing", action: "delete", detail: "임시 Cluster·PVC·도우미 Job 둘 지우고 0개 확인" };
      },
      async apply(w) {
        await withLease(w, n, "cleanup", async (r) => cleanup(w, n, r));
      },
    },
  ];
}

// 6단계. lease Job도 이 실행의 라벨이라 deleteRestoreObjects가 함께 지운다(마지막 단계라 괜찮다).
function cleanup(w: WriteCtx, n: Names, r: RestoreRecord): void {
  if (r.data["ok.resumed"] !== "1") throw new Error("멈춤: 앱 재개 전에는 정리하지 않는다");
  // Job은 파드까지(foreground), 그다음 임시 Cluster와 PVC. 잠금은 남긴다(--finish).
  w.k8s.deleteRestoreObject(n.ns, "job", n.dbJob(r.run), r.run);
  w.k8s.deleteRestoreObject("database", "job", n.r2Job(r.run), r.run);
  w.k8s.deleteRestoreObjects("database", r.run);
  w.k8s.deleteRestoreObjects(n.ns, r.run);
  const left = runObjects(w, n, r.run);
  if (left.length) throw new Error(`이 실행의 객체가 남았다(${left.join(", ")}). 없어진 뒤 다시`);
  w.k8s.restoreRecordUpdate(n.ns, RECORD, r.run, { "ok.cleanup": "1" });
}

function finishSteps(n: Names): Step[] {
  return [
    {
      id: "done",
      target: "복원 결과",
      async read(ctx) {
        const r = record(ctx, n);
        if (!r) return same("기록 없음");
        if (r.data["ok.cleanup"] !== "1") return { state: "differs", action: "none", detail: `실행 ${r.run}이 끝나지 않았다`, next: `homelab db restore ${n.app} --to '<같은 시각>' --apply로 잇거나 --abort` };
        const left = runObjects(ctx, n, r.run);
        if (left.length) return { state: "differs", action: "none", detail: `실행 ${r.run}의 객체가 남아 있다(${left.join(", ")})`, next: "없어진 뒤 다시" };
        return same(`실행 ${r.run} 끝남. 되돌림 사본 r2:${r.data.bucket ?? "<버킷>"}/pgdump/${n.app}/pre-restore-${r.run}.dump는 확인 뒤 손으로 지운다`);
      },
    },
    {
      id: "lock-removed",
      target: `잠금 ${n.ns}/${RECORD}`,
      async read(ctx) {
        const r = record(ctx, n);
        return r ? { state: "differs", action: "delete", detail: `실행 ${r.run} 잠금 지움` } : same("없음");
      },
      async apply(w) {
        const r = mine(w, n);
        // 잠금은 이 실행의 파드가 모두 없어진 것을 지금 클러스터에서 본 뒤에만 지운다(restore.md 2절 6).
        if (r.data["ok.cleanup"] !== "1") throw new Error(`실행 ${r.run}이 끝나지 않았다`);
        const left = runObjects(w, n, r.run);
        if (left.length) throw new Error(`실행 ${r.run}의 객체가 남아 있다(${left.join(", ")}). 잠금은 그대로다`);
        w.k8s.restoreRecordDelete(n.ns, RECORD, r.run);
      },
    },
  ];
}

function abortObjects(w: WriteCtx, n: Names, r: RestoreRecord): void {
  if (r.data.dropped === "1") throw new Error("DB를 지운 뒤라 그만두지 않는다");
  w.k8s.deleteRestoreObject(n.ns, "job", n.dbJob(r.run), r.run);
  w.k8s.deleteRestoreObject("database", "job", n.r2Job(r.run), r.run);
  w.k8s.deleteRestoreObjects("database", r.run);
  w.k8s.deleteRestoreObjects(n.ns, r.run);
}

// DB를 지우기 전(dropped 없음)에만 그만둔다. 그 뒤에는 지금 DB가 비었거나 일부만 복원돼 끝까지 잇는다.
function abortSteps(n: Names): Step[] {
  const app = n.app;
  return [
    {
      id: "abortable",
      target: "그만둘 수 있는지",
      async read(ctx) {
        const r = record(ctx, n);
        if (!r) {
          const left = traces(ctx, n);
          if (left.length) return { state: "differs", action: "none", detail: `실행 기록 없이 복원 흔적이 있다(${left.join(", ")})`, next: "DB가 지워졌는지 손으로 확인한다(restore.md 2절)" };
          return same("기록 없음, 복원 흔적 없음");
        }
        if (r.data.dropped === "1") return { state: "differs", action: "none", detail: "DB를 지운 뒤라 그만두지 않는다(지금 DB가 비었거나 일부만 복원됐다)", next: `homelab db restore ${app} --to '${r.data.to}' --apply로 잇거나, 되돌림 사본 pgdump/${app}/pre-restore-${r.run}.dump로 손 복원` };
        return same(`실행 ${r.run}: DB를 지우기 전`);
      },
    },
    {
      id: "objects-removed",
      target: "이 실행의 복원 객체",
      async read(ctx) {
        const r = record(ctx, n);
        if (!r) return same("기록 없음");
        const left = runObjects(ctx, n, r.run);
        return left.length ? { state: "differs", action: "delete", detail: `${left.length}개 지움` } : same("0개");
      },
      async apply(w) {
        // 진행 중인 다른 호출이 있으면 그만두지 않는다(lease). 지우는 객체에 lease Job도 들어간다.
        await withLease(w, n, "abort", async (r) => abortObjects(w, n, r));
      },
    },
    holdPr(
      "pr-resume",
      prStep({
        command: "db restore abort",
        app,
        title: `db restore ${app}: 그만두고 앱 재개`,
        body: `\`homelab db restore ${app} --abort\`: DB를 지우기 전에 그만둔다. \`suspended\` 줄을 지운다(DB는 바뀌지 않았다).`,
        files: [n.appsFile],
        edit: suspendEdit(n, false),
      }),
    ),
    {
      id: "lock-removed",
      target: `잠금 ${n.ns}/${RECORD}`,
      async read(ctx) {
        const r = record(ctx, n);
        return r ? { state: "differs", action: "delete", detail: `실행 ${r.run} 잠금 지움` } : same("없음");
      },
      async apply(w) {
        const r = mine(w, n);
        if (r.data.dropped === "1") throw new Error("DB를 지운 뒤라 그만두지 않는다");
        const left = runObjects(w, n, r.run);
        if (left.length) throw new Error(`이 실행의 객체가 남아 있다(${left.join(", ")}). 잠금은 그대로다`);
        w.k8s.restoreRecordDelete(n.ns, RECORD, r.run);
      },
    },
  ];
}

export default defineCommand({
  path: ["db", "restore"],
  summary: "앱 하나의 PostgreSQL을 시각 T1로 복원(C.5.7). 끝나면 --finish",
  kind: "change",
  args: [{ name: "app", required: true, help: "앱 이름", pattern: APP_NAME }],
  flags: [
    { name: "to", kind: "value", valueName: "시각", pattern: TO, help: "되돌릴 시각, 오프셋 필수(예 2026-11-02T10:00:00+09:00)" },
    { name: "finish", kind: "bool", help: "끝난 복원의 잠금을 지운다" },
    { name: "abort", kind: "bool", help: "DB를 지우기 전이면 그만두고 앱을 재개한다" },
  ],
  async run(ctx, input) {
    const app = input.args.app as string;
    const finish = input.flags.finish === true;
    const abort = input.flags.abort === true;
    const toFlag = input.flags.to as string | undefined;
    if (finish && abort) throw new UsageError("--finish와 --abort는 함께 쓰지 않는다");
    if ((finish || abort) && toFlag !== undefined) throw new UsageError("--finish·--abort에는 --to를 쓰지 않는다");
    if (!finish && !abort && toFlag === undefined) throw new UsageError("--to <시각>이 필요하다(오프셋 필수, 예 2026-11-02T10:00:00+09:00)");
    const to = toFlag === undefined ? null : normalizeTo(toFlag);
    if (toFlag !== undefined && !to) throw new UsageError("--to: 없는 날짜·시각이다");
    const n = namesOf(app, to?.t1 ?? null);
    return ctx.engine({
      command: "db restore",
      app,
      steps: finish ? finishSteps(n) : abort ? abortSteps(n) : mainSteps(n, to),
      notes: finish ? [] : abort ? [`열린 PR(cli/db-restore-${app})이 있으면 닫는다(병합하지 않는다).`] : [`DB 다시 만들기 단계에서 지금 DB를 지운다. 되돌림 사본은 1단계, 앞 확인이 하나라도 없으면 지우지 않는다.`, "앱 멈춤·재개 PR마다 병합을 기다리며 멈춘다(종료 코드 3). 같은 명령을 다시 치면 잇는다."],
      next: finish || abort ? undefined : (status) => (status === "done" || status === "same" ? `homelab db restore ${app} --finish` : KEEP),
    });
  },
});
