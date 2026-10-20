// ci 검사 공통 도구. 외부 패키지 없이 Bun 내장 기능만 쓴다(의존성 설치가 필수 검사를 막지 않게).
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export const REPO_URL = "https://github.com/ukyi-app/homelab";
export const ROOT = join(import.meta.dir, "..", "..");

// 렌더된 매니페스트 하나와 그 출처. 출처는 실패 메시지와 출처별 예외(policy.ts)에 쓴다.
// ns: 렌더한 Application의 유효 destination namespace. metadata.namespace가 없는 namespaced 리소스는 Argo CD가 여기에 적용한다.
export type Doc = { origin: string; obj: Record<string, any>; ns?: string };

// Argo CD는 spec.sources가 비어 있지 않을 때만 그것을 쓰고, 비었거나 없으면 단수 spec.source로 돌아간다.
export function effectiveSources(spec: any): any[] {
  if (Array.isArray(spec?.sources) && spec.sources.length > 0) return spec.sources;
  return spec?.source ? [spec.source] : [];
}

export type Violation = { rule: string; where: string; message: string };

export function fmt(v: Violation): string {
  return `[${v.rule}] ${v.where}: ${v.message}`;
}

export type RunResult = { code: number; stdout: string; stderr: string };

// argv 배열로만 실행한다(셸을 거치지 않는다). 실패 출력은 호출한 쪽이 판단한다.
export function run(cmd: string[], opts: { cwd?: string; env?: Record<string, string | undefined>; input?: string } = {}): RunResult {
  const p = Bun.spawnSync(cmd, {
    cwd: opts.cwd ?? ROOT,
    env: opts.env ?? process.env,
    stdin: opts.input === undefined ? "ignore" : new TextEncoder().encode(opts.input),
    stdout: "pipe",
    stderr: "pipe",
  });
  return { code: p.exitCode ?? 1, stdout: p.stdout.toString(), stderr: p.stderr.toString() };
}

export function mustRun(cmd: string[], opts: Parameters<typeof run>[1] = {}): string {
  const r = run(cmd, opts);
  if (r.code !== 0) {
    throw new Error(`${cmd.join(" ")} 실패(exit ${r.code})\n${r.stderr || r.stdout}`);
  }
  return r.stdout;
}

// 여러 문서 YAML을 객체 배열로. 빈 문서(null)는 뺀다. 별칭(&·*)과 병합 키(<<)는 파서가 푼다.
export function parseAll(text: string): any[] {
  const parsed = Bun.YAML.parse(text);
  const docs = Array.isArray(parsed) && /^---/m.test(text) ? parsed : [parsed];
  return docs.filter((d) => d !== null && d !== undefined);
}

export function readText(path: string): string {
  return readFileSync(join(ROOT, path), "utf8");
}

// 추적 파일만 본다. 작업 사본의 미추적 파일이 결과를 바꾸지 않게 한다.
// Argo CD는 source 경로의 .argocd-source.yaml·.argocd-source-<앱>.yaml을 source 매개변수(kustomize.images,
// helm.parameters 등) 위에 합친다. ci는 그 합치기를 재현하지 않으므로 파일 자체를 막는다(작업 트리는 main.ts tracked files, 태그 트리는 render.ts).
export const ARGOCD_SOURCE_OVERRIDE = /^\.argocd-source(-.+)?\.ya?ml$/;

export function gitFiles(...pathspecs: string[]): string[] {
  const out = mustRun(["git", "ls-files", "-z", "--", ...pathspecs]);
  return out.split("\0").filter(Boolean).sort();
}

export function tempDir(prefix: string): string {
  return mkdtempSync(join(tmpdir(), `homelab-ci-${prefix}-`));
}

export function toolVersion(name: string): string {
  for (const line of readText(".tool-versions").split("\n")) {
    const [tool, version] = line.trim().split(/\s+/);
    if (tool === name && version) return version;
  }
  throw new Error(`.tool-versions에 ${name} 버전이 없다`);
}

// GitHub Actions에서는 접힌 그룹으로, 로컬에서는 제목 줄로 보인다.
const inActions = process.env.GITHUB_ACTIONS === "true";
export function group(title: string): void {
  console.log(inActions ? `::group::${title}` : `\n== ${title}`);
}
export function endGroup(): void {
  if (inActions) console.log("::endgroup::");
}
export function errorLine(message: string): void {
  console.log(inActions ? `::error::${message.replaceAll("\n", "%0A")}` : `ERROR ${message}`);
}

export function sameRepo(url: unknown): boolean {
  if (typeof url !== "string") return false;
  const norm = url
    .trim()
    .toLowerCase()
    .replace(/^git@github\.com:/, "https://github.com/")
    .replace(/^http:\/\//, "https://")
    // 끝 슬래시를 먼저 떼야 homelab.git/도 같은 저장소로 본다.
    .replace(/\/+$/, "")
    .replace(/\.git$/, "");
  return norm === REPO_URL;
}
