// homelab db restore-check: 최신 백업 복원 시험. 앱에는 손대지 않는다(설계 C.7, C.5.7 2단계와 같은 임시 Cluster).
//
// R2의 base backup과 WAL로 임시 Cluster를 지금 − 10분까지 되감고, Database CR마다 그 DB가 있는지 본 뒤 지우고 0개를 확인한다.
// 지금 − 10분: archive_timeout(5분)보다 넉넉히 앞이라 WAL까지 시험한다. 아카이브가 밀렸으면 Ready가 되지 않아 실패로 드러난다.
// 실행 기록은 database ns의 ConfigMap restore-check. 중간에 멈추면 같은 명령이 그 실행을 잇고, 끝나면 기록까지 지운다
// (시험이라 다시 치면 새 시험이다).
import { defineCommand, type Observation, type ReadCtx, type RestoreRecord, type Step, type WriteCtx } from "../core/command";
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
// (Ready 뒤 DB 확인에서 실패한 경우도. 그사이 바뀐 Cluster를 이번 백업의 복구로 볼 수 없다, #886 r2 P1-2).
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
        const v = { to: t1, srv: srvOf(pg) ?? "", img: pg?.spec?.imageName ?? "", size: pg?.spec?.storage?.size ?? "" };
        if (!T1.test(v.to) || !SRV.test(v.srv) || !IMG.test(v.img) || !SIZE.test(v.size)) throw new Error("Cluster pg에서 읽은 serverName·이미지·크기 형식이 아니다");
        if (w.k8s.restoreRecordCreate(NS, RECORD, newRunId(), v) === "exists") throw new Error("그사이 다른 시험이 기록을 만들었다. 다시 실행해 상태를 읽는다");
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
        // Ready·DB 이름만으로는 이번 백업의 복구라고 볼 수 없다(restore.md 2절 2단계, #886 r1 P1-2). --abort로 정리하고 새 시험으로.
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
        return { state: "missing", action: "update", detail: `Database CR ${databases(ctx).length}개의 DB가 임시 클러스터에 있는지` };
      },
      async apply(w) {
        fresh();
        const r = mine(w);
        if (r.data["ok.tmp"] !== "1") throw new Error("멈춤: 임시 클러스터 확인이 끝나지 않았다");
        const dbs = databases(w);
        const missing = dbs.filter((db) => w.pgRestore.tmpDbCount(r.run, db) !== 1);
        if (missing.length) throw new Error(`임시 클러스터에 없는 DB: ${missing.join(", ")}`);
        w.k8s.restoreRecordUpdate(NS, RECORD, r.run, { "ok.contents": "1", dbs: dbs.join(",") || "-" });
      },
    },
    {
      id: "cleanup",
      target: "이 시험의 객체와 기록",
      async read(ctx) {
        const r = record(ctx);
        return r ? { state: "missing", action: "delete", detail: "임시 Cluster·PVC 지우고 0개 확인 → 기록 지움" } : same("없음");
      },
      async apply(w) {
        const r = mine(w);
        if (r.data["ok.contents"] !== "1") throw new Error("멈춤: 시험이 끝나지 않았다(임시 클러스터를 남겨 원인을 본다. 버리려면 --abort)");
        w.k8s.deleteRestoreObjects(NS, r.run);
        const left = runObjects(w, r.run);
        if (left.length) throw new Error(`이 시험의 객체가 남았다(${left.join(", ")}). 기록은 그대로다`);
        w.k8s.restoreRecordDelete(NS, RECORD, r.run);
      },
    },
  ];
}

// 멈춘 시험을 버린다: 이 시험의 객체를 지우고 0개를 본 뒤 기록을 지운다(앱·pg에는 쓰지 않으니 언제든 된다).
const abortSteps: Step[] = [
  {
    id: "abort",
    target: "이 시험의 객체와 기록",
    async read(ctx) {
      const r = record(ctx);
      return r ? { state: "differs", action: "delete", detail: `실행 ${r.run}: 임시 Cluster·PVC 지우고 0개 확인 → 기록 지움` } : same("기록 없음");
    },
    async apply(w) {
      const r = mine(w);
      w.k8s.deleteRestoreObjects(NS, r.run);
      const left = runObjects(w, r.run);
      if (left.length) throw new Error(`이 시험의 객체가 남았다(${left.join(", ")}). 기록은 그대로다`);
      w.k8s.restoreRecordDelete(NS, RECORD, r.run);
    },
  },
];

export default defineCommand({
  path: ["db", "restore-check"],
  summary: "최신 백업 복원 시험(임시 Cluster, 앱 영향 없음). 멈춘 시험은 --abort",
  kind: "change",
  args: [],
  flags: [{ name: "abort", kind: "bool", help: "멈춘 시험의 임시 Cluster·기록을 지운다" }],
  async run(ctx, input) {
    if (input.flags.abort === true) return ctx.engine({ command: "db restore-check", steps: abortSteps });
    return ctx.engine({
      command: "db restore-check",
      steps: stepsFor({ created: false }),
      notes: ["앱과 공유 Cluster pg에는 쓰지 않는다. 임시 Cluster(R2 읽기)와 그 PVC만 만들고 지운다."],
      // 끝나면 기록까지 지우므로 다시 치면 새 시험이다(재실행이 same이 아닌 명령).
      next: (status) => (status === "done" ? null : (undefined as unknown as string | null)),
    });
  },
});
