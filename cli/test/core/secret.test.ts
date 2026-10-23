import { describe, expect, test } from "bun:test";
import { inspect } from "node:util";
import { renderHuman, render, OutputBlocked } from "../../src/core/output";
import { valueProblem } from "../../src/core/infisical";
import { MIN_SECRET, Secret, containsTracked, newPassword } from "../../src/core/secret";
import type { Result } from "../../src/core/result";

const base = (extra: Partial<Result> = {}): Result => ({ command: "db add", app: "smoke", mode: "plan", status: "pending", steps: [], notes: [], next: null, ...extra });

describe("Secret", () => {
  test("문자열로 바뀌는 길은 모두 [secret]", () => {
    const s = new Secret("fakevalue-secret-1111");
    expect(String(s)).toBe("[secret]");
    expect(`${s}`).toBe("[secret]");
    expect(JSON.stringify({ s })).toBe('{"s":"[secret]"}');
    expect(inspect(s)).toBe("[secret]");
    expect(s.reveal()).toBe("fakevalue-secret-1111");
    expect(containsTracked("x fakevalue-secret-1111 y")).toBe(true);
  });

  test("해시 앞부분은 sha256의 앞 12자", () => {
    const s = new Secret("fakevalue-secret-2222");
    expect(s.sha256Prefix()).toBe(new Bun.CryptoHasher("sha256").update("fakevalue-secret-2222").digest("hex").slice(0, 12));
  });

  test("생성 비밀번호는 영숫자 40자, 매번 다르다(명령은 apply 문맥의 generatePassword로만 얻는다)", () => {
    const p = newPassword();
    expect(p.length).toBe(40);
    expect(/^[A-Za-z0-9]{40}$/.test(p.reveal())).toBe(true);
    expect(newPassword().equals(p)).toBe(false);
  });

  test("원문 추적은 16자 이상만(사용자 결정 2026-10-23): 짧은 값은 고정 옵션·JSON 키와 겹쳐도 출력을 막지 않는다", () => {
    expect(MIN_SECRET).toBe(16);
    new Secret("false");
    new Secret("mode");
    expect(containsTracked("--expand=false")).toBe(false);
    expect(containsTracked('{"mode":"plan"}')).toBe(false);
    new Secret("fakevalue-secret-16");
    expect(containsTracked("x fakevalue-secret-16 y")).toBe(true);
  });
});

describe("출력 차단", () => {
  test("Result 안의 Secret 객체는 렌더하지 않는다", () => {
    const r = base({ notes: [new Secret("fakevalue-secret-3333") as unknown as string] });
    expect(() => render(r, true)).toThrow(OutputBlocked);
    expect(() => render(r, false)).toThrow(OutputBlocked);
  });

  test("추적 중인 원문이 섞인 문자열은 막고, 어느 단계인지만 알린다", () => {
    const raw = new Secret("fakevalue-secret-4444").reveal();
    const r = base({ steps: [{ id: "infisical-password", state: "missing", action: "create", target: "x", detail: `값 ${raw}`, result: "planned" }] });
    let msg = "";
    try {
      render(r, false);
    } catch (e) {
      msg = (e as Error).message;
    }
    expect(msg).toContain("infisical-password");
    expect(msg).not.toContain(raw);
  });

  test("JSON 이스케이프 꼴과 base64 꼴도 막는다", () => {
    const raw = 'fake"value\\quote-5555';
    new Secret(raw);
    const r = base({ notes: [`x ${raw}`] });
    expect(() => render(r, true)).toThrow(OutputBlocked);
    expect(() => render(base({ notes: [Buffer.from(raw).toString("base64")] }), false)).toThrow(OutputBlocked);
  });

  test("값이 없으면 사람용 출력이 설계 C.7 모양", () => {
    const r = base({
      steps: [
        { id: "a", state: "missing", action: "create", target: "data/smoke/values.yaml", detail: "없음 → 생성 (postgres)", result: "planned" },
        { id: "b", state: "same", action: "none", target: "Infisical homelab/prod /apps/smoke/postgres/PASSWORD", detail: "있음 (그대로 사용)", result: "skipped" },
      ],
      next: "homelab db add smoke --apply",
    });
    expect(renderHuman(r)).toBe(
      ["계획 (아무것도 바꾸지 않았다)", "  1 data/smoke/values.yaml                                 없음 → 생성 (postgres)", "  2 Infisical homelab/prod /apps/smoke/postgres/PASSWORD   있음 (그대로 사용)", "다음: homelab db add smoke --apply", ""].join("\n"),
    );
  });

  test("JSON은 schema가 맨 앞이고 설계 예시의 키를 가진다", () => {
    const doc = JSON.parse(render(base({ next: "homelab db add smoke --apply" }), true));
    expect(Object.keys(doc)).toEqual(["schema", "command", "app", "mode", "status", "steps", "notes", "next"]);
    expect(doc.schema).toBe("homelab-cli/v1");
  });
});

describe("Infisical 값 형식(.env 한 줄로 왕복하고 16자 이상인 값만)", () => {
  const pad = (v: string) => v + "x".repeat(Math.max(0, 16 - v.length));
  test.each([["a\nOTHER=x"], ["a\r"], ["tab\tx"], [" lead"], ["trail "], ['"q"'], ["'q"], [""], ["short"]])("거부: %p", (v) => {
    const value = v === "short" || v === "" ? v : v.startsWith(" ") || v.startsWith('"') || v.startsWith("'") ? pad(v) : v.endsWith(" ") ? "x".repeat(16) + v : pad(v);
    expect(valueProblem(new Secret(value))).not.toBeNull();
  });
  test.each([["abc#def"], ["a$HOME"], ["a${HOME}b"], ['a "q" b'], ["@/etc/hostname"]])("통과(그대로 간다, 2026-10-23 실측): %p", (v) => {
    expect(valueProblem(new Secret(pad(v)))).toBeNull();
  });
});
