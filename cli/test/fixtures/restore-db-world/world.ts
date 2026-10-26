// db restore·restore-check 흐름 시험용 가짜 세계. 상태가 있는 클러스터 객체·실행 기록·GitHub(PR)·w.pgRestore를 메모리에 두고
// 실제 엔진(runEngine)과 실제 PR 작성기(prStep)로 명령을 돌린다.
// 가짜 pgRestore는 core의 파괴 단계 재확인을 흉내 내지 않는다. 그래서 "확인 실패면 DROP 0건" 시험은 명령의 확인만 본다
// (core의 재확인은 core 시험 cli/test/core가 본다). argv 모양과 plan 부수효과 0은 명령 시험의 runCli(스텁) 쪽이 본다.
import type { CommandSpec, Plan, ReadCtx, WriteCtx } from "../../../src/core/command";
import type { Input } from "../../../src/core/args";
import type { Exec } from "../../../src/core/exec";
import { ExecTimeout } from "../../../src/core/exec";
import { runEngine } from "../../../src/core/engine";
import { registerWriteExec } from "../../../src/core/runtime-internal";
import type { Result } from "../../../src/core/result";

type Obj = Record<string, any>;
type Failure = Error | "timeout";
const LABEL = "homelab.ukyi.app/restore";
let shaCounter = 0;
const nextSha = () => (++shaCounter).toString(16).padStart(40, "0");

export class World {
  objects = new Map<string, Obj>();
  records = new Map<string, { run: string; data: Record<string, string> }>();
  writes: string[] = [];
  fail = new Map<string, Failure>();
  // DB 상태: 운영 DB의 내용("live" | "t1" | "empty" | null=없음), R2 되돌림 사본, 임시 클러스터 Ready 여부
  db: string | null = "live";
  r2 = new Set<string>();
  tmpReady = true;
  tmpHasDb = true;
  inputsValid = true;
  aclSame = true;
  flags = "f|f|f|f|f";
  tmpDbs = new Set<string>();
  commits = new Map<string, { files: Map<string, string>; message: string }>();
  trees = new Map<string, Map<string, string>>();
  refs = new Map<string, string>();
  prs: { number: number; head: string; open: boolean }[] = [];
  // 기록 쓰기마다 부른다(시험이 단계 사이에 기록을 바꿔 보는 데 쓴다).
  onUpdate?: (set: Record<string, string | null>, data: Record<string, string>) => void;
  // DROP 직후(복원 전)에 부른다. 같은 실행을 다른 호출이 함께 돌리는 시험에 쓴다.
  duringDrop?: () => Promise<void>;
  // 복원 객체를 만든 직후에 부른다(lease를 쥔 순간에 다른 호출이 그 단계를 끝낸 경우를 흉내 낸다).
  onCreate?: (m: Obj) => void;
  // 객체를 읽을 때마다 부른다(단계 사이에 다른 호출의 변경을 끼워 넣는다).
  onGet?: (kind: string, ns: string | null, name: string) => void;

  constructor(files: Record<string, string>) {
    const sha = nextSha();
    this.commits.set(sha, { files: new Map(Object.entries(files)), message: "init" });
    this.refs.set("main", sha);
  }

  put(kind: string, ns: string | null, name: string, obj: Obj) {
    this.objects.set(`${kind}/${ns ?? "-"}/${name}`, { ...obj, metadata: { name, ...(obj.metadata ?? {}) } });
  }
  obj(kind: string, ns: string | null, name: string): Obj | undefined {
    return this.objects.get(`${kind}/${ns ?? "-"}/${name}`);
  }
  main(): Map<string, string> {
    return this.commits.get(this.refs.get("main")!)!.files;
  }
  merge(pr: number) {
    const p = this.prs.find((x) => x.number === pr && x.open)!;
    const sha = nextSha();
    this.commits.set(sha, { files: new Map(this.commits.get(this.refs.get(p.head)!)!.files), message: `merge #${pr}` });
    this.refs.set("main", sha);
    this.refs.delete(p.head);
    p.open = false;
  }
  openPrs() {
    return this.prs.filter((p) => p.open);
  }
  // 이 실행 라벨의 객체 수(두 ns)
  runObjects(run: string): string[] {
    return [...this.objects].filter(([, v]) => v.metadata?.labels?.[LABEL] === run).map(([k]) => k);
  }
  private failIf(op: string) {
    const f = this.fail.get(op);
    if (!f) return;
    this.fail.delete(op);
    if (f === "timeout") throw new ExecTimeout(`${op}: 시간 초과(주입)`);
    throw f;
  }
  write(op: string) {
    this.writes.push(op);
    this.failIf(op);
  }

  ghGet(path: string): { status: number; json: any } {
    const m = path.replace(/^repos\/ukyi-app\/homelab\//, "");
    let x: RegExpMatchArray | null;
    if ((x = m.match(/^pulls\?head=ukyi-app%3A(.+)&state=open$/))) {
      const b = decodeURIComponent(x[1]);
      return { status: 200, json: this.openPrs().filter((p) => p.head === b).map((p) => ({ number: p.number, base: { ref: "main" }, head: { sha: this.refs.get(p.head) } })) };
    }
    if ((x = m.match(/^git\/commits\/([0-9a-f]{40})$/))) return { status: 200, json: { message: this.commits.get(x[1])!.message, tree: { sha: `t${x[1].slice(1)}` } } };
    if ((x = m.match(/^git\/ref\/heads\/(.+)$/))) {
      const sha = this.refs.get(x[1]);
      return sha ? { status: 200, json: { object: { sha } } } : { status: 404, json: { message: "Not Found" } };
    }
    if ((x = m.match(/^compare\/([0-9a-f]{40})\.\.\.([0-9a-f]{40})$/))) {
      const a = this.commits.get(x[1])!.files;
      const b = this.commits.get(x[2])!.files;
      return { status: 200, json: { files: [...new Set([...a.keys(), ...b.keys()])].filter((n) => a.get(n) !== b.get(n)).map((filename) => ({ filename })) } };
    }
    throw new Error(`가짜 GitHub에 없는 GET: ${path}`);
  }

  ghExec: Exec = (argv, opts = {}) => {
    const method = argv[4];
    const path = argv[5].replace(/^repos\/ukyi-app\/homelab\//, "");
    const body = JSON.parse(String(opts.input ?? "{}"));
    this.write(`gh ${method} ${path.split("/").slice(0, 2).join("/")}`);
    const reply = (status: number, json: unknown) => ({ code: status < 300 ? 0 : 1, stdout: `HTTP/2.0 ${status} X\r\nContent-Type: application/json\r\n\r\n${JSON.stringify(json)}`, stderr: "", notFound: false });
    let x: RegExpMatchArray | null;
    if (method === "POST" && path === "git/trees") {
      const files = new Map(this.commits.get(`0${String(body.base_tree).slice(1)}`)?.files ?? this.main());
      for (const e of body.tree) e.sha === null ? files.delete(e.path) : files.set(e.path, e.content);
      const sha = nextSha();
      this.trees.set(sha, files);
      return reply(201, { sha });
    }
    if (method === "POST" && path === "git/commits") {
      const sha = nextSha();
      this.commits.set(sha, { files: this.trees.get(body.tree)!, message: body.message });
      return reply(201, { sha });
    }
    if (method === "POST" && path === "git/refs") {
      this.refs.set(body.ref.replace(/^refs\/heads\//, ""), body.sha);
      return reply(201, {});
    }
    if (method === "PATCH" && (x = path.match(/^git\/refs\/heads\/(.+)$/))) {
      this.refs.set(x[1], body.sha);
      return reply(200, {});
    }
    if (method === "POST" && path === "pulls") {
      const number = 900 + this.prs.length;
      this.prs.push({ number, head: body.head, open: true });
      return reply(201, { number });
    }
    if (method === "PATCH" && path.startsWith("pulls/")) return reply(200, {});
    throw new Error(`가짜 GitHub에 없는 쓰기: ${method} ${path}`);
  };

  read(mode: "plan" | "apply"): ReadCtx {
    const w = this;
    const matches = (v: Obj, selector?: string) => {
      if (!selector) return true;
      return selector.split(",").every((part) => {
        const [k, val] = part.split("=");
        const have = v.metadata?.labels?.[k];
        return val === undefined ? have !== undefined : have === val;
      });
    };
    const k8s = {
      get: (kind: string, ns: string | null, name: string) => (w.onGet?.(kind, ns, name), w.obj(kind, ns, name) ?? null),
      list: (kind: string, ns: string | null, selector?: string) => [...w.objects].filter(([k, v]) => k.split("/")[0] === kind && (ns === null || k.split("/")[1] === ns) && matches(v, selector)).map(([, v]) => v),
      restoreRecord(ns: string, name: string) {
        const r = w.records.get(`${ns}/${name}`);
        return r ? { run: r.run, data: { ...r.data, run: r.run }, resourceVersion: "1", uid: "u-1" } : null;
      },
      waitCondition(kind: string, ns: string, target: { name: string } | { jobPods: string }) {
        if (kind === "cluster" && "name" in target) return w.tmpReady && !!w.obj("cluster", ns, target.name);
        return true;
      },
      rolloutStatus: () => true,
    };
    const repo = {
      mainSha: () => w.refs.get("main")!,
      readFile(path: string, ref = "main") {
        const sha = /^[0-9a-f]{40}$/.test(ref) ? ref : w.refs.get(ref)!;
        return w.commits.get(sha)?.files.get(path) ?? null;
      },
    };
    const ctx: any = { mode, json: false, line: "homelab test", k8s, repo, gh: { get: (p: string) => w.ghGet(p), login: () => "owner" }, infisical: {}, ghcr: {}, tools: {}, web: {}, progress() {} };
    ctx.engine = (plan: Plan) => runEngine(ctx, plan, () => ({ w: w.writeCtx(ctx), revoke() {} }));
    return ctx as ReadCtx;
  }

  writeCtx(ctx: any): WriteCtx {
    const w = this;
    const rec = (ns: string, name: string, run: string) => {
      const r = w.records.get(`${ns}/${name}`);
      if (!r || r.run !== run) throw new Error("잠금이 이 실행의 것이 아니다(test 실패)");
      return r;
    };
    const job = (ns: string, name: string, run: string) => {
      w.put("job", ns, name, { metadata: { labels: { [LABEL]: run } } });
      w.put("pod", ns, `${name}-p`, { metadata: { labels: { [LABEL]: run, "job-name": name } }, status: { phase: "Running", conditions: [{ type: "Ready", status: "True" }] } });
    };
    const k8sW = {
      ...ctx.k8s,
      restoreRecordCreate(ns: string, name: string, run: string, data: Record<string, string>) {
        w.write(`recordCreate ${ns}/${name}`);
        if (w.records.has(`${ns}/${name}`)) return "exists";
        w.records.set(`${ns}/${name}`, { run, data: { ...data } });
        return "created";
      },
      restoreRecordUpdate(ns: string, name: string, run: string, set: Record<string, string | null>) {
        const r = rec(ns, name, run);
        // 시험 훅이 던지면 기록은 바뀌지 않는다(쓰기 실패). 훅이 data를 고치면 쓰기 전 다른 변경으로 본다.
        w.onUpdate?.(set, r.data);
        for (const [k, v] of Object.entries(set)) v === null ? delete r.data[k] : (r.data[k] = v);
      },
      restoreRecordDelete(ns: string, name: string, run: string) {
        w.write(`recordDelete ${ns}/${name}`);
        if (w.records.get(`${ns}/${name}`)?.run === run) w.records.delete(`${ns}/${name}`);
      },
      deleteRestoreObject(ns: string, kind: string, name: string, run: string) {
        w.write(`delete ${kind} ${ns}/${name}`);
        const o = w.obj(kind, ns, name);
        if (o && o.metadata?.labels?.[LABEL] !== run) throw new Error("이 실행의 객체가 아니다");
        w.objects.delete(`${kind}/${ns}/${name}`);
        for (const [k, v] of [...w.objects]) if (k.startsWith(`pod/${ns}/`) && v.metadata?.labels?.["job-name"] === name) w.objects.delete(k);
      },
      deleteRestoreObjects(ns: string, run: string) {
        w.write(`deleteRestoreObjects ${ns}`);
        for (const [k, v] of [...w.objects]) if (k.split("/")[1] === ns && v.metadata?.labels?.[LABEL] === run && ["cluster", "job", "pod", "pvc"].includes(k.split("/")[0])) w.objects.delete(k);
      },
      rolloutRestart(ns: string, d: string) {
        w.write(`rolloutRestart ${ns}/${d}`);
      },
      createRestoreObject(ns: string, m: Obj) {
        w.write(`create ${m.kind} ${ns}/${m.metadata.name}`);
        const kind = String(m.kind).toLowerCase();
        if (w.obj(kind, ns, m.metadata.name)) throw new Error(`kubectl create ${m.kind}: AlreadyExists`);
        w.put(kind, ns, m.metadata.name, m);
        w.onCreate?.(m);
      },
    };
    const pg = {
      createR2Helper(run: string) {
        w.write("pg createR2Helper");
        job("database", `restore-${run}-r2`, run);
      },
      createDbJob(app: string, run: string) {
        w.write("pg createDbJob");
        job(`app-${app}`, `restore-${run}-db`, run);
      },
      createTmpCluster(run: string) {
        w.write("pg createTmpCluster");
        if (w.obj("cluster", "database", `pg-restore-${run}`)) throw new Error("임시 클러스터가 이미 있다");
        w.put("cluster", "database", `pg-restore-${run}`, { metadata: { labels: { [LABEL]: run } } });
        w.put("pvc", "database", `pg-restore-${run}-1`, { metadata: { labels: { [LABEL]: run } } });
      },
      tmpPrimary: (run: string) => `pg-restore-${run}-1`,
      tmpDbCount: (run: string, app: string) => (w.tmpDbs.size ? (w.tmpDbs.has(app) ? 1 : 0) : w.tmpHasDb ? 1 : 0),
      pinTmpPrimary(app: string, run: string) {
        const r = rec(`app-${app}`, "restore-pg", run);
        r.data.tmp ??= `pg-restore-${run}-1`;
        return r.data.tmp;
      },
      srcOk: () => true,
      r2DumpExists: (app: string, run: string) => w.r2.has(`${app}/${run}`),
      async dumpToR2(app: string, run: string) {
        w.write("pg dumpToR2");
        if (rec(`app-${app}`, "restore-pg", run).data.dropped === "1") throw new Error("dropped 뒤");
        if (w.r2.has(`${app}/${run}`)) throw new Error("이미 있다");
        w.r2.add(`${app}/${run}`);
      },
      async r2DumpReadable(app: string, run: string) {
        w.failIf("pg r2DumpReadable");
        if (!w.r2.has(`${app}/${run}`)) throw new Error("사본 없음");
      },
      dbCount: () => (w.db === null ? 0 : 1),
      roleFlags: () => w.flags,
      jobAuth(app: string, run: string) {
        w.failIf("pg jobAuth");
        if (!w.obj("job", `app-${app}`, `restore-${run}-db`)) throw new Error("복원 Job 없음");
      },
      async prepareInputs(app: string, run: string) {
        w.write("pg prepareInputs");
        rec(`app-${app}`, "restore-pg", run).data["in.sha"] = "x";
        return { ext: [], mainEntries: 3, aclEntries: 0, aclSuEntries: 0 };
      },
      inputsOk: () => w.inputsValid,
      async recreateDatabase(app: string, run: string) {
        w.write("pg recreateDatabase(DROP)");
        rec(`app-${app}`, "restore-pg", run).data.dropped = "1";
        w.db = "empty";
        await w.duringDrop?.();
        return "recreated" as const;
      },
      createExtensions: () => w.write("pg createExtensions"),
      // 실제 pg_restore처럼 문장마다 커밋한다: 중간에 끊기면 일부 테이블이 남고, 빈 DB가 아니면 "already exists"로 실패한다.
      async restoreMain() {
        w.write("pg restoreMain");
        if (w.db !== "empty") throw new Error('pg_restore: relation "t" already exists');
        if (w.fail.get("pg restoreMain partial")) {
          w.fail.delete("pg restoreMain partial");
          w.db = "partial";
          throw new Error("pg_restore: 연결이 끊겼다(주입)");
        }
        w.db = "t1";
      },
      async restoreAcl() {
        w.write("pg restoreAcl");
      },
      aclCompare: () => (w.aclSame ? { same: true, diff: [] } : { same: false, diff: ["- function|f(int)|{a=X/a}"] }),
    };
    const out: any = { k8s: k8sW, infisical: {}, gh: ctx.gh, repo: ctx.repo, ghcr: {}, web: {}, pgRestore: pg, progress() {} };
    registerWriteExec(out as WriteCtx, w.ghExec);
    return out as WriteCtx;
  }
}

export async function runIn(world: World, cmd: CommandSpec, mode: "plan" | "apply", args: Record<string, string>, flags: Record<string, string | true> = {}): Promise<Result> {
  const input: Input = { args, flags, apply: mode === "apply", json: false, help: false };
  return cmd.run(world.read(mode), input);
}

export const T1_INPUT = "2026-10-20T10:00:00+09:00";
export const T1_NORMAL = "2026-10-20 01:00:00+00";

// 앱 하나가 DB를 쓰는 처음 상태(복원 가능한 백업·WAL 아카이브 있음).
export function dbWorld(app: string, opts: { cache?: boolean } = {}): World {
  const w = new World({
    [`apps/${app}/values.yaml`]: `chartVersion: 1.1.0\nport: 8080\nuses: { postgres: true }\n${opts.cache ? "cache: { enabled: true }\n" : ""}`,
    [`data/${app}/values.yaml`]: "chartVersion: 1.0.1\npostgres: { enabled: true }\n",
  });
  w.put("cluster", "database", "pg", {
    spec: { imageName: "ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie@sha256:" + "a".repeat(64), storage: { size: "8Gi" }, plugins: [{ name: "barman-cloud.cloudnative-pg.io", parameters: { serverName: "pg-20261023" } }] },
    status: { conditions: [{ type: "ContinuousArchiving", status: "True" }] },
  });
  w.put("objectstore", "database", "r2", { status: { serverRecoveryWindow: { "pg-20261023": { firstRecoverabilityPoint: "2026-10-19T18:00:00Z" } } } });
  w.put("backup", "database", "b1", { spec: { cluster: { name: "pg" } }, status: { phase: "completed", stoppedAt: "2026-10-19T18:05:00Z" } });
  // T1 뒤에 끝난 base backup(그 시각까지의 WAL이 R2에 있다는 근거)
  w.put("backup", "database", "b2", { spec: { cluster: { name: "pg" } }, status: { phase: "completed", stoppedAt: "2026-10-20T18:05:00Z" } });
  w.put("database", "database", app, { spec: { cluster: { name: "pg" }, name: app }, status: { applied: true } });
  w.put("deployment", `app-${app}`, app, { metadata: { generation: 1 }, spec: { replicas: 1 }, status: { observedGeneration: 1, replicas: 1, updatedReplicas: 1, readyReplicas: 1 } });
  return w;
}
