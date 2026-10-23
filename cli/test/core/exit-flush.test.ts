// 큰 출력이 끝까지 가는지(Connector 4360396737). 진입점이 process.exit()로 끝나면 파이프 버퍼(64KB)를 넘는 출력이 잘린다.
// 소비자가 늦게 읽기 시작해도 전체가 와야 한다. doctor의 gh 버전 칸에 큰 값을 넣어 출력을 키운다.
import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import { expectedTools } from "../../src/core/version";
import { rule, stubSandbox } from "../harness";

const MAIN = join(import.meta.dir, "..", "..", "src", "main.ts");
const want = expectedTools();
const BIG = "9".repeat(300_000);

describe("출력 비우기", () => {
  test("느린 소비자에게도 300KB 넘는 JSON 문서가 잘리지 않는다", async () => {
    const sb = stubSandbox([
      rule(["kubectl", "version", "--client", "-o", "json"], { stdout: JSON.stringify({ clientVersion: { gitVersion: `v${want.kubectl}` } }) }),
      rule(["infisical", "--version"], { stdout: `infisical version ${want.infisical}\n` }),
      rule(["terraform", "version"], { stdout: `Terraform v${want.terraform}\n` }),
      rule(["gh", "--version"], { stdout: `gh version ${BIG}\n` }),
      rule(["git", "--version"], { stdout: "git version 2.53.0\n" }),
      rule(["curl", "--version"], { stdout: "curl 8.18.0\n" }),
      rule(["jq", "--version"], { stdout: "jq-1.8.1\n" }),
      rule(["gh", "auth", "status", "--active", "--hostname", "github.com"], {}),
      rule(["infisical", "user", "get", "token", "--silent"], { stdout: "Token: x\n" }),
      rule(["kubectl", "config", "current-context"], { stdout: "homelab\n" }),
    ]);
    // Bun.spawn의 pipe는 부모가 곧바로 다 읽어 가서 잘림이 드러나지 않는다. 그래서 OS 파이프 뒤에 1초 늦게 읽는 소비자를 둔다.
    // sh의 인자로만 경로를 넘긴다(문자열에 끼우지 않는다). PATH는 스텁 폴더뿐이라 sleep·cat은 절대 경로로 부른다.
    const p = Bun.spawn(["/bin/sh", "-c", '"$0" --no-env-file "$1" doctor --json | { /bin/sleep 1; exec /bin/cat; }', process.execPath, MAIN], {
      env: sb.env,
      cwd: sb.env.HOME,
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
    });
    const out = await new Response(p.stdout).text();
    await p.exited;
    expect(out.length).toBeGreaterThan(BIG.length);
    const doc = JSON.parse(out);
    expect(doc.steps.find((s: { id: string }) => s.id === "tool-gh").detail).toBe(BIG);
  }, 20_000);
});
