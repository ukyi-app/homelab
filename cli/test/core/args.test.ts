import { describe, expect, test } from "bun:test";
import { APPLY_FLAG, GLOBAL_FLAGS, parseInput, type ArgSpec, type FlagSpec } from "../../src/core/args";
import { APP_NAME } from "../../src/core/names";
import { UsageError } from "../../src/core/result";

const flags: FlagSpec[] = [
  { name: "confirm", kind: "value", pattern: APP_NAME, help: "" },
  { name: "cache", kind: "optional-value", values: ["persistent"], help: "" },
  { name: "postgres", kind: "bool", help: "" },
  APPLY_FLAG,
  ...GLOBAL_FLAGS,
];
const args: ArgSpec[] = [{ name: "app", required: true, help: "", pattern: APP_NAME }];
const parse = (t: string[]) => parseInput(flags, args, t);
const usage = (t: string[]) => expect(() => parse(t)).toThrow(UsageError);

describe("인자 파서", () => {
  test("정상 꼴", () => {
    const r = parse(["smoke", "--confirm", "smoke", "--cache=persistent", "--postgres", "--apply", "--json"]);
    expect(r.args.app).toBe("smoke");
    expect(r.flags).toMatchObject({ confirm: "smoke", cache: "persistent", postgres: true });
    expect(r.apply).toBe(true);
    expect(r.json).toBe(true);
    expect(parse(["smoke", "--confirm=smoke", "--cache"]).flags.cache).toBe(true);
  });

  test("중복 플래그는 64(B.8 E7: --confirm 우회)", () => {
    usage(["smoke", "--confirm", "x", "--confirm", "smoke"]);
    usage(["smoke", "--confirm=x", "--confirm", "smoke"]);
    usage(["smoke", "--apply", "--apply"]);
    usage(["smoke", "--json", "--json"]);
    usage(["smoke", "--cache", "--cache=persistent"]);
  });

  test("모르는 플래그·짧은 플래그·빠진 값", () => {
    usage(["smoke", "--nope"]);
    usage(["smoke", "-a"]);
    usage(["smoke", "--confirm"]);
    usage(["smoke", "--confirm", "--apply"]);
    usage(["smoke", "--confirm="]);
    usage(["smoke", "--apply=true"]);
    usage(["smoke", "--cache=nope"]);
  });

  test("위치 인자: 빠짐, 남음, 형식", () => {
    usage([]);
    usage(["smoke", "extra"]);
    usage(["Smoke"]);
    usage(["-smoke"]);
  });

  test("값 전체 형식: 줄바꿈이 낀 값은 한 줄이 맞아도 거부(#872 함정)", () => {
    usage(["smoke\nevil"]);
    usage(["evil\nsmoke"]);
    usage(["smoke", "--confirm", "smoke\r"]);
    usage(["smoke", "--confirm", "x\nsmoke"]);
  });

  test("-- 뒤는 위치 인자", () => {
    expect(parse(["--", "smoke"]).args.app).toBe("smoke");
  });
});
