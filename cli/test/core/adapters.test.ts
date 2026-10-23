// core 어댑터 시험. 명령이 받는 문맥(testCtx는 makeRuntime으로 실제와 같은 ReadCtx를 만든다)으로만 부른다.
import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import type { KubeKind } from "../../src/core/command";
import { argvFor as ghArgv } from "../../src/core/github";
import { argvFor, projectResolver, valueProblem } from "../../src/core/infisical";
import { readHiddenLine } from "../../src/core/input";
import { containsSecretManifest } from "../../src/core/kubectl";
import { render } from "../../src/core/output";
import { CliError, type Result } from "../../src/core/result";
import { Secret } from "../../src/core/secret";
import { classify } from "../../src/core/writes";
import { FAKE_PROJECT, FAKE_SECRETS, REST, applyWith, expectNoSecrets, expectPlanReadOnly, infisicalList, infisicalSet, kubectlRule, rule, sha256, testCtx } from "../harness";

const ok = (extra: Partial<Result> = {}): Result => ({ command: "t", mode: "plan", status: "same", steps: [], notes: [], next: null, ...extra });

describe("Infisical 어댑터", () => {
  test("존재는 폴더 목록으로 본다(`secrets get`의 *not found* 함정 회피). 키 이름만 나온다", () => {
    const { ctx, calls } = testCtx("plan", [infisicalList("/apps/smoke/postgres", { PASSWORD: FAKE_SECRETS[0], OTHER: FAKE_SECRETS[1] })]);
    expect(ctx.infisical.has("/apps/smoke/postgres", "PASSWORD")).toBe(true);
    expect(ctx.infisical.has("/apps/smoke/postgres", "NOPE")).toBe(false);
    expect(ctx.infisical.listKeys("/apps/smoke/postgres")).toEqual(["OTHER", "PASSWORD"]);
    expect(String(ctx.infisical.getValue("/apps/smoke/postgres", "PASSWORD"))).toBe("[secret]");
    expect(ctx.infisical.valueHash("/apps/smoke/postgres", "PASSWORD")).toBe(sha256(FAKE_SECRETS[0]).slice(0, 12));
    expectPlanReadOnly(calls());
  });

  test("쓰기는 apply 문맥에서만, --file /dev/stdin에 KEY=값 한 줄, argv에 값이 없다", async () => {
    const { ctx, calls } = testCtx("apply", [infisicalSet("/apps/smoke/postgres")]);
    await applyWith(ctx, (w) => w.infisical.setValue("/apps/smoke/postgres", "PASSWORD", new Secret(FAKE_SECRETS[1])));
    const c = calls();
    expect(c.calls.length).toBe(1);
    expect(c.calls[0].argv).toEqual(argvFor.set(FAKE_PROJECT, "/apps/smoke/postgres"));
    expect(c.calls[0].stdinSha256).toBe(sha256(`PASSWORD=${FAKE_SECRETS[1]}\n`));
    expectNoSecrets(c);
  });

  test("16자 미만·줄바꿈·제어 문자·앞뒤 공백·양끝 따옴표 값은 쓰기 전에 거부(원장 0건)", async () => {
    const { ctx, calls } = testCtx("apply", [infisicalSet("/apps/smoke")]);
    for (const v of ["fifteen-chars15", "fakevalue-0001-a\nOTHER=x", "fakevalue-0001-ab\t", " fakevalue-0001-ab", '"fakevalue-0001-ab"']) {
      await expect(applyWith(ctx, (w) => w.infisical.setValue("/apps/smoke", "TOKEN", new Secret(v)))).rejects.toThrow();
    }
    expect(calls().calls).toEqual([]);
    expect(valueProblem(new Secret("a".repeat(16)))).toBeNull();
    // 깨진 디코딩의 흔적(U+FFFD)은 거부한다.
    expect(valueProblem(new Secret("abcdefghijklmno\uFFFD\uFFFD"))).toContain("U+FFFD");
  });

  test("짧은 값은 추적하지 않아 고정 옵션·JSON 키와 겹쳐도 정상 동작(2라운드 P2, 사용자 결정)", () => {
    new Secret("false");
    new Secret("mode");
    const { ctx } = testCtx("plan", [infisicalList("/apps/smoke", { A: FAKE_SECRETS[0] })]);
    expect(ctx.infisical.has("/apps/smoke", "A")).toBe(true);
    expect(() => render(ok({ app: "smoke" }), true)).not.toThrow();
    expect(() => render(ok(), false)).not.toThrow();
  });

  test("프로젝트 ID: 없고 tty 아니면 CliError, 형식 틀림, tty면 한 번 묻는다", () => {
    expect(() => projectResolver({ env: {}, isTTY: false, ask: () => null }).id()).toThrow(CliError);
    expect(() => projectResolver({ env: { HOMELAB_INFISICAL_PROJECT_ID: "nope" }, isTTY: false, ask: () => null }).id()).toThrow("UUID");
    let asked = 0;
    const p = projectResolver({ env: {}, isTTY: true, ask: () => (asked++, FAKE_PROJECT) });
    expect([p.id(), p.id(), asked]).toEqual([FAKE_PROJECT, FAKE_PROJECT, 1]);
  });

  test("시크릿 입력은 16자 이상만, 파이프 끝 줄바꿈 하나만 뗀다", async () => {
    const child = join(import.meta.dir, "..", "fixtures", "core", "input-child.ts");
    const runChild = async (stdin: string) => {
      const p = Bun.spawn([process.execPath, "--no-env-file", child], { stdin: new TextEncoder().encode(stdin), stdout: "pipe", stderr: "pipe" });
      const [out] = await Promise.all([new Response(p.stdout).text(), p.exited]);
      return out.trim();
    };
    expect(await runChild("short\n")).toStartWith("error:");
    expect(await runChild("fakevalue-input-0001\n")).toBe(`ok ${sha256("fakevalue-input-0001").slice(0, 12)}`);
    expect(await runChild("fakevalue-input-0001\nsecond\n")).toStartWith("error:");
  });
});

describe("키 이름과 TTY 입력", () => {
  test("Infisical 키는 차트 env 이름 꼴(^[A-Z_][A-Z0-9_]*$): _TOKEN 허용(Connector 3라운드)", async () => {
    const { ctx, calls } = testCtx("apply", [infisicalSet("/apps/smoke")]);
    await applyWith(ctx, (w) => w.infisical.setValue("/apps/smoke", "_TOKEN", new Secret("fakevalue-under-0001")));
    expect(calls().calls.length).toBe(1);
    await expect(applyWith(ctx, (w) => w.infisical.setValue("/apps/smoke", "1TOKEN", new Secret("fakevalue-under-0001")))).rejects.toThrow("키 이름");
  });

  test("TTY 입력은 바이트를 모아 UTF-8로 한 번만 디코딩한다(한글이 U+FFFD로 바뀌지 않는다, #873 3라운드)", () => {
    const feed = (text: string, end = [0x0d]) => {
      const bytes = [...new TextEncoder().encode(text), ...end];
      let i = 0;
      return () => (i < bytes.length ? bytes[i++] : null);
    };
    expect(readHiddenLine(feed("abcdefghijklmno한"))).toBe("abcdefghijklmno한");
    expect(readHiddenLine(feed("가나다라마바"))).toBe("가나다라마바");
    // 6자는 16자 검사에서 걸린다(바이트 단위였다면 U+FFFD 18자로 통과했다).
    expect(valueProblem(new Secret(readHiddenLine(feed("가나다라마바"))))).toContain("16자");
    expect(() => readHiddenLine(feed("x", [0x03]))).toThrow("취소");
    let i = 0;
    const broken = [0xed, 0x95, 0x0d];
    expect(() => readHiddenLine(() => (i < broken.length ? broken[i++] : null))).toThrow("UTF-8");
  });
});

describe("kubectl 어댑터", () => {
  test("범용 조회에 Secret 종류는 없다(타입 밖 값을 넣어도 외부 호출 전에 거부)", () => {
    const { ctx, calls } = testCtx("read", [rule(["kubectl", REST])]);
    for (const kind of ["secret", "secrets", "Secret", "secrets.v1", "pods,secrets"]) {
      expect(() => ctx.k8s.get(kind as KubeKind, "app-smoke", "x")).toThrow("Secret은 secretHash");
      expect(() => ctx.k8s.list(kind as KubeKind, "app-smoke")).toThrow("Secret은 secretHash");
    }
    expect(calls().calls).toEqual([]);
  });

  test("secretHash는 요청한 키만 추적: 같은 Secret의 username(공개 앱 이름)이 다음 조회·출력을 막지 않는다(2라운드 P1)", () => {
    const app = "homelab-probe-long";
    const data = { data: { username: Buffer.from(app).toString("base64"), password: Buffer.from(FAKE_SECRETS[0]).toString("base64") } };
    const { ctx, calls } = testCtx("read", [
      kubectlRule(["-n", "database", "get", "secret", `pg-role-${app}`, "-o", "json"], { stdout: JSON.stringify(data) }),
      kubectlRule(["-n", "database", "get", "databaseroles.postgresql.cnpg.io", app, "-o", "json"], { stdout: JSON.stringify({ status: { applied: true } }) }),
    ]);
    expect(ctx.k8s.secretHash("database", `pg-role-${app}`, "password")).toBe(sha256(FAKE_SECRETS[0]).slice(0, 12));
    expect(ctx.k8s.get("databaserole", "database", app)?.status?.applied).toBe(true);
    expect(() => render(ok({ app, notes: [`역할 ${app}`] }), true)).not.toThrow();
    expect(() => render(ok({ notes: [FAKE_SECRETS[0]] }), true)).toThrow("시크릿");
    expectPlanReadOnly(calls());
  });

  test("logs는 앱 로그를 그대로 주되, 이 실행이 다룬 시크릿이 섞이면 출력 계층이 결과를 막는다(Connector 3라운드 판단)", () => {
    const leaked = new Secret("fakevalue-logs-0001");
    void leaked;
    const { ctx, calls } = testCtx("read", [kubectlRule(["-n", "app-smoke", "logs", "deploy/smoke", "--tail=200"], { stdout: "boot ok\npassword=fakevalue-logs-0001\n" })]);
    const text = ctx.k8s.logs("app-smoke", "smoke");
    expect(text).toContain("boot ok");
    expect(() => render(ok({ notes: [text] }), false)).toThrow("시크릿");
    expect(() => render(ok({ notes: ["boot ok"] }), false)).not.toThrow();
    expectPlanReadOnly(calls());
  });

  test("secretExists는 키 이름만", () => {
    const data = { data: { password: Buffer.from(FAKE_SECRETS[0]).toString("base64"), user: Buffer.from("u").toString("base64") } };
    const { ctx, calls } = testCtx("read", [kubectlRule(["-n", "database", "get", "secret", "pg-role-smoke", "-o", "json"], { stdout: JSON.stringify(data) })]);
    expect(ctx.k8s.secretExists("database", "pg-role-smoke")).toEqual({ exists: true, keys: ["password", "user"] });
    expectPlanReadOnly(calls());
  });

  test("API NotFound만 없음(null). 인증 플러그인의 not found는 오류로 던진다(Connector 2라운드)", () => {
    const { ctx } = testCtx("read", [
      kubectlRule(["-n", "app-smoke", "get", "deployments.apps", "a", "-o", "json"], { code: 1, stderr: 'Error from server (NotFound): deployments.apps "a" not found\n' }),
      kubectlRule(["-n", "app-smoke", "get", "deployments.apps", "b", "-o", "json"], { code: 1, stderr: "error: exec plugin: executable kubelogin not found\n" }),
    ]);
    expect(ctx.k8s.get("deployment", "app-smoke", "a")).toBeNull();
    expect(() => ctx.k8s.get("deployment", "app-smoke", "b")).toThrow();
  });

  test("복원 객체: 라벨 필수, 허용 종류만, List 안 Secret까지 거부(Connector 2라운드 P1)", async () => {
    const { ctx, calls } = testCtx("apply", [rule(["kubectl", REST])]);
    const labels = { "homelab.ukyi.app/restore": "r1abc" };
    const bad = [
      { kind: "Secret", metadata: { labels } },
      { kind: "List", items: [{ kind: "Secret" }], metadata: { labels } },
      { kind: "Job", metadata: { labels }, spec: { template: { items: [{ kind: "secret" }] } } },
      { kind: "Job", metadata: {} },
      { kind: "Deployment", metadata: { labels } },
      { kind: "Job", metadata: { labels }, spec: { env: [{ value: new Secret("fakevalue-manifest-01") }] } },
    ];
    for (const m of bad) await expect(applyWith(ctx, (w) => w.k8s.createRestoreObject("database", m))).rejects.toThrow();
    expect(calls().calls).toEqual([]);
    await applyWith(ctx, (w) => w.k8s.createRestoreObject("database", { kind: "Job", metadata: { name: "restore-r1abc", labels } }));
    expect(calls().writes.length).toBe(1);
    expect(containsSecretManifest({ kind: "SecretList" })).toBe(true);
  });
});

describe("gh·GHCR 어댑터", () => {
  test("gh GET은 ukyi-app 경로와 user만(graphql·다른 owner는 외부 호출 전 거부)", () => {
    const { ctx, calls } = testCtx("read", [rule(["gh", REST])]);
    for (const p of ["graphql", "repos/other/x", "repos/ukyi-app/x\nfoo", "/repos/ukyi-app/x"]) expect(() => ctx.gh.get(p)).toThrow();
    expect(calls().calls).toEqual([]);
  });

  test("GHCR 익명 토큰은 고정 argv(-q로 .curlrc 끔)이고 읽기로 판정된다", () => {
    expect(classify(ghArgv.ghcr("smoke")).write).toBe(false);
    const { ctx, calls } = testCtx("read", [rule(ghArgv.ghcr("smoke"), { stdout: "200" })]);
    expect(ctx.ghcr.anonymousPullStatus("smoke")).toBe(200);
    expect(() => ctx.ghcr.anonymousPullStatus("Bad/App")).toThrow();
    expectPlanReadOnly(calls());
  });
});
