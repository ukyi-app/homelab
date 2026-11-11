import { describe, expect, test } from "bun:test";
import { argvFor as infArgv } from "../../src/core/infisical";
import { runEngine } from "../../src/core/engine";
import { workerHashArgv } from "../../src/core/podops";
import { Secret, revealSecret } from "../../src/core/secret";
import type { BotAdminCommand, BotAdminReport, BotMarker, BotMethod, Plan, ReadCtx, WorkerLane, WriteCtx } from "../../src/core/command";
import type { Input } from "../../src/core/args";
import { FAKE_PROJECT, applyWith, expectNoSecrets, expectPlanReadOnly, infisicalList, kubectlRule, rule, runCli, testCtx, type Resp } from "../harness";
import { folderJson } from "../fixtures/app-add-world/world";
import { API_CHAT, API_TASK, CHAT, FOLDER, POD, TASK, WORKER, hash12, pod, pods } from "../fixtures/bot-account";
import add from "../../src/commands/bot-account-add";
import use from "../../src/commands/bot-account-use";
import list from "../../src/commands/bot-account-list";

// homelab bot account use(봇 COLLEAGUE_SPEC §4.8 "계정 전환", AC-21·AC-22). 경계 S3: 명령 엔진 + 가짜 infisical·kubectl.
// 값 노출(argv·출력)과 plan 부수효과 0은 실제 프로세스(runCli, PATH 스텁)로, 단계 순서(두 레인, 반영 전 해제 없음, 방식 표시와 자격이
// 함께 바뀜)와 재실행은 상태가 있는 가짜 세계(아래 AccountWorld)로 본다. PATH 스텁은 "쓰면 다음 읽기가 바뀌는" 흐름을 볼 수 없다.
// 키 이름과 방식 표시 값은 봇 DECISIONS "C23 API 크레딧 방식" 표 그대로다.

const OLD = { chat: "fakevalue-old-chat-aaaaaaaa", task: "fakevalue-old-task-aaaaaaaa" };
describe("bot account use", () => {
  test("plan(runCli): Infisical·Secret 해시만 읽고 쓰기·exec 0건, 값은 출력에 없다", async () => {
    const secret = (v: string): Resp => ({ stdout: JSON.stringify({ data: { CLAUDE_CODE_OAUTH_TOKEN: Buffer.from(v).toString("base64") } }) });
    const r = await runCli(["bot", "account", "use", "main", "--json"], [
      rule(infArgv.folders(FAKE_PROJECT, "/bot-accounts"), { stdout: folderJson("/bot-accounts", ["main"]) }),
      infisicalList(FOLDER, { CLAUDE_CODE_OAUTH_TOKEN: CHAT, CLAUDE_CODE_OAUTH_TOKEN_TASK: TASK }),
      infisicalList(WORKER, { CLAUDE_CODE_OAUTH_TOKEN: OLD.chat, CLAUDE_CODE_OAUTH_TOKEN_TASK: OLD.task }),
      kubectlRule(["-n", "sandbox", "get", "secret", "worker-credential-claude-subscription", "-o", "json"], secret(OLD.chat)),
      kubectlRule(["-n", "sandbox", "get", "secret", "worker-task-credential-claude-subscription", "-o", "json"], secret(OLD.task)),
      pods(pod()),
    ]);
    expect(r.code).toBe(0);
    expectPlanReadOnly(r, { secrets: [CHAT, TASK, OLD.chat, OLD.task] });
    expect(r.json.steps.map((s: any) => [s.id, s.state])).toEqual([["account-tokens", "same"], ["account-record", "differs"], ["worker-keys", "differs"],
      ["worker-secrets", "differs"], ["worker-volumes", "differs"], ["bot-account-use", "differs"]]);
  });

  test("plan --by api(runCli): 계정의 API 키 둘과 작업자 키를 해시로만 읽고 쓰기·exec 0건, 값은 출력에 없다", async () => {
    const secret = (v: string): Resp => ({ stdout: JSON.stringify({ data: { CLAUDE_CODE_OAUTH_TOKEN: Buffer.from(v).toString("base64") } }) });
    const r = await runCli(["bot", "account", "use", "main", "--by", "api", "--json"], [
      rule(infArgv.folders(FAKE_PROJECT, "/bot-accounts"), { stdout: folderJson("/bot-accounts", ["main"]) }),
      infisicalList(FOLDER, { ANTHROPIC_API_KEY: API_CHAT, ANTHROPIC_API_KEY_TASK: API_TASK }),
      infisicalList(WORKER, { CLAUDE_CODE_OAUTH_TOKEN: OLD.chat, CLAUDE_CODE_OAUTH_TOKEN_TASK: OLD.task }),
      kubectlRule(["-n", "sandbox", "get", "secret", "worker-credential-claude-subscription", "-o", "json"], secret(OLD.chat)),
      kubectlRule(["-n", "sandbox", "get", "secret", "worker-task-credential-claude-subscription", "-o", "json"], secret(OLD.task)),
      pods(pod()),
    ]);
    expect(r.code).toBe(0);
    expectPlanReadOnly(r, { secrets: [API_CHAT, API_TASK, OLD.chat, OLD.task] });
    expect(r.json.steps.map((s: any) => [s.id, s.state])).toEqual([["account-tokens", "same"], ["account-record", "differs"], ["worker-keys", "differs"],
      ["worker-secrets", "differs"], ["worker-volumes", "differs"], ["bot-account-use", "differs"]]);
    expect(JSON.stringify(r.json)).toContain("API 크레딧");
  });
});

// ---- 상태가 있는 가짜 세계: Infisical·작업자 Secret(ESO)·작업자 볼륨(kubelet)·봇 DB ----
const MARKER = "CLAUDE_AUTH_METHOD";
// 레인마다 ExternalSecret이 옮기는 키(Secret 키 ← Infisical 키). sandbox 배포(할 일 6) 전에는 구독 토큰 하나뿐이다.
const LANES: { lane: WorkerLane; secret: string; before: Record<string, string>; after: Record<string, string> }[] = [
  { lane: "chat", secret: "worker-credential-claude-subscription", before: { CLAUDE_CODE_OAUTH_TOKEN: "CLAUDE_CODE_OAUTH_TOKEN" },
    after: { CLAUDE_CODE_OAUTH_TOKEN: "CLAUDE_CODE_OAUTH_TOKEN", ANTHROPIC_API_KEY: "ANTHROPIC_API_KEY", [MARKER]: MARKER } },
  { lane: "task", secret: "worker-task-credential-claude-subscription", before: { CLAUDE_CODE_OAUTH_TOKEN: "CLAUDE_CODE_OAUTH_TOKEN_TASK" },
    after: { CLAUDE_CODE_OAUTH_TOKEN: "CLAUDE_CODE_OAUTH_TOKEN_TASK", ANTHROPIC_API_KEY: "ANTHROPIC_API_KEY_TASK", [MARKER]: MARKER } },
];
const FILE: Record<BotMethod, string> = { subscription: "CLAUDE_CODE_OAUTH_TOKEN", api: "ANTHROPIC_API_KEY" };
type Account = { name: string; method: BotMethod; current: boolean };
class AccountWorld {
  infisical = new Map<string, Map<string, string>>();
  secrets = new Map<string, Map<string, string>>();
  volumes = new Map<WorkerLane, Map<string, string>>();
  // sandbox 배포(ExternalSecret이 API 키·방식 표시도 옮김) 뒤인지.
  sandboxApi = false;
  // 볼륨이 Secret을 따라오기까지 남은 확인 횟수(kubelet 지연). 0이면 확인 때 바로 따라온다.
  volumeLag: Record<WorkerLane, number> = { chat: 0, task: 0 };
  // ESO가 이 ExternalSecret을 동기화하지 못한다(예: store 장애).
  esoBroken = new Set<string>();
  // 레인 키를 쓰다 실패한다(Infisical 장애 주입).
  failSet = new Set<string>();
  accounts: Account[] = [{ name: "main", method: "subscription", current: false }, { name: "main", method: "api", current: false },
    { name: "old", method: "subscription", current: true }];
  log: string[] = [];

  constructor() {
    this.set(FOLDER, "CLAUDE_CODE_OAUTH_TOKEN", CHAT);
    this.set(FOLDER, "CLAUDE_CODE_OAUTH_TOKEN_TASK", TASK);
    this.set(FOLDER, "ANTHROPIC_API_KEY", API_CHAT);
    this.set(FOLDER, "ANTHROPIC_API_KEY_TASK", API_TASK);
    this.set(WORKER, "CLAUDE_CODE_OAUTH_TOKEN", OLD.chat);
    this.set(WORKER, "CLAUDE_CODE_OAUTH_TOKEN_TASK", OLD.task);
    for (const l of LANES) this.sync(l.secret);
    for (const l of LANES) this.volumes.set(l.lane, new Map(this.secrets.get(l.secret)));
  }
  set(path: string, key: string, value: string) {
    if (!this.infisical.has(path)) this.infisical.set(path, new Map());
    this.infisical.get(path)!.set(key, value);
  }
  worker(key: string) { return this.infisical.get(WORKER)!.get(key); }
  // ExternalSecret 동기화. 옮길 원격 키가 하나라도 없으면 Degraded라 Secret을 바꾸지 않는다.
  sync(es: string) {
    const lane = LANES.find((l) => l.secret === es)!;
    const map = this.sandboxApi ? lane.after : lane.before;
    const values = Object.entries(map).map(([k, remote]) => [k, this.worker(remote)] as const);
    if (values.some(([, v]) => v === undefined)) return;
    this.secrets.set(es, new Map(values as [string, string][]));
  }
  admin(cmd: BotAdminCommand): BotAdminReport {
    this.log.push(`admin ${cmd.name === "account" ? cmd.action === "list" ? "account list" : `account ${cmd.action} ${cmd.method}` : cmd.name}`);
    if (cmd.name !== "account") throw new Error("계정 명령만");
    if (cmd.action === "list") return { exit: 0, result: "accounts", state: null, paused: { rate_limit: 0, auth_expired: 0, billing: 0 },
      accounts: this.accounts.map((a) => ({ name: a.name, method: a.method, current: a.current, issuedAt: null, expiresAt: null, limit: null })) };
    if (cmd.action === "use") {
      if (!this.accounts.some((a) => a.name === cmd.account && a.method === cmd.method)) return { exit: 3, result: "unknown_account", state: null };
      for (const a of this.accounts) a.current = a.name === cmd.account && a.method === cmd.method;
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
        expect(ns).toBe("sandbox");
        const v = w.secrets.get(name)?.get(key);
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
      infisical: { ...ctx.infisical,
        setValue(p: string, k: string, v: Secret) {
          if (w.failSet.has(k)) throw new Error(`Infisical ${p}/${k} 쓰기 실패`);
          w.log.push(`set ${p}/${k}`);
          w.set(p, k, revealSecret(v));
        },
        setMarker(p: string, k: string, v: BotMarker) {
          if (w.failSet.has(k)) throw new Error(`Infisical ${p}/${k} 쓰기 실패`);
          w.log.push(`mark ${p}/${k}=${v}`);
          w.set(p, k, v);
        } },
      k8s: { ...ctx.k8s, forceSync(ns: string, es: string) {
        w.log.push(`forceSync ${ns}/${es}`);
        if (!w.esoBroken.has(es)) w.sync(es);
      } },
      bot: { ...ctx.bot, admin: (cmd: BotAdminCommand) => w.admin(cmd), waitWorkerCredentials(want: Record<WorkerLane, string>, _timeout: number, method: BotMethod) {
        w.log.push(`waitWorkerCredentials ${method}`);
        const seen = { chat: false, task: false };
        for (const l of LANES) {
          if (w.volumeLag[l.lane] > 0) { w.volumeLag[l.lane]--; continue; }
          const files = new Map(w.secrets.get(l.secret)!);
          w.volumes.set(l.lane, files);
          const marker = files.get(MARKER);
          const markerOk = method === "api" ? marker === "api" : marker === undefined || marker === "subscription";
          const file = files.get(FILE[method]);
          seen[l.lane] = file !== undefined && hash12(file) === want[l.lane] && markerOk;
        }
        return seen;
      } },
    } as unknown as WriteCtx;
  }
}
const input = (args: Record<string, string>, flags: Record<string, unknown> = {}): Input => ({ args, flags } as unknown as Input);
const runUse = (w: AccountWorld, by?: BotMethod) => use.run(w.ctx("apply"), input({ name: "main" }, by ? { by } : {}));
const SUB_WRITES = [`set ${WORKER}/CLAUDE_CODE_OAUTH_TOKEN`, `set ${WORKER}/CLAUDE_CODE_OAUTH_TOKEN_TASK`, `mark ${WORKER}/${MARKER}=subscription`,
  `mark ${WORKER}/ANTHROPIC_API_KEY=unset`, `mark ${WORKER}/ANTHROPIC_API_KEY_TASK=unset`];
const API_WRITES = [`set ${WORKER}/ANTHROPIC_API_KEY`, `set ${WORKER}/ANTHROPIC_API_KEY_TASK`, `mark ${WORKER}/${MARKER}=api`,
  `mark ${WORKER}/CLAUDE_CODE_OAUTH_TOKEN=unset`, `mark ${WORKER}/CLAUDE_CODE_OAUTH_TOKEN_TASK=unset`];
const SYNCS = ["forceSync sandbox/worker-credential-claude-subscription", "forceSync sandbox/worker-task-credential-claude-subscription"];

describe("bot account use 흐름(가짜 세계)", () => {
  test("두 레인 자격 → 방식 표시 → 다른 방식 자리 비움 → 두 Secret 동기화 → 두 볼륨 지문 확인 → 봇 지금 계정·해제 순서로 끝나고, 해제는 반영 확인 뒤 한 번이다", async () => {
    const w = new AccountWorld();
    const r = await runUse(w);
    expect(r.status).toBe("done");
    expect(w.log).toEqual(["admin account list", ...SUB_WRITES, ...SYNCS, "waitWorkerCredentials subscription", "admin account use subscription"]);
    // 방식 표시 키가 없는 지금의 Secret(sandbox 배포 전)에서도 구독 전환은 그대로 된다.
    expect([w.volumes.get("chat")!.get(FILE.subscription), w.volumes.get("task")!.get(FILE.subscription)]).toEqual([CHAT, TASK]);
    expect(w.volumes.get("chat")!.has(MARKER)).toBe(false);
    expect(w.accounts.find((a) => a.current)).toEqual({ name: "main", method: "subscription", current: true });
    expect(r.notes.join("\n")).toContain("switched · 해제 2건 · 아직 대기 0건");
    expectNoSecrets({ stdout: JSON.stringify(r), calls: [] });
  });

  test("--by api: API 키 둘 → 방식 표시 api → 구독 토큰 자리 비움 순서로 쓰고, 작업자 키·볼륨에 구독 토큰이 남지 않으며 방식 표시와 자격이 함께 바뀐다", async () => {
    const w = new AccountWorld();
    w.sandboxApi = true;
    const r = await runUse(w, "api");
    expect(r.status).toBe("done");
    expect(w.log).toEqual(["admin account list", ...API_WRITES, ...SYNCS, "waitWorkerCredentials api", "admin account use api"]);
    expect(["ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY_TASK", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN_TASK", MARKER].map((k) => w.worker(k)))
      .toEqual([API_CHAT, API_TASK, "unset", "unset", "api"]);
    for (const l of LANES) expect(Object.fromEntries(w.volumes.get(l.lane)!)).toEqual({ CLAUDE_CODE_OAUTH_TOKEN: "unset",
      ANTHROPIC_API_KEY: l.lane === "chat" ? API_CHAT : API_TASK, [MARKER]: "api" });
    expect(w.accounts.find((a) => a.current)).toEqual({ name: "main", method: "api", current: true });
    expectNoSecrets({ stdout: JSON.stringify(r), calls: [] }, [API_CHAT, API_TASK, CHAT, TASK]);
    // 구독으로 돌아가면 그 반대다: 구독 토큰 → 방식 표시 subscription → API 키 자리 비움.
    w.log = [];
    const back = await runUse(w);
    expect(back.status).toBe("done");
    expect(w.log).toEqual(["admin account list", ...SUB_WRITES, ...SYNCS, "waitWorkerCredentials subscription", "admin account use subscription"]);
    for (const l of LANES) expect(Object.fromEntries(w.volumes.get(l.lane)!)).toEqual({ CLAUDE_CODE_OAUTH_TOKEN: l.lane === "chat" ? CHAT : TASK,
      ANTHROPIC_API_KEY: "unset", [MARKER]: "subscription" });
  });

  test("--by api인데 작업자 Secret이 API 키·방식 표시를 받지 않으면(sandbox 배포 전) 볼륨 확인·해제로 넘어가지 않는다", async () => {
    const w = new AccountWorld();
    const r = await runUse(w, "api");
    expect(r.status).toBe("failed");
    expect(w.log).not.toContain("waitWorkerCredentials api");
    expect(w.log.some((l) => l.startsWith("admin account use"))).toBe(false);
  });

  test("방식 표시 쓰기가 실패하면 동기화·해제로 넘어가지 않고 구독 토큰도 비우지 않으며, 다시 실행하면 이어 쓴다", async () => {
    const w = new AccountWorld();
    w.sandboxApi = true;
    w.failSet.add(MARKER);
    const first = await runUse(w, "api");
    expect(first.status).toBe("failed");
    expect(w.log).toEqual(["admin account list", ...API_WRITES.slice(0, 2)]);
    expect(w.worker("CLAUDE_CODE_OAUTH_TOKEN")).toBe(OLD.chat);
    w.failSet.clear();
    w.log = [];
    const again = await runUse(w, "api");
    expect(again.status).toBe("done");
    expect(w.log.filter((l) => l.startsWith("set ") || l.startsWith("mark "))).toEqual(API_WRITES);
  });

  test("작업 레인 볼륨이 기한 안에 따라오지 않으면 해제하지 않고 실패하며, 다시 실행하면 된 단계는 건너뛰고 이어서 해제한다", async () => {
    const w = new AccountWorld();
    w.volumeLag.task = 1;
    const first = await runUse(w);
    expect(first.status).toBe("failed");
    expect(first.error?.message).toContain("작업 레인 작업자에");
    expect(w.log).not.toContain("admin account use subscription");
    expect(w.accounts.find((a) => a.current)?.name).toBe("old");
    w.log = [];
    const again = await runUse(w);
    expect(again.status).toBe("done");
    expect(w.log).toEqual(["admin account list", "waitWorkerCredentials subscription", "admin account use subscription"]);
  });

  test("작업 레인 키 쓰기가 실패하면 동기화·해제로 넘어가지 않고, 다시 실행하면 남은 레인을 이어 쓴다(한 레인만 바뀐 채 해제 없음)", async () => {
    const w = new AccountWorld();
    w.failSet.add("CLAUDE_CODE_OAUTH_TOKEN_TASK");
    const first = await runUse(w);
    expect(first.status).toBe("failed");
    expect(w.log).toEqual(["admin account list", `set ${WORKER}/CLAUDE_CODE_OAUTH_TOKEN`]);
    expect(w.secrets.get("worker-credential-claude-subscription")!.get("CLAUDE_CODE_OAUTH_TOKEN")).toBe(OLD.chat);
    w.failSet.clear();
    w.log = [];
    const again = await runUse(w);
    expect(again.status).toBe("done");
    expect(w.log.filter((l) => l.startsWith("set ") || l.startsWith("mark "))).toEqual(SUB_WRITES);
    expect(w.log.at(-1)).toBe("admin account use subscription");
  });

  test("ESO가 Secret을 바꾸지 못하면 볼륨 확인·해제로 넘어가지 않는다", async () => {
    const w = new AccountWorld();
    w.esoBroken.add("worker-task-credential-claude-subscription");
    const r = await runUse(w);
    expect(r.status).toBe("failed");
    expect(w.log).not.toContain("waitWorkerCredentials subscription");
    expect(w.log).not.toContain("admin account use subscription");
  });

  test("계정 폴더에 그 방식의 레인 값이 하나라도 없거나 봇 DB에 그 방식의 기록이 없으면 작업자 키를 바꾸지 않는다", async () => {
    const missing = new AccountWorld();
    missing.infisical.get(FOLDER)!.delete("CLAUDE_CODE_OAUTH_TOKEN_TASK");
    const a = await runUse(missing);
    expect(a.status).toBe("failed");
    expect(a.error?.next).toBe("homelab bot account add main");
    expect(missing.log).toEqual([]);
    const apiMissing = new AccountWorld();
    apiMissing.infisical.get(FOLDER)!.delete("ANTHROPIC_API_KEY_TASK");
    const b = await runUse(apiMissing, "api");
    expect(b.status).toBe("failed");
    expect(b.error?.next).toBe("homelab bot account add main --by api");
    expect(apiMissing.log).toEqual([]);
    const unknown = new AccountWorld();
    unknown.accounts = [{ name: "main", method: "subscription", current: false }, { name: "old", method: "subscription", current: true }];
    const c = await runUse(unknown, "api");
    expect(c.status).toBe("failed");
    expect(unknown.log).toEqual(["admin account list"]);
    expect(unknown.worker("CLAUDE_CODE_OAUTH_TOKEN")).toBe(OLD.chat);
  });

  test("이미 그 계정이면 자격 단계는 건너뛰고 지문 확인 뒤 해제만 다시 한다(같은 계정에서 푼 결제 멈춤의 해제 경로)", async () => {
    const w = new AccountWorld();
    await runUse(w);
    w.log = [];
    const again = await runUse(w);
    expect(again.status).toBe("done");
    expect(w.log).toEqual(["admin account list", "waitWorkerCredentials subscription", "admin account use subscription"]);
  });
});

describe("작업자 자격 지문 대기(core botWrite.waitWorkerCredentials)", () => {
  const line = (v: string, file: string) => `${new Bun.CryptoHasher("sha256").update(v).digest("hex")}  /run/worker-credential/${file}\n`;
  const sum = (v: string, marker?: string) => ({ stdout: line(v, "CLAUDE_CODE_OAUTH_TOKEN") + (marker === undefined ? "" : line(marker, "CLAUDE_AUTH_METHOD")),
    ...(marker === undefined ? { code: 1, stderr: "sha256sum: /run/worker-credential/CLAUDE_AUTH_METHOD: No such file or directory" } : {}) });
  const apiSum = (v: string, marker?: string) => ({ stdout: line(v, "ANTHROPIC_API_KEY") + (marker === undefined ? "" : line(marker, "CLAUDE_AUTH_METHOD")) });
  const want = { chat: hash12(CHAT), task: hash12(TASK) };
  test("exec가 죽거나(정리 sweep) 옛 값이면 다시 보고, 두 레인이 맞으면 끝난다. 방식 표시 파일이 없는 구독(sandbox 배포 전)도 맞다", async () => {
    const { ctx, calls } = testCtx("apply", [
      rule(workerHashArgv("chat", "subscription"), sum(CHAT)),
      rule(workerHashArgv("task", "subscription"), [{ code: 137, stderr: "command terminated with exit code 137" }, sum(OLD.task), sum(TASK, "subscription")]),
    ], { env: { HOMELAB_TEST_POLL_MS: "10" } });
    const { value } = await applyWith(ctx, (w) => w.bot.waitWorkerCredentials(want, 5, "subscription"));
    expect(value).toEqual({ chat: true, task: true });
    expect(calls().calls.map((c) => c.argv[4])).toEqual(["deploy/worker", "deploy/worker-task", "deploy/worker-task", "deploy/worker-task"]);
  });
  test("기한 안에 맞지 않은 레인은 false다. 구독인데 방식 표시가 api인 레인도 false다", async () => {
    const { ctx } = testCtx("apply", [rule(workerHashArgv("chat", "subscription"), sum(CHAT)), rule(workerHashArgv("task", "subscription"), sum(TASK, "api"))], { env: { HOMELAB_TEST_POLL_MS: "200" } });
    const { value } = await applyWith(ctx, (w) => w.bot.waitWorkerCredentials(want, 1, "subscription"));
    expect(value).toEqual({ chat: true, task: false });
    await expect(applyWith(ctx, (w) => w.bot.waitWorkerCredentials({ chat: "x", task: want.task }, 1, "subscription"))).rejects.toThrow("sha256 앞 12자");
  });
  test("API 방식은 API 키 파일과 방식 표시 api가 함께 맞아야 한다(표시가 없거나 subscription이면 false)", async () => {
    const apiWant = { chat: hash12(API_CHAT), task: hash12(API_TASK) };
    const { ctx } = testCtx("apply", [rule(workerHashArgv("chat", "api"), apiSum(API_CHAT, "api")), rule(workerHashArgv("task", "api"), [apiSum(API_TASK, "subscription"), apiSum(API_TASK)])], { env: { HOMELAB_TEST_POLL_MS: "200" } });
    const { value } = await applyWith(ctx, (w) => w.bot.waitWorkerCredentials(apiWant, 1, "api"));
    expect(value).toEqual({ chat: true, task: false });
  });
});

describe("bot account add·list 문맥", () => {
  test("add·list 명령은 등록 표의 경로와 같다", () => {
    expect([add.path, use.path, list.path]).toEqual([["bot", "account", "add"], ["bot", "account", "use"], ["bot", "account", "list"]]);
  });
  test("작업자 지문 확인 argv는 sandbox ns의 두 Deployment, 컨테이너 worker, 고정 파일(방식의 자격·방식 표시)만 본다", () => {
    expect(workerHashArgv("chat", "subscription")).toEqual(["kubectl", "-n", "sandbox", "exec", "deploy/worker", "-c", "worker", "--request-timeout=20s", "--", "sha256sum",
      "/run/worker-credential/CLAUDE_CODE_OAUTH_TOKEN", "/run/worker-credential/CLAUDE_AUTH_METHOD"]);
    expect(workerHashArgv("task", "api").slice(4)).toEqual(["deploy/worker-task", "-c", "worker", "--request-timeout=20s", "--", "sha256sum",
      "/run/worker-credential/ANTHROPIC_API_KEY", "/run/worker-credential/CLAUDE_AUTH_METHOD"]);
  });
});
