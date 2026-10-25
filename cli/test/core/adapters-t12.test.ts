// 02·03·04가 요청한 core 어댑터 시험(~/t12/REPORT-adapters.md). argv 모양 고정, 읽기 문맥에 쓰기 없음, 시크릿은 불투명 핸들,
// 실패 주입. 스텁 규칙은 어댑터와 같은 argv 함수(kubectlRule 등)로 만든다.
import { describe, expect, test } from "bun:test";
import type { Observation, Step } from "../../src/core/command";
import { ExecTimeout } from "../../src/core/exec";
import { APP_REPO_CALLS, argvFor as ghArgv, parsePlanJson } from "../../src/core/github";
import { argvFor as infArgv } from "../../src/core/infisical";
import { parseRecord } from "../../src/core/kubectl";
import { newRunId } from "../../src/core/names";
import { render } from "../../src/core/output";
import { PG_PASSWORD_CHECK, VALKEY_CLI } from "../../src/core/podops";
import { prStep } from "../../src/core/pr";
import { Secret } from "../../src/core/secret";
import { flow, setTopLevel } from "../../src/core/values";
import { FAKE_PROJECT, FAKE_SECRETS, FAKE_SHA, REST, applyWith, expectNoSecrets, expectPlanReadOnly, ghGet, ghResponse, ghSend, kubectlRule, rule, sha256, testCtx } from "../harness";

const b64 = (s: string) => Buffer.from(s).toString("base64");
const same = (detail = "됨"): Observation => ({ state: "same", action: "none", detail });

describe("엔진 hold", () => {
  const steps = (world: { held: boolean; applied: string[] }): Step[] => [
    {
      id: "pr-stop",
      target: "앱 멈춤 PR",
      read: async () => (world.applied.includes("pr-stop") ? { ...same(), ...(world.held ? { hold: "PR #12 병합 대기" } : {}) } : { state: "missing", action: "create", detail: "없음" }),
      apply: async () => void world.applied.push("pr-stop"),
    },
    {
      id: "drop",
      target: "DB 지우기",
      read: async () => (world.applied.includes("drop") ? same() : { state: "missing", action: "delete", detail: "지운다" }),
      apply: async () => void world.applied.push("drop"),
    },
  ];

  test("apply: 실행 뒤 hold면 뒤 단계는 not-run, waiting(3), 다음은 같은 apply. 풀린 뒤 재실행이 이어 간다", async () => {
    const world = { held: true, applied: [] as string[] };
    const { ctx } = testCtx("apply", []);
    const r = await ctx.engine({ command: "t", steps: steps(world) });
    expect([r.status, r.steps.map((s) => s.result)]).toEqual(["waiting", ["waiting", "not-run"]]);
    expect(world.applied).toEqual(["pr-stop"]);
    expect(r.next).toContain("PR #12 병합 대기. 끝나면 다시: homelab test");
    // 아직 병합 전 재실행: 아무것도 더 하지 않는다.
    const again = await ctx.engine({ command: "t", steps: steps(world) });
    expect([again.status, world.applied]).toEqual(["waiting", ["pr-stop"]]);
    world.held = false;
    const done = await ctx.engine({ command: "t", steps: steps(world) });
    expect([done.status, world.applied]).toEqual(["done", ["pr-stop", "drop"]]);
  });

  test("plan: 뒤 단계도 읽어 보이고 notes에 대기를 적는다", async () => {
    const world = { held: true, applied: ["pr-stop"] };
    const { ctx } = testCtx("plan", []);
    const r = await ctx.engine({ command: "t", steps: steps(world) });
    expect(r.status).toBe("pending");
    expect(r.steps.map((s) => s.result)).toEqual(["skipped", "planned"]);
    expect(r.notes.join("\n")).toContain("PR #12 병합 대기. 뒤 단계는 대기가 끝난 뒤 실행한다");
  });

  test("same이 아닌 관찰의 hold는 엔진이 거부한다(실패, 쓰기 0)", async () => {
    let applied = 0;
    const { ctx } = testCtx("apply", []);
    const r = await ctx.engine({ command: "t", steps: [{ id: "x", target: "x", read: async () => ({ state: "missing", action: "create", detail: "", hold: "대기" }), apply: async () => void applied++ }] });
    expect([r.status, applied]).toEqual(["failed", 0]);
  });
});

describe("결과 body·PR 요약", () => {
  test("body는 단계 뒤에 그대로, 제어 문자는 \\x 꼴로 바꾸고 JSON에도 같은 값을 둔다", async () => {
    const { ctx } = testCtx("read", []);
    const r = await ctx.engine({ command: "logs", steps: [{ id: "a", target: "로그", read: async () => same("200줄") }], body: "줄1\n\u001b[2J줄2\r\tok\n" });
    const human = render(r, false);
    expect(human).toContain("줄1\n\\x1b[2J줄2\\x0d\tok");
    expect(human).not.toContain("\u001b");
    expect(JSON.parse(render(r, true)).body).toBe("줄1\n\\x1b[2J줄2\\x0d\tok\n");
  });

  test("body에 이 실행이 다룬 시크릿이 섞이면 출력이 막힌다", async () => {
    new Secret(FAKE_SECRETS[0]);
    const { ctx } = testCtx("read", []);
    const r = await ctx.engine({ command: "logs", steps: [], body: `x ${FAKE_SECRETS[0]}` });
    expect(() => render(r, false)).toThrow("시크릿");
    expect(() => render(r, true)).toThrow("시크릿");
  });

  test("PrSpec.describe가 plan detail에 파일별 요약을 붙인다", async () => {
    const R = "repos/ukyi-app/homelab";
    const path = "apps/smoke/values.yaml";
    const { ctx } = testCtx("plan", [
      ghGet(`${R}/git/ref/heads/main`, 200, { object: { sha: FAKE_SHA } }),
      ghGet(`${R}/contents/${path}?ref=${FAKE_SHA}`, 200, { type: "file", encoding: "base64", content: b64("uses: { postgres: false }\n") }),
      ghGet(`${R}/pulls?head=${encodeURIComponent("ukyi-app:cli/db-add-smoke")}&state=open`, 200, []),
    ]);
    const step = prStep({ command: "db add", app: "smoke", title: "t", body: "b", files: [path], edit: () => ({ [path]: "uses: { postgres: true }\n" }), describe: () => "uses.postgres: false → true" });
    expect((await step.read(ctx)).detail).toBe("새로 (브랜치 cli/db-add-smoke); apps/smoke/values.yaml: uses.postgres: false → true");
  });
});

describe("values 편집", () => {
  const T11 = `# 앱 values(사람이 쓴 주석)
chartVersion: 1.0.0
public:
  host: smoke.ukyi.app  # 공개 주소
# 아래 uses는 CLI가 고친다
uses: { postgres: false }

secrets:
  - API_TOKEN
port: 8080
`;

  test("고친 키만 한 줄 flow로, 주석·다른 줄은 그대로", () => {
    const out = setTopLevel(T11, { uses: { postgres: true, valkey: true }, chartVersion: "1.1.0" });
    expect(out).toBe(`# 앱 values(사람이 쓴 주석)
chartVersion: 1.1.0
public:
  host: smoke.ukyi.app  # 공개 주소
# 아래 uses는 CLI가 고친다
uses: { postgres: true, valkey: true }

secrets:
  - API_TOKEN
port: 8080
`);
  });

  test("블록 키 지우기, 없는 키는 끝에 더한다", () => {
    const out = setTopLevel(T11, { secrets: undefined, public: undefined, cache: { enabled: true } });
    expect(out).toContain("# 아래 uses는 CLI가 고친다\nuses: { postgres: false }\n");
    expect(out).not.toContain("API_TOKEN");
    expect(out).not.toContain("smoke.ukyi.app");
    expect(out.endsWith("port: 8080\ncache: { enabled: true }\n")).toBe(true);
  });

  test("값 꼴: 예약어·숫자처럼 보이는 문자열은 따옴표, 시크릿 객체는 거부", () => {
    expect(flow({ a: "yes", b: "1.0", c: "smoke.ukyi.app", d: [1, "x y"] })).toBe('{ a: "yes", b: "1.0", c: smoke.ukyi.app, d: [1, "x y"] }');
    expect(() => flow({ k: new Secret(FAKE_SECRETS[0]) })).toThrow("시크릿");
    expect(() => setTopLevel(T11, { uses: { password: new Secret(FAKE_SECRETS[1]) } })).toThrow("시크릿");
  });

  test("블록 경계를 못 읽는 꼴은 고치지 않는다(따옴표 키, 여러 문서, 같은 키 두 번)", () => {
    expect(() => setTopLevel('"uses": { a: 1 }\n', { uses: { a: 2 } })).toThrow("블록을 찾지 못했다");
    expect(() => setTopLevel("a: 1\n---\nb: 2\n", { a: 2 })).toThrow("여러 문서");
    expect(() => setTopLevel("a: 1\nb: 2\na: 3\n", { b: 3 })).toThrow();
  });

  test("다시 읽은 값이 기대와 다르면 던진다(0열 주석 뒤 들여쓴 줄처럼 경계가 애매한 블록)", () => {
    expect(() => setTopLevel("a:\n  x: 1\n# 주석\n  y: 2\nb: 1\n", { a: { z: 1 } })).toThrow();
  });
});

describe("kubectl 읽기 확장", () => {
  test("새 종류와 Job 로그(--previous, -c)", () => {
    const { ctx, calls } = testCtx("read", [
      kubectlRule(["-n", "database", "get", "objectstores.barmancloud.cnpg.io", "r2", "-o", "json"], { stdout: "{}" }),
      kubectlRule(["-n", "app-smoke", "logs", "job/smoke-migrate", "--tail=50", "--previous", "-c", "migrate"], { stdout: "x\n" }),
    ]);
    expect(ctx.k8s.get("objectstore", "database", "r2")).toEqual({});
    expect(ctx.k8s.logs("app-smoke", { job: "smoke-migrate" }, { tail: 50, previous: true, container: "migrate" })).toBe("x\n");
    expect(() => ctx.k8s.logs("app-smoke", { job: "Bad_Name" })).toThrow();
    expectPlanReadOnly(calls());
  });

  const secretDoc = (value: string, rv = "7") => JSON.stringify({ metadata: { resourceVersion: rv }, data: { DATABASE_URL: b64(value), password: b64(value) } });

  test("secretEmbeds: 원문·URL 인코딩 꼴을 품는지만 보고 값은 어디에도 없다", () => {
    const pw = new Secret("fakevalue/with+sign=");
    const url = `postgres://smoke:${encodeURIComponent("fakevalue/with+sign=")}@pg-rw/smoke`;
    const { ctx, calls } = testCtx("read", [kubectlRule(["-n", "app-smoke", "get", "secrets", "smoke-db", "-o", "json"], [{ stdout: secretDoc(url) }, { stdout: secretDoc("other-value-0000000") }, { stdout: "", stderr: 'Error from server (NotFound): secrets "smoke-db" not found', code: 1 }])]);
    expect(ctx.k8s.secretEmbeds("app-smoke", "smoke-db", "DATABASE_URL", pw)).toBe(true);
    expect(ctx.k8s.secretEmbeds("app-smoke", "smoke-db", "DATABASE_URL", pw)).toBe(false);
    expect(ctx.k8s.secretEmbeds("app-smoke", "smoke-db", "DATABASE_URL", pw)).toBeNull();
    expectPlanReadOnly(calls(), { secrets: ["fakevalue/with+sign="] });
  });

  test("waitSecret: 맞을 때까지 다시 보고, 끝내 안 맞으면 false(시간 초과)", () => {
    const want = sha256("new-value-000000000").slice(0, 12);
    const argv = ["-n", "database", "get", "secret", "pg-role-smoke", "-o", "json"];
    const ok = testCtx("read", [kubectlRule(argv, [{ stdout: secretDoc("old-value-000000000") }, { stdout: secretDoc("new-value-000000000") }])]);
    expect(ok.ctx.k8s.waitSecret("database", "pg-role-smoke", "password", { hash: want }, 5)).toBe(true);
    expect(ok.calls().calls.length).toBe(2);
    const never = testCtx("read", [kubectlRule(argv, { stdout: secretDoc("old-value-000000000") })]);
    expect(never.ctx.k8s.waitSecret("database", "pg-role-smoke", "password", { hash: want }, 1)).toBe(false);
    expect(() => never.ctx.k8s.waitSecret("database", "pg-role-smoke", "password", { hash: want }, 301)).toThrow("1~300");
  });

  test("waitFor·waitCondition: argv 고정, 시간 초과는 false, 대상 없음은 던진다", () => {
    const { ctx, calls } = testCtx("read", [
      kubectlRule(["-n", "database", "wait", "clusters.postgresql.cnpg.io/pg-restore-x", "--for=jsonpath={.status.phase}=Cluster in healthy state", REST], {}),
      kubectlRule(["-n", "database", "wait", "clusters.postgresql.cnpg.io/pg", "--for=jsonpath={.status.currentPrimary}=pg-1", "--timeout=10s"], [{ code: 1, stderr: "error: timed out waiting for the condition" }, { code: 1, stderr: 'Error from server (NotFound): clusters "pg" not found' }]),
      kubectlRule(["-n", "app-smoke", "wait", "pods", "-l", "job-name=restore-vk", "--for=condition=Ready", "--timeout=300s"], {}),
    ]);
    expect(() => ctx.k8s.waitFor("cluster", "database", "pg-restore-x", "{.status.phase}", "Cluster in healthy state", 10)).toThrow("값 형식");
    expect(ctx.k8s.waitFor("cluster", "database", "pg", "{.status.currentPrimary}", "pg-1", 10)).toBe(false);
    expect(() => ctx.k8s.waitFor("cluster", "database", "pg", "{.status.currentPrimary}", "pg-1", 10)).toThrow("대상이 없다");
    expect(() => ctx.k8s.waitFor("cluster", "database", "pg", "{.spec.x}", "a", 10)).toThrow("jsonpath");
    expect(ctx.k8s.waitCondition("job", "app-smoke", { jobPods: "restore-vk" }, "Ready", 300)).toBe(true);
    expectPlanReadOnly(calls());
  });

  const deployment = (annotation?: string) =>
    JSON.stringify({
      metadata: { generation: 3 },
      spec: { replicas: 1, template: { metadata: { annotations: annotation ? { "homelab.ukyi.app/secrets-rv": annotation } : {} }, spec: { containers: [{ envFrom: [{ secretRef: { name: "smoke-app" } }], env: [{ valueFrom: { secretKeyRef: { name: "smoke-db", key: "DATABASE_URL" } } }] }], volumes: [{ secret: { secretName: "smoke-db" } }] } } },
      status: { observedGeneration: 3, replicas: 1, updatedReplicas: 1, availableReplicas: 1 },
    });
  const rvRules = () => [
    kubectlRule(["-n", "app-smoke", "get", "secrets", "smoke-app", "-o", "jsonpath={.metadata.resourceVersion}"], { stdout: "11" }),
    kubectlRule(["-n", "app-smoke", "get", "secrets", "smoke-db", "-o", "jsonpath={.metadata.resourceVersion}"], { stdout: "22" }),
  ];
  const HASH = sha256("smoke-app@11\nsmoke-db@22").slice(0, 16);

  test("podSecretsCurrent: 참조 Secret 전부의 rv 해시와 템플릿 주석을 비교한다(값은 안 읽는다)", () => {
    const cur = testCtx("read", [kubectlRule(["-n", "app-smoke", "get", "deployments.apps", "smoke", "-o", "json"], { stdout: deployment(HASH) }), ...rvRules()]);
    expect(cur.ctx.k8s.podSecretsCurrent("app-smoke", "smoke")).toEqual({ current: true, rolledOut: true, secrets: ["smoke-app", "smoke-db"] });
    const old = testCtx("read", [kubectlRule(["-n", "app-smoke", "get", "deployments.apps", "smoke", "-o", "json"], { stdout: deployment("0000000000000000") }), ...rvRules()]);
    expect(old.ctx.k8s.podSecretsCurrent("app-smoke", "smoke").current).toBe(false);
    expectPlanReadOnly(cur.calls());
  });

  test("restoreRecord: 라벨 = data.run, 키 형식, in.* 밖의 줄바꿈 거부. 범용 ConfigMap 이름은 받지 않는다", () => {
    const doc = (data: Record<string, string>, label = "20261026000000abcdef") => JSON.stringify({ metadata: { resourceVersion: "5", labels: { "homelab.ukyi.app/restore": label } }, data });
    const run = "20261026000000abcdef";
    const { ctx } = testCtx("read", [kubectlRule(["-n", "app-smoke", "get", "configmaps", "restore-pg", "-o", "json"], [{ stdout: doc({ run, to: "2026-10-26 00:00:00+00", "in.ext": "a\nb" }) }, { stdout: doc({ run }, "other") }, { stdout: doc({ run, to: "x\ny" }) }])]);
    expect(ctx.k8s.restoreRecord("app-smoke", "restore-pg")).toEqual({ run, data: { run, to: "2026-10-26 00:00:00+00", "in.ext": "a\nb" }, resourceVersion: "5" });
    expect(() => ctx.k8s.restoreRecord("app-smoke", "restore-pg")).toThrow("라벨");
    expect(() => ctx.k8s.restoreRecord("app-smoke", "restore-pg")).toThrow("제어 문자");
    expect(() => ctx.k8s.restoreRecord("app-smoke", "smoke-config" as never)).toThrow("restore-pg");
    expect(() => parseRecord({ metadata: { resourceVersion: "1", labels: { "homelab.ukyi.app/restore": run } }, data: { run, "Bad Key": "x" } }, "restore-pg")).toThrow("키 형식");
  });
});

describe("kubectl 쓰기 확장", () => {
  test("forceSync waitSec: refreshTime이 annotate 뒤이고 Ready면 끝, 아니면 ExecTimeout", async () => {
    const es = (refresh: string, ready = "True") => JSON.stringify({ status: { refreshTime: refresh, conditions: [{ type: "Ready", status: ready }] } });
    const annotate = kubectlRule(["-n", "app-smoke", "annotate", "externalsecrets.external-secrets.io", "smoke-db", /force-sync=[0-9]+/, "--overwrite"]);
    const get = (resps: { stdout: string }[]) => kubectlRule(["-n", "app-smoke", "get", "externalsecrets.external-secrets.io", "smoke-db", "-o", "json"], resps);
    const future = new Date(Date.now() + 60_000).toISOString();
    const ok = testCtx("apply", [annotate, get([{ stdout: es("2020-01-01T00:00:00Z") }, { stdout: es(future) }])]);
    await applyWith(ok.ctx, (w) => w.k8s.forceSync("app-smoke", "smoke-db", { waitSec: 5 }));
    const stuck = testCtx("apply", [annotate, get([{ stdout: es("2020-01-01T00:00:00Z") }])]);
    await expect(applyWith(stuck.ctx, (w) => w.k8s.forceSync("app-smoke", "smoke-db", { waitSec: 1 }))).rejects.toBeInstanceOf(ExecTimeout);
  });

  test("restartForSecrets: 참조 Secret rv 해시를 템플릿 주석으로 patch(stdin), 명령은 rv를 넘기지 않는다", async () => {
    const dep = JSON.stringify({ spec: { template: { spec: { containers: [{ envFrom: [{ secretRef: { name: "smoke-app" } }] }] } } } });
    const patch = kubectlRule(["-n", "app-smoke", "patch", "deployments.apps", "smoke", "--type=merge", "--patch-file=/dev/stdin"]);
    const { ctx, calls } = testCtx("apply", [kubectlRule(["-n", "app-smoke", "get", "deployments.apps", "smoke", "-o", "json"], { stdout: dep }), kubectlRule(["-n", "app-smoke", "get", "secrets", "smoke-app", "-o", "jsonpath={.metadata.resourceVersion}"], { stdout: "11" }), { ...patch, captureStdin: true }]);
    await applyWith(ctx, (w) => w.k8s.restartForSecrets("app-smoke", "smoke"));
    const p = calls().calls.find((c) => c.argv.includes("patch"))!;
    expect(JSON.parse(p.stdin!)).toEqual({ spec: { template: { metadata: { annotations: { "homelab.ukyi.app/secrets-rv": sha256("smoke-app@11").slice(0, 16) } } } } });
  });

  const RUN = "20261026000000abcdef";
  const recDoc = (data: Record<string, string>, run = RUN) => JSON.stringify({ metadata: { resourceVersion: "5", labels: { "homelab.ukyi.app/restore": run } }, data: { run, ...data } });
  const recGet = (resps: { stdout: string }[]) => kubectlRule(["-n", "app-smoke", "get", "configmaps", "restore-vk", "-o", "json"], resps);

  test("restoreRecordCreate: 라벨을 함께 만들고, 이미 있으면 exists", async () => {
    const create = { ...kubectlRule(["-n", "app-smoke", "create", "-f", "-"], [{}, { code: 1, stderr: 'Error from server (AlreadyExists): configmaps "restore-vk" already exists' }]), captureStdin: true };
    const { ctx, calls } = testCtx("apply", [create]);
    expect((await applyWith(ctx, (w) => w.k8s.restoreRecordCreate("app-smoke", "restore-vk", RUN, { "ok.stop": "1" }))).value).toBe("created");
    expect(JSON.parse(calls().calls[0].stdin!).metadata.labels).toEqual({ "homelab.ukyi.app/restore": RUN });
    const again = testCtx("apply", [create]);
    await applyWith(again.ctx, (w) => w.k8s.restoreRecordCreate("app-smoke", "restore-vk", RUN, {}));
    expect((await applyWith(again.ctx, (w) => w.k8s.restoreRecordCreate("app-smoke", "restore-vk", RUN, {}))).value).toBe("exists");
  });

  test("restoreRecordUpdate: 첫 op는 test /data/run, 없는 키는 remove하지 않는다. 남의 기록이면 patch 0건", async () => {
    const patch = { ...kubectlRule(["-n", "app-smoke", "patch", "configmaps", "restore-vk", "--type=json", "--patch-file=/dev/stdin"]), captureStdin: true };
    const { ctx, calls } = testCtx("apply", [recGet([{ stdout: recDoc({ "ok.a": "1" }) }]), patch]);
    await applyWith(ctx, (w) => w.k8s.restoreRecordUpdate("app-smoke", "restore-vk", RUN, { "ok.a": null, "ok.b": null, "ok.c": "1" }));
    expect(JSON.parse(calls().calls.find((c) => c.argv.includes("patch"))!.stdin!)).toEqual([
      { op: "test", path: "/data/run", value: RUN },
      { op: "remove", path: "/data/ok.a" },
      { op: "add", path: "/data/ok.c", value: "1" },
    ]);
    const other = testCtx("apply", [recGet([{ stdout: recDoc({}, "20261026000000ffffff") }]), patch]);
    await expect(applyWith(other.ctx, (w) => w.k8s.restoreRecordUpdate("app-smoke", "restore-vk", RUN, { "ok.c": "1" }))).rejects.toThrow("이 실행");
    expect(other.calls().calls.filter((c) => c.argv.includes("patch"))).toEqual([]);
    // 읽은 뒤 남이 잠금을 가져가면 API 서버의 test가 거부한다(경쟁 주입).
    const raced = testCtx("apply", [recGet([{ stdout: recDoc({}) }]), { ...patch, responses: [{ code: 1, stderr: 'The request is invalid: the server rejected our request due to an error in our request: testing value /data/run failed' }] }]);
    await expect(applyWith(raced.ctx, (w) => w.k8s.restoreRecordUpdate("app-smoke", "restore-vk", RUN, { "ok.c": "1" }))).rejects.toThrow("잠금이 이 실행의 것이 아니다");
  });

  test("restoreRecordDelete·deleteRestoreObject·createJobFromCronJob argv, 라벨이 다르면 지우지 않는다", async () => {
    const job = (run: string) => JSON.stringify({ metadata: { labels: { "homelab.ukyi.app/restore": run } } });
    const dry = JSON.stringify({ kind: "Job", metadata: { name: "backup-run1-ab12" }, spec: {} });
    const rules = [
      kubectlRule(["-n", "app-smoke", "delete", "configmaps", "-l", `homelab.ukyi.app/restore=${RUN}`, "--field-selector=metadata.name=restore-vk", "--wait=true"]),
      kubectlRule(["-n", "database", "get", "jobs.batch", "restore-x-db", "-o", "json"], [{ stdout: job(RUN) }, { stdout: job("other") }]),
      kubectlRule(["-n", "database", "delete", "jobs.batch", "restore-x-db", "--ignore-not-found", "--cascade=foreground", "--wait=true", "--timeout=120s"]),
      kubectlRule(["-n", "app-smoke", "create", "job", "backup-run1-ab12", "--from=cronjob/smoke-valkey-backup", "--dry-run=client", "-o", "json"], { stdout: dry }),
      { ...kubectlRule(["-n", "app-smoke", "create", "-f", "-"]), captureStdin: true },
    ];
    const { ctx, calls } = testCtx("apply", rules);
    await applyWith(ctx, (w) => {
      w.k8s.restoreRecordDelete("app-smoke", "restore-vk", RUN);
      w.k8s.deleteRestoreObject("database", "job", "restore-x-db", RUN);
      w.k8s.createJobFromCronJob("app-smoke", "smoke-valkey-backup", "backup-run1-ab12", "run1");
    });
    expect(JSON.parse(calls().calls.at(-1)!.stdin!).metadata.labels["homelab.ukyi.app/restore"]).toBe("run1");
    expect(calls().unmatched).toEqual([]);
    await expect(applyWith(ctx, (w) => w.k8s.deleteRestoreObject("database", "job", "restore-x-db", RUN))).rejects.toThrow("이 실행");
    expect(calls().calls.filter((c) => c.argv.includes("delete") && c.argv.includes("jobs.batch")).length).toBe(1);
    await expect(applyWith(ctx, (w) => w.k8s.createJobFromCronJob("app-smoke", "x", "not-backup", "run1"))).rejects.toThrow("형식");
  });

  test("setPvReclaimDelete: local-retain·claimRef가 맞을 때만 patch", async () => {
    const pvc = kubectlRule(["-n", "database", "get", "persistentvolumeclaims", "pg-1", "-o", "json"], { stdout: JSON.stringify({ spec: { volumeName: "pvc-123" } }) });
    const pv = (sc: string) => kubectlRule(["get", "persistentvolumes", "pvc-123", "-o", "json"], { stdout: JSON.stringify({ spec: { storageClassName: sc, claimRef: { namespace: "database", name: "pg-1" } } }) });
    const patch = { ...kubectlRule(["patch", "persistentvolumes", "pvc-123", "--type=merge", "--patch-file=/dev/stdin"]), captureStdin: true };
    const ok = testCtx("apply", [pvc, pv("local-retain"), patch]);
    await applyWith(ok.ctx, (w) => w.k8s.setPvReclaimDelete("database", "pg-1"));
    expect(JSON.parse(ok.calls().calls.at(-1)!.stdin!)).toEqual({ spec: { persistentVolumeReclaimPolicy: "Delete" } });
    const other = testCtx("apply", [pvc, pv("local-path"), patch]);
    await expect(applyWith(other.ctx, (w) => w.k8s.setPvReclaimDelete("database", "pg-1"))).rejects.toThrow("local-retain");
    expect(other.calls().calls.filter((c) => c.argv.includes("patch"))).toEqual([]);
  });
});

describe("파드 안 작업", () => {
  const primary = kubectlRule(["-n", "database", "get", "clusters.postgresql.cnpg.io", "pg", "-o", "json"], { stdout: JSON.stringify({ status: { currentPrimary: "pg-2" } }) });
  const psql = (resp: { stdout?: string; stderr?: string; code?: number }) => rule(["kubectl", "-n", "database", "exec", "-i", "pg-2", "-c", "postgres", "--request-timeout=20s", "--", "sh", "-c", PG_PASSWORD_CHECK, "sh", "smoke"], resp);

  test("pg.passwordCheck: 비밀번호는 stdin만, accepted·rejected, 그 밖 실패는 던진다", async () => {
    const pw = FAKE_SECRETS[0];
    const { ctx, calls } = testCtx("apply", [primary, psql({ stdout: "1\n" })]);
    expect((await applyWith(ctx, (w) => w.pg.passwordCheck("smoke", new Secret(pw)))).value).toBe("accepted");
    expect(calls().calls.at(-1)!.stdinSha256).toBe(sha256(pw));
    expectNoSecrets(calls());
    const bad = testCtx("apply", [primary, psql({ code: 2, stderr: 'psql: error: FATAL:  password authentication failed for user "smoke"' })]);
    expect((await applyWith(bad.ctx, (w) => w.pg.passwordCheck("smoke", new Secret(pw)))).value).toBe("rejected");
    const down = testCtx("apply", [primary, psql({ code: 2, stderr: "psql: error: connection refused" })]);
    await expect(applyWith(down.ctx, (w) => w.pg.passwordCheck("smoke", new Secret(pw)))).rejects.toThrow("로그인 확인");
    await expect(applyWith(down.ctx, (w) => w.pg.passwordCheck("smoke; drop", new Secret(pw)))).rejects.toThrow("앱 이름");
  });

  const auth = kubectlRule(["-n", "app-smoke", "get", "secrets", "smoke-valkey-auth", "-o", "json"], { stdout: JSON.stringify({ data: { password: b64(FAKE_SECRETS[1]) } }) });
  const vk = (words: string[], resp: { stdout?: string; stderr?: string; code?: number } | { stdout: string }[]) => rule(["kubectl", "-n", "app-smoke", "exec", "-i", "deploy/smoke-valkey", "--request-timeout=20s", "--", "sh", "-c", VALKEY_CLI, "sh", ...words], resp);

  test("valkey.cli: 정해진 명령만, 인증은 Secret 값을 stdin으로. waitAof", async () => {
    const info = (inProgress: string) => `# Persistence\r\naof_enabled:1\r\naof_rewrite_in_progress:${inProgress}\r\naof_last_bgrewrite_status:ok\r\n`;
    const { ctx, calls } = testCtx("apply", [auth, vk(["DBSIZE"], { stdout: "42\n" }), vk(["INFO", "persistence"], [{ stdout: info("1") }, { stdout: info("0") }])]);
    expect((await applyWith(ctx, (w) => w.valkey.cli("app-smoke", "smoke-valkey", "DBSIZE"))).value).toBe("42\n");
    expect(calls().calls.find((c) => c.argv.includes("DBSIZE"))!.stdinSha256).toBe(sha256(FAKE_SECRETS[1]));
    expect((await applyWith(ctx, (w) => w.valkey.waitAof("app-smoke", "smoke-valkey", 5))).value).toBe(true);
    await expect(applyWith(ctx, (w) => w.valkey.cli("app-smoke", "smoke-valkey", "FLUSHALL" as never))).rejects.toThrow("다섯");
    await expect(applyWith(ctx, (w) => w.valkey.cli("app-smoke", "smoke", "PING"))).rejects.toThrow("-valkey");
    expectNoSecrets(calls(), FAKE_SECRETS);
  });

  test("valkey.authCheck: WRONGPASS·NOAUTH면 rejected", async () => {
    const ok = testCtx("apply", [vk(["PING"], { stdout: "PONG\n" })]);
    expect((await applyWith(ok.ctx, (w) => w.valkey.authCheck("app-smoke", "smoke-valkey", new Secret(FAKE_SECRETS[0])))).value).toBe("accepted");
    const no = testCtx("apply", [vk(["PING"], { stdout: "NOAUTH Authentication required.\n", stderr: "AUTH failed: WRONGPASS invalid username-password pair" })]);
    expect((await applyWith(no.ctx, (w) => w.valkey.authCheck("app-smoke", "smoke-valkey", new Secret(FAKE_SECRETS[0])))).value).toBe("rejected");
  });

  test("http.appStatus: port-forward가 알린 로컬 포트로 curl 하나, 끝나면 port-forward를 끈다", async () => {
    const pf = rule(["kubectl", "-n", "app-smoke", "port-forward", "deploy/smoke", ":8080", "--request-timeout=20s"], { stdout: "Forwarding from 127.0.0.1:43210 -> 8080\n", holdMs: 5_000 }, { noStdin: true });
    const curl = rule(["curl", "-q", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "10", "http://127.0.0.1:43210/healthz/db"], { stdout: "503" });
    const { ctx, calls } = testCtx("apply", [pf, curl]);
    const started = Date.now();
    expect((await applyWith(ctx, (w) => w.http.appStatus("app-smoke", "smoke", 8080, "/healthz/db"))).value).toBe(503);
    // holdMs(5초)를 기다리지 않았다: 끝나자마자 port-forward를 죽였다.
    expect(Date.now() - started).toBeLessThan(4_000);
    expect(calls().unmatched).toEqual([]);
    await expect(applyWith(ctx, (w) => w.http.appStatus("app-smoke", "smoke", 8080, "/admin" as never))).rejects.toThrow("헬스 경로");
  });

  test("port-forward가 포트를 알리지 않고 끝나면 실패, curl 0건", async () => {
    const pf = rule(["kubectl", "-n", "app-smoke", "port-forward", "deploy/smoke", ":8080", "--request-timeout=20s"], { stderr: 'error: deployments.apps "smoke" not found', code: 1 }, { noStdin: true });
    const { ctx, calls } = testCtx("apply", [pf]);
    await expect(applyWith(ctx, (w) => w.http.appStatus("app-smoke", "smoke", 8080, "/healthz"))).rejects.toThrow("포트를 알리기 전에");
    expect(calls().calls.filter((c) => c.argv[0] === "curl")).toEqual([]);
  });
});

describe("Infisical 폴더·web·확인", () => {
  test("folderExists(읽기)·createFolder(없는 조각만 바깥부터)", async () => {
    const list = (parent: string, names: string[]) => rule(infArgv.folders(FAKE_PROJECT, parent), { stdout: JSON.stringify(names.map((name) => ({ name }))) });
    const r = testCtx("plan", [list("/apps", ["other"])]);
    expect(r.ctx.infisical.folderExists("/apps/smoke")).toBe(false);
    expectPlanReadOnly(r.calls());
    const { ctx, calls } = testCtx("apply", [list("/", ["apps"]), list("/apps", []), list("/apps/smoke", []), rule(infArgv.createFolder(FAKE_PROJECT, "/apps", "smoke")), rule(infArgv.createFolder(FAKE_PROJECT, "/apps/smoke", "postgres"))]);
    await applyWith(ctx, (w) => w.infisical.createFolder("/apps/smoke/postgres"));
    expect(calls().calls.filter((c) => c.argv.includes("create")).map((c) => c.argv[c.argv.indexOf("--name") + 1])).toEqual(["smoke", "postgres"]);
    expect(calls().unmatched).toEqual([]);
  });

  test("web.publicStatus: 정해진 curl 꼴, host는 <이름>.ukyi.app만", () => {
    const { ctx, calls } = testCtx("read", [rule(ghArgv.web("smoke.ukyi.app", "/healthz"), { stdout: "200" })]);
    expect(ctx.web.publicStatus("smoke.ukyi.app", "/healthz")).toBe(200);
    expect(() => ctx.web.publicStatus("evil.example.com", "/")).toThrow("host");
    expect(() => ctx.web.publicStatus("smoke.ukyi.app", "/?x=1")).toThrow("경로");
    expectPlanReadOnly(calls());
  });

  test("confirm: tty에서 같은 답만 true, tty가 아니면 묻지도 않고 false", async () => {
    const asked: string[] = [];
    const tty = testCtx("apply", [], { isTTY: true, ask: (q) => (asked.push(q), "smoke") });
    expect((await applyWith(tty.ctx, (w) => w.confirm("앱 이름을 다시 친다: ", "smoke"))).value).toBe(true);
    expect((await applyWith(tty.ctx, (w) => w.confirm("q", "other"))).value).toBe(false);
    const pipe = testCtx("apply", [], { ask: () => "smoke" });
    expect((await applyWith(pipe.ctx, (w) => w.confirm("q", "smoke"))).value).toBe(false);
  });

  test("newRunId: 20자 [0-9a-f], 시각 앞부분", () => {
    const id = newRunId(new Date("2026-10-26T01:02:03Z"));
    expect(id).toMatch(/^20261026010203[0-9a-f]{6}$/);
  });
});

describe("읽기 문맥에 쓰기가 없다", () => {
  test("ctx에는 pg·valkey·http·confirm·appRepo가 없고, wrapper가 아닌 명령의 w에는 github·appRepo가 없다", async () => {
    const { ctx } = testCtx("apply", []);
    for (const k of ["pg", "valkey", "http", "confirm", "appRepo", "generatePassword"]) expect([k, k in ctx]).toEqual([k, false]);
    expect(Object.keys(ctx.k8s)).not.toContain("restartForSecrets");
    expect(Object.keys(ctx.infisical)).not.toContain("createFolder");
    expect(ctx.github).toBeUndefined();
    const { value } = await applyWith(ctx, (w) => [w.github, w.appRepo]);
    expect(value).toEqual([undefined, undefined]);
  });

  test("붙잡아 둔 w의 새 어댑터도 apply가 끝나면 막힌다(원장 0건)", async () => {
    const { ctx, calls } = testCtx("apply", [rule(["kubectl", REST])]);
    const { value: w } = await applyWith(ctx, (w) => w);
    expect(() => w.k8s.restoreRecordDelete("app-smoke", "restore-vk", "run1")).toThrow("Step.apply 밖");
    expect(() => w.confirm("q", "x")).toThrow("Step.apply 밖");
    await expect(w.http.appStatus("app-smoke", "smoke", 8080, "/healthz")).rejects.toThrow("Step.apply 밖");
    expect(calls().calls).toEqual([]);
  });
});

describe("github 래퍼 plan JSON·app new 쓰기", () => {
  const clone = rule(["git", REST], { materialize: { "tools/tf-github.sh": "stub" } });
  const planJson = JSON.stringify({ schema: "tf-github-plan/v1", sha: "b".repeat(40), changes: [{ address: 'github_repository_ruleset.app_main["smoke"]', mode: "managed", actions: ["create"], importing: false }] });

  test("planChanges: 파일은 clone 밖 임시 폴더, 코드 2면 변경 목록, 1이면 null, 0인데 파일 없으면 던진다", () => {
    const wrap = (resp: object) => rule(["tf-github.sh", "plan", "--plan-json", /.*\/homelab-cli-plan-[^/]+\/plan\.json/], resp, { noStdin: true });
    const two = testCtx("plan", [clone, wrap({ code: 2, writeLastArg: planJson })], { wrapper: true });
    expect(two.ctx.github!.planChanges()).toEqual({ exitCode: 2, sha: "b".repeat(40), changes: [{ address: 'github_repository_ruleset.app_main["smoke"]', mode: "managed", actions: ["create"], importing: false }] });
    const out = two.calls().calls.find((c) => c.argv[0] === "tf-github.sh")!.argv.at(-1)!;
    expect(out).not.toMatch(/homelab-cli-github-/);
    expect(two.calls().writes).toEqual([]);
    expect(testCtx("plan", [clone, wrap({ code: 1 })], { wrapper: true }).ctx.github!.planChanges()).toEqual({ exitCode: 1, sha: null, changes: null });
    expect(() => testCtx("plan", [clone, wrap({ code: 0 })], { wrapper: true }).ctx.github!.planChanges()).toThrow("plan JSON을 쓰지 않았다");
  });

  test("plan JSON 형식이 다르면 던진다(값 키는 받지 않고 주소·동작만)", () => {
    expect(() => parsePlanJson("{}")).toThrow("tf-github-plan/v1");
    expect(() => parsePlanJson(JSON.stringify({ schema: "tf-github-plan/v1", sha: "b".repeat(40), changes: [{ address: "a; rm", mode: "managed", actions: ["create"], importing: false }] }))).toThrow("주소");
    expect(() => parsePlanJson(JSON.stringify({ schema: "tf-github-plan/v1", sha: "b".repeat(40), changes: [{ address: "a", mode: "managed", actions: ["destroy-everything"], importing: false }] }))).toThrow("동작");
    expect(parsePlanJson(JSON.stringify({ schema: "tf-github-plan/v1", sha: "b".repeat(40), changes: [{ address: "a", mode: "data", actions: ["read"], importing: false, after: { token: "x" } }] })).changes![0]).toEqual({ address: "a", mode: "data", actions: ["read"], importing: false });
  });

  test("w.github.apply는 wrapper 명령의 apply 문맥에만, 래퍼 apply를 쓰기로 부른다(--allow-destroy 없음)", async () => {
    const { ctx, calls } = testCtx("apply", [clone, rule(["tf-github.sh", "apply"], { code: 0 }, { noStdin: true })], { wrapper: true });
    expect(() => ctx.github!.run("apply")).toThrow("apply 문맥");
    expect((await applyWith(ctx, (w) => w.github!.apply())).value).toBe(0);
    expect(calls().calls.filter((c) => c.argv[0] === "tf-github.sh").map((c) => c.argv)).toEqual([["tf-github.sh", "apply"]]);
  });

  test("appRepo: 메서드·경로·본문 고정, homelab·template 이름 거부, 2xx가 아니면 던진다", async () => {
    const rules = (Object.keys(APP_REPO_CALLS) as (keyof typeof APP_REPO_CALLS)[]).map((k) => {
      const [method, path] = APP_REPO_CALLS[k]("smoke");
      return ghSend(method, path, 201, {});
    });
    const { ctx, calls } = testCtx("apply", rules, { wrapper: true });
    await applyWith(ctx, (w) => {
      w.appRepo!.createFromTemplate("smoke");
      w.appRepo!.setRepoSettings("smoke");
      w.appRepo!.enableVulnReporting("smoke");
      w.appRepo!.setForkPrApproval("smoke");
    });
    const bodies = calls().calls.map((c) => [c.argv[4], c.argv[5], JSON.parse(c.stdin!)]);
    expect(bodies).toEqual([
      ["POST", "repos/ukyi-app/homelab-app-template/generate", { owner: "ukyi-app", name: "smoke", private: false, include_all_branches: false }],
      ["PATCH", "repos/ukyi-app/smoke", { security_and_analysis: { secret_scanning: { status: "enabled" }, secret_scanning_push_protection: { status: "enabled" } }, pull_request_creation_policy: "collaborators_only" }],
      ["PUT", "repos/ukyi-app/smoke/private-vulnerability-reporting", {}],
      ["PUT", "repos/ukyi-app/smoke/actions/permissions/fork-pr-contributor-approval", { approval_policy: "all_external_contributors" }],
    ]);
    await expect(applyWith(ctx, (w) => w.appRepo!.createFromTemplate("homelab"))).rejects.toThrow("앱 저장소 이름");
    const fail = testCtx("apply", [ghSend("POST", "repos/ukyi-app/homelab-app-template/generate", [ghResponse(422, { message: "name already exists" })])], { wrapper: true });
    await expect(applyWith(fail.ctx, (w) => w.appRepo!.createFromTemplate("smoke"))).rejects.toThrow("HTTP 422 name already exists");
  });
});
