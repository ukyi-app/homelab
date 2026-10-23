import { describe, expect, test } from "bun:test";
import { expectPlanReadOnly, rule, runCli, type Rule } from "../harness";
import { expectedTools } from "../../src/core/version";

const want = expectedTools();

function healthy(): Rule[] {
  return [
    rule(["kubectl", "version", "--client", "-o", "json"], { stdout: JSON.stringify({ clientVersion: { gitVersion: `v${want.kubectl}` } }) }),
    rule(["infisical", "--version"], { stdout: `infisical version ${want.infisical}\n` }),
    rule(["terraform", "version"], { stdout: `Terraform v${want.terraform}\non linux_amd64\n` }),
    rule(["gh", "--version"], { stdout: "gh version 2.102.0 (2026-10-01)\n" }),
    rule(["git", "--version"], { stdout: "git version 2.53.0\n" }),
    rule(["curl", "--version"], { stdout: "curl 8.18.0 (x86_64-pc-linux-gnu)\n" }),
    rule(["jq", "--version"], { stdout: "jq-1.8.1\n" }),
    rule(["gh", "auth", "status", "--active", "--hostname", "github.com"], { stdout: "github.com\n  ✓ Logged in\n" }),
    // 토큰이 출력에 새지 않는지 보려고 가짜 시크릿을 토큰 자리에 둔다.
    rule(["infisical", "user", "get", "token", "--silent"], { stdout: "Token: fakevalue-aaaa-bbbb-cccc\n" }),
    rule(["kubectl", "config", "current-context"], { stdout: "homelab\n" }),
  ];
}

describe("doctor", () => {
  test("모두 정상이면 exit 0, 쓰기 0건, 토큰이 출력에 없다", async () => {
    const r = await runCli(["doctor", "--json"], healthy());
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.schema).toBe("homelab-cli/v1");
    expect(r.json.mode).toBe("read");
    expect(r.json.status).toBe("same");
    expect(r.json.steps.every((s: { state: string }) => s.state === "same")).toBe(true);
  });

  test("사람용 출력: 머리, 단계 목록, 다음 없음", async () => {
    const r = await runCli(["doctor"], healthy());
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.stdout.split("\n")[0]).toBe("homelab doctor");
    expect(r.stdout).toContain(`도구 kubectl`);
    expect(r.stdout).toContain("다음: 없음");
  });

  test("도구가 없거나 버전이 다르면 exit 1과 다음 행동", async () => {
    const rules = healthy().filter((x) => !(x.argv[0] === "jq")).map((x) => (x.argv[0] === "kubectl" && x.argv[1] === "version" ? rule(x.argv, { stdout: JSON.stringify({ clientVersion: { gitVersion: "v1.0.0" } }) }) : x));
    const r = await runCli(["doctor", "--json"], rules, { tools: ["gh", "git", "kubectl", "infisical", "curl", "terraform"] });
    expect(r.code).toBe(1);
    expectPlanReadOnly(r);
    const byId = Object.fromEntries(r.json.steps.map((s: { id: string }) => [s.id, s]));
    expect(byId["tool-kubectl"].state).toBe("differs");
    expect(byId["tool-jq"].state).toBe("missing");
    expect(r.json.error.next).toBe("mise install");
  });

  test("프로젝트 ID가 없으면 경고(exit 0, 주의 줄), 형식이 틀리면 실패", async () => {
    const r = await runCli(["doctor", "--json"], healthy(), { project: false });
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.status).toBe("same");
    expect(r.json.notes.join(" ")).toContain("HOMELAB_INFISICAL_PROJECT_ID");
    const h = await runCli(["doctor"], healthy(), { project: false });
    expect(h.stdout).toContain("주의: 환경변수 HOMELAB_INFISICAL_PROJECT_ID");
    const bad = await runCli(["doctor", "--json"], healthy(), { env: { HOMELAB_INFISICAL_PROJECT_ID: "nope" } });
    expect(bad.code).toBe(1);
  });

  test("--apply는 읽기 명령에 사용법 오류(64)", async () => {
    const r = await runCli(["doctor", "--apply"], []);
    expect(r.code).toBe(64);
    expect(r.calls).toEqual([]);
  });
});
