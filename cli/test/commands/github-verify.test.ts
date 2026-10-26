// homelab github verify: 래퍼 verify의 종료 코드를 그대로 낸다(AC-5). 스텁 git clone이 tools/tf-github.sh 스텁을 만든다.
import { describe, expect, test } from "bun:test";
import { REST, expectPlanReadOnly, rule, runCli, type Resp } from "../harness";

const clone = rule(["git", REST], { materialize: { "tools/tf-github.sh": "stub" } });
const wrapper = (resp: Resp) => rule(["tf-github.sh", "verify"], resp, { noStdin: true });

describe("github verify", () => {
  for (const code of [0, 1, 2, 7]) {
    test(`래퍼 exit ${code} → CLI exit ${code}, 쓰기 0건`, async () => {
      const r = await runCli(["github", "verify", "--json"], [clone, wrapper({ code })]);
      expect(r.code).toBe(code);
      expectPlanReadOnly(r);
      expect(r.json.exitCode).toBe(code);
      expect(r.json.mode).toBe("read");
      expect(r.json.status).toBe(code === 0 ? "same" : code === 2 ? "pending" : "failed");
      if (code !== 0 && code !== 2) expect(r.json.error.next).toContain("guard 번호");
      const w = r.calls.filter((c) => c.argv[0].endsWith("tf-github.sh"));
      expect(w.map((c) => c.argv.slice(1))).toEqual([["verify"]]);
    });
  }

  test("--json이면 래퍼 출력은 stderr로, stdout은 JSON 하나", async () => {
    const r = await runCli(["github", "verify", "--json"], [clone, wrapper({ code: 2, stdout: "WRAPPER-PLAN-TEXT\n" })]);
    expect(r.code).toBe(2);
    expect(r.json.schema).toBe("homelab-cli/v1");
    expect(r.stdout).not.toContain("WRAPPER-PLAN-TEXT");
    expect(r.stderr).toContain("WRAPPER-PLAN-TEXT");
  });

  test("사람용: 래퍼 출력을 그대로 두고 머리에 종료 코드와 뜻", async () => {
    const r = await runCli(["github", "verify"], [clone, wrapper({ code: 0, stdout: "WRAPPER-PLAN-TEXT\n" })]);
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.stdout).toContain("WRAPPER-PLAN-TEXT");
    expect(r.stdout).toContain("homelab github verify: exit 0 (선언과 같음)");
    expect(r.stdout).toContain("다음: 없음");
  });

  test("clone 실패면 래퍼를 부르지 않고 exit 1(래퍼의 clone 실패 die와 같은 코드)", async () => {
    const r = await runCli(["github", "verify", "--json"], [rule(["git", REST], { code: 128 }), wrapper({ code: 0 })]);
    expect(r.code).toBe(1);
    expectPlanReadOnly(r);
    expect(r.calls.some((c) => c.argv[0].endsWith("tf-github.sh"))).toBe(false);
  });

  test("--allow-destroy·--apply는 사용법 오류(64), 아무것도 실행하지 않는다", async () => {
    for (const flag of ["--allow-destroy", "--apply"]) {
      const r = await runCli(["github", "verify", flag], [clone, wrapper({ code: 0 })]);
      expect(r.code).toBe(64);
      expect(r.calls).toEqual([]);
    }
  });
});
