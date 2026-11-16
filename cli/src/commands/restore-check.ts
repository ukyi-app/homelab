// homelab db restore-check: 최신 백업 복원 시험. 앱에는 손대지 않는다(설계 C.7, C.5.7 2단계와 같은 임시 Cluster).
//
// R2의 base backup과 WAL로 임시 Cluster를 지금 − 10분까지 되감고, Database CR마다 그 DB가 있는지 본 뒤 지우고 0개를 확인한다.
// 지금 − 10분: archive_timeout(5분)보다 넉넉히 앞이라 WAL까지 시험한다. 아카이브가 밀렸으면 Ready가 되지 않아 실패로 드러난다.
// 실행 기록은 database ns의 ConfigMap restore-check. 중간에 멈추면 같은 명령이 그 실행을 잇고, 끝나면 기록까지 지운다
// (시험이라 다시 치면 새 시험이다).
// 결과는 Cluster pg의 annotation 두 키에 남긴다(봇 브리핑이 읽는다). 통과는 정리 0개 확인 뒤·실행 기록 삭제 전에
// 쓰고, 그 기록이 실패하면 완료가 아니다(실행 기록이 남아 다시 치면 정리부터 잇는다). 실패는 DB 확인 실패와 --abort만 남긴다.
import { defineCommand, type Observation, type ReadCtx, type RestoreCheckMark, type RestoreRecord, type Step, type WriteCtx } from "../core/command";
import { newRunId } from "../core/names";

const NS = "database";
const RECORD = "restore-check";
const LABEL = "homelab.ukyi.app/restore";
// 런북 fit 정규식(restore.md 2절 vars). core pgrestore.ts에도 같은 것이 있고 매니페스트를 만들 때 다시 본다(명령은 core 내부를 import하지 못한다).
const T1 = /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}([+-][0-9]{2}(:?[0-9]{2})?)?$/;
const SRV = /^[a-z0-9-]+$/;
const IMG = /^[a-z0-9./_-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$/;
const SIZE = /^[0-9]+(Mi|Gi|Ti)$/;
const PLUGIN = "barman-cloud.cloudnative-pg.io";
const LOOKBACK_MS = 10 * 60_000;
const BACKUP_FRESH_MS = 26 * 3600_000;

const same = (detail: string, extra: Partial<Observation> = {}): Observation => ({ state: "same", action: "none", detail, ...extra });
const hasTrue = (o: any, type: string) => (o?.status?.conditions ?? []).some((c: any) => c?.type === type && c?.status === "True");
const record = (ctx: ReadCtx | WriteCtx): RestoreRecord | null => ctx.k8s.restoreRecord(NS, RECORD);
const tmpName = (run: string) => `pg-restore-${run}`;
// 실행 기록의 시각(T1 꼴, lock이 늘 +00으로 만든다) → 결과 기록의 RFC3339 UTC.
function utc(t1: string | undefined): string {
  const m = /^([0-9]{4}-[0-9]{2}-[0-9]{2}) ([0-9]{2}:[0-9]{2}:[0-9]{2})\+00$/.exec(t1 ?? "");
  if (!m) throw new Error("실행 기록의 복구 시각이 UTC(+00) 꼴이 아니다");
  return `${m[1]}T${m[2]}Z`;
}
const nowUtc = () => new Date().toISOString().replace(/\.[0-9]{3}Z$/, "Z");
const dbCount = (r: RestoreRecord) => (r.data.dbs ?? "").split(",").filter((x) => x && x !== "-").length;
// cluster: 시험을 시작할 때의 Cluster pg uid(실행 기록 pguid). 결과는 그 Cluster에만 귀속한다.
type Attempt = { run: string; to: string | undefined; srv: string | undefined; cluster: string | undefined };
const UID = /^[0-9a-f-]{8,64}$/;
const attempt = (r: RestoreRecord): Attempt => ({ run: r.run, to: r.data.to, srv: r.data.srv, cluster: r.data.pguid });
// 지금 Cluster pg가 시험을 시작한 그 객체인지. 다시 만들어졌으면 이 시험의 결과는 새 Cluster에 쓰지 않는다.
const samePg = (ctx: ReadCtx | WriteCtx, a: Attempt) => a.cluster !== undefined && ctx.k8s.get("cluster", NS, "pg")?.metadata?.uid === a.cluster;

function mark(w: WriteCtx, a: Attempt, result: "pass" | "fail", dbs: number, reason?: RestoreCheckMark["reason"]): void {
  w.k8s.restoreCheckMark({ run: a.run, result, at: nowUtc(), target: utc(a.to), server: a.srv ?? "", dbs, cluster: a.cluster ?? "", ...(reason ? { reason } : {}) });
}

// DB 확인 실패: 실패를 기록하고 멈춘다. 기록마저 실패하면 두 원인을 함께 보인다(확인 실패를 가리지 않게).
function failCheck(w: WriteCtx, a: Attempt, dbs: number, reason: "missing_db" | "no_db", message: string): never {
  try {
    mark(w, a, "fail", dbs, reason);
  } catch (e) {
    throw new Error(`${message} (실패 결과 기록도 못 남겼다: ${(e as Error).message})`);
  }
  throw new Error(message);
}
// 키 이름은 core(kubectl.ts RESTORE_CHECK_LAST)와 같다. 명령은 core 내부를 import하지 못해 여기 다시 둔다(읽기만 한다).
const LAST_KEY = "homelab.ukyi.app/restore-check-last";
const NO_DB = "확인할 Database CR(cluster pg)이 0개다. 복원을 확인할 DB가 없어 통과로 치지 않는다";

function mine(w: WriteCtx): RestoreRecord {
  const r = record(w);
  if (!r) throw new Error(`실행 기록 ${NS}/${RECORD}이 없다`);
  return r;
}

function srvOf(pg: any): string | null {
  const v = (pg?.spec?.plugins ?? []).find((x: any) => x?.name === PLUGIN)?.parameters?.serverName;
  return typeof v === "string" && SRV.test(v) ? v : null;
}

function databases(ctx: ReadCtx | WriteCtx): string[] {
  return ctx.k8s
    .list("database", NS)
    .filter((d) => d?.spec?.cluster?.name === "pg")
    .map((d) => d?.spec?.name)
    .filter((x): x is string => typeof x === "string")
    .sort();
}

function runObjects(ctx: ReadCtx | WriteCtx, run: string): string[] {
  const out: string[] = [];
  for (const kind of ["cluster", "job", "pvc", "pod"] as const) for (const o of ctx.k8s.list(kind, NS, `${LABEL}=${run}`)) out.push(`${kind}/${o.metadata?.name}`);
  return out;
}

// created: 이 호출이 기록(과 임시 Cluster)을 새로 만들었는지. 앞 호출이 남긴 미완료 시험은 단계와 상관없이 이어받지 않는다
// (Ready 뒤 DB 확인에서 실패한 경우도. 그사이 바뀐 Cluster를 이번 백업의 복구로 볼 수 없다).
function stepsFor(inv: { created: boolean }): Step[] {
  const fresh = () => {
    if (!inv.created) throw new Error("멈춤: 앞 호출이 남긴 시험이다. 다시 쓰지 않는다: homelab db restore-check --abort 뒤 새 시험");
  };
  return [
    {
      id: "previous",
      target: "앞 시험",
      async read(ctx) {
        const r = record(ctx);
        if (!r || inv.created) return same(r ? "이 호출의 시험" : "없음");
        // 정리만 남은 시험(내용 확인까지 끝남)은 정리를 이어 간다. 그 밖에는 버리고 새로.
        if (r.data["ok.contents"] === "1") return same(`실행 ${r.run}: 확인은 끝났고 정리만 남음`);
        return { state: "differs", action: "none", detail: `앞 호출이 남긴 미완료 시험(실행 ${r.run})이 있다. 그 임시 Cluster를 다시 쓰지 않는다`, next: "homelab db restore-check --abort 뒤 다시" };
      },
    },
    {
      id: "backups",
      target: "백업 상태",
      async read(ctx) {
        const pg = ctx.k8s.get("cluster", NS, "pg");
        if (!srvOf(pg)) return { state: "differs", action: "none", detail: "Cluster pg의 serverName을 읽지 못했다", next: "kubectl -n database get cluster pg -o yaml" };
        if (!hasTrue(pg, "ContinuousArchiving")) return { state: "differs", action: "none", detail: "WAL 아카이브(ContinuousArchiving)가 True가 아니다", next: "kubectl -n database get cluster pg" };
        const done = ctx.k8s.list("backup", NS).filter((b) => b?.spec?.cluster?.name === "pg" && b?.status?.phase === "completed").map((b) => Date.parse(b?.status?.stoppedAt ?? "")).filter(Number.isFinite);
        const last = Math.max(-Infinity, ...done);
        if (!Number.isFinite(last)) return { state: "differs", action: "none", detail: "completed base backup이 없다", next: "kubectl -n database get backups" };
        if (Date.now() - last > BACKUP_FRESH_MS) return { state: "differs", action: "none", detail: `마지막 completed base backup이 26시간보다 오래됐다(${new Date(last).toISOString()})`, next: "kubectl -n database get scheduledbackups,backups" };
        return same(`마지막 base backup ${new Date(last).toISOString()}`);
      },
    },
    {
      id: "lock",
      target: `실행 기록 ${NS}/${RECORD}`,
      async read(ctx) {
        const r = record(ctx);
        return r ? same(`실행 ${r.run}을 잇는다(시각 ${r.data.to})`) : { state: "missing", action: "create", detail: "새 시험(지금 − 10분까지 복구)" };
      },
      async apply(w) {
        const pg = w.k8s.get("cluster", NS, "pg");
        const t1 = new Date(Date.now() - LOOKBACK_MS).toISOString().replace("T", " ").replace(/\.[0-9]{3}Z$/, "+00");
        const v = { to: t1, srv: srvOf(pg) ?? "", img: pg?.spec?.imageName ?? "", size: pg?.spec?.storage?.size ?? "", pguid: pg?.metadata?.uid ?? "" };
        if (!T1.test(v.to) || !SRV.test(v.srv) || !IMG.test(v.img) || !SIZE.test(v.size) || !UID.test(v.pguid)) throw new Error("Cluster pg에서 읽은 serverName·이미지·크기·uid 형식이 아니다");
        const run = newRunId();
        // 확인할 DB가 없으면 임시 Cluster를 만들기 전에 실패로 남기고 멈춘다(30분 복구를 헛돌지 않는다. 남는 객체·기록 없음).
        if (!databases(w).length) failCheck(w, { run, to: v.to, srv: v.srv, cluster: v.pguid }, 0, "no_db", NO_DB);
        if (w.k8s.restoreRecordCreate(NS, RECORD, run, v) === "exists") throw new Error("그사이 다른 시험이 기록을 만들었다. 다시 실행해 상태를 읽는다");
        inv.created = true;
      },
    },
    {
      id: "tmp",
      target: "임시 클러스터",
      async read(ctx) {
        const r = record(ctx);
        if (r?.data["ok.tmp"] === "1") return same("복구됨, Ready");
        return { state: "missing", action: "create", detail: "R2에서 복구, Ready 대기(최대 30분)" };
      },
      async apply(w) {
        fresh();
        const r = mine(w);
        const v = { t1: r.data.to, srv: r.data.srv, img: r.data.img, size: r.data.size };
        if (!T1.test(v.t1 ?? "") || !SRV.test(v.srv ?? "") || !IMG.test(v.img ?? "") || !SIZE.test(v.size ?? "")) throw new Error("실행 기록의 값 형식이 아니다");
        // 같은 실행의 임시 클러스터가 이미 있으면(앞 시도) 다시 쓰지 않는다. 그사이 사람이 다른 원본으로 다시 만들거나 바꿨을 수 있어
        // Ready·DB 이름만으로는 이번 백업의 복구라고 볼 수 없다(restore.md 2절 2단계). --abort로 정리하고 새 시험으로.
        if (w.k8s.get("cluster", NS, tmpName(r.run))) throw new Error(`임시 클러스터 ${tmpName(r.run)}가 이미 있다(앞 시도). 다시 쓰지 않는다: homelab db restore-check --abort 뒤 새 시험`);
        w.pgRestore.createTmpCluster(r.run, v as { t1: string; srv: string; img: string; size: string });
        if (!w.k8s.waitCondition("cluster", NS, { name: tmpName(r.run) }, "Ready", 1800)) throw new Error("임시 클러스터가 30분 안에 Ready가 되지 않았다(복구 실패: WAL 아카이브·base backup을 본다. 버리려면 --abort)");
        w.k8s.restoreRecordUpdate(NS, RECORD, r.run, { "ok.tmp": "1" });
      },
    },
    {
      id: "contents",
      target: "앱 DB",
      async read(ctx) {
        const r = record(ctx);
        if (r?.data["ok.contents"] === "1") return same(`DB ${r.data.dbs ?? ""} 있음`);
        const n = databases(ctx).length;
        return { state: "missing", action: "update", detail: n ? `Database CR ${n}개의 DB가 임시 클러스터에 있는지(없으면 실패 기록)` : "Database CR 0개: 실패(no_db)로 기록하고 멈춘다" };
      },
      async apply(w) {
        fresh();
        const r = mine(w);
        if (r.data["ok.tmp"] !== "1") throw new Error("멈춤: 임시 클러스터 확인이 끝나지 않았다");
        const dbs = databases(w);
        // lock 뒤 Database CR이 모두 지워졌어도 통과로 치지 않는다.
        if (!dbs.length) failCheck(w, attempt(r), 0, "no_db", NO_DB);
        const missing = dbs.filter((db) => w.pgRestore.tmpDbCount(r.run, db) !== 1);
        if (missing.length) failCheck(w, attempt(r), dbs.length, "missing_db", `임시 클러스터에 없는 DB: ${missing.join(", ")}`);
        w.k8s.restoreRecordUpdate(NS, RECORD, r.run, { "ok.contents": "1", dbs: dbs.join(",") || "-" });
      },
    },
    {
      id: "cleanup",
      target: "이 시험의 객체와 기록",
      async read(ctx) {
        const r = record(ctx);
        return r ? { state: "missing", action: "delete", detail: "임시 Cluster·PVC 지우고 0개 확인 → Cluster pg에 통과 기록 → 실행 기록 지움" } : same("없음");
      },
      async apply(w) {
        const r = mine(w);
        if (r.data["ok.contents"] !== "1") throw new Error("멈춤: 시험이 끝나지 않았다(임시 클러스터를 남겨 원인을 본다. 버리려면 --abort)");
        // 옛 CLI가 DB 0개로 확인을 끝낸 기록(dbs "-")은 통과로 남기지 않는다.
        const n = dbCount(r);
        if (!n) throw new Error("멈춤: 확인한 DB가 0개인 시험은 통과로 기록하지 않는다. 버리려면 --abort");
        // 정리 전에 본다: 시험 시작 Cluster가 아니면(다시 만들어짐, 또는 uid를 남기지 않은 옛 실행 기록) 통과로 남길 곳이 없다.
        if (!samePg(w, attempt(r))) throw new Error("멈춤: Cluster pg가 시험을 시작한 그 객체가 아니다(다시 만들어졌거나 옛 실행 기록). 이 시험은 통과로 남기지 않는다. 버리려면 --abort");
        w.k8s.deleteRestoreObjects(NS, r.run);
        const left = runObjects(w, r.run);
        if (left.length) throw new Error(`이 시험의 객체가 남았다(${left.join(", ")}). 기록은 그대로다`);
        // 통과 기록은 정리 0개를 본 뒤, 실행 기록을 지우기 전이다. 기록이 실패하면 여기서 멈춰 실행 기록이 남고 재실행이 이어 쓴다.
        mark(w, attempt(r), "pass", n);
        w.k8s.restoreRecordDelete(NS, RECORD, r.run);
      },
    },
  ];
}

// 이 실행의 실패가 이미 last에 있는지(missing_db·no_db로 멈춘 시험). 읽지 못하거나 모양이 다르면 없는 것으로 본다(aborted를 쓴다).
function failedAlready(ctx: ReadCtx | WriteCtx, run: string): boolean {
  const raw = ctx.k8s.get("cluster", NS, "pg")?.metadata?.annotations?.[LAST_KEY];
  if (typeof raw !== "string") return false;
  try {
    const v = JSON.parse(raw);
    return v?.run === run && v?.result === "fail";
  } catch {
    return false;
  }
}

// 멈춘 시험을 버린다: 이 시험의 객체를 지우고 0개를 본 뒤 실패(aborted)를 기록하고 실행 기록을 지운다
// (앱에는 쓰지 않고 pg에는 결과 annotation만 쓰니 언제든 된다). 결과 기록이 실패하면 실행 기록을 남겨 다시 --abort로 잇는다.
// 같은 실행의 실패가 이미 last에 있으면 덮지 않는다(missing_db·no_db 이유를 aborted로 지우지 않게).
const abortSteps: Step[] = [
  {
    id: "abort",
    target: "이 시험의 객체와 기록",
    async read(ctx) {
      const r = record(ctx);
      if (!r) return same("기록 없음");
      const rec = !samePg(ctx, attempt(r)) ? "Cluster pg가 시험 시작 때와 달라 결과 기록 없음"
        : failedAlready(ctx, r.run) ? "이 실행의 실패 기록은 그대로 둠" : "Cluster pg에 실패(aborted) 기록";
      return { state: "differs", action: "delete", detail: `실행 ${r.run}: 임시 Cluster·PVC 지우고 0개 확인 → ${rec} → 실행 기록 지움` };
    },
    async apply(w) {
      const r = mine(w);
      w.k8s.deleteRestoreObjects(NS, r.run);
      const left = runObjects(w, r.run);
      if (left.length) throw new Error(`이 시험의 객체가 남았다(${left.join(", ")}). 기록은 그대로다`);
      // 확인까지 끝난 시험이면 그 DB 수, 아니면 0(확인한 것이 없다).
      // 시험 시작 Cluster가 아니면 쓰지 않는다(새 Cluster는 이 시험과 무관하다). 정리는 그대로 끝낸다.
      if (samePg(w, attempt(r)) && !failedAlready(w, r.run)) mark(w, attempt(r), "fail", r.data["ok.contents"] === "1" ? dbCount(r) : 0, "aborted");
      w.k8s.restoreRecordDelete(NS, RECORD, r.run);
    },
  },
];

export default defineCommand({
  path: ["db", "restore-check"],
  summary: "백업 복원 시험 (앱 영향 없음)",
  help: {
    about:
      "R2의 백업을 임시 DB 클러스터에 10분 전 시각까지 복원해 백업이 실제로 쓸 만한지 확인하고 결과를 기록합니다. 앱에는 영향이 없습니다. 내용 확인까지 끝난 뒤 멈췄으면 같은 명령으로 정리를 이어 갑니다. 그 전에 멈췄으면 --abort로 임시 클러스터와 기록을 치운 뒤 새로 시작합니다.",
    examples: ["homelab db restore-check --apply", "homelab db restore-check --abort --apply"],
    related: ["db restore"],
    doc: "docs/runbooks-public/restore.md 2.2절",
  },
  kind: "change",
  args: [],
  flags: [{ name: "abort", kind: "bool", help: "멈춘 시험의 임시 클러스터·기록 치우기" }],
  async run(ctx, input) {
    if (input.flags.abort === true) return ctx.engine({ command: "db restore-check", steps: abortSteps });
    return ctx.engine({
      command: "db restore-check",
      steps: stepsFor({ created: false }),
      notes: ["앱에는 쓰지 않는다. 임시 Cluster(R2 읽기)와 그 PVC만 만들고 지운다. 공유 Cluster pg에는 결과 annotation 두 키(restore-check-last·restore-check-pass)만 쓴다."],
      // 끝나면 기록까지 지우므로 다시 치면 새 시험이다(재실행이 same이 아닌 명령).
      next: (status) => (status === "done" ? null : (undefined as unknown as string | null)),
    });
  },
});
