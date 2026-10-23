// 모든 등록 명령에 자동으로 도는 공통 시험. 명령을 구현해도 이 파일은 고치지 않는다.
import { describe, expect, test } from "bun:test";
import { REGISTRY } from "../../src/registry";
import { runCli } from "../harness";

// 위치 인자 견본 값(형식이 맞는 값).
const SAMPLE: Record<string, string> = { app: "smoke", KEY: "API_TOKEN" };
const argsOf = (c: (typeof REGISTRY)[number]) => [...c.path, ...c.args.filter((a) => a.required).map((a) => SAMPLE[a.name] ?? "x")];

describe("진입점", () => {
  test("--version은 0, 인자 없으면 사용법 + 64, 모르는 명령은 64", async () => {
    const v = await runCli(["--version"], []);
    expect([v.code, v.stdout]).toEqual([0, "homelab 0.1.0 (dev)\n"]);
    expect((await runCli([], [])).code).toBe(64);
    const u = await runCli(["nope", "--json"], []);
    expect(u.code).toBe(64);
    expect(u.json).toMatchObject({ schema: "homelab-cli/v1", status: "usage" });
    expect((await runCli(["--help"], [])).code).toBe(0);
  });
});

describe("등록 표", () => {
  test("경로가 겹치지 않고, 명령 플래그가 전역 플래그 이름을 쓰지 않는다", () => {
    const seen = new Set<string>();
    for (const c of REGISTRY) {
      const key = c.path.join(" ");
      expect(seen.has(key)).toBe(false);
      seen.add(key);
      for (const f of c.flags) expect(["apply", "json", "help"]).not.toContain(f.name);
      if (c.kind === "delegate") expect(c.path[0]).toBe("github");
      else expect(c.delegateMode).toBeUndefined();
    }
  });
});

describe("모든 명령: 사용법 오류는 외부 호출 없이 64", () => {
  for (const c of REGISTRY) {
    const base = argsOf(c);
    test(`homelab ${c.path.join(" ")}`, async () => {
      for (const extra of [["--json", "--json"], ["--nope"], ["-x"], ...(c.kind === "change" ? [["--apply", "--apply"]] : [["--apply"]])]) {
        const r = await runCli([...base, ...extra], []);
        expect([extra.join(" "), r.code]).toEqual([extra.join(" "), 64]);
        expect(r.calls).toEqual([]);
      }
      const h = await runCli([...base, "--help"], []);
      expect(h.code).toBe(0);
      expect(h.stdout).toStartWith(`homelab ${c.path.join(" ")}`);
    });
  }
});

describe("자리표시 명령은 외부 호출 없이 exit 1", () => {
  for (const c of REGISTRY.filter((x) => x.placeholder)) {
    test(`homelab ${c.path.join(" ")} (${c.placeholder})`, async () => {
      const r = await runCli([...argsOf(c), "--json"], []);
      expect(r.code).toBe(1);
      expect(r.json.error.message).toContain("아직 구현 전");
      expect(r.calls).toEqual([]);
    });
  }
});
