// #873 남은 리뷰 지적의 회귀 시험(T12-01b). 지적마다 고치기 전 동작이면 실패하는 꼴로 쓴다.
import { describe, expect, test } from "bun:test";
import { applyLine } from "../../src/core/engine";
import { readHiddenLine } from "../../src/core/input";
import { valueProblem } from "../../src/core/infisical";
import { makeRuntime } from "../../src/core/runtime";
import { Secret } from "../../src/core/secret";
import { classify } from "../../src/core/writes";
import { applyWith, kubectlRule, runCli, stubSandbox, testCtx } from "../harness";

const feed = (bytes: number[]) => {
  const all = [...bytes, 0x0d];
  let i = 0;
  return () => (i < all.length ? all[i++] : null);
};
const enc = (t: string) => [...new TextEncoder().encode(t)];

describe("#873 남은 지적", () => {
  test("모르는 플래그 이름을 되찍지 않는다(Connector 4360754418)", async () => {
    for (const args of [["doctor", "--hunter2-fakevalue-0001"], ["doctor", "--hunter2-fakevalue-0001", "--json"]]) {
      const r = await runCli(args, []);
      expect(r.code).toBe(64);
      expect(`${r.stdout}${r.stderr}`).not.toContain("hunter2");
      expect(`${r.stdout}${r.stderr}`).toContain("모르는 플래그");
    }
  });

  test("숨김 입력의 Backspace·Delete는 직전 UTF-8 문자 하나를 지운다(Connector 4360754443)", () => {
    expect(readHiddenLine(feed([...enc("abcx"), 0x7f, ...enc("d")]))).toBe("abcd");
    expect(readHiddenLine(feed([...enc("ab한"), 0x08, ...enc("c")]))).toBe("abc");
    expect(readHiddenLine(feed([0x7f, 0x08, ...enc("a")]))).toBe("a");
    expect(readHiddenLine(feed([...enc("😀"), 0x7f]))).toBe("");
  });

  test("숨김 입력이 선두 U+FEFF를 지우지 않아 형식 검사가 거부한다(codex 확인 라운드 P2)", () => {
    const v = readHiddenLine(feed(enc("﻿abcdefghijklmnop")));
    expect(v.startsWith("﻿")).toBe(true);
    expect(valueProblem(new Secret(v))).not.toBeNull();
  });

  test("복원 객체 삭제는 사라질 때까지 기다린다(--wait=true, 상한 300s, Connector 4360754447·4360754464)", async () => {
    const del = ["-n", "database", "delete", "clusters.postgresql.cnpg.io,jobs.batch,pods,persistentvolumeclaims", "-l", "homelab.ukyi.app/restore=run1", "--ignore-not-found", "--wait=true", "--timeout=300s"];
    const { ctx, calls } = testCtx("apply", [kubectlRule(del)]);
    await applyWith(ctx, (w) => w.k8s.deleteRestoreObjects("database", "run1"));
    expect(calls().unmatched).toEqual([]);
    expect(calls().calls.length).toBe(1);
  });

  test("logs --since의 일 단위는 kubectl이 받는 시간 단위로 바꾼다(Connector 4360754457)", () => {
    const { ctx, calls } = testCtx("read", [kubectlRule(["-n", "app-smoke", "logs", "deploy/smoke", "--tail=200", "--since=168h"], { stdout: "ok\n" }), kubectlRule(["-n", "app-smoke", "logs", "deploy/smoke", "--tail=200", "--since=30m"], { stdout: "ok\n" })]);
    expect(ctx.k8s.logs("app-smoke", { deployment: "smoke" }, { since: "7d" })).toBe("ok\n");
    expect(ctx.k8s.logs("app-smoke", { deployment: "smoke" }, { since: "30m" })).toBe("ok\n");
    expect(() => ctx.k8s.logs("app-smoke", { deployment: "smoke" }, { since: "7w" })).toThrow("--since");
    expect(calls().unmatched).toEqual([]);
  });

  test("다음 명령의 --apply는 `--` 앞에 들어간다(Connector 4360754469)", async () => {
    expect(applyLine("homelab db add -- smoke")).toBe("homelab db add --apply -- smoke");
    expect(applyLine("homelab db add smoke")).toBe("homelab db add smoke --apply");
    expect(applyLine("homelab db add smoke --")).toBe("homelab db add smoke --apply --");
    // 엔진이 pending의 next를 이 함수로 만든다.
    const sb = stubSandbox([]);
    const ctx = makeRuntime({ mode: "plan", json: false, line: "homelab db add -- smoke", env: sb.env, isTTY: false, ask: () => null, progress: () => {} });
    const r = await ctx.engine({ command: "db add", steps: [{ id: "x", target: "x", read: async () => ({ state: "missing", action: "create", detail: "" }), apply: async () => {} }] });
    expect(r.next).toBe("homelab db add --apply -- smoke");
  });

  test("리소스 이름이 secret인 조회·로그는 Secret 조회로 보지 않는다(Connector 4360396711)", () => {
    expect(classify(["kubectl", "-n", "app-secret", "logs", "deploy/secret", "--tail=200"]).sensitiveOutput ?? false).toBe(false);
    expect(classify(["kubectl", "-n", "x", "logs", "secret"]).sensitiveOutput ?? false).toBe(false);
    expect(classify(["kubectl", "-n", "app-secret", "get", "deployments.apps", "secret", "-o", "json"]).sensitiveOutput ?? false).toBe(false);
    expect(classify(["kubectl", "-n", "x", "rollout", "status", "deploy/secret"]).sensitiveOutput ?? false).toBe(false);
    // 종류 자리는 여전히 민감하다.
    expect(classify(["kubectl", "get", "secret", "x"]).sensitiveOutput).toBe(true);
    expect(classify(["kubectl", "get", "deploy,secrets"]).sensitiveOutput).toBe(true);
    expect(classify(["kubectl", "get", "secret/x"]).sensitiveOutput).toBe(true);
    expect(classify(["kubectl", "logs", "secret/x"]).sensitiveOutput).toBe(true);
    // 어댑터로: 앱 이름 secret의 로그를 읽을 수 있다.
    const { ctx } = testCtx("read", [kubectlRule(["-n", "app-secret", "logs", "deploy/secret", "--tail=200"], { stdout: "ok\n" })]);
    expect(ctx.k8s.logs("app-secret", { deployment: "secret" })).toBe("ok\n");
  });
});
