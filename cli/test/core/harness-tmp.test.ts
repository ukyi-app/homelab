// 시험 장치의 임시 뿌리 정리(#880 3라운드 P2, #887 리뷰 P2 둘). 하위 bun test를 전용 TMPDIR로 돌려, 다른 실행의 폴더는
// 그대로 두고 자기 것(장치 뿌리, core tempDir 폴더, 감싸개의 TMPDIR)만 지우는지 본다. 다른 PID 네임스페이스의 살아 있는
// 실행은 이쪽에서 죽은 PID로 보이므로, 이미 끝난 프로세스의 PID 이름으로 폴더를 심어 그 경우를 흉내 낸다.
import { afterAll, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { removeTree } from "../remove-tree";

const REPO = join(import.meta.dir, "..", "..", "..");
const HARNESS = join(import.meta.dir, "..", "harness.ts");
const RUN = join(import.meta.dir, "..", "run.ts");
const TEMP = join(import.meta.dir, "..", "..", "src", "core", "temp.ts");
const top = mkdtempSync(join(tmpdir(), "homelab-cli-harness-tmp-"));

afterAll(() => removeTree(top));

// CHILD_FAIL이면 첫 시험이 실패한다(뒤 시험이 있어야 --bail이 남은 시험을 건너뛰고 끝난다). CHILD_WAIT이면 READY를 낸 뒤 기다린다.
const CHILD = `import { expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { runCli, testCtx, testRoot } from ${JSON.stringify(HARNESS)};
import { tempDir } from ${JSON.stringify(TEMP)};
test("child", async () => {
  const t = testCtx("plan", []);
  expect(existsSync(t.home)).toBe(true);
  // 시험 HOME의 Infisical 백업 폴더처럼 잠긴 폴더 안에 파일이 남아도 지워야 한다.
  mkdirSync(join(t.home, ".infisical", "secrets-backup", "left"), { recursive: true });
  chmodSync(join(t.home, ".infisical", "secrets-backup"), 0o500);
  await runCli(["--help"], []);
  // 같은 프로세스에서 GitHub 어댑터를 부른 시험처럼 core 임시 폴더를 만든다(TMPDIR 바로 아래).
  expect(existsSync(tempDir("github"))).toBe(true);
  expect(testRoot().startsWith(process.env.TMPDIR ?? "")).toBe(true);
  console.log("ROOT=" + testRoot());
  if (process.env.CHILD_WAIT) {
    console.log("READY");
    await Bun.sleep(60_000);
  }
  if (process.env.CHILD_FAIL) throw new Error("의도한 실패");
}, 120_000);
test("after", () => {});
`;

async function deadPid(): Promise<number> {
  const p = Bun.spawn(["true"]);
  await p.exited;
  return p.pid;
}

type Opts = { fail?: boolean; wrap?: boolean; bail?: boolean; term?: boolean };

async function childRun(name: string, o: Opts) {
  const base = join(top, name);
  const tmp = join(base, "tmp");
  const kase = join(base, "case");
  mkdirSync(tmp, { recursive: true });
  mkdirSync(kase);
  // 다른 실행의 폴더 셋: 예전 PID 이름(죽은 PID로 보임), 지금 장치 뿌리 이름, 감싸개 TMPDIR 이름(모두 살아 있는 다른 실행).
  const others = [`homelab-cli-test-${await deadPid()}`, "homelab-cli-test-run-other", "homelab-cli-test-tmp-other"];
  for (const x of others) {
    mkdirSync(join(tmp, x, "s-x", "home"), { recursive: true });
    writeFileSync(join(tmp, x, "s-x", "ledger.jsonl"), "");
  }
  const file = join(kase, "child.test.ts");
  writeFileSync(file, CHILD);
  const args = [...(o.bail ? ["--bail"] : []), file];
  // cwd는 저장소 뿌리: bunfig.toml의 preload(setup.ts)가 실제와 같이 걸린다.
  const p = Bun.spawn(o.wrap ? [process.execPath, RUN, ...args] : [process.execPath, "test", ...args], {
    cwd: REPO,
    env: { ...process.env, TMPDIR: tmp, ...(o.fail ? { CHILD_FAIL: "1" } : {}), ...(o.term ? { CHILD_WAIT: "1" } : {}) },
    stdout: "pipe",
    stderr: "pipe",
  });
  const err = new Response(p.stderr).text();
  let out = "";
  const reader = p.stdout.getReader();
  const dec = new TextDecoder();
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    out += dec.decode(value);
    // 시험이 READY를 내면 감싸개에 SIGTERM을 보낸다(사람이 Ctrl-C·kill로 멈추는 경우).
    if (o.term && out.includes("READY") && !p.killed) p.kill("SIGTERM");
  }
  const code = await p.exited;
  const log = `${out}${await err}`;
  return { code, own: log.match(/ROOT=(\S+)/)?.[1] ?? null, others, tmp, log };
}

function expectOnlyOthers(r: Awaited<ReturnType<typeof childRun>>, code: number, ownPrefix: string): void {
  expect({ code: r.code, log: r.code === code ? "" : r.log }).toEqual({ code, log: "" });
  expect(r.own).not.toBeNull();
  expect(r.own!.startsWith(join(r.tmp, ownPrefix))).toBe(true);
  expect(existsSync(r.own!)).toBe(false);
  for (const x of r.others) expect(existsSync(join(r.tmp, x, "s-x", "ledger.jsonl"))).toBe(true);
  expect(readdirSync(r.tmp).sort()).toEqual([...r.others].sort());
}

describe("시험 장치 임시 뿌리", () => {
  for (const fail of [false, true]) {
    test(`bun test: 다른 실행의 폴더는 남기고 자기 뿌리와 core 임시 폴더만 지운다(시험 ${fail ? "실패" : "성공"})`, async () => {
      expectOnlyOthers(await childRun(fail ? "ok-fail" : "ok", { fail }), fail ? 1 : 0, "homelab-cli-test-run-");
    }, 60_000);
  }

  test("감싸개 + --bail 실패 종료: 전용 TMPDIR째 지우고 exit 1을 그대로 낸다(#887 리뷰 P2)", async () => {
    expectOnlyOthers(await childRun("wrap-bail", { wrap: true, bail: true, fail: true }), 1, "homelab-cli-test-tmp-");
  }, 60_000);

  test("감싸개 + 성공: exit 0, 전용 TMPDIR째 지운다", async () => {
    expectOnlyOthers(await childRun("wrap-ok", { wrap: true }), 0, "homelab-cli-test-tmp-");
  }, 60_000);

  test("감싸개에 SIGTERM: 자식에게 넘기고 지운 뒤 143으로 끝난다", async () => {
    expectOnlyOthers(await childRun("wrap-term", { wrap: true, term: true }), 143, "homelab-cli-test-tmp-");
  }, 60_000);

  // 대조군(bun 1.4.3 실측): 감싸개 없이 --bail로 실패하면 afterAll이 돌지 않아 자기 뿌리가 남는다. 감싸개가 필요한 이유다.
  // bun이 이 동작을 바꾸면 여기가 깨진다. 그때는 감싸개가 아직 필요한지 다시 본다.
  test("대조군: 감싸개 없는 --bail 실패는 자기 뿌리를 남긴다", async () => {
    const r = await childRun("bail-bare", { bail: true, fail: true });
    expect(r.code).toBe(1);
    expect(r.own).not.toBeNull();
    expect(existsSync(r.own!)).toBe(true);
  }, 60_000);
});
