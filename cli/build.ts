// homelab CLI 단일 실행 파일 빌드·설치(설계 C.7, AC-9). 사용법은 cli/README.md.
//   bun cli/build.ts                       cli/dist/homelab
//   bun cli/build.ts --out <경로>           다른 곳에(시험용)
//   bun cli/build.ts --install             ~/.local/bin/homelab, 이전 파일은 homelab.prev
//   bun cli/build.ts --install --allow-dirty
//   bun cli/build.ts --check-deps          npm 패키지 확인만(bun run cli가 실행 전에 부른다)
// 함정(B.8 E7): bun link는 절대 경로 고정이라 worktree를 지우면 전역 명령이 끊긴다. 그래서 실행 파일을 복사한다.
// 함정(bun 1.4.3 실측): --compile 실행 파일은 기본으로 실행한 폴더의 .env·bunfig.toml을 읽는다.
// 아무 폴더에서 돌린 homelab에 남의 환경변수가 섞이므로 둘 다 끈다.
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, renameSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { parseToolVersions } from "./src/core/version";

const ROOT = join(import.meta.dir, "..");

function run(cmd: string[]): string {
  const p = Bun.spawnSync(cmd, { cwd: ROOT, stdout: "pipe", stderr: "pipe" });
  if (p.exitCode !== 0) throw new Error(`${cmd.join(" ")} 실패(exit ${p.exitCode})\n${p.stderr.toString()}`);
  return p.stdout.toString();
}

type Opts = { install: boolean; allowDirty: boolean; checkDeps: boolean; out?: string };

function parseArgs(argv: string[]): Opts {
  const seen = new Set<string>();
  const opts: Opts = { install: false, allowDirty: false, checkDeps: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (seen.has(a)) throw new Error(`${a}를 두 번 줬다`);
    seen.add(a);
    if (a === "--install") opts.install = true;
    else if (a === "--allow-dirty") opts.allowDirty = true;
    else if (a === "--check-deps") opts.checkDeps = true;
    else if (a === "--out" && argv[i + 1] && !argv[i + 1].startsWith("--")) opts.out = argv[++i];
    else throw new Error(`모르는 인자: ${a}`);
  }
  if (opts.install && opts.out) throw new Error("--install과 --out은 함께 쓰지 않는다");
  if (opts.checkDeps && (opts.install || opts.out || opts.allowDirty)) throw new Error("--check-deps는 혼자 쓴다");
  return opts;
}

// 실행 의존성(package.json dependencies, 정확한 버전)이 node_modules에 그 버전으로 있는지. 없으면 다음 행동 문구.
// 빌드가 스스로 받지 않는다: 빌드는 네트워크 없이 돌아야 하고, 패키지 받기는 ci의 npm deps 단계와 같은
// --frozen-lockfile --ignore-scripts 명령으로 사람이 따로 한다(공급망). 버전도 본다. lockfile만 올린 뒤 옛 node_modules로
// 빌드하면 오류 없이 옛 버전이 실행 파일에 묶인다. 전이 의존성은 보지 않는다(bun install이 bun.lock대로 맞춘다).
function depsProblem(): string | undefined {
  const want: Record<string, string> = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8")).dependencies ?? {};
  const bad: string[] = [];
  for (const [name, version] of Object.entries(want)) {
    const pkg = join(ROOT, "node_modules", name, "package.json");
    const have = existsSync(pkg) ? (JSON.parse(readFileSync(pkg, "utf8")).version as string) : undefined;
    if (have !== version) bad.push(`${name} ${version}(${have ? `있는 것 ${have}` : "없음"})`);
  }
  if (bad.length === 0) return undefined;
  return `npm 패키지가 package.json과 다르다: ${bad.join(", ")}\n다음: 저장소 루트에서 bun install --frozen-lockfile --ignore-scripts`;
}

function main(): number {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (e) {
    console.error(`사용법 오류: ${(e as Error).message}`);
    return 64;
  }
  const deps = depsProblem();
  if (deps) {
    console.error(deps);
    return 1;
  }
  if (opts.checkDeps) return 0;
  const sha = run(["git", "rev-parse", "HEAD"]).trim();
  const dirty = run(["git", "status", "--porcelain"]).trim() !== "";
  if (opts.install && dirty && !opts.allowDirty) {
    console.error("작업 트리에 커밋 안 된 변경이 있다. 검토한 main에서 빌드한다(--allow-dirty로만 넘어간다)");
    return 1;
  }
  const all = parseToolVersions(readFileSync(join(ROOT, ".tool-versions"), "utf8"));
  // doctor가 비교하는 도구만 박는다.
  const tools = Object.fromEntries(["kubectl", "infisical", "terraform"].map((t) => [t, all[t]]));
  for (const [t, v] of Object.entries(tools)) if (!v) throw new Error(`.tool-versions에 ${t}가 없다`);

  const out = opts.out ?? join(ROOT, "cli", "dist", "homelab");
  mkdirSync(dirname(out), { recursive: true });
  run([
    process.execPath,
    "build",
    "--compile",
    "--no-compile-autoload-dotenv",
    "--no-compile-autoload-bunfig",
    "--define",
    `HOMELAB_BUILD=${JSON.stringify({ sha, dirty, tools })}`,
    join(ROOT, "cli", "src", "main.ts"),
    "--outfile",
    out,
  ]);
  console.log(`빌드: ${out} (${sha.slice(0, 12)}${dirty ? "-dirty" : ""})`);

  if (opts.install) {
    const dest = join(homedir(), ".local", "bin", "homelab");
    mkdirSync(dirname(dest), { recursive: true });
    // 되돌리기는 이전 파일 하나: mv ~/.local/bin/homelab.prev ~/.local/bin/homelab
    if (existsSync(dest)) renameSync(dest, `${dest}.prev`);
    copyFileSync(out, dest);
    chmodSync(dest, 0o755);
    console.log(`설치: ${dest}${existsSync(`${dest}.prev`) ? ` (이전 파일 ${dest}.prev)` : ""}`);
    console.log(run([dest, "--version"]).trim());
  }
  return 0;
}

process.exit(main());
