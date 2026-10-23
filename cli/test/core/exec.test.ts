// exec seam 시험. 명령은 exec를 볼 수 없으므로 여기서는 core 어댑터 밑의 마지막 방어선을 직접 시험한다.
// 각 계약마다 어기는 호출을 주입해 막히는지, 스텁 원장에 실제 호출이 없는지 본다.
import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import { PLAN_WRITE_BLOCKED, makeExec } from "../../src/core/exec";
import { Secret } from "../../src/core/secret";
import { tempDir } from "../../src/core/temp";
import { REST, rule, sha256, stubSandbox } from "../harness";

function execs(rules: Parameters<typeof stubSandbox>[0], opts: Parameters<typeof stubSandbox>[1] = {}) {
  const sb = stubSandbox(rules, opts);
  let live = true;
  return {
    ...sb,
    read: makeExec("read", { env: sb.env }),
    write: makeExec("write", { env: sb.env, live: () => live }),
    revoke: () => (live = false),
  };
}

describe("read exec", () => {
  test("쓰기 argv는 실행하지 않는다(원장 0건)", () => {
    const e = execs([rule(["gh", REST]), rule(["kubectl", REST])]);
    expect(() => e.read(["gh", "pr", "create"])).toThrow(PLAN_WRITE_BLOCKED);
    expect(() => e.read(["kubectl", "delete", "pod", "x"])).toThrow(PLAN_WRITE_BLOCKED);
    expect(e.calls().calls).toEqual([]);
  });

  test("git clone은 core가 만든 임시 폴더 안 목적지일 때만(Connector 2라운드: 임의 경로 clone)", () => {
    const e = execs([rule(["git", REST])]);
    const own = tempDir("exectest");
    expect(() => e.read(["git", "clone", "https://github.com/ukyi-app/homelab.git", "apps/new-app"])).toThrow(PLAN_WRITE_BLOCKED);
    expect(() => e.read(["git", "clone", "https://github.com/ukyi-app/homelab.git", "/tmp/elsewhere/tree"], { cloneInto: "/tmp/elsewhere" })).toThrow(PLAN_WRITE_BLOCKED);
    expect(() => e.read(["git", "show", "HEAD", "--output=/tmp/x"])).toThrow(PLAN_WRITE_BLOCKED);
    expect(e.calls().calls).toEqual([]);
    expect(e.read(["git", "clone", "https://github.com/ukyi-app/homelab.git", join(own, "tree")], { cloneInto: own }).code).toBe(0);
  });
});

describe("write exec", () => {
  test("폐기(revoke) 뒤에는 모든 호출을 막는다(붙잡아 둔 쓰기 문맥)", () => {
    const e = execs([rule(["gh", REST])]);
    expect(e.write(["gh", "pr", "create"]).code).toBe(0);
    e.revoke();
    expect(() => e.write(["gh", "pr", "create"])).toThrow(PLAN_WRITE_BLOCKED);
    expect(() => e.write(["gh", "pr", "list"])).toThrow(PLAN_WRITE_BLOCKED);
    expect(e.calls().calls.length).toBe(1);
  });

  test("github 위임 쓰기 exec는 래퍼 밖 쓰기를 막는다", () => {
    const sb = stubSandbox([rule(["tf-github.sh", REST]), rule(["gh", REST])]);
    const w = makeExec("write", { env: sb.env, delegate: true, live: () => true });
    expect(w(["tf-github.sh", "apply"]).code).toBe(0);
    expect(() => w(["gh", "pr", "create"])).toThrow("래퍼 밖");
  });
});

describe("직접 stdio", () => {
  test("위임이 아니면 inherit·stdout-to-stderr를 쓸 수 없다", () => {
    const e = execs([rule(["gh", REST])]);
    expect(() => e.read(["gh", "pr", "list"], { stdio: "inherit" })).toThrow("github 위임 명령만");
    expect(() => e.write(["gh", "pr", "list"], { stdio: "stdout-to-stderr" })).toThrow("github 위임 명령만");
    expect(e.calls().calls).toEqual([]);
  });

  test("위임도 직접 stdio에 시크릿 입출력을 섞지 못한다", () => {
    const sb = stubSandbox([rule(["gh", REST])]);
    const r = makeExec("read", { env: sb.env, delegate: true });
    expect(() => r(["gh", "auth", "token"], { stdio: "inherit", secretStdout: true })).toThrow("시크릿 입출력");
    expect(() => r(["gh", "pr", "list"], { stdio: "inherit", input: new Secret("fakevalue-stdio-0001") })).toThrow("시크릿 입출력");
  });

  test("위임 stdout-to-stderr는 부모 stdin을 래퍼에 넘기고 stdout을 지킨다", async () => {
    const sb = stubSandbox([rule(["tf-github.sh", "apply"], { stdout: "WRAPPER-OUT\n" })]);
    const p = Bun.spawn([process.execPath, "--no-env-file", join(import.meta.dir, "..", "fixtures", "core", "delegate-child.ts")], { env: sb.env, stdin: new TextEncoder().encode("yes\n"), stdout: "pipe", stderr: "pipe" });
    const [stdout, stderr] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
    const c = sb.calls().calls;
    expect(c.length).toBe(1);
    expect(c[0].stdinSha256).toBe(sha256("yes\n"));
    expect(stdout).toBe('{"code":0}\n');
    expect(stderr).toContain("WRAPPER-OUT");
  });
});

describe("값을 내는 호출", () => {
  test("secretStdout 없이 실행하지 않는다(--raw=·config view 포함, 2라운드 P1)", () => {
    const e = execs([rule(["kubectl", REST]), rule(["infisical", REST]), rule(["gh", REST])]);
    for (const argv of [
      ["kubectl", "get", "secret", "x", "-o", "json"],
      ["kubectl", "get", "--raw=/api/v1/namespaces/x/secrets/y"],
      ["kubectl", "get", "--raw", "/api/v1/namespaces/x/secrets/y"],
      ["kubectl", "config", "view", "--raw"],
      ["infisical", "secrets", "--path", "/apps/x"],
      ["gh", "auth", "token"],
    ]) {
      expect(() => e.read(argv)).toThrow();
    }
    expect(e.calls().calls).toEqual([]);
  });

  test("민감 호출의 stderr 원문은 버리고, argv의 시크릿 원문(16자 이상)은 막는다", () => {
    const e = execs([rule(["infisical", REST], { code: 1, stderr: "error: bad value fakevalue-exec-0002\n" })]);
    const s = new Secret("fakevalue-exec-0002");
    expect(() => e.write(["infisical", "secrets", "set", `K=${s.reveal()}`])).toThrow("명령행 인자");
    const r = e.write(["infisical", "secrets", "set", "--file", "/dev/stdin"], { input: s });
    expect([r.stderr, r.stderrHidden]).toEqual(["", true]);
    expect(e.calls().calls[0].stdinSha256).toBe(sha256("fakevalue-exec-0002"));
  });

  test("kubectl NotFound는 API 응답만. 인증 플러그인의 not found는 아니다(Connector 2라운드)", () => {
    const e = execs([
      rule(["kubectl", "get", "pods", "a"], { code: 1, stderr: 'Error from server (NotFound): pods "a" not found\n' }),
      rule(["kubectl", "get", "pods", "b"], { code: 1, stderr: 'error: exec plugin: executable kubelogin not found\n' }),
    ]);
    expect(e.read(["kubectl", "get", "pods", "a"]).notFound).toBe(true);
    expect(e.read(["kubectl", "get", "pods", "b"]).notFound).toBe(false);
  });
});

describe("기타", () => {
  test("없는 명령은 not-found, 시간 초과는 timeout(재시도 없음)", () => {
    const e = execs([rule(["gh", REST], { sleepMs: 5000 })], { env: { HOMELAB_TEST_TIMEOUT_MS: "300" } });
    const bare = execs([], { tools: [] });
    expect(bare.read(["kubectl", "get", "x"]).errKind).toBe("not-found");
    expect(e.read(["gh", "pr", "list"]).errKind).toBe("timeout");
    expect(e.calls().calls.length).toBe(1);
  });

  test("git에는 GIT_DIR 등을 넘기지 않는다. 절대 경로로 불러도 같다", () => {
    const names = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_TERMINAL_PROMPT"];
    const e = execs([rule(["git", REST], { echoEnv: names }), rule(["gh", REST], { echoEnv: names })], { env: { GIT_DIR: "/elsewhere/.git", GIT_WORK_TREE: "/elsewhere", GIT_INDEX_FILE: "/x" } });
    const scrubbed = { GIT_DIR: null, GIT_WORK_TREE: null, GIT_INDEX_FILE: null, GIT_TERMINAL_PROMPT: "0" };
    expect(JSON.parse(e.read(["git", "--version"]).stdout)).toEqual(scrubbed);
    expect(JSON.parse(e.read([join(e.bin, "git"), "--version"]).stdout)).toEqual(scrubbed);
    expect(JSON.parse(e.read(["gh", "pr", "list"]).stdout).GIT_DIR).toBe("/elsewhere/.git");
  });
});
