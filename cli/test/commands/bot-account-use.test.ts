import { describe, expect, test } from "bun:test";
import { argvFor as infArgv } from "../../src/core/infisical";
import { runEngine } from "../../src/core/engine";
import { workerHashArgv } from "../../src/core/podops";
import { Secret, revealSecret } from "../../src/core/secret";
import type { BotAccount, BotAdminCommand, BotAdminReport, Plan, ReadCtx, WorkerLane, WriteCtx } from "../../src/core/command";
import type { Input } from "../../src/core/args";
import { FAKE_PROJECT, applyWith, expectNoSecrets, expectPlanReadOnly, infisicalList, kubectlRule, rule, runCli, testCtx, type Resp } from "../harness";
import { folderJson } from "../fixtures/app-add-world/world";
import { CHAT, FOLDER, POD, TASK, WORKER, hash12, pod, pods } from "../fixtures/bot-account";
import add from "../../src/commands/bot-account-add";
import use from "../../src/commands/bot-account-use";
import list from "../../src/commands/bot-account-list";

// homelab bot account use(봇 COLLEAGUE_SPEC §4.8 "계정 전환", AC-21). 경계 S3: 명령 엔진 + 가짜 infisical·kubectl.
// 값 노출(argv·출력)과 plan 부수효과 0은 실제 프로세스(runCli, PATH 스텁)로, 단계 순서(두 레인, 반영 전 해제 없음)와 재실행은
// 상태가 있는 가짜 세계(아래 AccountWorld)로 본다. PATH 스텁은 "쓰면 다음 읽기가 바뀌는" 흐름을 볼 수 없다.

describe("bot account use", () => {
  test("--by api는 아직 없어(C23) 아무것도 읽지 않고 사용법 오류다", async () => {
    const r = await runCli(["bot", "account", "use", "main", "--by", "api", "--json"], []);
    expect(r.code).toBe(64);
    expect(r.calls).toEqual([]);
  });

  test("plan(runCli): Infisical·Secret 해시만 읽고 쓰기·exec 0건, 값은 출력에 없다", async () => {
    const secret = (v: string): Resp => ({ stdout: JSON.stringify({ data: { CLAUDE_CODE_OAUTH_TOKEN: Buffer.from(v).toString("base64") } }) });
    const r = await runCli(["bot", "account", "use", "main", "--json"], [
      rule(infArgv.folders(FAKE_PROJECT, "/bot-accounts"), { stdout: folderJson("/bot-accounts", ["main"]) }),
      infisicalList(FOLDER, { CLAUDE_CODE_OAUTH_TOKEN: CHAT, CLAUDE_CODE_OAUTH_TOKEN_TASK: TASK }),
      infisicalList(WORKER, { CLAUDE_CODE_OAUTH_TOKEN: "fakevalue-old-chat-aaaaaaaa", CLAUDE_CODE_OAUTH_TOKEN_TASK: "fakevalue-old-task-aaaaaaaa" }),
      kubectlRule(["-n", "sandbox", "get", "secret", "worker-credential-claude-subscription", "-o", "json"], secret("fakevalue-old-chat-aaaaaaaa")),
      kubectlRule(["-n", "sandbox", "get", "secret", "worker-task-credential-claude-subscription", "-o", "json"], secret("fakevalue-old-task-aaaaaaaa")),
      pods(pod()),
    ]);
    expect(r.code).toBe(0);
    expectPlanReadOnly(r, { secrets: [CHAT, TASK, "fakevalue-old-chat-aaaaaaaa", "fakevalue-old-task-aaaaaaaa"] });
    expect(r.json.steps.map((s: any) => [s.id, s.state])).toEqual([["account-tokens", "same"], ["account-record", "differs"], ["worker-keys", "differs"],
      ["worker-secrets", "differs"], ["worker-volumes", "differs"], ["bot-account-use", "differs"]]);
  });
});

// ---- 상태가 있는 가짜 세계: Infisical·작업자 Secret(ESO)·작업자 볼륨(kubelet)·봇 DB ----
const LANES: { lane: WorkerLane; key: string; secret: string }[] = [
  { lane: "chat", key: "CLAUDE_CODE_OAUTH_TOKEN", secret: "worker-credential-claude-subscription" },
  { lane: "task", key: "CLAUDE_CODE_OAUTH_TOKEN_TASK", secret: "worker-task-credential-claude-subscription" },
];
class AccountWorld {
  infisical = new Map<string, Map<string, string>>();
  secrets = new Map<string, string>();
  volumes = new Map<WorkerLane, string>();
  // 볼륨이 Secret을 따라오기까지 남은 확인 횟수(kubelet 지연). 0이면 확인 때 바로 따라온다.
  volumeLag: Record<WorkerLane, number> = { chat: 0, task: 0 };
  // ESO가 이 키를 동기화하지 못한다(예: store 장애).
  esoBroken = new Set<string>();
  // 레인 키를 쓰다 실패한다(Infisical 장애 주입).
  failSet = new Set<string>();
  accounts: { name: string; current: boolean }[] = [{ name: "main", current: false }, { name: "old", current: true }];
  log: string[] = [];

  constructor() {
    this.set(FOLDER, "CLAUDE_CODE_OAUTH_TOKEN", CHAT);
    this.set(FOLDER, "CLAUDE_CODE_OAUTH_TOKEN_TASK", TASK);
    this.set(WORKER, "CLAUDE_CODE_OAUTH_TOKEN", "fakevalue-old-chat-aaaaaaaa");
    this.set(WORKER, "CLAUDE_CODE_OAUTH_TOKEN_TASK", "fakevalue-old-task-aaaaaaaa");
    for (const l of LANES) {
      this.secrets.set(l.secret, this.infisical.get(WORKER)!.get(l.key)!);
      this.volumes.set(l.lane, this.infisical.get(WORKER)!.get(l.key)!);
    }
  }
  set(path: string, key: string, value: string) {
    if (!this.infisical.has(path)) this.infisical.set(path, new Map());
    this.infisical.get(path)!.set(key, value);
  }
  admin(cmd: BotAdminCommand): BotAdminReport {
    this.log.push(`admin ${cmd.name === "account" ? `account ${cmd.action}` : cmd.name}`);
    if (cmd.name !== "account") throw new Error("계정 명령만");
    if (cmd.action === "list") return { exit: 0, result: "accounts", state: null, paused: { rate_limit: 0, auth_expired: 0, billing: 0 },
      accounts: this.accounts.map((a) => ({ name: a.name, method: "subscription", current: a.current, issuedAt: null, expiresAt: null, limit: null })) };
    if (cmd.action === "use") {
      if (!this.accounts.some((a) => a.name === cmd.account)) return { exit: 3, result: "unknown_account", state: null };
      for (const a of this.accounts) a.current = a.name === cmd.account;
      return { exit: 0, result: "switched", state: null, switch: { resumed: 2, waiting: 0, held: null } };
    }
    return { exit: 0, result: "recorded", state: null };
  }
  ctx(mode: "plan" | "apply"): ReadCtx {
    const w = this;
    const infRead = {
      folderExists: (p: string) => w.infisical.has(p),
      valueHash: (p: string, k: string) => { const v = w.infisical.get(p)?.get(k); return v === undefined ? null : hash12(v); },
      getValue: (p: string, k: string) => { const v = w.infisical.get(p)?.get(k); return v === undefined ? null : new Secret(v); },
    };
    const k8s = {
      secretHash: (ns: string, name: string, key: string) => {
        expect([ns, key]).toEqual(["sandbox", "CLAUDE_CODE_OAUTH_TOKEN"]);
        const v = w.secrets.get(name);
        return v === undefined ? null : hash12(v);
      },
      waitSecret: (ns: string, name: string, key: string, want: { hash: string }) => k8s.secretHash(ns, name, key) === want.hash,
    };
    const bot = { pod: () => POD, argv: (_pod: string, cmd: BotAdminCommand) => ["admin", JSON.stringify(cmd)] };
    const ctx: any = { mode, json: true, line: "homelab bot account use main", k8s, infisical: infRead, bot, progress() {} };
    ctx.engine = (plan: Plan) => runEngine(ctx, plan, () => ({ w: w.write(ctx), revoke() {} }));
    return ctx as ReadCtx;
  }
  write(ctx: any): WriteCtx {
    const w = this;
    return {
      ...ctx,
      infisical: { ...ctx.infisical, setValue(p: string, k: string, v: Secret) {
        if (w.failSet.has(k)) throw new Error(`Infisical ${p}/${k} 쓰기 실패`);
        w.log.push(`set ${p}/${k}`);
        w.set(p, k, revealSecret(v));
      } },
      k8s: { ...ctx.k8s, forceSync(ns: string, es: string) {
        w.log.push(`forceSync ${ns}/${es}`);
        const lane = LANES.find((l) => l.secret === es)!;
        if (!w.esoBroken.has(es)) w.secrets.set(es, w.infisical.get(WORKER)!.get(lane.key)!);
      } },
      bot: { ...ctx.bot, admin: (cmd: BotAdminCommand) => w.admin(cmd), waitWorkerCredentials(want: Record<WorkerLane, string>) {
        w.log.push("waitWorkerCredentials");
        const seen = { chat: false, task: false };
        for (const l of LANES) {
          if (w.volumeLag[l.lane] > 0) { w.volumeLag[l.lane]--; continue; }
          w.volumes.set(l.lane, w.secrets.get(l.secret)!);
          seen[l.lane] = hash12(w.volumes.get(l.lane)!) === want[l.lane];
        }
        return seen;
      } },
    } as unknown as WriteCtx;
  }
}
const input = (args: Record<string, string>, flags: Record<string, unknown> = {}): Input => ({ args, flags } as unknown as Input);
const runUse = (w: AccountWorld) => use.run(w.ctx("apply"), input({ name: "main" }));

describe("bot account use 흐름(가짜 세계)", () => {
  test("두 레인 자격 → 두 Secret 동기화 → 두 볼륨 지문 확인 → 봇 지금 계정·해제 순서로 끝나고, 해제는 반영 확인 뒤 한 번이다", async () => {
    const w = new AccountWorld();
    const r = await runUse(w);
    expect(r.status).toBe("done");
    expect(w.log).toEqual([
      "admin account list",
      `set ${WORKER}/CLAUDE_CODE_OAUTH_TOKEN`, `set ${WORKER}/CLAUDE_CODE_OAUTH_TOKEN_TASK`,
      "forceSync sandbox/worker-credential-claude-subscription", "forceSync sandbox/worker-task-credential-claude-subscription",
      "waitWorkerCredentials",
      "admin account use",
    ]);
    expect([w.volumes.get("chat"), w.volumes.get("task")]).toEqual([CHAT, TASK]);
    expect(w.accounts.find((a) => a.current)?.name).toBe("main");
    expect(r.notes.join("\n")).toContain("switched · 해제 2건 · 아직 대기 0건");
    expectNoSecrets({ stdout: JSON.stringify(r), calls: [] });
  });

  test("작업 레인 볼륨이 기한 안에 따라오지 않으면 해제하지 않고 실패하며, 다시 실행하면 된 단계는 건너뛰고 이어서 해제한다", async () => {
    const w = new AccountWorld();
    w.volumeLag.task = 1;
    const first = await runUse(w);
    expect(first.status).toBe("failed");
    expect(first.error?.message).toContain("작업 레인 작업자에");
    expect(w.log).not.toContain("admin account use");
    expect(w.accounts.find((a) => a.current)?.name).toBe("old");
    w.log = [];
    const again = await runUse(w);
    expect(again.status).toBe("done");
    expect(w.log).toEqual(["admin account list", "waitWorkerCredentials", "admin account use"]);
  });

  test("작업 레인 키 쓰기가 실패하면 동기화·해제로 넘어가지 않고, 다시 실행하면 남은 레인을 이어 쓴다(한 레인만 바뀐 채 해제 없음)", async () => {
    const w = new AccountWorld();
    w.failSet.add("CLAUDE_CODE_OAUTH_TOKEN_TASK");
    const first = await runUse(w);
    expect(first.status).toBe("failed");
    expect(w.log).toEqual(["admin account list", `set ${WORKER}/CLAUDE_CODE_OAUTH_TOKEN`]);
    expect(w.secrets.get("worker-credential-claude-subscription")).toBe("fakevalue-old-chat-aaaaaaaa");
    w.failSet.clear();
    w.log = [];
    const again = await runUse(w);
    expect(again.status).toBe("done");
    expect(w.log.filter((l) => l.startsWith("set "))).toEqual([`set ${WORKER}/CLAUDE_CODE_OAUTH_TOKEN`, `set ${WORKER}/CLAUDE_CODE_OAUTH_TOKEN_TASK`]);
    expect(w.log.at(-1)).toBe("admin account use");
  });

  test("ESO가 Secret을 바꾸지 못하면 볼륨 확인·해제로 넘어가지 않는다", async () => {
    const w = new AccountWorld();
    w.esoBroken.add("worker-task-credential-claude-subscription");
    const r = await runUse(w);
    expect(r.status).toBe("failed");
    expect(w.log).not.toContain("waitWorkerCredentials");
    expect(w.log).not.toContain("admin account use");
  });

  test("계정 폴더에 레인 토큰이 하나라도 없거나 봇 DB에 기록이 없으면 작업자 키를 바꾸지 않는다", async () => {
    const missing = new AccountWorld();
    missing.infisical.get(FOLDER)!.delete("CLAUDE_CODE_OAUTH_TOKEN_TASK");
    const a = await runUse(missing);
    expect(a.status).toBe("failed");
    expect(a.error?.next).toBe("homelab bot account add main");
    expect(missing.log).toEqual([]);
    const unknown = new AccountWorld();
    unknown.accounts = [{ name: "old", current: true }];
    const b = await runUse(unknown);
    expect(b.status).toBe("failed");
    expect(unknown.log).toEqual(["admin account list"]);
    expect(unknown.infisical.get(WORKER)!.get("CLAUDE_CODE_OAUTH_TOKEN")).toBe("fakevalue-old-chat-aaaaaaaa");
  });

  test("이미 그 계정이면 자격 단계는 건너뛰고 지문 확인 뒤 해제만 다시 한다(같은 계정에서 푼 결제 멈춤의 해제 경로)", async () => {
    const w = new AccountWorld();
    await runUse(w);
    w.log = [];
    const again = await runUse(w);
    expect(again.status).toBe("done");
    expect(w.log).toEqual(["admin account list", "waitWorkerCredentials", "admin account use"]);
  });
});

describe("작업자 자격 지문 대기(core botWrite.waitWorkerCredentials)", () => {
  const sum = (v: string) => ({ stdout: `${new Bun.CryptoHasher("sha256").update(v).digest("hex")}  /run/worker-credential/CLAUDE_CODE_OAUTH_TOKEN\n` });
  const want = { chat: hash12(CHAT), task: hash12(TASK) };
  test("exec가 죽거나(정리 sweep) 옛 값이면 다시 보고, 두 레인이 맞으면 끝난다", async () => {
    const { ctx, calls } = testCtx("apply", [
      rule(workerHashArgv("chat"), sum(CHAT)),
      rule(workerHashArgv("task"), [{ code: 137, stderr: "command terminated with exit code 137" }, sum("fakevalue-old-task-aaaaaaaa"), sum(TASK)]),
    ], { env: { HOMELAB_TEST_POLL_MS: "10" } });
    const { value } = await applyWith(ctx, (w) => w.bot.waitWorkerCredentials(want, 5));
    expect(value).toEqual({ chat: true, task: true });
    expect(calls().calls.map((c) => c.argv[4])).toEqual(["deploy/worker", "deploy/worker-task", "deploy/worker-task", "deploy/worker-task"]);
  });
  test("기한 안에 맞지 않은 레인은 false다", async () => {
    const { ctx } = testCtx("apply", [rule(workerHashArgv("chat"), sum(CHAT)), rule(workerHashArgv("task"), sum("fakevalue-old-task-aaaaaaaa"))], { env: { HOMELAB_TEST_POLL_MS: "200" } });
    const { value } = await applyWith(ctx, (w) => w.bot.waitWorkerCredentials(want, 1));
    expect(value).toEqual({ chat: true, task: false });
    await expect(applyWith(ctx, (w) => w.bot.waitWorkerCredentials({ chat: "x", task: want.task }, 1))).rejects.toThrow("sha256 앞 12자");
  });
});

describe("bot account add·list 문맥", () => {
  test("add·list 명령은 등록 표의 경로와 같다", () => {
    expect([add.path, use.path, list.path]).toEqual([["bot", "account", "add"], ["bot", "account", "use"], ["bot", "account", "list"]]);
  });
  test("작업자 지문 확인 argv는 sandbox ns의 두 Deployment, 컨테이너 worker, 고정 파일만 본다", () => {
    expect(workerHashArgv("chat")).toEqual(["kubectl", "-n", "sandbox", "exec", "deploy/worker", "-c", "worker", "--request-timeout=20s", "--", "sha256sum", "/run/worker-credential/CLAUDE_CODE_OAUTH_TOKEN"]);
    expect(workerHashArgv("task")[4]).toBe("deploy/worker-task");
  });
});
