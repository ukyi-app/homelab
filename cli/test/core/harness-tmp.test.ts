// 시험 장치의 임시 뿌리 정리(#880 3라운드 P2). 하위 bun test를 전용 TMPDIR로 돌려, 다른 실행의 폴더는 그대로 두고
// 자기 뿌리만 지우는지 본다. 다른 PID 네임스페이스의 살아 있는 실행은 이쪽에서 죽은 PID로 보이므로,
// 이미 끝난 프로세스의 PID 이름으로 폴더를 심어 그 경우를 흉내 낸다.
import { afterAll, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const REPO = join(import.meta.dir, "..", "..", "..");
const HARNESS = join(import.meta.dir, "..", "harness.ts");
const top = mkdtempSync(join(tmpdir(), "homelab-cli-harness-tmp-"));

afterAll(() => rmSync(top, { recursive: true, force: true }));

const CHILD = `import { expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { runCli, testCtx, testRoot } from ${JSON.stringify(HARNESS)};
test("child", async () => {
  const t = testCtx("plan", []);
  expect(existsSync(t.home)).toBe(true);
  // 시험 HOME의 Infisical 백업 폴더처럼 잠긴 폴더 안에 파일이 남아도 지워야 한다.
  mkdirSync(join(t.home, ".infisical", "secrets-backup", "left"), { recursive: true });
  chmodSync(join(t.home, ".infisical", "secrets-backup"), 0o500);
  await runCli(["--help"], []);
  expect(testRoot().startsWith(process.env.TMPDIR ?? "")).toBe(true);
  console.log("ROOT=" + testRoot());
  if (process.env.CHILD_FAIL) throw new Error("의도한 실패");
});
`;

async function deadPid(): Promise<number> {
  const p = Bun.spawn(["true"]);
  await p.exited;
  return p.pid;
}

async function childRun(name: string, fail: boolean) {
  const base = join(top, name);
  const tmp = join(base, "tmp");
  const kase = join(base, "case");
  mkdirSync(tmp, { recursive: true });
  mkdirSync(kase);
  // 다른 실행의 폴더 둘: 예전 PID 이름(죽은 PID로 보임)과 지금 이름(살아 있는 다른 실행).
  const others = [`homelab-cli-test-${await deadPid()}`, "homelab-cli-test-run-other"];
  for (const o of others) {
    mkdirSync(join(tmp, o, "s-x", "home"), { recursive: true });
    writeFileSync(join(tmp, o, "s-x", "ledger.jsonl"), "");
  }
  const file = join(kase, "child.test.ts");
  writeFileSync(file, CHILD);
  // cwd는 저장소 뿌리: bunfig.toml의 preload(setup.ts)가 실제와 같이 걸린다.
  const p = Bun.spawn([process.execPath, "test", file], {
    cwd: REPO,
    env: { ...process.env, TMPDIR: tmp, ...(fail ? { CHILD_FAIL: "1" } : {}) },
    stdout: "pipe",
    stderr: "pipe",
  });
  const [out, err, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  const own = `${out}${err}`.match(/ROOT=(\S+)/)?.[1] ?? null;
  return { code, own, others, tmp, log: `${out}${err}` };
}

describe("시험 장치 임시 뿌리", () => {
  for (const fail of [false, true]) {
    test(`다른 실행의 폴더는 남기고 자기 뿌리만 지운다(시험 ${fail ? "실패" : "성공"})`, async () => {
      const r = await childRun(fail ? "fail" : "ok", fail);
      expect({ code: r.code, log: r.code === (fail ? 1 : 0) ? "" : r.log }).toEqual({ code: fail ? 1 : 0, log: "" });
      expect(r.own).not.toBeNull();
      expect(r.own!.startsWith(join(r.tmp, "homelab-cli-test-run-"))).toBe(true);
      expect(existsSync(r.own!)).toBe(false);
      for (const o of r.others) expect(existsSync(join(r.tmp, o, "s-x", "ledger.jsonl"))).toBe(true);
      expect(readdirSync(r.tmp).sort()).toEqual([...r.others].sort());
    }, 60_000);
  }
});
