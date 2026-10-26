// homelab github plan: 래퍼 plan의 종료 코드를 그대로 낸다(결정 D2). plan은 읽기(-lock=false)라 쓰기 0건이다(AC-2).
import { describe, expect, test } from "bun:test";
import { REST, expectPlanReadOnly, rule, runCli, type Resp } from "../harness";

const clone = rule(["git", REST], { materialize: { "tools/tf-github.sh": "stub" } });
const wrapper = (resp: Resp) => rule(["tf-github.sh", "plan", REST], resp, { noStdin: true });
const wrapperArgs = (r: { calls: { argv: string[] }[] }) => r.calls.filter((c) => c.argv[0].endsWith("tf-github.sh")).map((c) => c.argv.slice(1));

describe("github plan", () => {
  for (const code of [0, 1, 2]) {
    test(`래퍼 exit ${code} → CLI exit ${code}, 쓰기 0건`, async () => {
      const r = await runCli(["github", "plan", "--json"], [clone, wrapper({ code })]);
      expect(r.code).toBe(code);
      expectPlanReadOnly(r);
      expect(r.json.exitCode).toBe(code);
      expect(r.json.status).toBe(code === 0 ? "same" : code === 2 ? "pending" : "failed");
      expect(wrapperArgs(r)).toEqual([["plan"]]);
    });
  }

  test("차이(2)면 다음 행동은 github apply, --allow-destroy를 래퍼에 넘기고 다음 행동에도 붙인다", async () => {
    const plain = await runCli(["github", "plan", "--json"], [clone, wrapper({ code: 2 })]);
    expect(plain.json.next).toBe("homelab github apply");
    const r = await runCli(["github", "plan", "--allow-destroy", "--json"], [clone, wrapper({ code: 2 })]);
    expect(r.code).toBe(2);
    expectPlanReadOnly(r);
    expect(wrapperArgs(r)).toEqual([["plan", "--allow-destroy"]]);
    expect(r.json.next).toBe("homelab github apply --allow-destroy");
  });

  test("--json이면 stdout은 JSON 하나, 래퍼 출력은 stderr", async () => {
    const r = await runCli(["github", "plan", "--json"], [clone, wrapper({ code: 2, stdout: "WRAPPER-PLAN-TEXT\n" })]);
    expect(r.json.schema).toBe("homelab-cli/v1");
    expect(r.stderr).toContain("WRAPPER-PLAN-TEXT");
    expect(r.stdout).not.toContain("WRAPPER-PLAN-TEXT");
  });

  test("--apply는 사용법 오류(64), 같은 플래그 두 번도 64", async () => {
    for (const args of [["--apply"], ["--allow-destroy", "--allow-destroy"]]) {
      const r = await runCli(["github", "plan", ...args], [clone, wrapper({ code: 0 })]);
      expect(r.code).toBe(64);
      expect(r.calls).toEqual([]);
    }
  });
});
