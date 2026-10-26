// homelab github apply: 래퍼 apply를 쓰기로 한 번 부르고 종료 코드를 그대로 낸다. 래퍼가 묻는 값과 yes는 사람이 답한다(stdin 상속).
import { describe, expect, test } from "bun:test";
import { REST, expectNoSecrets, expectPlanReadOnly, rule, runCli, type Resp } from "../harness";

const clone = rule(["git", REST], { materialize: { "tools/tf-github.sh": "stub" } });
const wrapper = (resp: Resp) => rule(["tf-github.sh", "apply", REST], resp, { noStdin: true });
const wrapperArgs = (r: { calls: { argv: string[] }[] }) => r.calls.filter((c) => c.argv[0].endsWith("tf-github.sh")).map((c) => c.argv.slice(1));

describe("github apply", () => {
  for (const code of [0, 1, 2]) {
    test(`래퍼 exit ${code} → CLI exit ${code}, 래퍼 apply 쓰기 1건`, async () => {
      const r = await runCli(["github", "apply", "--json"], [clone, wrapper({ code })]);
      expect(r.code).toBe(code);
      expect(r.json.exitCode).toBe(code);
      expect(r.json.mode).toBe("apply");
      expect(r.json.status).toBe(code === 0 ? "done" : "failed");
      expect(r.writes.map((c) => c.argv.slice(1))).toEqual([["apply"]]);
      expect(r.unmatched).toEqual([]);
      expectNoSecrets(r);
      if (code !== 0) expect(r.json.error.next.length).toBeGreaterThan(0);
    });
  }

  test("--allow-destroy를 래퍼에 넘긴다", async () => {
    const r = await runCli(["github", "apply", "--allow-destroy", "--json"], [clone, wrapper({ code: 0 })]);
    expect(r.code).toBe(0);
    expect(wrapperArgs(r)).toEqual([["apply", "--allow-destroy"]]);
  });

  test("--json이면 래퍼 출력(plan·yes 질문)은 stderr로, stdout은 JSON 하나", async () => {
    const r = await runCli(["github", "apply", "--json"], [clone, wrapper({ code: 0, stdout: "WRAPPER-PLAN-TEXT\n" })]);
    expect(r.json.schema).toBe("homelab-cli/v1");
    expect(r.stderr).toContain("WRAPPER-PLAN-TEXT");
  });

  test("사용법 오류(모르는 플래그·--apply)는 아무것도 실행하지 않는다", async () => {
    for (const flag of ["--yes", "--apply"]) {
      const r = await runCli(["github", "apply", flag], [clone, wrapper({ code: 0 })]);
      expect(r.code).toBe(64);
      expectPlanReadOnly(r, { allowNoCalls: true });
      expect(r.calls).toEqual([]);
    }
  });
});
