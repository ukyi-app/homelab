// 배포 절차(AC-9): 단일 실행 파일, 버전·SHA 표시, 실행 폴더의 .env를 읽지 않음.
import { describe, expect, test } from "bun:test";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
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
      // .env에 프로젝트 ID를 두고 돌린다. 읽었다면 doctor의 infisical-project가 "있음(UUID)"이 된다.
      writeFileSync(join(dir, ".env"), `HOMELAB_INFISICAL_PROJECT_ID=${FAKE_PROJECT}\n`);
      const d = Bun.spawnSync([out, "doctor", "--json"], { cwd: dir, env: { PATH: join(dir, "nothing"), HOME: dir }, stdout: "pipe", stderr: "pipe" });
      const doc = JSON.parse(d.stdout.toString());
      expect(doc.steps.find((s: { id: string }) => s.id === "infisical-project").detail).toStartWith("없음");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  // 새 체크아웃(node_modules 없음)이나 lockfile만 올린 뒤의 옛 node_modules. 빌드 전에 멈추고 다음 행동을 보인다.
  // build.ts는 자기 위치로 저장소 루트를 정하므로, build.ts와 그것이 import하는 version.ts만 둔 가짜 루트에서 돌린다.
  test("npm 패키지가 없거나 버전이 다르면 빌드하지 않고 bun install을 안내한다", () => {
    const dir = mkdtempSync(join(tmpdir(), "homelab-cli-build-deps-"));
    try {
      mkdirSync(join(dir, "cli", "src", "core"), { recursive: true });
      copyFileSync(join(ROOT, "cli", "build.ts"), join(dir, "cli", "build.ts"));
      copyFileSync(join(ROOT, "cli", "src", "core", "version.ts"), join(dir, "cli", "src", "core", "version.ts"));
      writeFileSync(join(dir, "package.json"), JSON.stringify({ dependencies: { "fake-dep": "1.2.3" } }));
      const check = (...args: string[]) => {
        const p = Bun.spawnSync([process.execPath, join(dir, "cli", "build.ts"), ...args], { cwd: dir, stdout: "pipe", stderr: "pipe" });
        return { code: p.exitCode, err: p.stderr.toString() };
      };
      const missing = check();
      expect(missing.code).toBe(1);
      expect(missing.err).toContain("fake-dep 1.2.3(없음)");
      expect(missing.err).toContain("bun install --frozen-lockfile --ignore-scripts");
      expect(existsSync(join(dir, "cli", "dist"))).toBe(false);
      mkdirSync(join(dir, "node_modules", "fake-dep"), { recursive: true });
      writeFileSync(join(dir, "node_modules", "fake-dep", "package.json"), JSON.stringify({ version: "1.2.2" }));
      const stale = check("--check-deps");
      expect(stale.code).toBe(1);
      expect(stale.err).toContain("fake-dep 1.2.3(있는 것 1.2.2)");
      writeFileSync(join(dir, "node_modules", "fake-dep", "package.json"), JSON.stringify({ version: "1.2.3" }));
      expect(check("--check-deps")).toEqual({ code: 0, err: "" });
      expect(check("--check-deps", "--install").code).toBe(64);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("이 저장소의 실행 의존성은 package.json과 같다(--check-deps)", () => {
    const p = Bun.spawnSync([process.execPath, join(ROOT, "cli", "build.ts"), "--check-deps"], { cwd: ROOT, stdout: "pipe", stderr: "pipe" });
    expect(p.stderr.toString()).toBe("");
    expect(p.exitCode).toBe(0);
  });
});
