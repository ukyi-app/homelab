// 인자 파서. 틀리면 UsageError(64).
// 함정(B.8 E7): 같은 플래그를 두 번 받는 파서는 `--confirm x --confirm <app>`으로 파괴 확인을 우회시킨다. 중복은 거부한다.
import { fullMatch, hasControl } from "./names";
import { UsageError } from "./result";

export type FlagKind = "bool" | "value" | "optional-value";

export type FlagSpec = {
  name: string;
  kind: FlagKind;
  help: string;
  valueName?: string;
  // value·optional-value의 허용 값. optional-value는 필수.
  values?: string[];
  // value의 전체 형식(fullMatch로 값 전체를 본다).
  pattern?: RegExp;
};

export type ArgSpec = { name: string; required: boolean; help: string; pattern?: RegExp };

export type Input = {
  args: Record<string, string | undefined>;
  flags: Record<string, string | true | undefined>;
  apply: boolean;
  json: boolean;
  help: boolean;
};

export const GLOBAL_FLAGS: FlagSpec[] = [
  { name: "json", kind: "bool", help: "결과를 JSON(schema homelab-cli/v1)으로" },
  { name: "help", kind: "bool", help: "사용법" },
];
export const APPLY_FLAG: FlagSpec = { name: "apply", kind: "bool", help: "계획대로 실행(없으면 plan만)" };

function checkValue(what: string, value: string, spec: { values?: string[]; pattern?: RegExp }): void {
  if (value === "") throw new UsageError(`${what}: 값이 비었다`);
  if (hasControl(value)) throw new UsageError(`${what}: 줄바꿈·제어 문자를 받지 않는다`);
  if (spec.values && !spec.values.includes(value)) throw new UsageError(`${what}: ${spec.values.join(" | ")} 중 하나`);
  // 값은 되찍지 않는다. 시크릿을 인자로 잘못 넣은 경우 출력·로그로 다시 퍼진다(Connector 2라운드).
  if (spec.pattern && !fullMatch(spec.pattern, value)) throw new UsageError(`${what}: 형식이 아니다`);
}

export function parseInput(specFlags: FlagSpec[], specArgs: ArgSpec[], tokens: string[]): Input {
  const flags: Record<string, string | true | undefined> = {};
  const positional: string[] = [];
  const byName = new Map(specFlags.map((f) => [f.name, f]));
  let onlyPositional = false;

  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i];
    if (onlyPositional || !t.startsWith("-")) {
      positional.push(t);
      continue;
    }
    if (t === "--") {
      onlyPositional = true;
      continue;
    }
    if (t === "-h") {
      if (flags.help !== undefined) throw new UsageError("--help를 두 번 줬다");
      flags.help = true;
      continue;
    }
    if (!t.startsWith("--")) throw new UsageError(`짧은 플래그는 받지 않는다: ${t.slice(0, 2)}`);
    const eq = t.indexOf("=");
    const name = t.slice(2, eq === -1 ? undefined : eq);
    const inline = eq === -1 ? undefined : t.slice(eq + 1);
    const spec = byName.get(name);
    if (!spec) throw new UsageError(`모르는 플래그: --${name.slice(0, 40)}`);
    if (flags[name] !== undefined) throw new UsageError(`--${name}를 두 번 줬다(중복 플래그는 받지 않는다)`);
    if (spec.kind === "bool") {
      if (inline !== undefined) throw new UsageError(`--${name}는 값을 받지 않는다`);
      flags[name] = true;
    } else if (spec.kind === "optional-value") {
      // 값은 = 꼴만 받는다. `--cache persistent`는 위치 인자와 헷갈린다.
      if (inline === undefined) flags[name] = true;
      else {
        checkValue(`--${name}`, inline, spec);
        flags[name] = inline;
      }
    } else {
      let value = inline;
      if (value === undefined) {
        value = tokens[++i];
        if (value === undefined || value.startsWith("--")) throw new UsageError(`--${name}에 값이 없다`);
      }
      checkValue(`--${name}`, value, spec);
      flags[name] = value;
    }
  }

  const args: Record<string, string | undefined> = {};
  // --help면 위치 인자를 보지 않는다(필수 인자를 몰라도 도움말을 본다, Connector 2라운드).
  if (flags.help === true) return { args, flags, apply: flags.apply === true, json: flags.json === true, help: true };
  if (positional.length > specArgs.length) throw new UsageError(`인자가 ${positional.length - specArgs.length}개 많다(값은 보이지 않는다. 시크릿은 stdin으로)`);
  specArgs.forEach((a, idx) => {
    const v = positional[idx];
    if (v === undefined) {
      if (a.required) throw new UsageError(`<${a.name}>가 없다`);
      return;
    }
    if (v.startsWith("-")) throw new UsageError(`<${a.name}>는 -로 시작할 수 없다`);
    checkValue(`<${a.name}>`, v, a);
    args[a.name] = v;
  });

  return { args, flags, apply: flags.apply === true, json: flags.json === true, help: false };
}

export function usageLine(path: string[], specArgs: ArgSpec[], specFlags: FlagSpec[]): string {
  const parts = ["homelab", ...path];
  for (const a of specArgs) parts.push(a.required ? `<${a.name}>` : `[<${a.name}>]`);
  for (const f of specFlags) {
    if (f.name === "help") continue;
    const v = f.valueName ?? f.values?.join("|") ?? "값";
    parts.push(f.kind === "bool" ? `[--${f.name}]` : f.kind === "value" ? `[--${f.name} <${v}>]` : `[--${f.name}[=${v}]]`);
  }
  return parts.join(" ");
}
