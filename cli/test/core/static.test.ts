// 소스 규칙 정적 검사(cli/README.md "명령 더하기"). 어기면 PATH 스텁과 출력 차단이 보장하던 것이 깨진다.
import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { basename, join, relative } from "node:path";
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

// 주석을 빼고 본다(규칙을 설명하는 주석이 걸리지 않게).
function code(path: string): string {
  return readFileSync(path, "utf8")
    .split("\n")
    .filter((l) => !l.trim().startsWith("//"))
    .join("\n");
}

const src = files(SRC);
const rel = (p: string) => relative(SRC, p);

function offenders(re: RegExp, allowed: string[]): string[] {
  return src.filter((p) => !allowed.includes(rel(p)) && re.test(code(p))).map(rel);
}

describe("소스 규칙", () => {
  test("대상 파일이 있다(0건 검사는 검사가 아니다)", () => {
    expect(src.length).toBeGreaterThan(10);
    expect(REGISTRY.length).toBeGreaterThan(10);
  });

  test("프로세스·네트워크는 core/exec.ts에서만(PATH 스텁이 모든 바깥 호출을 본다)", () => {
    expect(offenders(/Bun\.spawn|Bun\.\$|child_process|\bfetch\(|new WebSocket|Bun\.connect/, ["core/exec.ts"])).toEqual([]);
  });

  test("stdout·stderr는 core/output.ts에서만", () => {
    expect(offenders(/console\.|process\.stdout|process\.stderr/, ["core/output.ts"])).toEqual([]);
  });

  test("Secret.reveal()은 core 안에서만", () => {
    expect(src.filter((p) => rel(p).startsWith("commands/") && /\.reveal\(/.test(code(p))).map(rel)).toEqual([]);
  });

  test("exitCode는 github 하위 명령만", () => {
    expect(src.filter((p) => rel(p).startsWith("commands/") && !basename(p).startsWith("github") && /exitCode/.test(code(p))).map(rel)).toEqual([]);
  });

  test("파일 쓰기 없음(cli/src는 파일을 쓰지 않는다. 시크릿을 파일에 두지 않는다)", () => {
    expect(offenders(/writeFileSync|appendFileSync|Bun\.write|createWriteStream/, [])).toEqual([]);
  });
});

describe("명령 파일", () => {
  const commandFiles = readdirSync(join(SRC, "commands")).filter((f) => f.endsWith(".ts"));
  const registered = new Set(REGISTRY.map((c) => c.path.join(" ")));

  test("등록 표의 명령마다 같은 이름의 파일이 default로 그 명령을 내보낸다", async () => {
    const reg = readFileSync(join(SRC, "registry.ts"), "utf8");
    for (const m of reg.matchAll(/from "\.\/commands\/([a-z0-9-]+)"/g)) {
      const mod = await import(join(SRC, "commands", `${m[1]}.ts`));
      expect(registered.has(mod.default.path.join(" "))).toBe(true);
    }
    expect([...reg.matchAll(/from "\.\/commands\//g)].length).toBe(REGISTRY.length);
  });

  test("도우미 파일은 등록된 명령 파일 이름을 접두로 가진다(소유 범위)", () => {
    const reg = readFileSync(join(SRC, "registry.ts"), "utf8");
    const names = [...reg.matchAll(/from "\.\/commands\/([a-z0-9-]+)"/g)].map((m) => m[1]);
    for (const f of commandFiles) {
      const stem = f.replace(/\.ts$/, "");
      expect([f, names.some((n) => stem === n || stem.startsWith(`${n}-`))]).toEqual([f, true]);
    }
  });

  test("구현된 명령마다 시험 파일이 있고 expectPlanReadOnly를 부른다(AC-2)", () => {
    const reg = readFileSync(join(SRC, "registry.ts"), "utf8");
    for (const m of reg.matchAll(/import (\w+) from "\.\/commands\/([a-z0-9-]+)"/g)) {
      const cmd = REGISTRY.find((c) => readFileSync(join(SRC, "commands", `${m[2]}.ts`), "utf8").includes(JSON.stringify(c.path)));
      if (!cmd || cmd.placeholder) continue;
      const t = join(TEST, "commands", `${m[2]}.test.ts`);
      expect([m[2], existsSync(t)]).toEqual([m[2], true]);
      expect([m[2], readFileSync(t, "utf8").includes("expectPlanReadOnly(")]).toEqual([m[2], true]);
    }
  });
});
