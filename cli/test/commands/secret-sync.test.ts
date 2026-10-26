import { describe, expect, test } from "bun:test";
import { esSyncVersion } from "../../src/core/kubectl";
import { FAKE_SECRETS, expectNoSecrets, expectPlanReadOnly, kubectlRule, runCli, sha256, type Resp, type Rule } from "../harness";
import { b64, folders, homelab, infisicalList } from "../fixtures/app-add-world/world";

const APP = "memo";
const NS = `app-${APP}`;
const VALUES = "chartVersion: 1.1.0\nkind: web\nport: 8080\nresources: { cpu: 50m, memory: 64Mi }\nsecrets: [API_TOKEN]\n";
// core kubectl.ts의 표식 계산과 같다(참조 Secret name@rv를 정렬해 줄로 이은 sha256 앞 16자).
const MARK = sha256(`${APP}-app@101`).slice(0, 16);

const ES_META = { generation: 1, annotations: { "force-sync": "1" } };
const secret = (v: string): Resp => ({ stdout: JSON.stringify({ data: { API_TOKEN: b64(v) } }) });
const deploy = (mark: string | null, ready = true): Resp => ({
  stdout: JSON.stringify({
    metadata: { generation: 2 },
    spec: { replicas: 1, template: { metadata: { annotations: mark ? { "homelab.ukyi.app/secrets-rv": mark } : {} }, spec: { containers: [{ name: "app", env: [{ name: "API_TOKEN", valueFrom: { secretKeyRef: { name: `${APP}-app`, key: "API_TOKEN" } } }] }] } } },
    status: { observedGeneration: 2, replicas: 1, updatedReplicas: 1, availableReplicas: ready ? 1 : 0 },
  }),
});

function world(o: { secret: Resp[]; deploy: Resp[]; patchCode?: number; rollout?: number }): Rule[] {
  return [
    ...homelab({ [`apps/${APP}/values.yaml`]: VALUES }),
    ...folders({ "/apps": [APP] }),
    infisicalList(`/apps/${APP}`, { API_TOKEN: FAKE_SECRETS[0] }),
    // 스텁의 메타데이터는 고정이라 그 메타데이터의 동기화 버전을 ESO가 썼다고 둔다(core forceSync의 완료 판정).
    kubectlRule(["-n", NS, "get", "externalsecrets.external-secrets.io", `${APP}-app`, "-o", "json"], { stdout: JSON.stringify({ metadata: ES_META, status: { syncedResourceVersion: esSyncVersion(ES_META), conditions: [{ type: "Ready", status: "True" }] } }) }),
    kubectlRule(["-n", NS, "get", "secret", `${APP}-app`, "-o", "json"], o.secret),
    kubectlRule(["-n", NS, "get", "deployments.apps", APP, "-o", "json"], o.deploy),
    kubectlRule(["-n", NS, "get", "secrets", `${APP}-app`, "-o", "jsonpath={.metadata.resourceVersion}"], { stdout: "101" }),
    kubectlRule(["-n", NS, "annotate", "externalsecrets.external-secrets.io", `${APP}-app`, /^force-sync=[0-9]+-[0-9a-f]{4}$/, "--overwrite"]),
    kubectlRule(["-n", NS, "patch", "deployments.apps", APP, "--type=merge", "--patch-file=/dev/stdin"], { code: o.patchCode ?? 0 }),
    kubectlRule(["-n", NS, "rollout", "status", `deploy/${APP}`, "--timeout=180s"], { code: o.rollout ?? 0 }),
  ];
}

describe("secret sync", () => {
  test("plan: 다른 키 → force-sync, 옛 파드 → 재시작, 쓰기 0건", async () => {
    const r = await runCli(["secret", "sync", APP, "--json"], world({ secret: [secret("old-value-1234567890")], deploy: [deploy("0".repeat(16))] }));
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.steps.map((s: any) => s.state)).toEqual(["same", "same", "differs", "differs"]);
  });

  test("apply: annotate → 기다림 → 표식 재시작 → rollout, done", async () => {
    const old = secret("old-value-1234567890");
    const r = await runCli(["secret", "sync", APP, "--apply", "--json"], world({ secret: [old, old, secret(FAKE_SECRETS[0])], deploy: [deploy(null), deploy(null), deploy(null), deploy(MARK)] }));
    expect(r.code).toBe(0);
    expect(r.json.status).toBe("done");
    const writes = r.writes.map((c) => c.argv[3]);
    expect(writes).toEqual(["annotate", "patch"]);
    const patch = r.calls.find((c) => c.argv[3] === "patch")!;
    expect(patch.stdinLength).toBeGreaterThan(0);
    expectNoSecrets(r);
  });

  test("다 된 상태 apply: same, 재시작 안 함", async () => {
    const r = await runCli(["secret", "sync", APP, "--apply", "--json"], world({ secret: [secret(FAKE_SECRETS[0])], deploy: [deploy(MARK)] }));
    expect(r.code).toBe(0);
    expect(r.json.steps.every((s: any) => s.state === "same")).toBe(true);
    expect(r.writes).toEqual([]);
  });

  test("재시작 쓰기 실패 → exit 1, 재실행은 동기화를 건너뛰고 재시작부터", async () => {
    const r = await runCli(["secret", "sync", APP, "--apply", "--json"], world({ secret: [secret(FAKE_SECRETS[0])], deploy: [deploy(null)], patchCode: 1 }));
    expect(r.code).toBe(1);
    expect(r.json.steps.find((s: any) => s.id === "restart").result).toBe("failed");
    const again = await runCli(["secret", "sync", APP, "--apply", "--json"], world({ secret: [secret(FAKE_SECRETS[0])], deploy: [deploy(null), deploy(null), deploy(null), deploy(MARK)] }));
    expect(again.code).toBe(0);
    expect(again.json.steps.find((s: any) => s.id === "sync").result).toBe("skipped");
    expect(again.writes.map((c) => c.argv[3])).toEqual(["patch"]);
  });

  test("Infisical에 없는 키가 있으면 secret set으로 안내하고 쓰지 않는다", async () => {
    const rules = world({ secret: [secret(FAKE_SECRETS[0])], deploy: [deploy(MARK)] }).map((x) => (x.argv[0] === "infisical" && x.argv[2] === "--path" ? infisicalList(`/apps/${APP}`, {}) : x));
    const r = await runCli(["secret", "sync", APP, "--apply", "--json"], rules);
    expect(r.code).toBe(1);
    expect(r.json.error.next).toBe(`homelab secret set ${APP} API_TOKEN`);
    expect(r.writes).toEqual([]);
  });
});
