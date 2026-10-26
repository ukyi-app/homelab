// 소스 규칙 정적 검사(cli/README.md "명령 더하기"). 3라운드 구조(사용자 결정 2026-10-23)의 근거는 두 가지다:
// 명령은 core의 타입 있는 어댑터만 부르고(import 허용 목록 + 전역 금지), core 안에서도 exec·문맥 조립·쓰기 문맥 내부·
// 시크릿 원문 해석은 정해진 파일만 쓴다. import는 문법 단위로 읽는다(Bun.Transpiler.scanImports, #873 3라운드 P2:
// 공백 없는 import와 .js 도우미가 정규식 검사를 빠져나갔다).
import { describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";
import type { CommandSpec } from "../../src/core/command";
import { REGISTRY } from "../../src/registry";
import { testRoot } from "../harness";

const SRC = join(import.meta.dir, "..", "..", "src");
const TEST = join(import.meta.dir, "..");

function walk(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(dir, e.name)) : [join(dir, e.name)]));
}

// 주석 줄을 빼고 본다(규칙을 설명하는 주석이 걸리지 않게).
export function code(text: string): string {
  return text
    .split("\n")
    .filter((l) => !l.trim().startsWith("//"))
    .join("\n");
}

const src = walk(SRC).filter((p) => p.endsWith(".ts"));
const rel = (p: string) => relative(SRC, p);
const body = (p: string) => code(readFileSync(p, "utf8"));

function offenders(re: RegExp, allowed: string[]): string[] {
  return src.filter((p) => !allowed.includes(rel(p)) && re.test(body(p))).map(rel);
}

const transpiler = new Bun.Transpiler({ loader: "ts" });

// 주석을 지우고 타입을 벗긴 코드. import /* 주석 */ (변수) 같은 꼴은 scanImports가 경로를 내지 않고 키워드 정규식도
// 주석 때문에 놓친다(codex 확인 라운드 P2). 변환 결과에는 주석이 없어 `import(`로 드러난다.
export function stripped(text: string): string {
  return transpiler.transformSync(text);
}

// 동적 import는 cli/src 어디에서도 쓰지 않는다(경로가 상수가 아니면 import 허용 목록을 볼 수 없다). 등록 표는 정적 import다.
export function hasDynamicImport(text: string): boolean {
  return /\bimport\s*\(/.test(stripped(text)) || /\bimport\s*\(/.test(code(text));
}

// 문법 단위로 읽은 import 경로(import·export from·동적 import()·require()). 공백 없는 꼴도 잡는다.
export function importsOf(text: string): string[] {
  return transpiler.scanImports(text).map((i) => i.path);
}

// node:fs를 import해도 되는 파일과 그 이름. 파일을 바꾸는 곳은 둘뿐이다: temp.ts(임시 폴더)와
// infisical-backup.ts(Infisical 로컬 백업 폴더 잠금·비우기, #873 P1). 나머지는 읽기만.
const FS_WRITERS = new Set(["core/temp.ts", "core/infisical-backup.ts"]);
const FS_IMPORTERS: Record<string, Set<string> | "any"> = {
  "core/temp.ts": "any",
  "core/infisical-backup.ts": "any",
  "core/version.ts": new Set(["readFileSync"]),
  "core/github.ts": new Set(["existsSync", "readFileSync", "realpathSync"]),
  "core/tools.ts": new Set(["realpathSync"]),
  "core/input.ts": new Set(["readFileSync", "readSync"]),
  "main.ts": new Set(["readSync"]),
};
// 어디서도 import하지 않는 모듈(프로세스·네트워크·Bun 내장 API. 실행은 exec.ts의 전역 Bun.spawnSync 하나로만).
const FORBIDDEN_MODULES = /^(bun(:.*)?|(node:)?(child_process|net|http|https|http2|dgram|tls|worker_threads|vm|cluster|fs\/promises))$/;
// 파일을 바꾸는 함수 호출. import 방식과 상관없이 호출 자체를 막는다(FS_WRITERS만 예외).
const FS_WRITE_CALL = /\b(writeFileSync|appendFileSync|writeFile|appendFile|rmSync|rmdirSync|unlinkSync|renameSync|copyFileSync|cpSync|mkdirSync|mkdtempSync|truncateSync|chmodSync|chownSync|symlinkSync|linkSync|utimesSync|openSync|createWriteStream)\s*\(|Bun\.(write|file)\b/;

export function fsProblems(file: string, text: string): string[] {
  const bad: string[] = [];
  const allowed = FS_IMPORTERS[file];
  for (const path of importsOf(text)) {
    if (FORBIDDEN_MODULES.test(path)) bad.push(`import ${path}`);
    else if (/^(node:)?fs$/.test(path) && !allowed) bad.push(`import ${path}`);
  }
  const t = code(text);
  if (allowed && allowed !== "any") {
    // 절에 따옴표·세미콜론이 없게 한다. 없으면 앞의 부작용 import(import "./x";)부터 한 덩어리로 읽는다.
    for (const m of t.matchAll(/import\s*(type\s+)?([^;"'`]*?)\s*from\s*["']((node:)?fs)["']/g)) {
      if (m[1]) continue;
      const clause = m[2].trim();
      if (!clause.startsWith("{")) bad.push(`${clause} from ${m[3]}`);
      else for (const name of clause.replace(/[{}]/g, "").split(",").map((x) => x.trim().split(/\s+as\s+/)[0]).filter(Boolean)) if (!allowed.has(name)) bad.push(name);
    }
  }
  if (!FS_WRITERS.has(file) && FS_WRITE_CALL.test(t)) bad.push(`파일 쓰기 호출 ${t.match(FS_WRITE_CALL)![0].trim()}`);
  return bad;
}

// 명령 파일이 import할 수 있는 것: core의 문맥·정의 모듈과 같은 접두의 자기 도우미(.ts, 확장자 없이)뿐.
const COMMAND_IMPORTS = new Set(["../core/command", "../core/names", "../core/result", "../core/pr", "../core/command-info", "../core/values"]);
// 명령 파일에서 쓰면 안 되는 전역(외부 명령·네트워크·파일·환경변수·출력의 우회로).
const COMMAND_GLOBALS = /\b(Bun|process|fetch|require|globalThis|eval|Deno|XMLHttpRequest|WebSocket|navigator|console|Function)\b|\bimport\s*\(/;
// 내장 전역을 바꾸는 꼴: 재할당·복합 대입·delete, 프로토타입 접근, defineProperty류, Object.assign(내장, …), global·self 경유.
// 실수로 core의 판정을 바꾸지 않게 하는 장치다. 일부러 우회하는 코드까지 막지는 않는다(설계 C.7 위협 모델, T12-01b).
// core는 시작할 때 잡아 둔 함수(core/intrinsics.ts)를 쓴다.
const BUILTINS = "JSON|Object|Array|String|Number|Boolean|Symbol|BigInt|Math|Date|RegExp|Promise|Reflect|Proxy|Map|Set|WeakMap|WeakSet|Error|TypeError|TextEncoder|TextDecoder|Buffer|crypto|Intl|URL|Atomics|structuredClone|setTimeout|setInterval|queueMicrotask";
const GLOBAL_WRITE = new RegExp(
  [
    `(?<![\\w$.])(${BUILTINS})\\s*(\\.\\s*[\\w$]+|\\[[^\\]]*\\])*\\s*(=(?![=>])|[-+*/%&|^]=|\\|\\|=|&&=|\\?\\?=|\\+\\+|--)`,
    `\\bdelete\\s+(${BUILTINS})\\b`,
    `\\.\\s*(prototype|constructor|__proto__)\\b`,
    `\\b(defineProperty|defineProperties|setPrototypeOf|getPrototypeOf|__defineGetter__|__defineSetter__)\\b`,
    `\\bObject\\s*\\.\\s*assign\\s*\\(\\s*(${BUILTINS})\\b`,
    `(?<![\\w$.])(global|self)\\s*[.[]`,
  ].join("|"),
);

// 명령 파일 이름 목록(등록 표). 도우미 파일의 주인은 이 중 가장 긴 접두다(db-add-values.ts → db-add).
const REGISTERED = [...readFileSync(join(SRC, "registry.ts"), "utf8").matchAll(/from "\.\/commands\/([a-z0-9-]+)"/g)].map((m) => m[1]);

export function commandProblems(file: string, text: string, names: string[] = REGISTERED, dir: string = join(SRC, "commands")): string[] {
  const stem = file.replace(/\.ts$/, "");
  const owner = names.filter((n) => stem === n || stem.startsWith(`${n}-`)).sort((a, b) => b.length - a.length)[0];
  const bad: string[] = [];
  for (const spec of importsOf(text)) {
    if (COMMAND_IMPORTS.has(spec)) continue;
    // 같은 명령의 .ts 파일(./db-add, ./db-add-values)만, 확장자 없이. .js 같은 검사 밖 파일은 받지 않는다.
    const own = owner !== undefined && /^\.\/[a-z0-9-]+$/.test(spec) && (spec === `./${owner}` || spec.startsWith(`./${owner}-`));
    if (own && existsSync(join(dir, `${spec.slice(2)}.ts`))) continue;
    bad.push(`import ${spec}`);
  }
  const plain = `${code(text)}\n${stripped(text)}`;
  const g = plain.match(COMMAND_GLOBALS);
  if (g) bad.push(`전역 ${g[0]}`);
  const w = plain.match(GLOBAL_WRITE);
  if (w) bad.push(`내장 전역 변경 ${w[0].trim()}`);
  return bad;
}

describe("소스 규칙", () => {
  test("대상 파일이 있다(0건 검사는 검사가 아니다)", () => {
    expect(src.length).toBeGreaterThan(10);
    expect(REGISTRY.length).toBeGreaterThan(10);
  });

  test("cli/src에는 .ts 파일만 둔다(검사 밖 .js 도우미 금지)", () => {
    expect(walk(SRC).filter((p) => !p.endsWith(".ts")).map(rel)).toEqual([]);
  });

  test("명령 파일은 core 문맥 모듈과 자기 도우미만 import하고, 외부 실행·파일·환경변수 전역을 쓰지 않는다", () => {
    const bad = src.filter((p) => rel(p).startsWith("commands/")).flatMap((p) => commandProblems(rel(p).slice("commands/".length), readFileSync(p, "utf8")).map((b) => `${rel(p)}: ${b}`));
    expect(bad).toEqual([]);
  });

  test("명령 규칙 검사가 우회 꼴을 잡는다", () => {
    expect(commandProblems("doctor.ts", 'import { write } from "bun";')).toEqual(["import bun"]);
    expect(commandProblems("doctor.ts", 'import { makeExec } from "../core/exec";')).toEqual(["import ../core/exec"]);
    expect(commandProblems("doctor.ts", 'import { revealSecret } from "../core/secret";')).toEqual(["import ../core/secret"]);
    expect(commandProblems("doctor.ts", 'import { readFileSync } from "node:fs";')).toEqual(["import node:fs"]);
    expect(commandProblems("doctor.ts", 'import{writeFileSync}from"node:fs";')).toEqual(["import node:fs"]);
    expect(commandProblems("doctor.ts", 'import { mark } from "./doctor-side-effect.js";')).toEqual(["import ./doctor-side-effect.js"]);
    expect(commandProblems("doctor.ts", 'import { mark } from "./doctor-missing";')).toEqual(["import ./doctor-missing"]);
    expect(commandProblems("doctor.ts", 'export * from "../core/exec";')).toEqual(["import ../core/exec"]);
    expect(commandProblems("db-add.ts", 'import { f } from "./app-add";')).toEqual(["import ./app-add"]);
    expect(commandProblems("db-add.ts", 'import { f } from "./db-add";')).toEqual([]);
    expect(commandProblems("doctor.ts", "const x = process.env.GITHUB_TOKEN;")).toEqual(["전역 process"]);
    expect(commandProblems("doctor.ts", "Bun.spawnSync(['x']);")).toEqual(["전역 Bun"]);
    expect(commandProblems("doctor.ts", "await fetch('https://x');")).toEqual(["전역 fetch"]);
    expect(commandProblems("doctor.ts", "const m = await import('../core/exec');")).toEqual(["import ../core/exec", "전역 import("]);
    expect(commandProblems("doctor.ts", 'import { defineCommand } from "../core/command";')).toEqual([]);
  });

  test("명령 규칙 검사가 내장 전역 변경을 잡고 보통 사용은 놓아준다(T12-01b)", () => {
    const caught = [
      "JSON.stringify = (x) => '';",
      "JSON . parse=f;",
      "String.prototype.includes = () => false;",
      "Array['isArray'] = f;",
      "Object.freeze ||= f;",
      "Math.random += 1;",
      "delete JSON.parse;",
      "Object.defineProperty(JSON, 'parse', { value: f });",
      "Reflect.setPrototypeOf(a, b);",
      "Object.assign(JSON, { parse: f });",
      "''.constructor.prototype.trim = f;",
      "x.__proto__.y = 1;",
      "self.JSON = {};",
      "global['Map'] = M;",
      "Map = class {};",
    ];
    for (const t of caught) expect([t, commandProblems("doctor.ts", t).some((b) => b.startsWith("내장 전역 변경"))]).toEqual([t, true]);
    const fine = [
      "const v = JSON.parse(o)?.clientVersion;",
      "const m = new Map<string, number>(); m.set('a', 1);",
      "if (Object.keys(x).length === 0) return;",
      "const ok = Array.isArray(x) && x.length >= 2;",
      "const t = (a: number) => a => 1;",
      "obj.Error = 1; obj.JSON = 2;",
      "const myself = 1; const globalName = 2;",
      "const n = Number(x); const s = String(y) === 'z';",
    ];
    for (const t of fine) expect([t, commandProblems("doctor.ts", t)]).toEqual([t, []]);
  });

  test("main.ts의 첫 import는 core/intrinsics다(명령 모듈보다 먼저 내장 함수를 잡는다)", () => {
    expect(importsOf(readFileSync(join(SRC, "main.ts"), "utf8"))[0]).toBe("./core/intrinsics");
  });

  test("core는 JSON·Object.freeze를 직접 부르지 않고 잡아 둔 함수를 쓴다", () => {
    expect(offenders(/\bJSON\s*\.\s*(parse|stringify)\b|\bObject\.freeze\b/, ["core/intrinsics.ts"]).filter((f) => f.startsWith("core/") || f === "main.ts")).toEqual([]);
  });

  test("cli/src 어디에도 동적 import가 없다(주석 낀 꼴·변수 경로 포함)", () => {
    expect(src.filter((p) => hasDynamicImport(readFileSync(p, "utf8"))).map(rel)).toEqual([]);
  });

  test("동적 import 검사가 주석 낀 꼴과 변수 경로를 잡는다(codex 확인 라운드 P2)", () => {
    const probe = "async function w(moduleName: string) {\n  const { writeFileSync: save } =\n    await import /* optional loader */ (moduleName);\n  save('/tmp/x', 'y');\n}";
    expect(hasDynamicImport(probe)).toBe(true);
    expect(commandProblems("doctor.ts", probe)).toContain("전역 import(");
    expect(hasDynamicImport("const m = await import(\n// c\n'node:fs');")).toBe(true);
    expect(hasDynamicImport('import { x } from "./y";\nconst important = 1;')).toBe(false);
  });

  test("프로세스·네트워크는 core/exec.ts에서만", () => {
    expect(offenders(/Bun\.spawn|Bun\.\$|child_process|\bfetch\(|new WebSocket|Bun\.connect|Bun\.listen|node:(net|http|https|dgram|tls)/, ["core/exec.ts"])).toEqual([]);
  });

  test("stdout·stderr는 core/output.ts에서만", () => {
    expect(offenders(/console\.|process\.stdout|process\.stderr/, ["core/output.ts"])).toEqual([]);
  });

  test("exec 생성·문맥 조립·비밀번호 생성·쓰기 문맥 내부는 정해진 core 파일만", () => {
    expect(offenders(/\b(makeExec|makePipe|makeForward)\b/, ["core/exec.ts", "core/runtime.ts"])).toEqual([]);
    expect(offenders(/\bmakeRuntime\b/, ["core/runtime.ts", "main.ts"])).toEqual([]);
    expect(offenders(/\bnewPassword\b/, ["core/secret.ts", "core/runtime.ts"])).toEqual([]);
    expect(offenders(/\b(writeExecOf|registerWriteExec)\b/, ["core/runtime-internal.ts", "core/runtime.ts", "core/pr.ts"])).toEqual([]);
  });

  test("시크릿 원문 해석(revealSecret)은 core 안에서만, 추적 초기화는 시험 전용", () => {
    expect(src.filter((p) => !rel(p).startsWith("core/") && /\brevealSecret\b/.test(body(p))).map(rel)).toEqual([]);
    expect(offenders(/\bresetTrackedForTests\b/, ["core/secret.ts"])).toEqual([]);
    expect(offenders(/\bresetBackupGuardForTests\b/, ["core/infisical-backup.ts"])).toEqual([]);
  });

  test("exitCode는 github 하위 명령만", () => {
    expect(src.filter((p) => rel(p).startsWith("commands/") && !rel(p).startsWith("commands/github") && /exitCode/.test(body(p))).map(rel)).toEqual([]);
  });

  test("fs는 정해진 파일만, 읽기 이름만. 금지 모듈은 어디서도 import하지 않고 파일 쓰기 호출은 temp.ts·infisical-backup.ts만", () => {
    const bad = src.flatMap((p) => fsProblems(rel(p), readFileSync(p, "utf8")).map((b) => `${rel(p)}: ${b}`));
    expect(bad).toEqual([]);
  });

  test("파일 쓰기 검사는 우회 꼴을 잡는다", () => {
    expect(fsProblems("commands/doctor.ts", 'import{writeFileSync}from"node:fs";writeFileSync("x","y");')).toEqual(["import node:fs", "파일 쓰기 호출 writeFileSync("]);
    expect(fsProblems("core/version.ts", 'import { readFileSync, writeFile } from "node:fs";')).toEqual(["writeFile"]);
    expect(fsProblems("core/version.ts", 'import{rmSync as r}from"fs";')).toEqual(["rmSync"]);
    expect(fsProblems("core/version.ts", 'import * as fs from "node:fs";')).toEqual(["* as fs from node:fs"]);
    expect(fsProblems("core/x.ts", 'import { readFile } from "node:fs/promises";')).toEqual(["import node:fs/promises"]);
    expect(fsProblems("core/x.ts", 'import { write } from "bun";')).toEqual(["import bun"]);
    expect(fsProblems("core/x.ts", "const fs = require('fs');")).toEqual(["import fs"]);
    expect(fsProblems("core/x.ts", 'await Bun.write("x", "y");')).toEqual(["파일 쓰기 호출 Bun.write"]);
    expect(fsProblems("core/version.ts", 'import { readFileSync } from "node:fs";')).toEqual([]);
    expect(fsProblems("main.ts", 'import "./core/intrinsics";\nimport { readSync } from "node:fs";')).toEqual([]);
    expect(fsProblems("main.ts", 'import "./core/intrinsics";\nimport { writeSync } from "node:fs";')).toEqual(["writeSync"]);
  });
});

// 등록 표의 파일 → 그 파일이 내보내는 명령. 이름이 아니라 실제 default export로 대조한다.
async function commandFiles(): Promise<{ file: string; cmd: CommandSpec }[]> {
  const out: { file: string; cmd: CommandSpec }[] = [];
  for (const f of REGISTERED) {
    const mod = await import(join(SRC, "commands", `${f}.ts`));
    out.push({ file: f, cmd: mod.default });
  }
  return out;
}

// 구현된 명령인데 시험 파일이 없거나 expectPlanReadOnly를 부르지 않는 파일 이름들.
export function missingPlanTests(entries: { file: string; cmd: Pick<CommandSpec, "placeholder"> }[], testDir: string): string[] {
  return entries
    .filter((e) => !e.cmd.placeholder)
    .filter((e) => {
      const t = join(testDir, `${e.file}.test.ts`);
      return !existsSync(t) || !readFileSync(t, "utf8").includes("expectPlanReadOnly(");
    })
    .map((e) => e.file);
}

describe("명령 파일", () => {
  test("등록 표의 파일마다 default export가 등록 표의 명령과 같은 객체다", async () => {
    const entries = await commandFiles();
    expect(entries.length).toBe(REGISTRY.length);
    for (const e of entries) expect([e.file, REGISTRY.includes(e.cmd)]).toEqual([e.file, true]);
  });

  test("도우미 파일은 등록된 명령 파일 이름을 접두로 가진다(소유 범위)", () => {
    for (const f of readdirSync(join(SRC, "commands")).filter((x) => x.endsWith(".ts"))) {
      const stem = f.replace(/\.ts$/, "");
      expect([f, REGISTERED.some((n) => stem === n || stem.startsWith(`${n}-`))]).toEqual([f, true]);
    }
  });

  test("구현된 명령마다 시험 파일이 있고 expectPlanReadOnly를 부른다(AC-2)", async () => {
    expect(missingPlanTests(await commandFiles(), join(TEST, "commands"))).toEqual([]);
  });

  // 시험 폴더는 fixture로 따로 만든다. 함정: 실제 commands 폴더로 보면 db-add 시험이 생기는 순간(#884) 이 자기 확인이 깨진다.
  test("검사가 두 단어 명령의 구현을 놓치지 않는다(자리표시를 지운 db-add로 확인)", async () => {
    const entries = await commandFiles();
    const dbAdd = entries.find((e) => e.cmd.path.join(" ") === "db add");
    expect(dbAdd).toBeDefined();
    const one = [{ file: dbAdd!.file, cmd: { ...dbAdd!.cmd, placeholder: undefined } }];
    const dir = mkdtempSync(join(testRoot(), "static-"));
    expect(missingPlanTests([{ file: dbAdd!.file, cmd: { placeholder: "T12-02" } }], dir)).toEqual([]);
    expect(missingPlanTests(one, dir)).toEqual(["db-add"]);
    writeFileSync(join(dir, "db-add.test.ts"), "test(\"plan\", () => {});\n");
    expect(missingPlanTests(one, dir)).toEqual(["db-add"]);
    writeFileSync(join(dir, "db-add.test.ts"), "expectPlanReadOnly(r);\n");
    expect(missingPlanTests(one, dir)).toEqual([]);
  });
});
