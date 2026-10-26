// 03 명령(회전·폐기·Valkey 복원)의 흐름 시험용 가짜 세계. 상태가 있는 Infisical·Secret·ExternalSecret·CNPG·Deployment·
// Valkey·GitHub(PR)를 메모리에 두고, 실제 엔진(runEngine)과 실제 PR 작성기(prStep)로 명령을 돌린다.
// PATH 스텁(정적 응답)으로는 "쓰면 다음 읽기가 바뀌는" 흐름·재실행·실패 주입을 볼 수 없어 따로 둔다. argv 모양과 plan 부수효과 0은
// 각 명령 시험의 runCli(스텁) 쪽이 본다.
import type { Plan, ReadCtx, WriteCtx } from "../../../src/core/command";
import type { Input } from "../../../src/core/args";
import type { CommandSpec } from "../../../src/core/command";
import type { Exec } from "../../../src/core/exec";
import { ExecTimeout } from "../../../src/core/exec";
import { runEngine } from "../../../src/core/engine";
import { registerWriteExec } from "../../../src/core/runtime-internal";
import { Secret, revealSecret } from "../../../src/core/secret";
import type { Result } from "../../../src/core/result";

type Obj = Record<string, any>;
type Failure = Error | "timeout";

let shaCounter = 0;
const nextSha = () => (++shaCounter).toString(16).padStart(40, "0");
const hash12 = (v: string) => new Bun.CryptoHasher("sha256").update(v).digest("hex").slice(0, 12);

export class World {
  // Infisical: 폴더 → 키 → 값
  infisical = new Map<string, Map<string, string>>();
  secrets = new Map<string, { data: Record<string, string>; rv: number }>();
  // ExternalSecret "ns/name" → Secret data를 만드는 함수(Infisical에서 읽음). null이면 동기화 실패.
  producers = new Map<string, () => Record<string, string> | null>();
  // 그 밖의 객체 "kind/ns/name"(ns 없으면 "-")
  objects = new Map<string, Obj>();
  // Deployment "ns/name" → 참조 Secret, 주석, rollout 완료, 재시작 때 받은 Secret 사본
  deploys = new Map<string, { secrets: string[]; annot: string | null; rolledOut: boolean; env: Record<string, Record<string, string>> }>();
  // CNPG가 적용한 역할 비밀번호와 그때의 Secret 버전
  roles = new Map<string, { password: string; rv: number }>();
  cnpgApplies = true;
  // Valkey 서버 "ns/deploy" → 시작 때 읽은 비밀번호와 데이터
  valkeys = new Map<string, { password: string; appendonly: boolean; aof: boolean; keys: number; markers?: Set<string> }>();
  strictNamespaces = false;
  clusterSkewMs = 0;
  records = new Map<string, { run: string; data: Record<string, string>; created?: string }>();
  rv = 100;
  writes: string[] = [];
  fail = new Map<string, Failure>();
  // GitHub
  commits = new Map<string, { files: Map<string, string>; message: string; parents: string[] }>();
  trees = new Map<string, Map<string, string>>();
  refs = new Map<string, string>();
  prs: { number: number; head: string; open: boolean; title: string }[] = [];
  removalDate = "2026-10-20T00:00:00Z";
  // 저장소 경로 → 커밋 시각(새것부터). 없으면 apps/는 [removalDate], 그 밖은 [2026-10-01]. "broken"은 모양이 다른 응답.
  history = new Map<string, { date: string; status: "added" | "modified" | "removed" }[] | "broken">();
  commitFiles = new Map<string, { filename: string; status: string }[]>();
  tags = new Set<string>();
  passwords = 0;
  jobLogs = new Map<string, string>();
  jobOutcome = new Map<string, "complete" | "failed">();

  constructor(files: Record<string, string> = {}) {
    const sha = nextSha();
    this.commits.set(sha, { files: new Map(Object.entries(files)), message: "init", parents: [] });
    this.refs.set("main", sha);
  }

  // 시험 도우미
  setValue(path: string, key: string, value: string) {
    if (!this.infisical.has(path)) this.infisical.set(path, new Map());
    this.infisical.get(path)!.set(key, value);
  }
  value(path: string, key: string): string | undefined {
    return this.infisical.get(path)?.get(key);
  }
  secret(ns: string, name: string) {
    return this.secrets.get(`${ns}/${name}`);
  }
  sync(id: string): boolean {
    const p = this.producers.get(id);
    const data = p?.();
    if (!data) return false;
    const cur = this.secrets.get(id);
    if (!cur || JSON.stringify(cur.data) !== JSON.stringify(data)) this.secrets.set(id, { data, rv: ++this.rv });
    const [ns, name] = id.split("/");
    if (ns === "database" && name.startsWith("pg-role-") && this.cnpgApplies) {
      const s = this.secrets.get(id)!;
      this.roles.set(name.slice("pg-role-".length), { password: s.data.password, rv: s.rv });
    }
    return true;
  }
  secretsHash(id: string): string {
    const d = this.deploys.get(id)!;
    const ns = id.split("/")[0];
    return hash12(d.secrets.map((s) => `${s}@${this.secrets.get(`${ns}/${s}`)?.rv ?? "none"}`).join("\n"));
  }
  restart(id: string) {
    const d = this.deploys.get(id)!;
    const ns = id.split("/")[0];
    d.annot = this.secretsHash(id);
    d.env = Object.fromEntries(d.secrets.map((s) => [s, { ...(this.secrets.get(`${ns}/${s}`)?.data ?? {}) }]));
    const vk = this.valkeys.get(id);
    if (vk) {
      const auth = d.env[`${id.split("/")[1]}-auth`];
      if (auth) vk.password = auth.password;
    }
  }
  put(kind: string, ns: string | null, name: string, obj: Obj) {
    this.objects.set(`${kind}/${ns ?? "-"}/${name}`, obj);
  }
  obj(kind: string, ns: string | null, name: string): Obj | undefined {
    return this.objects.get(`${kind}/${ns ?? "-"}/${name}`);
  }
  main(): Map<string, string> {
    return this.commits.get(this.refs.get("main")!)!.files;
  }
  // PR을 병합한다(그 브랜치 머리의 파일로 main을 바꾼다).
  merge(pr: number) {
    const p = this.prs.find((x) => x.number === pr && x.open);
    if (!p) throw new Error(`열린 PR #${pr} 없음`);
    const files = new Map(this.commits.get(this.refs.get(p.head)!)!.files);
    const sha = nextSha();
    this.commits.set(sha, { files, message: `merge #${pr}`, parents: [this.refs.get("main")!] });
    this.refs.set("main", sha);
    this.refs.delete(p.head);
    p.open = false;
  }
  openPrs() {
    return this.prs.filter((p) => p.open);
  }
  private failIf(op: string) {
    const f = this.fail.get(op);
    if (!f) return;
    this.fail.delete(op);
    if (f === "timeout") throw new ExecTimeout(`${op}: 시간 초과(주입)`);
    throw f;
  }
  private write(op: string) {
    this.writes.push(op);
    this.failIf(op);
  }

  // GitHub 읽기(prStep·명령이 쓰는 경로만)
  ghGet(path: string): { status: number; json: any } {
    const m = path.replace(/^repos\/ukyi-app\/homelab\//, "");
    let x: RegExpMatchArray | null;
    if ((x = m.match(/^pulls\?head=ukyi-app%3A(.+)&state=open$/))) {
      const branch = decodeURIComponent(x[1]);
      return { status: 200, json: this.openPrs().filter((p) => p.head === branch).map((p) => ({ number: p.number, base: { ref: "main" }, head: { sha: this.refs.get(p.head) } })) };
    }
    if ((x = m.match(/^git\/commits\/([0-9a-f]{40})$/))) {
      const c = this.commits.get(x[1]);
      return c ? { status: 200, json: { message: c.message, tree: { sha: `t${x[1].slice(1)}` } } } : { status: 404, json: {} };
    }
    if ((x = m.match(/^git\/ref\/heads\/(.+)$/))) {
      const sha = this.refs.get(x[1]);
      return sha ? { status: 200, json: { object: { sha } } } : { status: 404, json: { message: "Not Found" } };
    }
    if ((x = m.match(/^git\/ref\/tags\/(.+)$/))) return this.tags.has(x[1]) ? { status: 200, json: { object: { sha: nextSha() } } } : { status: 404, json: { message: "Not Found" } };
    if ((x = m.match(/^compare\/([0-9a-f]{40})\.\.\.([0-9a-f]{40})$/))) {
      const a = this.commits.get(x[1])!.files;
      const b = this.commits.get(x[2])!.files;
      const names = new Set([...a.keys(), ...b.keys()]);
      return { status: 200, json: { files: [...names].filter((n) => a.get(n) !== b.get(n)).map((filename) => ({ filename })) } };
    }
    if ((x = m.match(/^commits\?path=(.+)&sha=main&per_page=([0-9]+)$/))) {
      const path = decodeURIComponent(x[1]);
      const h = this.history.get(path) ?? (path.startsWith("apps/") ? [{ date: this.removalDate, status: "removed" as const }] : [{ date: "2026-10-01T00:00:00Z", status: "added" as const }]);
      if (h === "broken") return { status: 200, json: { message: "모양이 다름" } };
      return {
        status: 200,
        json: h.slice(0, Number(x[2])).map((e, i) => {
          const sha = new Bun.CryptoHasher("sha1").update(`${path}#${i}`).digest("hex");
          this.commitFiles.set(sha, [{ filename: path, status: e.status }]);
          return { sha, commit: { committer: { date: e.date } } };
        }),
      };
    }
    if ((x = m.match(/^commits\/([0-9a-f]{40})$/))) {
      const files = this.commitFiles.get(x[1]);
      return files ? { status: 200, json: { files } } : { status: 404, json: { message: "Not Found" } };
    }
    if ((x = m.match(/^contents\/([^?]+)\?ref=main$/))) {
      const dir = decodeURIComponent(x[1]);
      const entries = [...this.main().keys()].filter((k) => k.startsWith(`${dir}/`)).map((k) => ({ type: "file", path: k, name: k.slice(dir.length + 1) }));
      return entries.length ? { status: 200, json: entries } : { status: 404, json: { message: "Not Found" } };
    }
    throw new Error(`가짜 GitHub에 없는 GET: ${path}`);
  }

  // prStep의 쓰기(gh api -i -X <m> <path> --input -)
  ghExec: Exec = (argv, opts = {}) => {
    const method = argv[4];
    const path = argv[5].replace(/^repos\/ukyi-app\/homelab\//, "");
    const body = JSON.parse(String(opts.input ?? "{}"));
    this.write(`gh ${method} ${path.split("/").slice(0, 2).join("/")}`);
    const reply = (status: number, json: unknown) => ({ code: status < 300 ? 0 : 1, stdout: `HTTP/2.0 ${status} X\r\nContent-Type: application/json\r\n\r\n${JSON.stringify(json)}`, stderr: "", notFound: false });
    let x: RegExpMatchArray | null;
    if (method === "POST" && path === "git/trees") {
      const base = this.commits.get(`0${String(body.base_tree).slice(1)}`)?.files ?? this.main();
      const files = new Map(base);
      for (const e of body.tree) e.sha === null ? files.delete(e.path) : files.set(e.path, e.content);
      const sha = nextSha();
      this.trees.set(sha, files);
      return reply(201, { sha });
    }
    if (method === "POST" && path === "git/commits") {
      const sha = nextSha();
      this.commits.set(sha, { files: this.trees.get(body.tree)!, message: body.message, parents: body.parents });
      return reply(201, { sha });
    }
    if (method === "POST" && path === "git/refs") {
      const b = body.ref.replace(/^refs\/heads\//, "");
      if (this.refs.has(b)) return reply(422, { message: "exists" });
      this.refs.set(b, body.sha);
      return reply(201, {});
    }
    if (method === "PATCH" && (x = path.match(/^git\/refs\/heads\/(.+)$/))) {
      this.refs.set(x[1], body.sha);
      return reply(200, {});
    }
    if (method === "POST" && path === "pulls") {
      const number = 900 + this.prs.length;
      this.prs.push({ number, head: body.head, open: true, title: body.title });
      return reply(201, { number });
    }
    if (method === "PATCH" && path.startsWith("pulls/")) return reply(200, {});
    throw new Error(`가짜 GitHub에 없는 쓰기: ${method} ${path}`);
  };

  read(mode: "plan" | "apply"): ReadCtx {
    const w = this;
    const k8sRead = {
      get(kind: string, ns: string | null, name: string) {
        if (kind === "databaserole") {
          const r = w.roles.get(name);
          const o = w.obj("databaserole", "database", name);
          if (!o) return null;
          return { ...o, status: { applied: true, secretResourceVersion: String(r?.rv ?? "") } };
        }
        return w.obj(kind, ns, name) ?? null;
      },
      list(kind: string, ns: string | null, selector?: string) {
        const out: Obj[] = [];
        for (const [k, v] of w.objects) {
          const [kk, nn] = k.split("/");
          if (kk !== kind || (ns !== null && nn !== ns)) continue;
          if (selector) {
            const [lk, lv] = selector.split("=");
            if (v.metadata?.labels?.[lk] !== lv) continue;
          }
          out.push(v);
        }
        return out;
      },
      secretHash(ns: string, name: string, key: string) {
        const v = w.secret(ns, name)?.data[key];
        return v === undefined ? null : hash12(v);
      },
      secretExists(ns: string, name: string) {
        const s = w.secret(ns, name);
        return s ? { exists: true, keys: Object.keys(s.data).sort(), resourceVersion: String(s.rv) } : { exists: false, keys: [], resourceVersion: null };
      },
      secretEmbeds(ns: string, name: string, key: string, needle: Secret) {
        const v = w.secret(ns, name)?.data[key];
        return v === undefined ? null : v.includes(revealSecret(needle));
      },
      waitSecret(ns: string, name: string, key: string, want: { hash: string } | { embeds: Secret }) {
        return "hash" in want ? k8sRead.secretHash(ns, name, key) === want.hash : k8sRead.secretEmbeds(ns, name, key, want.embeds) === true;
      },
      waitFor(kind: string, ns: string, name: string, _jp: string, value: string) {
        return String(w.roles.get(name)?.rv ?? "") === value;
      },
      waitCondition(kind: string, ns: string, target: { name: string } | { jobPods: string }, cond: string) {
        if (kind === "job" && "name" in target) {
          const job = w.obj("job", ns, target.name);
          return job !== undefined && (w.jobOutcome.get(target.name) ?? "complete") === "complete";
        }
        return true;
      },
      podSecretsCurrent(ns: string, d: string) {
        const id = `${ns}/${d}`;
        const dep = w.deploys.get(id);
        if (!dep) throw new Error(`Deployment ${id} 없음`);
        return { current: dep.annot === w.secretsHash(id), rolledOut: dep.rolledOut, secrets: dep.secrets };
      },
      restoreRecord(ns: string, name: string) {
        const r = w.records.get(`${ns}/${name}`);
        return r ? { run: r.run, data: { ...r.data, run: r.run }, resourceVersion: "1", uid: "", created: r.created ?? "" } : null;
      },
      logs(ns: string, target: { job: string }) {
        return w.jobLogs.get(target.job) ?? "";
      },
      rolloutStatus(ns: string, d: string) {
        return w.deploys.get(`${ns}/${d}`)?.rolledOut ?? false;
      },
    };
    const infRead = {
      folderExists: (p: string) => w.infisical.has(p),
      has: (p: string, k: string) => w.infisical.get(p)?.has(k) ?? false,
      listKeys: (p: string) => [...(w.infisical.get(p)?.keys() ?? [])].sort(),
      getValue: (p: string, k: string) => {
        const v = w.value(p, k);
        return v === undefined ? null : new Secret(v);
      },
      valueHash: (p: string, k: string) => {
        const v = w.value(p, k);
        return v === undefined ? null : hash12(v);
      },
      projectStatus: () => "ok" as const,
    };
    const repo = {
      mainSha: () => w.refs.get("main")!,
      readFile(path: string, ref = "main") {
        const sha = /^[0-9a-f]{40}$/.test(ref) ? ref : w.refs.get(ref)!;
        return w.commits.get(sha)?.files.get(path) ?? null;
      },
    };
    const gh = { get: (p: string) => w.ghGet(p), login: () => "owner" };
    const ctx: any = { mode, json: false, line: "homelab test", k8s: k8sRead, infisical: infRead, gh, repo, ghcr: {}, tools: {}, web: {}, progress() {} };
    ctx.engine = (plan: Plan) =>
      runEngine(ctx, plan, () => {
        const wctx = w.writeCtx(ctx);
        return { w: wctx, revoke() {} };
      });
    return ctx as ReadCtx;
  }

  writeCtx(ctx: any): WriteCtx {
    const w = this;
    const k8s = {
      ...ctx.k8s,
      forceSync(ns: string, es: string, o: { waitSec?: number } = {}) {
        w.write(`forceSync ${ns}/${es}`);
        if (!w.sync(`${ns}/${es}`) && o.waitSec) throw new ExecTimeout(`ExternalSecret ${es}: 동기화 대기 시간 초과`);
      },
      rolloutRestart(ns: string, d: string) {
        w.write(`rolloutRestart ${ns}/${d}`);
        w.restart(`${ns}/${d}`);
      },
      restartForSecrets(ns: string, d: string) {
        w.write(`restartForSecrets ${ns}/${d}`);
        w.restart(`${ns}/${d}`);
      },
      restoreRecordCreate(ns: string, name: string, run: string, data: Record<string, string>) {
        w.write(`recordCreate ${ns}/${name}`);
        if (w.records.has(`${ns}/${name}`)) return "exists";
        // 실제 API는 없는 ns에 만들지 못한다(namespaces "<ns>" not found). strictNamespaces일 때만 본다.
        if (w.strictNamespaces && !w.obj("namespace", null, ns)) throw new Error(`namespaces "${ns}" not found`);
        // creationTimestamp는 API 서버 시계다. 시험에서는 clusterSkewMs로 이 기기 시계와 다르게 둔다.
        w.records.set(`${ns}/${name}`, { run, data: { ...data }, created: new Date(Date.now() + w.clusterSkewMs).toISOString().replace(/\.\d{3}Z$/, "Z") });
        return "created";
      },
      restoreRecordUpdate(ns: string, name: string, run: string, set: Record<string, string | null>) {
        w.write(`recordUpdate ${ns}/${name}`);
        const r = w.records.get(`${ns}/${name}`);
        if (!r || r.run !== run) throw new Error("잠금이 이 실행의 것이 아니다(test 실패)");
        for (const [k, v] of Object.entries(set)) v === null ? delete r.data[k] : (r.data[k] = v);
      },
      restoreRecordDelete(ns: string, name: string, run: string) {
        w.write(`recordDelete ${ns}/${name}`);
        if (w.records.get(`${ns}/${name}`)?.run === run) w.records.delete(`${ns}/${name}`);
      },
      createJobFromCronJob(ns: string, cj: string, job: string, run: string) {
        w.write(`createJobFromCronJob ${ns}/${job}`);
        w.put("job", ns, job, { metadata: { name: job, labels: { "homelab.ukyi.app/restore": run } }, status: {} });
        w.jobLogs.set(job, `올림: r2:homelab-backups/valkey/${ns.slice(4)}/dump-20261026T000000Z.rdb\n`);
      },
      createRestoreObject(ns: string, m: Obj) {
        w.write(`create ${m.kind} ${ns}/${m.metadata.name}`);
        if (w.obj(m.kind.toLowerCase(), ns, m.metadata.name)) throw new Error(`AlreadyExists ${m.metadata.name}`);
        w.put(m.kind.toLowerCase(), ns, m.metadata.name, m);
      },
      deleteRestoreObjects(ns: string, run: string) {
        w.write(`deleteRestoreObjects ${ns}/${run}`);
        for (const [k, v] of [...w.objects]) if (k.split("/")[1] === ns && v.metadata?.labels?.["homelab.ukyi.app/restore"] === run) w.objects.delete(k);
      },
      deleteRestoreObject(ns: string, kind: string, name: string) {
        w.write(`deleteRestoreObject ${ns}/${name}`);
        w.objects.delete(`${kind}/${ns}/${name}`);
      },
      setPvReclaimDelete(ns: string, pvc: string) {
        w.write(`setPvReclaimDelete ${ns}/${pvc}`);
        const claim = w.obj("pvc", ns, pvc);
        const pv = w.obj("pv", null, claim!.spec.volumeName)!;
        pv.spec.persistentVolumeReclaimPolicy = "Delete";
      },
    };
    const infisical = {
      ...ctx.infisical,
      setValue(p: string, k: string, v: Secret) {
        w.write(`infisical set ${p}/${k}`);
        w.setValue(p, k, revealSecret(v));
      },
      removeKey(p: string, k: string) {
        w.write(`infisical delete ${p}/${k}`);
        w.infisical.get(p)?.delete(k);
      },
      createFolder() {},
    };
    const valkey = {
      cli(ns: string, d: string, cmd: string) {
        const v = w.valkeys.get(`${ns}/${d}`)!;
        // keys는 앱 키 수, 표식 키는 따로 센다(DBSIZE에는 함께 잡힌다).
        if (cmd === "DBSIZE") return `${v.keys + (v.markers?.size ?? 0)}\n`;
        if (cmd === "CONFIG GET appendonly") return `appendonly\n${v.appendonly ? "yes" : "no"}\n`;
        if (cmd === "CONFIG SET appendonly yes") {
          w.write(`valkey appendonly ${ns}/${d}`);
          v.appendonly = true;
          v.aof = true;
          return "OK\n";
        }
        return "PONG\n";
      },
      waitAof: (ns: string, d: string) => w.valkeys.get(`${ns}/${d}`)!.aof,
      marker(ns: string, d: string, run: string, op: "set" | "exists" | "del") {
        const v = w.valkeys.get(`${ns}/${d}`)!;
        v.markers ??= new Set();
        if (op === "exists") return v.markers.has(run);
        w.write(`valkey marker ${op} ${ns}/${d}`);
        if (op === "set") v.markers.add(run);
        else v.markers.delete(run);
        return true;
      },
      authCheck: (ns: string, d: string, pw: Secret) => (w.valkeys.get(`${ns}/${d}`)?.password === revealSecret(pw) ? "accepted" : "rejected"),
    };
    const out: any = {
      k8s,
      infisical,
      gh: ctx.gh,
      repo: ctx.repo,
      ghcr: {},
      web: {},
      progress() {},
      generatePassword() {
        w.write("generatePassword");
        return new Secret(`Gen${String(++w.passwords).padStart(4, "0")}abcdefghijklmnopqrstuvwxyz0123`);
      },
      confirm: (_q: string, expected: string) => w.confirmAnswer === expected,
      pg: {
        passwordCheck: (app: string, pw: Secret) => (w.roles.get(app)?.password === revealSecret(pw) ? "accepted" : "rejected"),
      },
      valkey,
      http: {
        async appStatus(ns: string, d: string, _port: number, path: string) {
          w.failIf("appStatus");
          const dep = w.deploys.get(`${ns}/${d}`)!;
          const app = d;
          if (path === "/healthz/db") {
            const url = dep.env[`${app}-db`]?.DATABASE_URL ?? "";
            return url.includes(`:${w.roles.get(app)?.password}@`) ? 200 : 503;
          }
          if (path === "/healthz/cache") {
            const url = dep.env[`${app}-valkey-url`]?.VALKEY_URL ?? "";
            return url.includes(`:${w.valkeys.get(`${ns}/${app}-valkey`)?.password}@`) ? 200 : 503;
          }
          return 200;
        },
      },
    };
    registerWriteExec(out as WriteCtx, w.ghExec);
    return out as WriteCtx;
  }
  confirmAnswer: string | null = null;
}

export async function runIn(world: World, cmd: CommandSpec, mode: "plan" | "apply", args: Record<string, string>, flags: Record<string, string | true> = {}): Promise<Result> {
  const input: Input = { args, flags, apply: mode === "apply", json: false, help: false };
  return cmd.run(world.read(mode), input);
}

// 앱 하나의 DB·Valkey가 일관된 처음 상태.
export function postgresWorld(app: string, opts: { password?: string } = {}): World {
  const w = new World({
    [`apps/${app}/values.yaml`]: `chartVersion: 1.1.0\nkind: web\nport: 8080\nuses: { postgres: true }\n`,
    [`data/${app}/values.yaml`]: `chartVersion: 1.0.1\npostgres: { enabled: true }\n`,
  });
  const folder = `/apps/${app}/postgres`;
  w.setValue(folder, "PASSWORD", opts.password ?? "fakevalue-postgres-old-aaaa-bbbb");
  w.producers.set(`database/pg-role-${app}`, () => {
    const p = w.value(folder, "PASSWORD");
    return p ? { username: app, password: p } : null;
  });
  w.producers.set(`app-${app}/${app}-db`, () => {
    const p = w.value(folder, "PASSWORD");
    return p ? { DATABASE_URL: `postgresql://${app}:${p}@pg-rw.database.svc:5432/${app}` } : null;
  });
  w.put("databaserole", "database", app, {});
  w.sync(`database/pg-role-${app}`);
  w.sync(`app-${app}/${app}-db`);
  w.deploys.set(`app-${app}/${app}`, { secrets: [`${app}-db`], annot: null, rolledOut: true, env: {} });
  w.restart(`app-${app}/${app}`);
  w.writes = [];
  return w;
}

export function valkeyWorld(app: string, kind: "cache" | "persistent"): World {
  const w = new World({
    [`apps/${app}/values.yaml`]: `chartVersion: 1.1.0\nkind: web\nport: 8080\nuses: { valkey: true }\n${kind === "cache" ? "cache: { enabled: true }\n" : ""}`,
    ...(kind === "persistent" ? { [`data/${app}/values.yaml`]: `chartVersion: 1.0.1\nvalkey: { persistent: true }\n` } : {}),
  });
  const folder = `/apps/${app}/valkey`;
  const ns = `app-${app}`;
  w.setValue(folder, "PASSWORD", "fakevalue-valkey-old-aaaa-bbbb");
  w.producers.set(`${ns}/${app}-valkey-auth`, () => {
    const p = w.value(folder, "PASSWORD");
    return p ? { password: p } : null;
  });
  w.producers.set(`${ns}/${app}-valkey-url`, () => {
    const p = w.value(folder, "PASSWORD");
    return p ? { VALKEY_URL: `redis://:${p}@${app}-valkey:6379` } : null;
  });
  w.sync(`${ns}/${app}-valkey-auth`);
  w.sync(`${ns}/${app}-valkey-url`);
  w.valkeys.set(`${ns}/${app}-valkey`, { password: "", appendonly: true, aof: true, keys: 2 });
  w.deploys.set(`${ns}/${app}-valkey`, { secrets: [`${app}-valkey-auth`], annot: null, rolledOut: true, env: {} });
  w.deploys.set(`${ns}/${app}`, { secrets: [`${app}-valkey-url`], annot: null, rolledOut: true, env: {} });
  w.restart(`${ns}/${app}-valkey`);
  w.restart(`${ns}/${app}`);
  w.put("deployment", ns, `${app}-valkey`, { metadata: { name: `${app}-valkey` }, status: {} });
  if (kind === "persistent") {
    w.put("cronjob", ns, `${app}-valkey-backup`, {
      metadata: { name: `${app}-valkey-backup` },
      spec: { suspend: false, jobTemplate: { spec: { template: { spec: { containers: [{ name: "snapshot", env: [] }, { name: "upload", image: "docker.io/rclone/rclone:1.75.2@sha256:2687085f718d3c628f7fdfb77c52a1d344332aed543110bb88088f2c70d43eb5", env: [{ name: "BUCKET", value: "homelab-backups" }] }] } } } } },
      status: { lastSuccessfulTime: "2026-10-25T18:30:00Z" },
    });
    w.put("pvc", ns, "valkey-data", { metadata: { name: "valkey-data" }, spec: { volumeName: "pvc-1234" } });
    w.put("pv", null, "pvc-1234", { metadata: { name: "pvc-1234" }, spec: { storageClassName: "local-retain", persistentVolumeReclaimPolicy: "Retain", claimRef: { namespace: ns, name: "valkey-data" } } });
  }
  w.writes = [];
  return w;
}
