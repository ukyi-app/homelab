// 시작할 때 잡아 둔 내장 함수(core/intrinsics.ts, T12-01b). 모듈을 불러온 뒤 전역을 덮어도 core의 시크릿 판정·출력·해석이 그대로인지 본다.
// 시험이 끝나면 전역을 되돌린다(다른 시험에 새지 않게).
import { afterEach, describe, expect, test } from "bun:test";
import { findSecretPath } from "../../src/core/guard";
import { OutputBlocked, render } from "../../src/core/output";
import type { Result } from "../../src/core/result";
import { Secret, containsTracked } from "../../src/core/secret";
import { FAKE_SECRETS, infisicalList, testCtx } from "../harness";

const saved = { includes: String.prototype.includes, stringify: JSON.stringify, parse: JSON.parse, freeze: Object.freeze, isArray: Array.isArray, entries: Object.entries };

afterEach(() => {
  String.prototype.includes = saved.includes;
  JSON.stringify = saved.stringify;
  JSON.parse = saved.parse;
  Object.freeze = saved.freeze;
  Array.isArray = saved.isArray;
  Object.entries = saved.entries;
});

const withNote = (note: string): Result => ({ command: "t", mode: "plan", status: "same", steps: [], notes: [note], next: null });

describe("잡아 둔 내장 함수", () => {
  test("String.prototype.includes·JSON.stringify를 덮어도 출력 차단이 시크릿을 찾는다", () => {
    new Secret(FAKE_SECRETS[0]);
    String.prototype.includes = () => false;
    JSON.stringify = () => "{}";
    expect(containsTracked(`앞 ${FAKE_SECRETS[0]} 뒤`)).toBe(true);
    expect(() => render(withNote(FAKE_SECRETS[0]), true)).toThrow(OutputBlocked);
    expect(() => render(withNote(FAKE_SECRETS[0]), false)).toThrow(OutputBlocked);
  });

  test("Array.isArray·Object.entries를 덮어도 결과 안의 Secret 객체를 찾는다", () => {
    const s = new Secret(FAKE_SECRETS[1]);
    Array.isArray = (() => false) as unknown as typeof Array.isArray;
    Object.entries = (() => []) as typeof Object.entries;
    expect(findSecretPath({ a: [1, { b: s }] }, "r")).toBe("r.a[1].b");
  });

  test("Object.freeze를 덮어도 Secret은 얼어 있다", () => {
    Object.freeze = (<T>(o: T) => o) as typeof Object.freeze;
    expect(Object.isFrozen(new Secret(FAKE_SECRETS[0]))).toBe(true);
  });

  test("JSON.parse를 덮어도 Infisical 목록 해석이 그대로다", () => {
    const { ctx } = testCtx("plan", [infisicalList("/apps/smoke", { A: FAKE_SECRETS[0], B: FAKE_SECRETS[1] })]);
    JSON.parse = () => [];
    expect(ctx.infisical.listKeys("/apps/smoke")).toEqual(["A", "B"]);
  });
});
