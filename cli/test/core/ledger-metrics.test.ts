// 봇 삭제 원장 지표 어댑터(restore.md 2.1 재개 확인). argv는 앱 컨테이너 app 안의 node fetch 하나(런북 블록과 같은 스크립트),
// 쓰기 문맥에만 있고(plan은 파드에 들어가지 않는다), 돌려주는 것은 상태·개수뿐이다(본문은 오류 문구에도 넣지 않는다).
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { ExecTimeout } from "../../src/core/exec";
import { LEDGER_FETCH, parseLedgerMetrics } from "../../src/core/kubectl";
import { applyWith, rule, testCtx } from "../harness";

const NS = "app-homelab-bot";
const ARGV = ["kubectl", "-n", NS, "exec", "deploy/homelab-bot", "-c", "app", "--request-timeout=20s", "--", "node", "-e", LEDGER_FETCH];
// 본문에 섞인 다른 지표의 라벨 값. 어디에도 나오면 안 된다.
const LEAK = "mem-7f3a-leak-check";
const body = (state: string, pending: string) =>
  [
    "# HELP homelab_bot_deletion_ledger_state 원장 상태(one-hot)",
    "# TYPE homelab_bot_deletion_ledger_state gauge",
    ...["disabled", "failed", "ready"].map((s) => `homelab_bot_deletion_ledger_state{state="${s}"} ${s === state ? 1 : 0}`),
    "# TYPE homelab_bot_memory_deletions_pending gauge",
    `homelab_bot_memory_deletions_pending ${pending}`,
    `homelab_bot_probe{memory_id="${LEAK}"} 1`,
    "",
  ].join("\n");

describe("parseLedgerMetrics", () => {
  test("one-hot에서 값이 1인 상태와 삭제 대기 수만 꺼낸다", () => {
    expect(parseLedgerMetrics(body("ready", "0"))).toEqual({ state: "ready", pending: 0 });
    expect(parseLedgerMetrics(body("failed", "12"))).toEqual({ state: "failed", pending: 12 });
  });

  test("꼴이 다르면 던지고, 오류 문구에 본문을 넣지 않는다", () => {
    const cases: [string, string][] = [
      [body("none", "0"), "원장 상태 줄(값 1)이 0개다"],
      [`${body("ready", "0")}homelab_bot_deletion_ledger_state{state="failed"} 1\n`, "원장 상태 줄(값 1)이 2개다"],
      // 런북처럼 값은 정확히 1만 받는다
      [body("ready", "0").replace('{state="ready"} 1', '{state="ready"} 1.0'), "원장 상태 줄(값 1)이 0개다"],
      [body("ready", "0").replace(/^homelab_bot_memory_deletions_pending .*$/m, ""), "삭제 대기 줄이 0개다"],
      [`${body("ready", "0")}homelab_bot_memory_deletions_pending 0\n`, "삭제 대기 줄이 2개다"],
      [body("ready", "1.5"), "정수가 아니다"],
      [body("ready", "NaN"), "정수가 아니다"],
      ["", "원장 상태 줄(값 1)이 0개다"],
    ];
    for (const [text, msg] of cases) {
      let err: Error | undefined;
      try {
        parseLedgerMetrics(text);
      } catch (e) {
        err = e as Error;
      }
      expect(err?.message).toContain(msg);
      expect(err?.message).not.toContain(LEAK);
    }
  });

  test("스크립트는 restore.md 2.1 블록과 같은 글자다(CLI와 손 확인이 같은 것을 본다)", () => {
    const doc = readFileSync(join(import.meta.dir, "..", "..", "..", "docs", "runbooks-public", "restore.md"), "utf8");
    expect(doc).toContain(`'${LEDGER_FETCH}'`);
  });
});

describe("kubeWrite.ledgerMetrics", () => {
  test("앱 컨테이너 app 안의 node fetch 하나만 실행하고 상태·개수만 돌려준다", async () => {
    const { ctx, calls } = testCtx("apply", [rule(ARGV, { stdout: body("ready", "0") })]);
    const { value } = await applyWith(ctx, (w) => w.k8s.ledgerMetrics(NS, "homelab-bot"));
    expect(value).toEqual({ state: "ready", pending: 0 });
    const c = calls();
    expect(c.unmatched).toEqual([]);
    expect(c.calls.map((x) => x.argv)).toEqual([ARGV]);
  });

  test("exec 실패·꼴 다름은 던진다(통과로 보지 않는다). 본문은 문구에 없다", async () => {
    const failed = testCtx("apply", [rule(ARGV, { code: 1, stderr: "error: unable to upgrade connection: container not found (\"app\")" })]);
    await expect(applyWith(failed.ctx, (w) => w.k8s.ledgerMetrics(NS, "homelab-bot"))).rejects.toThrow("원장 지표: exit 1");
    const odd = testCtx("apply", [rule(ARGV, { stdout: `homelab_bot_probe{memory_id="${LEAK}"} 1\n` })]);
    const e = await applyWith(odd.ctx, (w) => w.k8s.ledgerMetrics(NS, "homelab-bot")).catch((x: Error) => x);
    expect((e as Error).message).toContain("원장 상태 줄(값 1)이 0개다");
    expect((e as Error).message).not.toContain(LEAK);
  });

  test("시간 초과는 ExecTimeout", async () => {
    const { ctx } = testCtx("apply", [rule(ARGV, { sleepMs: 3_000, stdout: body("ready", "0") })], { env: { HOMELAB_TEST_TIMEOUT_MS: "300" } });
    const e = await applyWith(ctx, (w) => w.k8s.ledgerMetrics(NS, "homelab-bot")).catch((x: Error) => x);
    expect(e).toBeInstanceOf(ExecTimeout);
  });

  test("읽기 문맥(plan)에는 없다: 파드에 들어가는 exec는 쓰기로 판정된다", () => {
    const { ctx, calls } = testCtx("plan", []);
    expect((ctx.k8s as unknown as Record<string, unknown>).ledgerMetrics).toBeUndefined();
    expect(calls().calls).toEqual([]);
  });
});
