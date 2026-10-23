// 배포 절차(AC-9): 단일 실행 파일, 버전·SHA 표시, 실행 폴더의 .env를 읽지 않음.
import { describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FAKE_PROJECT } from "../harness";

const ROOT = join(import.meta.dir, "..", "..", "..");

describe("bun build --compile", () => {
  test("버전에 git SHA, .env는 읽지 않는다", () => {
    const dir = mkdtempSync(join(tmpdir(), "homelab-cli-build-"));
    try {
      const out = join(dir, "homelab");
      const b = Bun.spawnSync([process.execPath, join(ROOT, "cli", "build.ts"), "--out", out], { cwd: ROOT, stdout: "pipe", stderr: "pipe" });
      expect(b.exitCode).toBe(0);
      const sha = Bun.spawnSync(["git", "rev-parse", "HEAD"], { cwd: ROOT, stdout: "pipe" }).stdout.toString().trim();
      const v = Bun.spawnSync([out, "--version"], { cwd: dir, stdout: "pipe" }).stdout.toString();
      expect(v).toStartWith(`homelab 0.1.0 (${sha.slice(0, 12)}`);
      // .env에 프로젝트 ID를 두고 돌린다. 읽었다면 doctor의 infisical-project가 same이 된다.
      writeFileSync(join(dir, ".env"), `HOMELAB_INFISICAL_PROJECT_ID=${FAKE_PROJECT}\n`);
      const d = Bun.spawnSync([out, "doctor", "--json"], { cwd: dir, env: { PATH: join(dir, "nothing"), HOME: dir }, stdout: "pipe", stderr: "pipe" });
      const doc = JSON.parse(d.stdout.toString());
      expect(doc.steps.find((s: { id: string }) => s.id === "infisical-project").state).toBe("missing");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
