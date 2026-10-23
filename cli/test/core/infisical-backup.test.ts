// Infisical 로컬 백업 막기(#873 Connector P1). 스텁이 CLI 0.44.2처럼 $HOME/.infisical/secrets-backup/에 파일을 쓰려 한다.
// 잠긴 폴더면 쓰기가 실패하고(CLI는 그 오류를 무시한다) 조회는 그대로 된다. 권한이 듣지 않아 파일이 생기면 명령이 실패한다.
import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, readdirSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { guardInfisicalBackup } from "../../src/core/infisical-backup";
import { CliError } from "../../src/core/result";
import { Secret } from "../../src/core/secret";
import { FAKE_PROJECT, FAKE_SECRETS, applyWith, expectNoSecrets, infisicalList, infisicalSet, rule, testCtx } from "../harness";
import { argvFor } from "../../src/core/infisical";

const BACKUP = ".infisical/secrets-backup";
const FILE = `${BACKUP}/project_secrets_${FAKE_PROJECT}_prod_-apps-smoke.json`;
const mode = (p: string) => statSync(p).mode & 0o777;

describe("Infisical 로컬 백업 막기", () => {
  test("조회 전에 백업 폴더를 0500으로 잠근다. CLI의 백업 쓰기는 실패하고 조회는 된다", () => {
    const { ctx, calls, home } = testCtx("plan", [rule(argvFor.list(FAKE_PROJECT, "/apps/smoke"), { stdout: JSON.stringify([{ secretKey: "A", secretValue: FAKE_SECRETS[0] }]), homeWrite: { path: FILE } })]);
    expect(ctx.infisical.has("/apps/smoke", "A")).toBe(true);
    const c = calls();
    expect(c.calls.map((x) => x.homeWrite)).toEqual(["denied"]);
    expect(readdirSync(join(home, BACKUP))).toEqual([]);
    expect(mode(join(home, BACKUP))).toBe(0o500);
  });

  test("plan 단계의 조회 뒤 백업 파일이 생기면 명령이 실패하고 파일을 지운다", async () => {
    const { ctx, home } = testCtx("plan", [rule(argvFor.list(FAKE_PROJECT, "/apps/smoke"), { stdout: "[]", homeWrite: { path: FILE, force: true } })]);
    const r = await ctx.engine({
      command: "test",
      steps: [{ id: "read", target: "Infisical", read: async () => (ctx.infisical.has("/apps/smoke", "A") ? { state: "same", action: "none", detail: "" } : { state: "missing", action: "create", detail: "" }) }],
    });
    expect(r.status).toBe("failed");
    expect(JSON.stringify(r)).toContain("백업 파일이 생겼다");
    expect(readdirSync(join(home, BACKUP))).toEqual([]);
    expect(mode(join(home, BACKUP))).toBe(0o500);
  });

  test("getValue·valueHash도 같은 길을 지난다(값을 돌려주지 않고 실패)", () => {
    const { ctx } = testCtx("plan", [rule(argvFor.list(FAKE_PROJECT, "/apps/smoke"), { stdout: JSON.stringify([{ secretKey: "A", secretValue: FAKE_SECRETS[0] }]), homeWrite: { path: FILE, force: true } })]);
    expect(() => ctx.infisical.getValue("/apps/smoke", "A")).toThrow(CliError);
    expect(() => ctx.infisical.valueHash("/apps/smoke", "A")).toThrow("백업 파일이 생겼다");
  });

  test("apply의 쓰기 호출도 백업 파일이 생기면 실패한다", async () => {
    const { ctx, calls, home } = testCtx("apply", [infisicalSet("/apps/smoke", { homeWrite: { path: FILE, force: true } })]);
    await expect(applyWith(ctx, (w) => w.infisical.setValue("/apps/smoke", "TOKEN", new Secret(FAKE_SECRETS[1])))).rejects.toThrow("백업 파일이 생겼다");
    expect(calls().calls.map((x) => x.homeWrite)).toEqual(["written"]);
    expect(readdirSync(join(home, BACKUP))).toEqual([]);
    expectNoSecrets(calls());
  });

  test("이전 실행이 남긴 백업 파일은 첫 조회 전에 지운다", () => {
    const { ctx, home } = testCtx("plan", [infisicalList("/apps/smoke", { A: FAKE_SECRETS[0] })]);
    mkdirSync(join(home, BACKUP), { recursive: true });
    writeFileSync(join(home, FILE), "old");
    expect(ctx.infisical.listKeys("/apps/smoke")).toEqual(["A"]);
    expect(readdirSync(join(home, BACKUP))).toEqual([]);
    expect(mode(join(home, BACKUP))).toBe(0o500);
  });

  test("백업 경로가 심볼릭 링크면 따라가지 않고, infisical을 띄우기 전에 실패한다", () => {
    const { ctx, calls, home } = testCtx("plan", [infisicalList("/apps/smoke", { A: FAKE_SECRETS[0] })]);
    mkdirSync(join(home, ".infisical"));
    mkdirSync(join(home, "elsewhere"));
    symlinkSync(join(home, "elsewhere"), join(home, BACKUP));
    expect(() => ctx.infisical.has("/apps/smoke", "A")).toThrow("폴더가 아니다");
    expect(calls().calls).toEqual([]);
    expect(mode(join(home, "elsewhere"))).not.toBe(0o500);
  });

  test("잠근 뒤에도 쓸 수 있으면(권한이 듣지 않는 파일시스템) 띄우지 않고 실패한다", () => {
    const home = testCtx("plan", []).home;
    let ran = false;
    expect(() => guardInfisicalBackup(home, () => (ran = true), { chmod: () => {} })).toThrow("쓰기 가능하다");
    expect(ran).toBe(false);
    expect(existsSync(join(home, BACKUP, ".probe"))).toBe(false);
  });

  test("HOME이 없거나 상대 경로면 띄우지 않고 실패한다", () => {
    let ran = false;
    expect(() => guardInfisicalBackup(undefined, () => (ran = true))).toThrow(CliError);
    expect(() => guardInfisicalBackup("rel/home", () => (ran = true))).toThrow(CliError);
    expect(ran).toBe(false);
  });

  test("infisical이 아닌 도구는 백업 폴더를 만들지 않는다", () => {
    const { ctx, home } = testCtx("plan", [rule(["gh", "--version"], { stdout: "gh 2" })]);
    ctx.tools.version("gh");
    expect(existsSync(join(home, ".infisical"))).toBe(false);
  });
});
