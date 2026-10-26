// 공유 PostgreSQL에서 앱 DB 하나 복원(restore.md 2절, 03 2부 D1·D2·D4·D5). 쓰기 문맥(w.pgRestore)만.
// 이 모듈이 흐름을 갖는다: SQL·셸 텍스트·Job·Cluster 매니페스트는 여기 상수이고, 명령은 (app, run)과 정규식을 거친 값만 넘긴다.
// 명령이 만든 SQL·파일 텍스트를 실행하거나 파드에 쓰는 길은 없다(범용 applyAclSql·putList는 거절, REPORT-adapters 3절).
//
// - 4-2 산출물(확장 목록·본 복원 목록·ACL 목록·postgres용 ACL SQL)은 이 모듈이 만들어 기록 ConfigMap restore-pg의 in.*에
//   두고 in.sha로 고정한다. in.*는 명령이 쓸 수 없다(kubectl.ts). 뒤 단계는 기록을 다시 읽어 sha와 형식을 확인한 뒤 쓴다.
// - 파괴 단계(DB 다시 만들기·본 복원·ACL 복원) 앞에서 잠금(mine), 앱 멈춤(stopped), 입력 고정(same)을 이 모듈이 다시 본다.
// - 덤프 데이터는 kubectl 둘을 잇는 파이프로만 흐른다(exec.ts makePipe). pg_restore stderr는 데이터가 섞일 수 있어 버린다.
// - 앱이 만든 이름(확장·스키마)은 psql 변수(:"x", :'x')로만 SQL에 들어간다.
import type { KubeRead, PgRestoreWrite, RestoreInputs } from "./command";
import { ExecTimeout, why, type Exec, type Pipe } from "./exec";
import { jsonStringify } from "./intrinsics";
import { updateRecord } from "./kubectl";
import { APP_NAME, fullMatch } from "./names";

const RUN = /^[a-z0-9]{1,22}$/;
const PRIMARY = /^pg-[0-9]+$/;
const RT = "--request-timeout=20s";
const RECORD = "restore-pg";
const RESTORE_LABEL = "homelab.ukyi.app/restore";
// 기록 ConfigMap 한도 1MiB. 다른 키를 위해 남긴다(03 2절).
const MAX_INPUTS = 900 * 1024;

// restore.md 2절 머리의 fit 정규식과 같다.
export const T1 = /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}([+-][0-9]{2}(:?[0-9]{2})?)?$/;
export const SRV = /^[a-z0-9-]+$/;
export const IMG = /^[a-z0-9./_-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$/;
export const SIZE = /^[0-9]+(Mi|Gi|Ti)$/;
const BUCKET = /^s3:\/\/([a-z0-9][a-z0-9-]{1,61}[a-z0-9])\//;
const BUCKET_NAME = /^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/;

export const EXT_SQL = "select e.extname, n.nspname, e.extversion, pg_get_userbyid(e.extowner) from pg_extension e join pg_namespace n on n.oid = e.extnamespace where e.extname <> 'plpgsql' order by e.oid";

// 4-5의 ACL 대조 조회(restore.md ACL_SQL 그대로).
export const ACL_SQL = `select kind, name, coalesce(acl, '-') from (
  select 'function' kind, p.oid::regprocedure::text name, p.proacl::text acl from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname not in ('pg_catalog', 'information_schema')
  union all
  select 'relation', c.oid::regclass::text, c.relacl::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg_toast%'
  union all
  select 'schema', n.nspname, n.nspacl::text from pg_namespace n where n.nspname not like 'pg\\_%' and n.nspname <> 'information_schema'
  union all
  select 'type', t.oid::regtype::text, t.typacl::text from pg_type t join pg_namespace n on n.oid = t.typnamespace
   where t.typacl is not null and n.nspname not in ('pg_catalog', 'information_schema')
  union all
  select 'default', pg_get_userbyid(a.defaclrole) || ' ' || coalesce(a.defaclnamespace::regnamespace::text, '*') || ' ' || a.defaclobjtype::text, a.defaclacl::text from pg_default_acl a
) x order by 1, 2;
`;

// 4-1 복원 Job 시작 스크립트(restore.md 그대로). DATABASE_URL에서 비밀번호만 꺼내 메모리 pgpass로 둔다(argv에 없다).
export const DB_JOB_SCRIPT = `set -euo pipefail
umask 077
enc=\${DATABASE_URL#*://*:}; enc=\${enc%%@*}
case $enc in *%0[AaDd]*) echo "비밀번호에 줄바꿈이 있다. 영숫자로 다시 만든다" >&2; exit 1;; esac
pw=$(printf '%b' "\${enc//%/\\\\x}")
pw=\${pw//\\\\/\\\\\\\\}; pw=\${pw//:/\\\\:}
printf '%s:%s:*:%s:%s\\n' "$PGHOST" "$PGPORT" "$PGUSER" "$pw" > "$PGPASSFILE"
unset enc pw
exec sleep 7000
`;

const RCLONE_IMAGE = "docker.io/rclone/rclone:1.75.2@sha256:2687085f718d3c628f7fdfb77c52a1d344332aed543110bb88088f2c70d43eb5";

// pg_restore를 파이프 소비자로 쓸 때의 고정 셸. --list나 ACL만 고른 -L은 데이터 본문을 다 읽지 않고 끝나 생산자가 SIGPIPE(141)로
// 죽는다(#885 리뷰 실측: 22MB 덤프, PostgreSQL 18.6). 끝난 뒤 남은 stdin을 읽어 버리고 pg_restore의 종료 코드를 그대로 낸다.
// 생산자의 141을 성공으로 바꾸지 않는다(진짜 생산자 실패를 숨긴다).
export const PG_RESTORE_DRAINED = 'pg_restore "$@"; rc=$?; cat >/dev/null; exit $rc';
const drained = (args: string[]) => ["sh", "-c", PG_RESTORE_DRAINED, "sh", ...args];

// 파드 안 고정 파일 이름. 내용은 이 모듈이 만든 것만 쓴다.
const LIST_FILES = { main: "/tmp/main.list", acl: "/tmp/acl.list", aclsu: "/tmp/acl-su.list" } as const;

// --- 순수 판정(단위 시험 대상) ---

export type ExtEntry = { name: string; schema: string; version: string; owner: string };

// 출력용: 제어 문자를 보이는 꼴로(cat -v 대신).
const shown = (l: string) => l.replace(/[\u0000-\u001f\u007f-\u009f]/g, (c) => `\\x${c.charCodeAt(0).toString(16).padStart(2, "0")}`).slice(0, 200);

// extok: 네 칸 모양, 소유자는 postgres 또는 앱 역할만. 빈 값은 확장 없음.
export function parseExt(text: string, app: string): ExtEntry[] {
  const re = new RegExp(`^[a-z][a-z0-9_-]{0,62} [a-z_][a-z0-9_]{0,62} [A-Za-z0-9._-]{1,32} (postgres|${app.replace(/-/g, "\\-")})$`);
  const lines = text.split("\n").filter((l) => l !== "");
  const bad = lines.filter((l) => !re.test(l));
  if (bad.length) throw new Error(`이름·버전·소유자 모양이 이상한 확장 줄이 있다: ${bad.slice(0, 5).map(shown).join(" | ")}`);
  return lines.map((l) => {
    const [name, schema, version, owner] = l.split(" ");
    return { name, schema, version, owner };
  });
}

// 4-2의 awk 세 개: 본 복원 목록(미리 만들 확장과 그 스키마를 주석으로), ACL 항목을 객체 소유자로 나누기.
export function buildLists(list: string, ext: ExtEntry[], app: string): { main: string; acl: string; aclsu: string } {
  const names = new Set(ext.flatMap((e) => [e.name, `"${e.name}"`]));
  const schemas = new Set(ext.filter((e) => e.schema !== "public").map((e) => e.schema));
  const lines = list.split("\n");
  if (lines.at(-1) === "") lines.pop();
  const f = (l: string) => l.trim().split(/\s+/);
  const main = lines.map((l) => {
    const x = f(l);
    const skip = (x[3] === "EXTENSION" && x[4] === "-" && names.has(x[5])) || (x[3] === "COMMENT" && x[5] === "EXTENSION" && names.has(x[6])) || (x[3] === "SCHEMA" && x[4] === "-" && schemas.has(x[5]));
    return skip ? `;${l}` : l;
  });
  const aclAll = lines.filter((l) => /^[0-9]+; [0-9]+ [0-9]+ (ACL|DEFAULT ACL) /.test(l));
  const owner = (l: string) => f(l).at(-1);
  const odd = aclAll.filter((l) => ![app, "pg_database_owner", "postgres"].includes(owner(l) ?? ""));
  if (odd.length) throw new Error(`앱 역할·pg_database_owner·postgres 밖의 소유자가 있는 ACL 항목이 있다: ${odd.slice(0, 5).map(shown).join(" | ")}`);
  const join = (ls: string[]) => (ls.length ? `${ls.join("\n")}\n` : "");
  const out = { main: join(main), acl: join(aclAll.filter((l) => owner(l) === app || owner(l) === "pg_database_owner")), aclsu: join(aclAll.filter((l) => owner(l) === "postgres")) };
  if (!out.main.trim()) throw new Error("본 복원 목록이 비었다");
  return out;
}

const SQLOK_SET = /^SET (statement_timeout|lock_timeout|idle_in_transaction_session_timeout|transaction_timeout|client_encoding|standard_conforming_strings|check_function_bodies|xmloption|client_min_messages|row_security|default_tablespace|default_table_access_method) = [^;]*;$/;

// sqlok: postgres로 넣을 ACL SQL의 문장 종류를 줄마다 본다(restore.md 그대로). 허용 밖 줄을 돌려준다(없으면 []).
export function sqlProblems(sql: string, app: string): string[] {
  const ok = (l: string) =>
    /^(GRANT|REVOKE) .*;$/.test(l) ||
    /^ALTER DEFAULT PRIVILEGES FOR ROLE postgres (IN SCHEMA [^ ]+ )?(GRANT|REVOKE) .*;$/.test(l) ||
    l === `SET SESSION AUTHORIZATION ${app};` ||
    l === `SET SESSION AUTHORIZATION "${app}";` ||
    l === "RESET SESSION AUTHORIZATION;" ||
    SQLOK_SET.test(l) ||
    l === "SELECT pg_catalog.set_config('search_path', '', false);" ||
    /^\\(un)?restrict [A-Za-z0-9]+$/.test(l) ||
    l.startsWith("--") ||
    l === "";
  return sql.split("\n").filter((l) => !ok(l)).map(shown);
}

const ACL_LINE = /^[0-9]+; [0-9]+ [0-9]+ (ACL|DEFAULT ACL) /;

function inputsSha(i: { ext: string; main: string; acl: string; aclsu: string }): string {
  return new Bun.CryptoHasher("sha256").update(jsonStringify([i.ext, i.main, i.acl, i.aclsu])).digest("hex");
}

// --- 어댑터 ---

function check(app: string, run: string): void {
  if (!fullMatch(APP_NAME, app)) throw new Error("앱 이름 형식이 아니다");
  if (!RUN.test(run)) throw new Error("복원 실행 id 형식이 아니다");
}

export function pgRestoreWrite(exec: Exec, k8s: KubeRead, pipe: Pipe, pollJob: (ns: string, job: string) => boolean): PgRestoreWrite {
  const appNs = (app: string) => `app-${app}`;
  const dbJob = (run: string) => `restore-${run}-db`;
  const r2Job = (run: string) => `restore-${run}-r2`;
  const tmpCluster = (run: string) => `pg-restore-${run}`;

  const must = (r: ReturnType<Exec>, what: string): string => {
    if (r.errKind === "timeout") throw new ExecTimeout(`${what}: 시간 초과(결과 미상)`);
    if (r.code !== 0) throw new Error(`${what}: ${why(r)}`);
    return r.stdout;
  };
  const primary = (): string => {
    const pod = k8s.get("cluster", "database", "pg")?.status?.currentPrimary;
    if (typeof pod !== "string" || !PRIMARY.test(pod)) throw new Error("CNPG pg의 currentPrimary를 읽지 못했다");
    return pod;
  };
  const tmpPod = (run: string): string => {
    const pod = k8s.get("cluster", "database", tmpCluster(run))?.status?.currentPrimary;
    if (typeof pod !== "string" || !new RegExp(`^pg-restore-${run}-[0-9]+$`).test(pod)) throw new Error("임시 클러스터의 주 파드를 읽지 못했다");
    return pod;
  };
  // postgres로 primary(또는 임시 클러스터 파드)에 SQL. 값은 -v 변수로만.
  const psqlArgv = (pod: string, vars: Record<string, string>, db?: string, extra: string[] = []) => [
    "kubectl", "-n", "database", "exec", "-i", pod, "-c", "postgres", RT, "--",
    "psql", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-tA", ...(db ? ["-d", db] : []), ...extra,
    ...Object.entries(vars).flatMap(([k, v]) => ["-v", `${k}=${v}`]),
  ];
  const q = (pod: string, sql: string, vars: Record<string, string>, db?: string, extra: string[] = []) => must(exec(psqlArgv(pod, vars, db, extra), { input: sql }), "psql").trim();
  // 복원 Job(앱 역할) 안에서. 긴 흐름(파이프)에는 --request-timeout을 붙이지 않는다(스트림이 20초에 끊길 수 있다).
  const jobArgv = (app: string, run: string, cmd: string[], rt = true) => ["kubectl", "-n", appNs(app), "exec", "-i", `job/${dbJob(run)}`, ...(rt ? [RT] : []), "--", ...cmd];
  // 덤프 원본은 2단계에서 고정한 임시 주 파드(기록 tmp)다. 지금 주 파드가 그와 다르면 멈춘다(#885 리뷰 P1: 다시 고르면
  // 검증하지 않은 다른 파드의 덤프로 DB를 지울 수 있다. pg_restore -L은 OID를 대조하지 않아 목록이 읽힌다는 것은 증거가 아니다).
  const dumpArgv = (app: string, run: string) => ["kubectl", "-n", "database", "exec", pinnedTmp(app, run), "-c", "postgres", "--", "pg_dump", "-U", "postgres", "-Fc", "-d", app];
  const piped = async (producer: string[], consumer: string[], what: string): Promise<string> => {
    const r = await pipe(producer, consumer);
    if (r.timedOut) throw new ExecTimeout(`${what}: 시간 초과(결과 미상)`);
    if (r.producerCode !== 0 || r.consumerCode !== 0) throw new Error(`${what}: exit ${r.producerCode}|${r.consumerCode}(오류 원문은 데이터가 섞일 수 있어 버렸다)`);
    return r.stdout;
  };
  const putFile = (app: string, run: string, path: string, text: string) => must(exec(jobArgv(app, run, ["sh", "-c", `cat > ${path}`]), { input: text }), `복원 Job ${path}`);
  const jobUser = (app: string, run: string, db: string): string => must(exec(jobArgv(app, run, ["psql", "-d", db, "-v", "ON_ERROR_STOP=1", "-tAc", "select current_user"])), "복원 Job 접속").trim();
  const jobAuth = (app: string, run: string, db: string) => {
    if (!pollJob(appNs(app), dbJob(run))) throw new Error("복원 Job이 Ready가 아니다(4-1을 다시)");
    if (jobUser(app, run, db) !== app) throw new Error("복원 Job이 앱 역할로 접속하지 않는다");
  };
  const dbCount = (app: string): 0 | 1 => {
    const n = q(primary(), "select count(*) from pg_database where datname = :'app'\n", { app });
    if (n !== "0" && n !== "1") throw new Error("DB 개수를 읽지 못했다");
    return n === "1" ? 1 : 0;
  };
  const bucketNow = (): string => {
    const dest = k8s.get("objectstore", "database", "r2")?.spec?.configuration?.destinationPath;
    const m = typeof dest === "string" ? BUCKET.exec(dest) : null;
    if (!m) throw new Error("ObjectStore r2의 destinationPath에서 버킷을 읽지 못했다");
    return m[1];
  };
  // 되돌림 사본 버킷은 이 실행에서 처음 한 번 기록(bucket)에 고정하고 조회·올리기·끝까지 읽기가 같은 값을 쓴다(#885 리뷰 P1,
  // 런북 vars.env의 BUCKET). 그 뒤 ObjectStore가 바뀌어도 원래 사본 위치를 쓴다.
  const fixedBucket = (app: string, run: string): string => {
    const rec = record(app, run);
    const b = rec.data.bucket;
    if (b !== undefined) {
      if (!BUCKET_NAME.test(b)) throw new Error("기록의 bucket 형식이 아니다");
      return b;
    }
    const now = bucketNow();
    updateRecord(exec, k8s, appNs(app), RECORD, run, { bucket: now }, true);
    return now;
  };
  const r2Path = (app: string, run: string) => `/pgdump/${app}/pre-restore-${run}.dump`;
  const r2Argv = (run: string, cmd: string[], rt = true) => ["kubectl", "-n", "database", "exec", "-i", `job/${r2Job(run)}`, ...(rt ? [RT] : []), "--", ...cmd];

  // 잠금(mine)과 기록. 기록은 앱 ns의 restore-pg, 값은 03 2절.
  const record = (app: string, run: string) => {
    const r = k8s.restoreRecord(appNs(app), RECORD);
    if (!r || r.run !== run) throw new Error(`멈춤: 복원 잠금이 이 실행(${run})의 것이 아니다`);
    return r;
  };
  // stopped(restore.md 2절 머리): Deployment 0, 실제 0, 끝나지 않은 앱 파드 없음.
  const stopped = (app: string) => {
    const d = k8s.get("deployment", appNs(app), app);
    if (!d) throw new Error(`Deployment ${app}을 읽지 못했다`);
    const live = k8s.list("pod", appNs(app), `homelab.ukyi.app/app=${app}`).filter((p) => p?.status?.phase !== "Succeeded" && p?.status?.phase !== "Failed");
    if (d.spec?.replicas !== 0 || (d.status?.replicas ?? 0) !== 0 || live.length > 0) throw new Error("멈춤: 앱이 멈춰 있지 않다(suspended PR 병합을 확인한다)");
  };
  // same: 기록의 in.*가 4-2가 고정한 그대로이고 형식이 맞는지.
  const inputs = (app: string, run: string): { ext: ExtEntry[]; main: string; acl: string; aclsu: string } => {
    const d = record(app, run).data;
    const i = { ext: d["in.ext"], main: d["in.main"], acl: d["in.acl"], aclsu: d["in.aclsu"] };
    if ([i.ext, i.main, i.acl, i.aclsu].some((x) => typeof x !== "string") || d["in.sha"] !== inputsSha(i as Required<typeof i>)) throw new Error("4-2 뒤 입력이 없어졌거나 바뀌었다. 4-2(prepareInputs)를 다시 돈다");
    const ext = parseExt(i.ext!, app);
    if (!i.main!.trim()) throw new Error("본 복원 목록이 비었다");
    if (i.acl && !i.acl.split("\n").filter(Boolean).every((l) => ACL_LINE.test(l))) throw new Error("ACL 목록 형식이 아니다");
    const bad = sqlProblems(i.aclsu!, app);
    if (bad.length) throw new Error(`postgres로 넣을 ACL에 허용하지 않는 문장이 있다: ${bad.slice(0, 5).join(" | ")}`);
    return { ext, main: i.main!, acl: i.acl!, aclsu: i.aclsu! };
  };
  const guard = (app: string, run: string) => {
    record(app, run);
    stopped(app);
    return inputs(app, run);
  };
  const mainReadable = async (app: string, run: string, main: string) => {
    putFile(app, run, LIST_FILES.main, main);
    await piped(dumpArgv(app, run), jobArgv(app, run, drained(["-L", LIST_FILES.main, "-f", "/dev/null"]), false), "본 복원 목록으로 덤프 읽기");
  };
  const createJob = (ns: string, name: string, manifest: object) => {
    // 같은 RUN의 재시도: 파드까지 지운 뒤(foreground) 새로 만든다(restore.md 1·4-1).
    must(exec(["kubectl", "-n", ns, "delete", "jobs.batch", name, "--ignore-not-found", "--cascade=foreground", "--wait=true", "--timeout=120s", RT], { timeoutMs: 150_000 }), `Job ${name} 지우기`);
    must(exec(["kubectl", "-n", ns, "create", "-f", "-", RT], { input: jsonStringify(manifest) }), `Job ${name} 만들기`);
  };
  const r2DumpExists = (app: string, run: string, bucket: string): boolean =>
    must(exec(r2Argv(run, ["rclone", "lsf", "-R", "--files-only", `r2:${bucket}`, "--include", r2Path(app, run)])), "되돌림 사본 찾기").trim() !== "";
  // 2단계에서 고정한 임시 주 파드. 기록 tmp가 있고 지금 currentPrimary와 같아야 한다.
  const pinnedTmp = (app: string, run: string): string => {
    const t = record(app, run).data.tmp;
    if (typeof t !== "string" || !new RegExp(`^pg-restore-${run}-[0-9]+$`).test(t)) throw new Error("기록에 고정한 임시 주 파드(tmp)가 없다. 2단계(pinTmpPrimary)를 먼저 돈다");
    if (tmpPod(run) !== t) throw new Error("멈춤: 임시 클러스터의 주 파드가 2단계와 다르다. 정리하고 새 실행으로 다시 시작한다");
    return t;
  };
  const srcOk = (app: string, run: string, v: { t1: string; srv: string }): boolean => {
    const t = record(app, run).data.tmp;
    const c = k8s.get("cluster", "database", tmpCluster(run));
    const ready = (c?.status?.conditions ?? []).some((x: any) => x?.type === "Ready" && x?.status === "True");
    const origin = (c?.spec?.externalClusters ?? []).find((x: any) => x?.name === "origin");
    return (
      ready &&
      typeof t === "string" &&
      c?.status?.currentPrimary === t &&
      c?.spec?.bootstrap?.recovery?.source === "origin" &&
      c?.spec?.bootstrap?.recovery?.recoveryTarget?.targetTime === v.t1 &&
      origin?.plugin?.name === "barman-cloud.cloudnative-pg.io" &&
      origin?.plugin?.parameters?.barmanObjectName === "r2" &&
      origin?.plugin?.parameters?.serverName === v.srv
    );
  };
  const labels = (run: string) => ({ [RESTORE_LABEL]: run });
  const restricted = (uid: number) => ({ runAsNonRoot: true, runAsUser: uid, runAsGroup: uid, seccompProfile: { type: "RuntimeDefault" } });
  const containerSec = { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } };

  return {
    createR2Helper(run) {
      check("x", run);
      const name = r2Job(run);
      const env = [
        { name: "HOME", value: "/tmp" },
        { name: "RCLONE_CONFIG_R2_TYPE", value: "s3" },
        { name: "RCLONE_CONFIG_R2_PROVIDER", value: "Cloudflare" },
        { name: "RCLONE_CONFIG_R2_REGION", value: "auto" },
        { name: "RCLONE_CONFIG_R2_NO_CHECK_BUCKET", value: "true" },
        ...(["ACCESS_KEY_ID", "SECRET_ACCESS_KEY", "ENDPOINT_URL"] as const).map((k) => ({ name: `RCLONE_CONFIG_R2_${k === "ENDPOINT_URL" ? "ENDPOINT" : k}`, valueFrom: { secretKeyRef: { name: "r2-backup", key: k } } })),
      ];
      createJob("database", name, {
        apiVersion: "batch/v1",
        kind: "Job",
        metadata: { name, namespace: "database", labels: labels(run) },
        spec: {
          backoffLimit: 0,
          activeDeadlineSeconds: 7200,
          template: {
            metadata: { labels: labels(run) },
            spec: {
              restartPolicy: "Never",
              automountServiceAccountToken: false,
              securityContext: restricted(65532),
              containers: [{ name: "rclone", image: RCLONE_IMAGE, command: ["sleep", "7000"], env, resources: { requests: { cpu: "10m", memory: "64Mi" }, limits: { memory: "128Mi" } }, securityContext: containerSec, volumeMounts: [{ name: "tmp", mountPath: "/tmp" }] }],
              volumes: [{ name: "tmp", emptyDir: { sizeLimit: "16Mi" } }],
            },
          },
        },
      });
    },
    createDbJob(app, run, img) {
      check(app, run);
      if (!IMG.test(img)) throw new Error("이미지 형식이 아니다(태그@digest)");
      const name = dbJob(run);
      const env = [
        { name: "HOME", value: "/tmp" },
        { name: "PGHOST", value: "pg-rw.database.svc" },
        { name: "PGPORT", value: "5432" },
        { name: "PGUSER", value: app },
        { name: "PGDATABASE", value: app },
        { name: "PGSSLMODE", value: "require" },
        { name: "PGPASSFILE", value: "/tmp/pgpass" },
        { name: "DATABASE_URL", valueFrom: { secretKeyRef: { name: `${app}-db`, key: "DATABASE_URL" } } },
      ];
      createJob(appNs(app), name, {
        apiVersion: "batch/v1",
        kind: "Job",
        metadata: { name, namespace: appNs(app), labels: labels(run) },
        spec: {
          backoffLimit: 0,
          activeDeadlineSeconds: 7200,
          template: {
            metadata: { labels: labels(run) },
            spec: {
              restartPolicy: "Never",
              automountServiceAccountToken: false,
              enableServiceLinks: false,
              securityContext: restricted(26),
              containers: [{ name: "restore", image: img, command: ["bash", "-c"], args: [DB_JOB_SCRIPT], env, resources: { requests: { cpu: "50m", memory: "128Mi" }, limits: { memory: "256Mi" } }, securityContext: containerSec, volumeMounts: [{ name: "tmp", mountPath: "/tmp" }] }],
              volumes: [{ name: "tmp", emptyDir: { medium: "Memory", sizeLimit: "16Mi" } }],
            },
          },
        },
      });
    },
    createTmpCluster(run, v) {
      check("x", run);
      if (!T1.test(v.t1) || !SRV.test(v.srv) || !IMG.test(v.img) || !SIZE.test(v.size)) throw new Error("임시 클러스터 값 형식이 아니다(T1·serverName·이미지·크기)");
      // 같은 RUN의 것이 이미 있으면 재사용하지 않는다(복구 지점을 바꿀 수 없다, restore.md 2단계).
      if (k8s.get("cluster", "database", tmpCluster(run))) throw new Error(`임시 클러스터 ${tmpCluster(run)}가 이미 있다. 정리하고 새 실행으로 다시 시작한다`);
      const manifest = {
        apiVersion: "postgresql.cnpg.io/v1",
        kind: "Cluster",
        metadata: { name: tmpCluster(run), namespace: "database", labels: labels(run) },
        spec: {
          instances: 1,
          imageName: v.img,
          inheritedMetadata: { labels: labels(run) },
          storage: { storageClass: "local-path", size: v.size },
          bootstrap: { recovery: { source: "origin", recoveryTarget: { targetTime: v.t1 } } },
          // WAL 아카이버 plugin을 붙이지 않는다(운영 prefix에 쓰지 않게, 설계 B.8 E6).
          externalClusters: [{ name: "origin", plugin: { name: "barman-cloud.cloudnative-pg.io", parameters: { barmanObjectName: "r2", serverName: v.srv } } }],
        },
      };
      must(exec(["kubectl", "-n", "database", "create", "-f", "-", RT], { input: jsonStringify(manifest) }), "임시 클러스터 만들기");
    },
    tmpPrimary: (run) => (check("x", run), tmpPod(run)),
    pinTmpPrimary(app, run) {
      check(app, run);
      const now = tmpPod(run);
      const t = record(app, run).data.tmp;
      if (t === undefined) updateRecord(exec, k8s, appNs(app), RECORD, run, { tmp: now }, true);
      else if (t !== now) throw new Error("멈춤: 임시 클러스터의 주 파드가 2단계와 다르다. 정리하고 새 실행으로 다시 시작한다");
      return now;
    },
    tmpDbCount(run, app) {
      check(app, run);
      const n = q(tmpPod(run), "select count(*) from pg_database where datname = :'app'\n", { app });
      if (n !== "0" && n !== "1") throw new Error("임시 클러스터의 DB 개수를 읽지 못했다");
      return n === "1" ? 1 : 0;
    },
    srcOk: (app, run, v) => (check(app, run), srcOk(app, run, v)),
    r2DumpExists: (app, run) => (check(app, run), r2DumpExists(app, run, fixedBucket(app, run))),
    async dumpToR2(app, run) {
      check(app, run);
      // 되돌림 사본은 한 실행에 한 번만, 덮어쓰지 않는다. 4-3에 들어간 뒤(dropped)의 DB는 원래 상태가 아니다.
      if (record(app, run).data.dropped === "1") throw new Error("4-3에 들어간 뒤라 되돌림 사본을 새로 만들지 않는다. 원래 사본을 찾는다");
      const bucket = fixedBucket(app, run);
      if (r2DumpExists(app, run, bucket)) throw new Error("되돌림 사본이 이미 있다(덮어쓰지 않는다)");
      await piped(["kubectl", "-n", "database", "exec", primary(), "-c", "postgres", "--", "pg_dump", "-U", "postgres", "-Fc", "-d", app], r2Argv(run, ["rclone", "rcat", `r2:${bucket}${r2Path(app, run)}`], false), "되돌림 사본 올리기");
    },
    async r2DumpReadable(app, run) {
      check(app, run);
      // 목록(--list)만 보면 잘린 사본도 통과한다. 끝까지 읽는다(restore.md 1단계).
      await piped(r2Argv(run, ["rclone", "cat", `r2:${fixedBucket(app, run)}${r2Path(app, run)}`], false), ["kubectl", "-n", "database", "exec", "-i", primary(), "-c", "postgres", "--", ...drained(["-f", "/dev/null"])], "되돌림 사본 끝까지 읽기");
    },
    dbCount: (app) => (check(app, "x"), dbCount(app)),
    roleFlags(app) {
      check(app, "x");
      return q(primary(), "select rolsuper, rolcreaterole, rolcreatedb, rolreplication, rolbypassrls from pg_roles where rolname = :'app'\n", { app });
    },
    jobAuth(app, run, db) {
      check(app, run);
      if (db !== "app" && db !== "postgres") throw new Error("db는 app·postgres만");
      jobAuth(app, run, db === "app" ? app : "postgres");
    },
    async prepareInputs(app, run): Promise<RestoreInputs> {
      check(app, run);
      record(app, run);
      jobAuth(app, run, dbCount(app) === 1 ? app : "postgres");
      const tmp = pinnedTmp(app, run);
      const list = await piped(dumpArgv(app, run), jobArgv(app, run, drained(["--list"]), false), "덤프 목록");
      if (!list.trim()) throw new Error("덤프 목록이 비었다");
      const extText = q(tmp, `${EXT_SQL}\n`, {}, app, ["-F", " "]);
      const ext = parseExt(extText, app);
      // 대상 이미지가 실제로 설치할 수 있는 이름·버전만. 앱 역할 소유는 trusted일 때만.
      for (const e of ext) {
        const tr = q(primary(), "select trusted from pg_available_extension_versions where name = :'e' and version = :'v'\n", { e: e.name, v: e.version });
        if (tr !== "t" && tr !== "f") throw new Error(`대상 이미지에 없는 확장·버전이다: ${e.name} ${e.version}`);
        if (e.owner === app && tr !== "t") throw new Error(`앱 역할 소유인데 trusted가 아닌 확장이다: ${e.name}`);
      }
      const lists = buildLists(list, ext, app);
      await mainReadable(app, run, lists.main);
      if (lists.acl) {
        putFile(app, run, LIST_FILES.acl, lists.acl);
        const sql = await piped(dumpArgv(app, run), jobArgv(app, run, drained(["-L", LIST_FILES.acl, "-f", "-"]), false), "앱 역할 ACL SQL 만들기");
        if (sql.includes("SESSION AUTHORIZATION")) throw new Error("앱 역할 ACL에 다른 역할로 바꿔 주는 문장이 있다(앱 역할로는 못 넣는다)");
      }
      let aclsu = "";
      if (lists.aclsu) {
        putFile(app, run, LIST_FILES.aclsu, lists.aclsu);
        aclsu = await piped(dumpArgv(app, run), jobArgv(app, run, drained(["-L", LIST_FILES.aclsu, "-f", "-"]), false), "postgres ACL SQL 만들기");
        const bad = sqlProblems(aclsu, app);
        if (bad.length) throw new Error(`postgres로 넣을 ACL에 허용하지 않는 문장이 있다: ${bad.slice(0, 5).join(" | ")}`);
      }
      const fixed = { ext: extText ? `${extText}\n` : "", main: lists.main, acl: lists.acl, aclsu };
      if (fixed.ext.length + fixed.main.length + fixed.acl.length + fixed.aclsu.length > MAX_INPUTS) throw new Error("4-2 입력이 기록 한도(900KiB)를 넘는다");
      updateRecord(exec, k8s, appNs(app), RECORD, run, { "in.ext": fixed.ext, "in.main": fixed.main, "in.acl": fixed.acl, "in.aclsu": fixed.aclsu, "in.sha": inputsSha(fixed) }, true);
      const count = (t: string) => t.split("\n").filter(Boolean).length;
      return { ext, mainEntries: count(lists.main), aclEntries: count(lists.acl), aclSuEntries: count(lists.aclsu) };
    },
    inputsOk(app, run) {
      check(app, run);
      try {
        inputs(app, run);
        return true;
      } catch {
        return false;
      }
    },
    async recreateDatabase(app, run, v) {
      check(app, run);
      const i = guard(app, run);
      if (!srcOk(app, run, v)) throw new Error("멈춤: 임시 클러스터가 이 실행의 복원 원본이 아니다(Ready·주 파드·복구 지점)");
      // 원본이 죽었으면 DROP 뒤에야 드러난다. 목록으로 덤프를 끝까지 읽어 본다(4-2와 같은 확인).
      await mainReadable(app, run, i.main);
      stopped(app);
      // 파괴 단계 표시(1단계가 되돌림 사본을 새로 만들지 않는다). DROP 전에 쓴다.
      updateRecord(exec, k8s, appNs(app), RECORD, run, { dropped: "1" }, true);
      const pod = primary();
      let dropped = false;
      if (dbCount(app) === 1) {
        jobAuth(app, run, app);
        q(pod, 'DROP DATABASE IF EXISTS :"app" WITH (FORCE)\n', { app });
        dropped = true;
      }
      // CNPG Database 리소스가 먼저 다시 만들 수 있다. 있으면 owner만 본다.
      const owner = q(pod, "select pg_get_userbyid(datdba) from pg_database where datname = :'app'\n", { app });
      if (owner === "") q(pod, 'CREATE DATABASE :"app" OWNER :"app"\n', { app });
      else if (owner !== app) throw new Error("DB owner가 앱 역할이 아니다");
      jobAuth(app, run, app);
      return dropped ? "recreated" : "created";
    },
    createExtensions(app, run) {
      check(app, run);
      const { ext } = guard(app, run);
      const pod = primary();
      for (const e of ext) {
        if (e.schema !== "public") q(pod, 'CREATE SCHEMA IF NOT EXISTS :"sch" AUTHORIZATION :"app"\n', { app, sch: e.schema }, app);
        const sql = "CREATE EXTENSION :\"e\" SCHEMA :\"sch\" VERSION :'v'\n";
        const vars = { e: e.name, sch: e.schema, v: e.version };
        if (e.owner === "postgres") q(pod, sql, vars, app);
        else must(exec(jobArgv(app, run, ["psql", "-v", "ON_ERROR_STOP=1", "-tA", ...Object.entries(vars).flatMap(([k, x]) => ["-v", `${k}=${x}`])]), { input: sql }), `확장 ${e.name} 만들기(앱 역할)`);
      }
    },
    async restoreMain(app, run) {
      check(app, run);
      const i = guard(app, run);
      jobAuth(app, run, app);
      putFile(app, run, LIST_FILES.main, i.main);
      await piped(dumpArgv(app, run), jobArgv(app, run, ["sh", "-c", `pg_restore -L ${LIST_FILES.main} --no-owner --no-privileges --exit-on-error -d "$PGDATABASE"; rc=$?; cat >/dev/null; exit $rc`], false), "본 복원");
    },
    async restoreAcl(app, run) {
      check(app, run);
      const i = guard(app, run);
      jobAuth(app, run, app);
      if (i.acl) {
        putFile(app, run, LIST_FILES.acl, i.acl);
        await piped(dumpArgv(app, run), jobArgv(app, run, ["sh", "-c", `pg_restore -L ${LIST_FILES.acl} --no-owner --exit-on-error -d "$PGDATABASE"; rc=$?; cat >/dev/null; exit $rc`], false), "앱 역할 ACL 복원");
      }
      // 4-2에서 만들고 이 모듈이 검증한 SQL만 postgres로 넣는다(guard가 sqlok를 다시 봤다).
      if (i.aclsu) must(exec(psqlArgv(primary(), {}, app, ["-q", "-o", "/dev/null"]), { input: i.aclsu }), "postgres ACL 복원");
    },
    aclCompare(app, run) {
      check(app, run);
      record(app, run);
      const src = q(pinnedTmp(app, run), ACL_SQL, {}, app, ["-q"]);
      const dst = q(primary(), ACL_SQL, {}, app, ["-q"]);
      // 둘 다 비면 "같음"이 된다. public 스키마 줄이 늘 있어 비지 않는다.
      if (!src || !dst) throw new Error("ACL 조회 결과가 비었다");
      const a = new Set(src.split("\n"));
      const b = new Set(dst.split("\n"));
      const diff = [...[...a].filter((l) => !b.has(l)).map((l) => `- ${shown(l)}`), ...[...b].filter((l) => !a.has(l)).map((l) => `+ ${shown(l)}`)];
      return { same: diff.length === 0, diff: diff.slice(0, 50) };
    },
  };
}
