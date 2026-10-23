// 명령에 넘기는 Secret이 불투명한지(#873 3라운드 P1). 16자 미만 기존 값은 원문 추적이 없으므로(사용자 결정 2026-10-23)
// 보호는 오직 "명령이 원문을 꺼낼 수 없다"에 기댄다. 명령이 쓸 수 있는 모든 길로 꺼내 보고 출력·PR 파일로 나가지 않는지 본다.
import { describe, expect, test } from "bun:test";
import { inspect } from "node:util";
import type { ReadCtx, Secret, Step } from "../../src/core/command";
import { HOMELAB_REPO } from "../../src/core/github";
import { render } from "../../src/core/output";
import { prStep } from "../../src/core/pr";
import { FAKE_SHA, ghGet, ghResponse, ghSend, infisicalList, testCtx, type Rule } from "../harness";

const OLD = "old-15-char-key"; // 기존 15자 값(추적 대상 아님)
const R = `repos/${HOMELAB_REPO}`;

function valueFromCommandSide(): { ctx: ReadCtx; v: Secret } {
  const { ctx } = testCtx("plan", [infisicalList("/apps/smoke", { LEGACY: OLD })]);
  const v = ctx.infisical.getValue("/apps/smoke", "LEGACY");
  expect(v).not.toBeNull();
  return { ctx, v: v! };
}

describe("명령용 Secret은 원문을 꺼낼 수 없다", () => {
  test("원문 메서드·속성이 없고, 문자열로 바뀌는 모든 길은 [secret]", () => {
    const { v } = valueFromCommandSide();
    const any = v as unknown as Record<string | symbol, unknown>;
    expect(any.reveal).toBeUndefined();
    expect("reveal" in v).toBe(false);
    expect(Reflect.ownKeys(v)).toEqual([]);
    expect(Object.isFrozen(v)).toBe(true);
    for (const s of [String(v), `${v}`, v + "", JSON.stringify(v).slice(1, -1), inspect(v), (v as unknown as { toLocaleString(): string }).toLocaleString()]) expect(s).toBe("[secret]");
    // 프로토타입의 모든 메서드를 인자 없이 불러도 원문이 나오지 않는다(새 메서드가 생겨도 이 시험이 본다).
    const proto = Object.getPrototypeOf(v);
    for (const key of Reflect.ownKeys(proto)) {
      if (key === "constructor") continue;
      const f = proto[key];
      if (typeof f !== "function") continue;
      let out: unknown;
      try {
        out = f.call(v);
      } catch {
        out = undefined;
      }
      expect([String(key), String(out).includes(OLD)]).toEqual([String(key), false]);
    }
    expect(v.sha256Prefix(64).length).toBe(12);
  });

  test("명령 결과(notes·detail)에 넣어도 원문이 출력되지 않는다(사람용·JSON)", async () => {
    const { ctx, v } = valueFromCommandSide();
    const step: Step = { id: "s", target: `값 ${v}`, read: async () => ({ state: "same", action: "none", detail: `값=${v} ${JSON.stringify({ v })}` }) };
    const r = await ctx.engine({ command: "t", steps: [step], notes: [`legacy ${String(v)}`] });
    for (const json of [true, false]) expect(render(r, json)).not.toContain(OLD);
  });

  test("PR 파일 내용으로도 나가지 않는다: 문자열로 섞으면 [secret], 객체째 넣으면 거부", async () => {
    const { v } = valueFromCommandSide();
    const PATH = "apps/smoke/values.yaml";
    const pulls = `${R}/pulls?head=${encodeURIComponent("ukyi-app:cli/db-add-smoke")}&state=open`;
    const rules: Rule[] = [
      infisicalList("/apps/smoke", { LEGACY: OLD }),
      ghGet(`${R}/git/ref/heads/main`, 200, { object: { sha: FAKE_SHA } }),
      ghGet(`${R}/contents/${PATH}?ref=${FAKE_SHA}`, 404, {}),
      ghGet(pulls, [ghResponse(200, []), ghResponse(200, []), ghResponse(200, [])]),
      ghGet(`${R}/git/commits/${FAKE_SHA}`, 200, { tree: { sha: "d".repeat(40) } }),
      ghGet(`${R}/git/ref/heads/cli/db-add-smoke`, 404, {}),
      ghSend("POST", `${R}/git/trees`, 201, { sha: "e".repeat(40) }),
      ghSend("POST", `${R}/git/commits`, 201, { sha: "c".repeat(40) }),
      ghSend("POST", `${R}/git/refs`, 201, {}),
      ghSend("POST", `${R}/pulls`, 201, { number: 1 }),
    ];
    const { ctx, calls } = testCtx("apply", rules);
    const legacy = ctx.infisical.getValue("/apps/smoke", "LEGACY")!;
    const mixed = prStep({ command: "db add", app: "smoke", title: "t", body: `b ${legacy}`, files: [PATH], edit: () => ({ [PATH]: `token: ${legacy}\n` }) });
    await ctx.engine({ command: "db add", app: "smoke", steps: [mixed] });
    const sent = calls().calls.map((c) => `${c.argv.join(" ")} ${c.stdin ?? ""}`).join("\n");
    expect(sent).toContain("[secret]");
    expect(sent).not.toContain(OLD);
    const raw = prStep({ command: "db add", app: "smoke", title: "t", body: "b", files: [PATH], edit: () => ({ [PATH]: v as unknown as string }) });
    await expect(raw.read(testCtx("plan", rules).ctx)).rejects.toThrow("시크릿 객체");
  });

  test("타입에도 원문 메서드가 없다(strict tsc에서 @ts-expect-error가 쓰여야 통과)", () => {
    const { v } = valueFromCommandSide();
    const probe = () => {
      // @ts-expect-error 명령용 Secret에는 reveal이 없다
      return v.reveal();
    };
    expect(probe).toThrow();
  });
});
