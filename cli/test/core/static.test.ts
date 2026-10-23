// 소스 규칙 정적 검사(cli/README.md "명령 더하기"). 3라운드 구조(사용자 결정 2026-10-23)의 근거는 두 가지다:
// 명령은 core의 타입 있는 어댑터만 부르고(import 허용 목록 + 전역 금지), core 안에서도 exec·문맥 조립·쓰기 문맥 내부는
// 정해진 파일만 쓴다. 어기면 고정 argv·쓰기 문맥 폐기·출력 차단이 보장하던 것이 깨진다.
import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join, relative } from "node:path";
import type { CommandSpec } from "../../src/core/command";
import { REGISTRY } from "../../src/registry";

const SRC = join(import.meta.dir, "..", "..", "src");
const TEST = join(import.meta.dir, "..");

function files(dir: string): string[] {
  const out: string[] = [];
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...files(p));
    else if (p.endsWith(".ts")) out.push(p);
  }
  return out;
}

// 주석 줄을 빼고 본다(규칙을 설명하는 주석이 걸리지 않게).
export function code(text: string): string {
  return text
    .split("\n")
    .filter((l) => !l.trim().startsWith("//"))
    .join("\n");
}

const src = files(SRC);
const rel = (p: string) => relative(SRC, p);
const body = (p: string) => code(readFileSync(p, "utf8"));

function offenders(re: RegExp, allowed: string[]): string[] {
  return src.filter((p) => !allowed.includes(rel(p)) && re.test(body(p))).map(rel);
}

// node:fs에서 가져와도 되는 이름. 읽기만 한다. 그 밖(쓰기·지우기·옮기기·만들기·promises)은 막는다.
const FS_READ = new Set(["readFileSync", "readSync", "existsSync", "readdirSync", "statSync", "lstatSync"]);

export function fsWriteImports(text: string): string[] {
  const bad: string[] = [];
  const t = code(text);
  for (const m of t.matchAll(/import\s+(type\s+)?([\s\S]*?)\s+from\s+["']((node:)?fs(\/promises)?)["']/g)) {
    if (m[1]) continue;
    if (m[5]) {
      bad.push(m[3]);
      continue;
    }
    const clause = m[2].trim();
    if (!clause.startsWith("{")) bad.push(`${clause} from ${m[3]}`);
    else for (const name of clause.replace(/[{}]/g, "").split(",").map((x) => x.trim().split(/\s+as\s+/)[0]).filter(Boolean)) if (!FS_READ.has(name)) bad.push(name);
  }
  // Bun 모듈의 named import(write, spawn, $, file, serve …)도 막는다(#873 2라운드 P2: import { write } from "bun").
  for (const m of t.matchAll(/from\s+["'](bun(:[a-z]+)?)["']/g)) bad.push(`import from ${m[1]}`);
  if (/\brequire\s*\(|\bimport\s*\(/.test(t)) bad.push("require()·동적 import()");
  if (/Bun\.(write|file)\b|createWriteStream/.test(t)) bad.push("Bun.write·Bun.file·createWriteStream");
  return bad;
}

// 명령 파일이 import할 수 있는 것: core의 문맥·정의 모듈과 같은 접두의 자기 도우미 파일뿐.
const COMMAND_IMPORTS = new Set(["../core/command", "../core/names", "../core/result", "../core/pr", "../core/command-info"]);
// 명령 파일에서 쓰면 안 되는 전역(외부 명령·네트워크·파일·환경변수·출력의 우회로).
const COMMAND_GLOBALS = /\b(Bun|process|fetch|require|globalThis|eval|Deno|XMLHttpRequest|WebSocket|navigator|console|Function)\b|\bimport\s*\(/;

// 명령 파일 이름 목록(등록 표). 도우미 파일의 주인은 이 중 가장 긴 접두다(db-add-values.ts → db-add).
const REGISTERED = [...readFileSync(join(SRC, "registry.ts"), "utf8").matchAll(/from "\.\/commands\/([a-z0-9-]+)"/g)].map((m) => m[1]);

export function commandProblems(file: string, text: string, names: string[] = REGISTERED): string[] {
  const stem = file.replace(/\.ts$/, "");
  const owner = names.filter((n) => stem === n || stem.startsWith(`${n}-`)).sort((a, b) => b.length - a.length)[0];
  const bad: string[] = [];
  const t = code(text);
  for (const m of t.matchAll(/(?:import|export)\s[\s\S]*?from\s+["']([^"']+)["']/g)) {
    const spec = m[1];
    if (COMMAND_IMPORTS.has(spec)) continue;
    // 같은 명령의 파일(./db-add, ./db-add-values)만. 다른 명령의 파일은 소유 범위 밖이다.
    if (owner && (spec === `./${owner}` || spec.startsWith(`./${owner}-`))) continue;
    bad.push(`import ${spec}`);
  }
  const g = t.match(COMMAND_GLOBALS);
  if (g) bad.push(`전역 ${g[0]}`);
  return bad;
}

describe("소스 규칙", () => {
  test("대상 파일이 있다(0건 검사는 검사가 아니다)", () => {
    expect(src.length).toBeGreaterThan(10);
    expect(REGISTRY.length).toBeGreaterThan(10);
  });

  test("명령 파일은 core 문맥 모듈과 자기 도우미만 import하고, 외부 실행·파일·환경변수 전역을 쓰지 않는다", () => {
    const bad = src.filter((p) => rel(p).startsWith("commands/")).flatMap((p) => commandProblems(rel(p).slice("commands/".length), readFileSync(p, "utf8")).map((b) => `${rel(p)}: ${b}`));
    expect(bad).toEqual([]);
  });

  test("명령 규칙 검사가 우회 꼴을 잡는다", () => {
    expect(commandProblems("doctor.ts", 'import { write } from "bun";')).toEqual(["import bun"]);
    expect(commandProblems("doctor.ts", 'import { makeExec } from "../core/exec";')).toEqual(["import ../core/exec"]);
    expect(commandProblems("doctor.ts", 'import { readFileSync } from "node:fs";')).toEqual(["import node:fs"]);
    expect(commandProblems("db-add.ts", 'import { f } from "./app-add-values";')).toEqual(["import ./app-add-values"]);
    expect(commandProblems("db-add.ts", 'import { f } from "./db-add-values";')).toEqual([]);
    expect(commandProblems("doctor.ts", "const x = process.env.GITHUB_TOKEN;")).toEqual(["전역 process"]);
    expect(commandProblems("doctor.ts", "Bun.spawnSync(['x']);")).toEqual(["전역 Bun"]);
    expect(commandProblems("doctor.ts", "await fetch('https://x');")).toEqual(["전역 fetch"]);
    expect(commandProblems("doctor.ts", "const m = await import('../core/exec');")).toEqual(["전역 import("]);
    expect(commandProblems("doctor.ts", 'import { defineCommand } from "../core/command";')).toEqual([]);
  });

  test("프로세스·네트워크는 core/exec.ts에서만", () => {
    expect(offenders(/Bun\.spawn|Bun\.\$|child_process|\bfetch\(|new WebSocket|Bun\.connect|Bun\.listen|node:(net|http|https|dgram|tls)/, ["core/exec.ts"])).toEqual([]);
  });

  test("stdout·stderr는 core/output.ts에서만", () => {
    expect(offenders(/console\.|process\.stdout|process\.stderr/, ["core/output.ts"])).toEqual([]);
  });

  test("exec 생성·문맥 조립·비밀번호 생성·쓰기 문맥 내부는 정해진 core 파일만", () => {
    expect(offenders(/\bmakeExec\b/, ["core/exec.ts", "core/runtime.ts"])).toEqual([]);
    expect(offenders(/\bmakeRuntime\b/, ["core/runtime.ts", "main.ts"])).toEqual([]);
    expect(offenders(/\bnewPassword\b/, ["core/secret.ts", "core/runtime.ts"])).toEqual([]);
    expect(offenders(/\b(writeExecOf|registerWriteExec)\b/, ["core/runtime-internal.ts", "core/runtime.ts", "core/pr.ts"])).toEqual([]);
  });

  test("exitCode는 github 하위 명령만", () => {
    expect(src.filter((p) => rel(p).startsWith("commands/") && !rel(p).startsWith("commands/github") && /exitCode/.test(body(p))).map(rel)).toEqual([]);
  });

  test("파일을 바꾸는 API는 core/temp.ts만, bun 모듈 import는 어디서도 안 된다", () => {
    const bad = src.filter((p) => rel(p) !== "core/temp.ts").flatMap((p) => fsWriteImports(readFileSync(p, "utf8")).map((b) => `${rel(p)}: ${b}`));
    expect(bad).toEqual([]);
  });

  test("파일 쓰기 검사는 우회 꼴을 잡는다", () => {
    expect(fsWriteImports('import { readFileSync, writeFile } from "node:fs";')).toEqual(["writeFile"]);
    expect(fsWriteImports('import { rmSync as r } from "fs";')).toEqual(["rmSync"]);
    expect(fsWriteImports('import * as fs from "node:fs";')).toEqual(["* as fs from node:fs"]);
    expect(fsWriteImports('import { readFile } from "node:fs/promises";')).toEqual(["node:fs/promises"]);
    expect(fsWriteImports('import { write } from "bun";')).toEqual(["import from bun"]);
    expect(fsWriteImports("const fs = require('fs');")).toEqual(["require()·동적 import()"]);
    expect(fsWriteImports('await Bun.write("x", "y");')).toEqual(["Bun.write·Bun.file·createWriteStream"]);
    expect(fsWriteImports('import { readFileSync, existsSync } from "node:fs";')).toEqual([]);
  });
});

// 등록 표의 파일 → 그 파일이 내보내는 명령. 이름이 아니라 실제 default export로 대조한다.
async function commandFiles(): Promise<{ file: string; cmd: CommandSpec }[]> {
  const reg = readFileSync(join(SRC, "registry.ts"), "utf8");
  const out: { file: string; cmd: CommandSpec }[] = [];
  for (const m of reg.matchAll(/from "\.\/commands\/([a-z0-9-]+)"/g)) {
    const mod = await import(join(SRC, "commands", `${m[1]}.ts`));
    out.push({ file: m[1], cmd: mod.default });
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

  test("도우미 파일은 등록된 명령 파일 이름을 접두로 가진다(소유 범위)", async () => {
    const names = (await commandFiles()).map((e) => e.file);
    for (const f of readdirSync(join(SRC, "commands")).filter((x) => x.endsWith(".ts"))) {
      const stem = f.replace(/\.ts$/, "");
      expect([f, names.some((n) => stem === n || stem.startsWith(`${n}-`))]).toEqual([f, true]);
    }
  });

  test("구현된 명령마다 시험 파일이 있고 expectPlanReadOnly를 부른다(AC-2)", async () => {
    expect(missingPlanTests(await commandFiles(), join(TEST, "commands"))).toEqual([]);
  });

  test("검사가 두 단어 명령의 구현을 놓치지 않는다(자리표시를 지운 db-add로 확인)", async () => {
    const entries = await commandFiles();
    const dbAdd = entries.find((e) => e.cmd.path.join(" ") === "db add");
    expect(dbAdd).toBeDefined();
    expect(missingPlanTests([{ file: dbAdd!.file, cmd: { ...dbAdd!.cmd, placeholder: undefined } }], join(TEST, "commands"))).toEqual(["db-add"]);
  });
});
