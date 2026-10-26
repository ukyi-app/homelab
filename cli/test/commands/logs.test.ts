import { describe, expect, test } from "bun:test";
import { expectPlanReadOnly, kubectlRule, runCli } from "../harness";

const APP = "memo";
const NS = `app-${APP}`;

describe("logs", () => {
  test("지금 파드 로그를 body로, 과거는 Grafana 안내, 쓰기 0건", async () => {
    const r = await runCli(["logs", APP, "--since", "7d", "--json"], [kubectlRule(["-n", NS, "logs", `deploy/${APP}`, "--tail=200", "--since=168h"], { stdout: "a\nb\n" })]);
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.body).toBe("a\nb\n");
    expect(r.json.steps[0].detail).toBe("2줄(최근 200줄까지)");
    expect(r.json.notes[0]).toContain(`{namespace="${NS}"}`);
  });

  test("--job migrate·--previous, 사람용 출력에 로그가 그대로", async () => {
    const r = await runCli(["logs", APP, "--job", "migrate", "--previous"], [kubectlRule(["-n", NS, "logs", `job/${APP}-migrate`, "--tail=200", "--previous"], { stdout: "migrate ok\n" })]);
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.stdout).toContain("migrate ok");
  });

  test("파드가 없으면 exit 1, --apply는 64", async () => {
    const r = await runCli(["logs", APP], [kubectlRule(["-n", NS, "logs", `deploy/${APP}`, "--tail=200"], { code: 1, stderr: 'Error from server (NotFound): deployments.apps "memo" not found' })]);
    expect(r.code).toBe(1);
    expect((await runCli(["logs", APP, "--apply"], [])).code).toBe(64);
    expect((await runCli(["logs", APP, "--job", "other"], [])).code).toBe(64);
  });
});
