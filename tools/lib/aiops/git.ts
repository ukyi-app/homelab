import { isolatedSpawnSync as spawnSync } from "../exec.ts";
import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { requireCondition } from "./input.ts";

export const digest = (value: string | Buffer) => createHash("sha256").update(value).digest("hex");
export type TreeEntry = { path: string; mode: string; blob: string };
// 설치 계정이 소유한 사본을 역할 UID가 읽는다. 전역 '*' 대신 요청된 고정 경로만 허용한다.
const gitConfig = (repository: string) => ["-c", `safe.directory=${repository}`, "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"];
export class GitSnapshot {
  readonly repository: string;
  readonly revision: string;
  readonly entries: TreeEntry[];
  readonly manifestHash: string;
  private deadline = Date.now() + 120_000;
  constructor(repository: string, revision: string) {
    requireCondition(/^[a-f0-9]{40}$/.test(revision), "invalid-fixed-revision");
    this.repository = resolve(repository); this.revision = revision;
    requireCondition(this.git(["rev-parse", `${revision}^{commit}`]).trim() === revision, "revision-not-a-commit");
    this.entries = this.git(["ls-tree", "-r", "-z", revision]).split("\0").filter(Boolean).map(row => {
      const match = /^(\d+) (?:blob|commit) ([a-f0-9]{40})\t(.+)$/s.exec(row);
      requireCondition(match, "invalid-git-tree");
      return { mode: match[1], blob: match[2], path: match[3] };
    });
    this.manifestHash = digest(JSON.stringify(this.entries));
  }
  git(args: string[], maxBuffer = 8 * 1024 * 1024): string {
    const remaining = this.deadline - Date.now();
    requireCondition(remaining > 0, "git-deadline");
    const result = spawnSync("git", [...gitConfig(this.repository), "-C", this.repository, ...args], {
      encoding: "utf8", timeout: Math.min(10_000, remaining), maxBuffer,
      env: { PATH: process.env.PATH, LANG: "C", GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null", GIT_TERMINAL_PROMPT: "0" },
    });
    requireCondition(result.status === 0 && !result.error, "git-read-failed");
    return result.stdout;
  }
  text(path: string, limit = 256 * 1024): string | null {
    return this.blob(path, limit)?.toString("utf8") ?? null;
  }
  blob(path: string, limit = 256 * 1024): Buffer | null {
    const entry = this.entries.find(e => e.path === path);
    if (!entry) return null;
    requireCondition(["100644", "100755"].includes(entry.mode), "nonregular-git-evidence");
    const size = Number(this.git(["cat-file", "-s", entry.blob]));
    requireCondition(Number.isSafeInteger(size) && size <= limit, "git-blob-too-large");
    const result = spawnSync("git", [...gitConfig(this.repository), "-C", this.repository, "cat-file", "blob", entry.blob], { timeout: Math.min(10_000, Math.max(1, this.deadline - Date.now())), maxBuffer: limit + 1,
      env: { PATH: process.env.PATH, LANG: "C", GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null", GIT_TERMINAL_PROMPT: "0" } });
    requireCondition(result.status === 0 && !result.error, "git-blob-read-failed");
    return result.stdout;
  }
  export(directory: string) {
    let total = 0;
    for (const entry of this.entries) {
      requireCondition(!entry.path.startsWith("/") && !entry.path.includes("\\") && entry.path.split("/").every(p => p && p !== "." && p !== ".." && p.toLowerCase() !== ".git"), "unsafe-tree-path");
      requireCondition(["100644", "100755"].includes(entry.mode), "unsupported-tree-mode");
      const text = this.blob(entry.path, 2 * 1024 * 1024)!;
      total += text.length;
      requireCondition(total <= 64 * 1024 * 1024, "repository-export-too-large");
      const path = join(directory, entry.path);
      mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
      writeFileSync(path, text, { mode: entry.mode === "100755" ? 0o700 : 0o600 });
    }
  }
}

export function applyCandidate(baseline: GitSnapshot, patch: string): { snapshot: GitSnapshot; dispose: () => void } {
  requireCondition(Buffer.byteLength(patch) <= 1024 * 1024 && patch.startsWith("diff --git "), "invalid-patch");
  const directory = mkdtempSync(join(tmpdir(), "aiops-candidate-"));
  const repository = join(directory, "repo"); mkdirSync(repository);
  const dispose = () => rmSync(directory, { recursive: true, force: true });
  const git = (args: string[]) => {
    const result = spawnSync("git", [...gitConfig(repository), "-c", `safe.directory=${baseline.repository}`, "-C", repository, ...args], {
      encoding: "utf8", maxBuffer: 8 * 1024 * 1024, timeout: 10_000,
      env: { PATH: process.env.PATH, LANG: "C", GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null", GIT_TERMINAL_PROMPT: "0",
        GIT_AUTHOR_NAME: "AIOps", GIT_AUTHOR_EMAIL: "aiops@localhost", GIT_COMMITTER_NAME: "AIOps", GIT_COMMITTER_EMAIL: "aiops@localhost",
        GIT_AUTHOR_DATE: "2000-01-01T00:00:00Z", GIT_COMMITTER_DATE: "2000-01-01T00:00:00Z" },
    });
    requireCondition(result.status === 0 && !result.error, "patch-application-failed");
    return result.stdout.trim();
  };
  try {
    git(["init", "--template=", "--quiet"]);
    git(["-c", "protocol.file.allow=always", "fetch", "--no-tags", "--", baseline.repository, baseline.revision]);
    git(["checkout", "--detach", "--quiet", baseline.revision]);
    const patchPath = join(directory, "change.patch"); writeFileSync(patchPath, patch, { mode: 0o400 });
    git(["apply", "--index", "--whitespace=nowarn", "--", patchPath]);
    git(["-c", "commit.gpgsign=false", "commit", "--quiet", "--no-verify", "-m", "운영 수정 초안"]);
    const candidate = new GitSnapshot(repository, git(["rev-parse", "HEAD"]));
    requireCondition(candidate.entries.every(e => ["100644", "100755"].includes(e.mode)), "candidate-symlink-or-submodule-unverified");
    return { snapshot: candidate, dispose };
  } catch (error) { dispose(); throw error; }
}
