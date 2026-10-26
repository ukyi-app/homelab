// DB 복원 흐름(core/pgrestore.ts, 03 2부). 순수 판정은 restore.md 2절의 awk·grep과 같은지, 흐름은 파괴 단계 앞의 확인이
// 하나라도 어긋나면 DROP·복원 호출이 0건인지 본다. 파드 안 명령은 PATH 스텁이다(실제 동작은 T12-05·2a 로컬 시험).
import { describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ExecTimeout } from "../../src/core/exec";
import { ACL_SQL, DB_JOB_SCRIPT, EXT_SQL, PG_RESTORE_DRAINED, buildLists, parseExt, sqlProblems } from "../../src/core/pgrestore";
import { REST, applyWith, kubectlRule, rule, sha256, testCtx, type Call, type Rule } from "../harness";

const RUNBOOK = readFileSync(join(import.meta.dir, "..", "..", "..", "docs", "runbooks-public", "restore.md"), "utf8");

describe("런북과 같은 텍스트", () => {
  test("복원 Job 시작 스크립트는 restore.md 4-1과 같다(주석 줄 제외)", () => {
    const block = RUNBOOK.split("name: restore-__RUN__-db")[1].split("args:\n               - |\n")[1].split("\n             env:")[0];
    const lines = block.split("\n").map((l) => l.replace(/^ {17}/, "")).filter((l) => l && !l.startsWith("#"));
    expect(DB_JOB_SCRIPT.trimEnd().split("\n")).toEqual(lines);
  });

  test("ACL 대조 조회는 restore.md 4-5 ACL_SQL과 같다", () => {
    const block = RUNBOOK.split("ACL_SQL=$(cat <<'SQL'\n")[1].split("\n   SQL\n")[0];
    expect(ACL_SQL.trimEnd().split("\n").map((l) => l.trim())).toEqual(block.split("\n").map((l) => l.trim()));
  });

  test("확장 조회는 restore.md 4-2와 같다", () => {
    expect(RUNBOOK).toContain(`"${EXT_SQL}"`);
  });
});

describe("순수 판정", () => {
  test("extok: 네 칸, 소유자는 postgres·앱 역할만, 따옴표·세미콜론 든 이름 거부", () => {
    expect(parseExt("uuid-ossp public 1.1 postgres\npgcrypto ext 1.3 smoke\n", "smoke")).toEqual([
      { name: "uuid-ossp", schema: "public", version: "1.1", owner: "postgres" },
      { name: "pgcrypto", schema: "ext", version: "1.3", owner: "smoke" },
    ]);
    expect(parseExt("", "smoke")).toEqual([]);
    expect(() => parseExt('e";DROP ROLE x public 1 postgres', "smoke")).toThrow("모양");
    expect(() => parseExt("pgcrypto public 1.3 other", "smoke")).toThrow("모양");
    expect(() => parseExt("pgcrypto public 1.3 postgres extra", "smoke")).toThrow("모양");
  });

  const LIST = [
    ";",
    "; Archive created at 2026-10-26",
    "215; 3079 16384 EXTENSION - pgcrypto",
    "4012; 0 0 COMMENT - EXTENSION pgcrypto",
    '216; 3079 16390 EXTENSION - "uuid-ossp"',
    "6; 2615 16385 SCHEMA - ext smoke",
    "220; 1259 16400 TABLE public t smoke",
    "4100; 0 0 ACL - SCHEMA public pg_database_owner",
    "4101; 0 0 ACL public TABLE t smoke",
    "4102; 0 0 ACL ext FUNCTION gen_random_uuid() postgres",
    "",
  ].join("\n");
  const EXT = [
    { name: "pgcrypto", schema: "ext", version: "1.3", owner: "postgres" },
    { name: "uuid-ossp", schema: "public", version: "1.1", owner: "postgres" },
  ];

  test("본 복원 목록: 미리 만들 확장·그 주석·public 밖 스키마만 ;로 뺀다. ACL은 소유자로 나눈다", () => {
    const l = buildLists(LIST, EXT, "smoke");
    expect(l.main.split("\n").filter((x) => x.startsWith(";2") || x.startsWith(";4") || x.startsWith(";6"))).toEqual([
      ";215; 3079 16384 EXTENSION - pgcrypto",
      ";4012; 0 0 COMMENT - EXTENSION pgcrypto",
      ';216; 3079 16390 EXTENSION - "uuid-ossp"',
      ";6; 2615 16385 SCHEMA - ext smoke",
    ]);
    expect(l.main).toContain("\n220; 1259 16400 TABLE public t smoke\n");
    expect(l.acl).toBe("4100; 0 0 ACL - SCHEMA public pg_database_owner\n4101; 0 0 ACL public TABLE t smoke\n");
    expect(l.aclsu).toBe("4102; 0 0 ACL ext FUNCTION gen_random_uuid() postgres\n");
  });

  test("다른 소유자의 ACL 항목이 있으면 멈춘다", () => {
    expect(() => buildLists(`${LIST}4200; 0 0 ACL public TABLE u other\n`, EXT, "smoke")).toThrow("밖의 소유자");
  });

  test("sqlok: GRANT·REVOKE·고정 머리만. 앱 역할 밖 SESSION AUTHORIZATION·임의 문장은 문제", () => {
    const ok = ["--", "-- PostgreSQL database dump", "\\restrict abc123", "SET statement_timeout = 0;", "SELECT pg_catalog.set_config('search_path', '', false);", "GRANT ALL ON FUNCTION ext.f() TO smoke;", "REVOKE ALL ON FUNCTION ext.f() FROM PUBLIC;", "ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA ext GRANT ALL ON TABLES TO smoke;", "SET SESSION AUTHORIZATION smoke;", "RESET SESSION AUTHORIZATION;", "\\unrestrict abc123", ""];
    expect(sqlProblems(ok.join("\n"), "smoke")).toEqual([]);
    for (const bad of ["SET SESSION AUTHORIZATION postgres;", "SET role = postgres;", "ALTER ROLE smoke SUPERUSER;", "SELECT 1;", "GRANT ALL ON t TO smoke; DROP TABLE x", "COPY t FROM PROGRAM 'id';"]) {
      expect([bad, sqlProblems(bad, "smoke").length]).toEqual([bad, 1]);
    }
  });
});

// --- 흐름 시험의 스텁 세계 ---

const RUN = "run1";
const TMP = "pg-restore-run1-1";
const ext = "pgcrypto public 1.3 postgres";
const list = "220; 1259 16400 TABLE public t smoke\n4101; 0 0 ACL public TABLE t smoke\n4102; 0 0 ACL public FUNCTION f() postgres\n";
const lists = buildLists(list, parseExt(ext, "smoke"), "smoke");
const aclsu = "GRANT ALL ON FUNCTION public.f() TO smoke;\n";
const fixed = { ext: `${ext}\n`, main: lists.main, acl: lists.acl, aclsu };
const inSha = sha256(JSON.stringify([fixed.ext, fixed.main, fixed.acl, fixed.aclsu]));

type World = { run?: string; replicas?: number; livePods?: number; inputs?: Partial<typeof fixed> & { sha?: string }; dropped?: boolean; dbCount?: string; srcTarget?: string; r2Have?: string; tmp?: string | null; current?: string; bucket?: string | null; storeBucket?: string };

function rules(w: World = {}): Rule[] {
  const i = { ...fixed, ...w.inputs };
  const data: Record<string, string> = { run: w.run ?? RUN, to: "2026-10-26 00:00:00+00", srv: "pg-v2", "in.ext": i.ext, "in.main": i.main, "in.acl": i.acl, "in.aclsu": i.aclsu, "in.sha": w.inputs?.sha ?? sha256(JSON.stringify([i.ext, i.main, i.acl, i.aclsu])) };
  if (w.dropped) data.dropped = "1";
  if (w.tmp !== null) data.tmp = w.tmp ?? TMP;
  if (w.bucket !== null) data.bucket = w.bucket ?? "homelab-backup";
  const record = JSON.stringify({ metadata: { resourceVersion: "9", labels: { "homelab.ukyi.app/restore": w.run ?? RUN } }, data });
  const psql = (vars: string[], resp: object) => rule(["kubectl", "-n", "database", "exec", "-i", "pg-2", "-c", "postgres", "--request-timeout=20s", "--", "psql", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-tA", ...vars], resp);
  const job = (cmd: string[], resp: object = {}) => rule(["kubectl", "-n", "app-smoke", "exec", "-i", `job/restore-${RUN}-db`, "--request-timeout=20s", "--", ...cmd], resp);
  const jobPipe = (cmd: string[], resp: object = {}) => rule(["kubectl", "-n", "app-smoke", "exec", "-i", `job/restore-${RUN}-db`, "--", ...cmd], resp);
  const drained = (args: string[]) => ["sh", "-c", PG_RESTORE_DRAINED, "sh", ...args];
  return [
    kubectlRule(["-n", "app-smoke", "get", "configmaps", "restore-pg", "-o", "json"], { stdout: record }),
    kubectlRule(["-n", "app-smoke", "patch", "configmaps", "restore-pg", "--type=json", "--patch-file=/dev/stdin"], {}),
    kubectlRule(["-n", "database", "get", "clusters.postgresql.cnpg.io", "pg", "-o", "json"], { stdout: JSON.stringify({ status: { currentPrimary: "pg-2" } }) }),
    kubectlRule(["-n", "database", "get", "clusters.postgresql.cnpg.io", `pg-restore-${RUN}`, "-o", "json"], {
      stdout: JSON.stringify({
        status: { currentPrimary: w.current ?? TMP, conditions: [{ type: "Ready", status: "True" }] },
        spec: { bootstrap: { recovery: { source: "origin", recoveryTarget: { targetTime: w.srcTarget ?? "2026-10-26 00:00:00+00" } } }, externalClusters: [{ name: "origin", plugin: { name: "barman-cloud.cloudnative-pg.io", parameters: { barmanObjectName: "r2", serverName: "pg-v2" } } }] },
      }),
    }),
    kubectlRule(["-n", "app-smoke", "get", "deployments.apps", "smoke", "-o", "json"], { stdout: JSON.stringify({ spec: { replicas: w.replicas ?? 0 }, status: {} }) }),
    kubectlRule(["-n", "app-smoke", "get", "pods", "-l", "homelab.ukyi.app/app=smoke", "-o", "json"], { stdout: JSON.stringify({ items: Array.from({ length: w.livePods ?? 0 }, () => ({ status: { phase: "Running" } })) }) }),
    kubectlRule(["-n", "app-smoke", "wait", "pods", "-l", `job-name=restore-${RUN}-db`, "--for=condition=Ready", "--timeout=60s"], {}),
    kubectlRule(["-n", "database", "get", "objectstores.barmancloud.cnpg.io", "r2", "-o", "json"], { stdout: JSON.stringify({ spec: { configuration: { destinationPath: `s3://${w.storeBucket ?? "homelab-backup"}/pg/` } } }) }),
    job(["psql", "-d", "smoke", "-v", "ON_ERROR_STOP=1", "-tAc", "select current_user"], { stdout: "smoke\n" }),
    job(["psql", "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-tAc", "select current_user"], { stdout: "smoke\n" }),
    job(["sh", "-c", REST], {}),
    job(["psql", REST], {}),
    // 파이프: 임시 클러스터 덤프 → 복원 Job
    rule(["kubectl", "-n", "database", "exec", TMP, "-c", "postgres", "--", "pg_dump", "-U", "postgres", "-Fc", "-d", "smoke"], { stdout: "PGDMP-fake-dump" }, { noStdin: true }),
    jobPipe(drained(["--list"]), { stdout: list }),
    jobPipe(drained(["-L", "/tmp/acl-su.list", "-f", "-"]), { stdout: aclsu }),
    jobPipe(drained(["-L", "/tmp/acl.list", "-f", "-"]), { stdout: "GRANT ALL ON TABLE public.t TO smoke;\n" }),
    jobPipe(drained(["-L", "/tmp/main.list", "-f", "/dev/null"]), {}),
    jobPipe(["sh", "-c", REST], {}),
    // primary psql: 개수·owner·확장 가능 여부·DDL
    psql(["-v", "app=smoke"], [{ stdout: `${w.dbCount ?? "1"}\n` }, { stdout: "smoke\n" }, {}]),
    psql(["-v", "e=pgcrypto", "-v", "v=1.3"], { stdout: "t\n" }),
    psql(["-d", "smoke", "-q", "-o", "/dev/null"], {}),
    psql(["-d", "smoke", "-q"], { stdout: "schema|public|-\n" }),
    psql([REST], {}),
    rule(["kubectl", "-n", "database", "exec", "-i", TMP, "-c", "postgres", "--request-timeout=20s", "--", "psql", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-tA", "-d", "smoke", "-F", " "], { stdout: `${ext}\n` }),
    rule(["kubectl", "-n", "database", "exec", "-i", TMP, "-c", "postgres", "--request-timeout=20s", "--", "psql", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-tA", "-d", "smoke", "-q"], { stdout: "schema|public|-\n" }),
    // R2 도우미
    rule(["kubectl", "-n", "database", "exec", "-i", `job/restore-${RUN}-r2`, "--request-timeout=20s", "--", "rclone", "lsf", REST], { stdout: w.r2Have ?? "" }),
    rule(["kubectl", "-n", "database", "exec", "-i", `job/restore-${RUN}-r2`, "--", "rclone", REST], { stdout: "PGDMP-fake-dump" }),
    rule(["kubectl", "-n", "database", "exec", "pg-2", "-c", "postgres", "--", "pg_dump", REST], { stdout: "PGDMP-live-dump" }, { noStdin: true }),
    rule(["kubectl", "-n", "database", "exec", "-i", "pg-2", "-c", "postgres", "--", ...drained(["-f", "/dev/null"])], {}),
  ];
}

const drops = (calls: Call[]) => calls.filter((c) => c.argv.includes("psql") && c.stdinSha256 === sha256('DROP DATABASE IF EXISTS :"app" WITH (FORCE)\n'));
const restores = (calls: Call[]) => calls.filter((c) => c.argv.some((a) => a.includes("--no-privileges") || a.includes("--no-owner --exit-on-error")));

describe("파이프", () => {
  test("생산자 출력이 그대로 소비자 stdin으로, 두 종료 코드를 함께 본다", async () => {
    const { ctx, calls } = testCtx("apply", rules());
    await applyWith(ctx, (w) => w.pgRestore.r2DumpReadable("smoke", RUN));
    const consumer = calls().calls.find((c) => c.argv.includes(PG_RESTORE_DRAINED) && c.argv.includes("/dev/null") && c.argv.includes("pg-2"))!;
    expect(consumer.stdinSha256).toBe(sha256("PGDMP-fake-dump"));
  });

  test("생산자가 실패하면 소비자가 0이어도 실패(잘린 입력을 성공으로 보지 않는다)", async () => {
    const broken = rules().map((r) => (r.argv.includes("rclone") && !r.argv.includes("lsf") ? { ...r, responses: [{ stdout: "PGDMP-half", code: 1 }] } : r));
    const { ctx } = testCtx("apply", broken);
    await expect(applyWith(ctx, (w) => w.pgRestore.r2DumpReadable("smoke", RUN))).rejects.toThrow("exit 1|0");
  });

  test("시간 초과면 둘 다 죽이고 ExecTimeout", async () => {
    const slow = rules().map((r) => (r.argv.includes("rclone") && !r.argv.includes("lsf") ? { ...r, responses: [{ sleepMs: 10_000 }] } : r));
    const { ctx } = testCtx("apply", slow);
    const started = Date.now();
    await expect(applyWith(ctx, (w) => w.pgRestore.r2DumpReadable("smoke", RUN))).rejects.toBeInstanceOf(ExecTimeout);
    expect(Date.now() - started).toBeLessThan(8_000);
  });

  test("되돌림 사본: 이미 있거나 dropped 뒤면 덮어쓰지 않는다(올리기 0건)", async () => {
    const uploads = (c: Call[]) => c.filter((x) => x.argv.includes("rcat"));
    const have = testCtx("apply", rules({ r2Have: "pgdump/smoke/pre-restore-run1.dump\n" }));
    await expect(applyWith(have.ctx, (w) => w.pgRestore.dumpToR2("smoke", RUN))).rejects.toThrow("이미 있다");
    const dropped = testCtx("apply", rules({ dropped: true }));
    await expect(applyWith(dropped.ctx, (w) => w.pgRestore.dumpToR2("smoke", RUN))).rejects.toThrow("4-3에 들어간 뒤");
    expect([...uploads(have.calls().calls), ...uploads(dropped.calls().calls)]).toEqual([]);
    const fresh = testCtx("apply", rules());
    await applyWith(fresh.ctx, (w) => w.pgRestore.dumpToR2("smoke", RUN));
    // 기록에 버킷이 없던 실행: ObjectStore의 버킷을 기록에 고정한 뒤 쓴다.
    const unpinned = testCtx("apply", rules({ bucket: null }).map((r) => (r.argv.includes("patch") ? { ...r, captureStdin: true } : r)));
    await applyWith(unpinned.ctx, (w) => w.pgRestore.dumpToR2("smoke", RUN));
    expect(JSON.parse(unpinned.calls().calls.find((c) => c.argv.includes("patch"))!.stdin!)).toContainEqual({ op: "add", path: "/data/bucket", value: "homelab-backup" });
    const up = uploads(fresh.calls().calls)[0];
    expect(up.argv.at(-1)).toBe("r2:homelab-backup/pgdump/smoke/pre-restore-run1.dump");
    expect(up.stdinSha256).toBe(sha256("PGDMP-live-dump"));
  });
});

describe("#885 리뷰 1라운드", () => {
  const v = { t1: "2026-10-26 00:00:00+00", srv: "pg-v2" };

  test("P1 임시 주 파드가 2단계(기록 tmp)와 다르면 srcOk false, DB 다시 만들기·복원이 멈추고 DROP·덤프 0건", async () => {
    const { ctx, calls } = testCtx("apply", rules({ current: "pg-restore-run1-2" }));
    expect((await applyWith(ctx, (w) => w.pgRestore.srcOk("smoke", RUN, v))).value).toBe(false);
    await expect(applyWith(ctx, (w) => w.pgRestore.recreateDatabase("smoke", RUN, v))).rejects.toThrow();
    await expect(applyWith(ctx, (w) => w.pgRestore.restoreMain("smoke", RUN))).rejects.toThrow("2단계와 다르다");
    expect(drops(calls().calls)).toEqual([]);
    expect(calls().calls.filter((c) => c.argv.includes("pg_dump"))).toEqual([]);
  });

  test("P1 pinTmpPrimary: 없으면 지금 주 파드를 기록에 고정, 있으면 같은지 보고 다르면 던진다. 기록이 없으면 덤프하지 않는다", async () => {
    const fresh = testCtx("apply", rules({ tmp: null }).map((r) => (r.argv.includes("patch") ? { ...r, captureStdin: true } : r)));
    expect((await applyWith(fresh.ctx, (w) => w.pgRestore.pinTmpPrimary("smoke", RUN))).value).toBe(TMP);
    expect(JSON.parse(fresh.calls().calls.find((c) => c.argv.includes("patch"))!.stdin!)).toContainEqual({ op: "add", path: "/data/tmp", value: TMP });
    await expect(applyWith(fresh.ctx, (w) => w.pgRestore.prepareInputs("smoke", RUN))).rejects.toThrow("tmp");
    const moved = testCtx("apply", rules({ current: "pg-restore-run1-2" }));
    await expect(applyWith(moved.ctx, (w) => w.pgRestore.pinTmpPrimary("smoke", RUN))).rejects.toThrow("2단계와 다르다");
    // 명령은 tmp·bucket을 쓸 수 없다.
    for (const k of ["tmp", "bucket"]) await expect(applyWith(moved.ctx, (w) => w.k8s.restoreRecordUpdate("app-smoke", "restore-pg", RUN, { [k]: "x" }))).rejects.toThrow("core만");
  });

  test("P1 되돌림 사본: 조회·올리기·끝까지 읽기가 기록에 고정한 같은 버킷 키를 쓴다(ObjectStore가 바뀌어도)", async () => {
    const { ctx, calls } = testCtx("apply", rules({ bucket: "bucket-one", storeBucket: "bucket-two" }));
    await applyWith(ctx, (w) => w.pgRestore.dumpToR2("smoke", RUN));
    await applyWith(ctx, (w) => w.pgRestore.r2DumpReadable("smoke", RUN));
    const keys = calls().calls.filter((c) => c.argv.includes("rclone")).map((c) => c.argv.find((a) => a.startsWith("r2:"))!);
    expect(keys).toEqual(["r2:bucket-one", "r2:bucket-one/pgdump/smoke/pre-restore-run1.dump", "r2:bucket-one/pgdump/smoke/pre-restore-run1.dump"]);
  });

  test("P2 목록·ACL·검증 소비자는 남은 stdin을 소진하는 고정 셸로 pg_restore를 부른다", async () => {
    const { ctx, calls } = testCtx("apply", rules());
    await applyWith(ctx, (w) => w.pgRestore.prepareInputs("smoke", RUN));
    await applyWith(ctx, (w) => w.pgRestore.restoreAcl("smoke", RUN));
    const restores = calls().calls.filter((c) => c.argv.some((a) => a.includes("pg_restore")));
    expect(restores.length).toBeGreaterThan(0);
    for (const c of restores) expect([c.argv.join(" "), c.argv.some((a) => a.includes("cat >/dev/null"))]).toEqual([c.argv.join(" "), true]);
  });

  test("P2 소진 셸: 입력을 다 읽지 않고 끝나는 pg_restore 앞의 생산자가 SIGPIPE로 죽지 않고, pg_restore 실패 코드는 그대로", () => {
    const dir = mkdtempSync(join(tmpdir(), "homelab-cli-test-drain-"));
    // 가짜 pg_restore: 앞 10바이트만 읽고 목록을 낸 뒤 끝낸다(--list의 실제 동작과 같은 모양). FAIL이면 3.
    writeFileSync(join(dir, "pg_restore"), '#!/bin/sh\nhead -c 10 >/dev/null\necho "list"\n[ "$FAIL" = 1 ] && exit 3\nexit 0\n');
    chmodSync(join(dir, "pg_restore"), 0o755);
    const run = (script: string, fail = "0") => {
      const p = Bun.spawnSync(["/bin/bash", "-c", 'head -c 5000000 /dev/zero | sh -c "$1" sh --list; echo "${PIPESTATUS[0]} ${PIPESTATUS[1]}"', "_", script], { env: { PATH: `${dir}:/usr/bin:/bin`, FAIL: fail } });
      return p.stdout.toString().trim().split("\n");
    };
    expect(run(PG_RESTORE_DRAINED)).toEqual(["list", "0 0"]);
    expect(run(PG_RESTORE_DRAINED, "1")).toEqual(["list", "0 3"]);
    // 대조군: 소진하지 않으면 생산자가 141(SIGPIPE)이다(#885 리뷰 실측과 같은 꼴).
    expect(run('pg_restore "$@"')).toEqual(["list", "141 0"]);
  });
});

describe("4-2 입력 고정", () => {
  test("prepareInputs: 목록·확장·ACL을 만들어 기록 in.*에 고정한다(sha 포함, DB 쓰기 0)", async () => {
    const rs = rules().map((r) => (r.argv.includes("patch") ? { ...r, captureStdin: true } : r));
    const { ctx, calls } = testCtx("apply", rs);
    const { value } = await applyWith(ctx, (w) => w.pgRestore.prepareInputs("smoke", RUN));
    expect(value).toEqual({ ext: [{ name: "pgcrypto", schema: "public", version: "1.3", owner: "postgres" }], mainEntries: 3, aclEntries: 1, aclSuEntries: 1 });
    const ops = JSON.parse(calls().calls.find((c) => c.argv.includes("patch"))!.stdin!);
    const set = Object.fromEntries(ops.filter((o: any) => o.op === "add").map((o: any) => [o.path, o.value]));
    expect(ops[0]).toEqual({ op: "test", path: "/data/run", value: RUN });
    expect(set["/data/in.sha"]).toBe(inSha);
    expect(set["/data/in.aclsu"]).toBe(aclsu);
    expect(drops(calls().calls)).toEqual([]);
  });

  test("postgres용 ACL SQL에 허용 밖 문장이 있으면 기록하지 않는다", async () => {
    const evil = rules().map((r) => (r.argv.includes("/tmp/acl-su.list") ? { ...r, responses: [{ stdout: "GRANT ALL ON FUNCTION public.f() TO smoke;\nALTER ROLE smoke SUPERUSER;\n" }] } : r));
    const { ctx, calls } = testCtx("apply", evil);
    await expect(applyWith(ctx, (w) => w.pgRestore.prepareInputs("smoke", RUN))).rejects.toThrow("허용하지 않는 문장");
    expect(calls().calls.filter((c) => c.argv.includes("patch"))).toEqual([]);
  });

  test("명령은 기록의 in.*·dropped를 쓸 수 없다(core만)", async () => {
    const { ctx, calls } = testCtx("apply", rules());
    for (const k of ["in.main", "in.sha", "dropped"]) await expect(applyWith(ctx, (w) => w.k8s.restoreRecordUpdate("app-smoke", "restore-pg", RUN, { [k]: "x" }))).rejects.toThrow("core만");
    await expect(applyWith(ctx, (w) => w.k8s.restoreRecordCreate("app-smoke", "restore-pg", RUN, { "in.main": "x" }))).rejects.toThrow("core만");
    expect(calls().calls.filter((c) => c.argv.includes("patch") || c.argv.includes("create"))).toEqual([]);
  });
});

describe("4-3·4-4·4-5 파괴 단계 앞 확인", () => {
  const v = { t1: "2026-10-26 00:00:00+00", srv: "pg-v2" };

  test("다 맞으면 dropped를 DROP보다 먼저 쓰고 DB를 지우고 다시 만든다", async () => {
    const { ctx, calls } = testCtx("apply", rules());
    expect((await applyWith(ctx, (w) => w.pgRestore.recreateDatabase("smoke", RUN, v))).value).toBe("recreated");
    const c = calls().calls;
    const markIdx = c.findIndex((x) => x.argv.includes("patch"));
    const dropIdx = c.indexOf(drops(c)[0]);
    expect(markIdx).toBeGreaterThan(-1);
    expect(dropIdx).toBeGreaterThan(markIdx);
  });

  const cases: [string, World][] = [
    ["잠금이 다른 실행", { run: "run2" }],
    ["앱이 떠 있음(replicas 1)", { replicas: 1 }],
    ["끝나지 않은 앱 파드", { livePods: 1 }],
    ["4-2 뒤 입력이 바뀜(sha 불일치)", { inputs: { main: "220; 1259 16400 TABLE public t smoke\n", sha: inSha } }],
    ["sha를 맞춰 바꾼 SQL도 sqlok가 다시 거름", { inputs: { aclsu: "ALTER ROLE smoke SUPERUSER;\n" } }],
    ["임시 클러스터 복구 지점이 다름", { srcTarget: "2026-10-25 00:00:00+00" }],
  ];
  for (const [name, w] of cases) {
    test(`${name}: DB 다시 만들기·복원·ACL 복원이 모두 멈추고 DROP·복원 0건`, async () => {
      const { ctx, calls } = testCtx("apply", rules(w));
      await expect(applyWith(ctx, (x) => x.pgRestore.recreateDatabase("smoke", RUN, v))).rejects.toThrow();
      if (!name.startsWith("임시")) {
        await expect(applyWith(ctx, (x) => x.pgRestore.restoreMain("smoke", RUN))).rejects.toThrow();
        await expect(applyWith(ctx, (x) => x.pgRestore.restoreAcl("smoke", RUN))).rejects.toThrow();
      }
      expect(drops(calls().calls)).toEqual([]);
      expect(restores(calls().calls)).toEqual([]);
      expect(calls().calls.filter((c) => c.argv.includes("-o") && c.argv.includes("/dev/null") && c.argv.includes("-q"))).toEqual([]);
    });
  }

  test("ACL 복원: 앱 역할 ACL과 core가 검증한 postgres SQL만 넣는다", async () => {
    const { ctx, calls } = testCtx("apply", rules());
    await applyWith(ctx, (w) => w.pgRestore.restoreAcl("smoke", RUN));
    const su = calls().calls.find((c) => c.argv.includes("/dev/null") && c.argv.includes("-q"))!;
    expect(su.stdinSha256).toBe(sha256(aclsu));
    expect(calls().calls.some((c) => c.argv.join(" ").includes("pg_restore -L /tmp/acl.list --no-owner --exit-on-error"))).toBe(true);
  });

  test("aclCompare: 같으면 same, 다르면 차이 줄(제어 문자는 보이는 꼴)", async () => {
    const same = testCtx("apply", rules());
    expect((await applyWith(same.ctx, (w) => w.pgRestore.aclCompare("smoke", RUN))).value).toEqual({ same: true, diff: [] });
    const diff = rules().map((r) => (r.argv.includes(TMP) && r.argv.includes("-q") ? { ...r, responses: [{ stdout: "schema|public|-\nfunction|f\u001b()|{x}\n" }] } : r));
    const d = testCtx("apply", diff);
    expect((await applyWith(d.ctx, (w) => w.pgRestore.aclCompare("smoke", RUN))).value).toEqual({ same: false, diff: ["- function|f\\x1b()|{x}"] });
  });

  test("tmpDbCount: 임시 클러스터 주 파드에서 그 앱 DB 개수(0·1만)", async () => {
    const r = rules().map((x) => x);
    r.unshift(rule(["kubectl", "-n", "database", "exec", "-i", TMP, "-c", "postgres", "--request-timeout=20s", "--", "psql", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-tA", "-v", "app=smoke"], [{ stdout: "1\n" }, { stdout: "2\n" }]));
    const { ctx } = testCtx("apply", r);
    expect((await applyWith(ctx, (w) => w.pgRestore.tmpDbCount(RUN, "smoke"))).value).toBe(1);
    await expect(applyWith(ctx, (w) => w.pgRestore.tmpDbCount(RUN, "smoke"))).rejects.toThrow("개수");
  });

  test("aclCompare: 두 조회가 모두 비면 같다고 하지 않고 실패한다", async () => {
    const empty = rules().map((r) => (r.argv.includes("-q") && !r.argv.includes("/dev/null") ? { ...r, responses: [{ stdout: "" }] } : r));
    const { ctx } = testCtx("apply", empty);
    await expect(applyWith(ctx, (w) => w.pgRestore.aclCompare("smoke", RUN))).rejects.toThrow("비었다");
  });

  test("읽기 문맥에는 pgRestore가 없다", () => {
    const { ctx } = testCtx("plan", []);
    expect("pgRestore" in ctx).toBe(false);
  });
});
