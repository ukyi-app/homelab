// 소스 규칙 정적 검사(cli/README.md "명령 더하기"). 어기면 PATH 스텁·쓰기 창·출력 차단이 보장하던 것이 깨진다.
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

// node:fs에서 가져와도 되는 이름. 읽기만 한다. 그 밖(writeFile*, append*, rm*, rename*, copy*, cp*, mkdir*, mkdtemp*,
// unlink*, truncate*, chmod*, chown*, symlink*, link*, utimes*, open*, createWriteStream, promises)은 막는다.
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
    const clause = m[2];
    // 기본·이름공간 import(import fs from, import * as fs from)는 무엇이든 부를 수 있다.
    if (!clause.trim().startsWith("{")) bad.push(`${clause.trim()} from ${m[3]}`);
    for (const name of clause.replace(/[{}]/g, "").split(",").map((x) => x.trim().split(/\s+as\s+/)[0]).filter(Boolean)) {
      if (clause.trim().startsWith("{") && !FS_READ.has(name)) bad.push(name);
    }
  }
  if (/\brequire\s*\(|\bimport\s*\(/.test(t)) bad.push("require()·동적 import()");
  if (/Bun\.(write|file)\b|createWriteStream/.test(t)) bad.push("Bun.write·Bun.file·createWriteStream");
  return bad;
}

describe("소스 규칙", () => {
  test("대상 파일이 있다(0건 검사는 검사가 아니다)", () => {
    expect(src.length).toBeGreaterThan(10);
    expect(REGISTRY.length).toBeGreaterThan(10);
  });

  test("프로세스·네트워크는 core/exec.ts에서만(PATH 스텁이 모든 바깥 호출을 본다)", () => {
    expect(offenders(/Bun\.spawn|Bun\.\$|child_process|\bfetch\(|new WebSocket|Bun\.connect|Bun\.listen|node:(net|http|https|dgram|tls)/, ["core/exec.ts"])).toEqual([]);
  });

  test("stdout·stderr는 core/output.ts에서만", () => {
    expect(offenders(/console\.|process\.stdout|process\.stderr/, ["core/output.ts"])).toEqual([]);
  });

  test("쓰기 창·exec 생성·비밀번호 허용은 엔진과 진입점만(02~04가 우회할 수 없게)", () => {
    expect(offenders(/\brunWithWrites\b/, ["core/exec.ts", "core/engine.ts", "main.ts"])).toEqual([]);
    expect(offenders(/\bmakeExec\b/, ["core/exec.ts", "main.ts"])).toEqual([]);
    expect(offenders(/\ballowGeneration\b/, ["core/secret.ts", "core/engine.ts"])).toEqual([]);
  });

  test("Secret.reveal()은 core 안에서만", () => {
    expect(src.filter((p) => !rel(p).startsWith("core/") && /\.reveal\(/.test(body(p))).map(rel)).toEqual([]);
  });

  test("exitCode는 github 하위 명령만", () => {
    expect(src.filter((p) => rel(p).startsWith("commands/") && !rel(p).startsWith("commands/github") && /exitCode/.test(body(p))).map(rel)).toEqual([]);
  });

  test("파일을 바꾸는 API는 core/temp.ts만(시크릿을 파일에 두지 않는다, Connector 리뷰)", () => {
    const bad = src.filter((p) => rel(p) !== "core/temp.ts").flatMap((p) => fsWriteImports(readFileSync(p, "utf8")).map((b) => `${rel(p)}: ${b}`));
    expect(bad).toEqual([]);
  });

  test("파일 쓰기 검사는 우회 꼴을 잡는다", () => {
    expect(fsWriteImports('import { readFileSync, writeFile } from "node:fs";')).toEqual(["writeFile"]);
    expect(fsWriteImports('import { rmSync as r } from "fs";')).toEqual(["rmSync"]);
    expect(fsWriteImports('import * as fs from "node:fs";')).toEqual(["* as fs from node:fs"]);
    expect(fsWriteImports('import { readFile } from "node:fs/promises";')).toEqual(["node:fs/promises"]);
    expect(fsWriteImports("const fs = require('fs');")).toEqual(["require()·동적 import()"]);
    expect(fsWriteImports('await Bun.write("x", "y");')).toEqual(["Bun.write·Bun.file·createWriteStream"]);
    expect(fsWriteImports('import { readFileSync, existsSync } from "node:fs";')).toEqual([]);
  });
});

// 등록 표의 파일 → 그 파일이 내보내는 명령. 이름이 아니라 실제 default export로 대조한다
// (#873 1라운드 P2: 소스 문자열 대조가 두 단어 명령 17개를 모두 놓쳤다).
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
    const implemented = [{ file: dbAdd!.file, cmd: { ...dbAdd!.cmd, placeholder: undefined } }];
    expect(missingPlanTests(implemented, join(TEST, "commands"))).toEqual(["db-add"]);
  });
});
