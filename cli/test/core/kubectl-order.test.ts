// kubectl 하위 명령 앞에는 전역 플래그만(T12-05 운영: `kubectl -A get pv`가 "flags cannot be placed before plugin name: -A"로 실패).
// 스텁이 실제 kubectl처럼 거부하므로 모든 시험의 kubectl 호출이 이 규칙을 지킨다. 여기서는 판정과 스텁 거부, list의 순서를 본다.
import { describe, expect, test } from "bun:test";
import { KINDS } from "../../src/core/kubectl";
import { kubectlLeadingProblem } from "../kubectl-order";
import { kubectlRule, stubSandbox, testCtx } from "../harness";

describe("kubectl 하위 명령 앞의 플래그", () => {
  test("전역 플래그(값 있음·=꼴·값 없음)는 통과, 그 밖은 그 플래그를 낸다", () => {
    expect(kubectlLeadingProblem(["-n", "app-x", "get", "pods"])).toBeNull();
    expect(kubectlLeadingProblem(["--request-timeout=20s", "--context", "c", "get", "pv", "-A"])).toBeNull();
    expect(kubectlLeadingProblem(["--insecure-skip-tls-verify", "-v=3", "get", "pv"])).toBeNull();
    expect(kubectlLeadingProblem(["get", "pv", "-A", "-o", "json"])).toBeNull();
    expect(kubectlLeadingProblem(["-A", "get", "pv"])).toBe("-A");
    expect(kubectlLeadingProblem(["--all-namespaces", "get", "pv"])).toBe("--all-namespaces");
    expect(kubectlLeadingProblem(["-n", "x", "-o", "json", "get", "pods"])).toBe("-o");
    expect(kubectlLeadingProblem(["-l", "a=b", "get", "pods"])).toBe("-l");
  });

  test("스텁은 실제 kubectl처럼 거부한다: exit 1, 같은 문구, 규칙이 맞아도", () => {
    const sb = stubSandbox([kubectlRule(["-A", "get", "persistentvolumes", "-o", "json"], { stdout: '{"items":[]}' })]);
    const p = Bun.spawnSync([`${sb.bin}/kubectl`, "-A", "get", "persistentvolumes", "-o", "json", "--request-timeout=20s"], { env: sb.env, stdin: "ignore" });
    expect(p.exitCode).toBe(1);
    expect(p.stderr.toString()).toContain("flags cannot be placed before plugin name: -A");
    expect(sb.calls().unmatched.map((c) => c.argv)).toEqual([["kubectl", "-A", "get", "persistentvolumes", "-o", "json", "--request-timeout=20s"]]);
  });

  test("list(kind, null)은 get <리소스> 뒤에 -A를 둔다(라벨 선택자 포함)", () => {
    const rules = [
      kubectlRule(["get", KINDS.pv, "-A", "-o", "json"], { stdout: '{"items":[{"metadata":{"name":"pv-1"}}]}' }),
      kubectlRule(["get", KINDS.pvc, "-A", "-l", "homelab.ukyi.app/restore", "-o", "json"], { stdout: '{"items":[]}' }),
      kubectlRule(["-n", "app-x", "get", KINDS.pvc, "-o", "json"], { stdout: '{"items":[]}' }),
    ];
    const { ctx, calls } = testCtx("read", rules);
    expect(ctx.k8s.list("pv", null).map((x) => x.metadata.name)).toEqual(["pv-1"]);
    expect(ctx.k8s.list("pvc", null, "homelab.ukyi.app/restore")).toEqual([]);
    expect(ctx.k8s.list("pvc", "app-x")).toEqual([]);
    const c = calls();
    expect(c.unmatched.map((x) => x.argv)).toEqual([]);
    for (const x of c.calls) expect([x.argv.join(" "), kubectlLeadingProblem(x.argv.slice(1))]).toEqual([x.argv.join(" "), null]);
  });
});
