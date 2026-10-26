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

const notFound = (what: string): Resp => ({ code: 1, stderr: `Error from server (NotFound): ${what} not found\n` });

function world(o: { secret: Resp[]; deploy: Resp[]; patchCode?: number; rollout?: number; values?: string; es?: Resp[] }): Rule[] {
  return [
    ...homelab({ [`apps/${APP}/values.yaml`]: o.values ?? VALUES }),
    ...folders({ "/apps": [APP] }),
    infisicalList(`/apps/${APP}`, { API_TOKEN: FAKE_SECRETS[0] }),
    // 스텁의 메타데이터는 고정이라 그 메타데이터의 동기화 버전을 ESO가 썼다고 둔다(core forceSync의 완료 판정).
    kubectlRule(["-n", NS, "get", "externalsecrets.external-secrets.io", `${APP}-app`, "-o", "json"], o.es ?? { stdout: JSON.stringify({ metadata: ES_META, status: { syncedResourceVersion: esSyncVersion(ES_META), conditions: [{ type: "Ready", status: "True" }] } }) }),
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

  // T12-05 F3: app add PR(secrets 추가) 병합 직후 Argo CD가 아직 반영하지 않으면 ExternalSecret이 없다. 앱이 이미 떠 있는 경우와
  // 새 앱이라 Deployment도 아직 없는 경우 모두 실패가 아니라 대기다.
  for (const shape of ["앱 있음", "새 앱(Deployment 없음)"] as const) {
    test(`T12-05 F3: Argo CD 반영 전(ExternalSecret 없음, ${shape})이면 대기(3), 쓰기 0, 다시 치면 잇는다`, async () => {
      const es = [notFound(`externalsecrets.external-secrets.io "${APP}-app"`)];
      const deployResp = shape === "앱 있음" ? [deploy(null)] : [notFound(`deployments.apps "${APP}"`)];
      const before = world({ es, secret: [notFound(`secrets "${APP}-app"`)], deploy: deployResp });
      const plan = await runCli(["secret", "sync", APP, "--json"], before);
      expect(plan.code).toBe(0);
      expectPlanReadOnly(plan);
      expect(plan.json.status).toBe("pending");
      expect(plan.json.notes.join(" ")).toContain("Argo CD가 values의 secrets를 반영해 ExternalSecret을 만들기를 기다림");

      const r = await runCli(["secret", "sync", APP, "--apply", "--json"], before);
      expect(r.code).toBe(3);
      expect(r.json.status).toBe("waiting");
      expect(r.json.steps.map((x: any) => x.result)).toEqual(["skipped", "skipped", "waiting", "not-run"]);
      expect(r.json.next).toBe(`Argo CD가 values의 secrets를 반영해 ExternalSecret을 만들기를 기다림. 끝나면 다시: homelab secret sync ${APP} --apply`);
      expect(r.writes).toEqual([]);

      // Argo CD가 반영한 뒤 같은 명령: 동기화·재시작으로 끝난다
      const old = secret("old-value-1234567890");
      const again = await runCli(["secret", "sync", APP, "--apply", "--json"], world({ secret: [old, old, secret(FAKE_SECRETS[0])], deploy: [deploy(null), deploy(null), deploy(null), deploy(MARK)] }));
      expect(again.code).toBe(0);
      expect(again.json.status).toBe("done");
    });
  }

  test("T12-05 F3: values에 secrets가 없으면 대기가 아니라 그대로 실패(1)하고 쓰지 않는다", async () => {
    const r = await runCli(["secret", "sync", APP, "--apply", "--json"], world({ values: VALUES.replace("secrets: [API_TOKEN]\n", ""), es: [notFound(`externalsecrets.external-secrets.io "${APP}-app"`)], secret: [notFound(`secrets "${APP}-app"`)], deploy: [deploy(null)] }));
    expect(r.code).toBe(1);
    expect(r.json.error.next).toBe(`homelab secret set ${APP} <KEY> 뒤 homelab app add ${APP}`);
    expect(r.writes).toEqual([]);
  });

  test("Infisical에 없는 키가 있으면 secret set으로 안내하고 쓰지 않는다", async () => {
    const rules = world({ secret: [secret(FAKE_SECRETS[0])], deploy: [deploy(MARK)] }).map((x) => (x.argv[0] === "infisical" && x.argv[2] === "--path" ? infisicalList(`/apps/${APP}`, {}) : x));
    const r = await runCli(["secret", "sync", APP, "--apply", "--json"], rules);
    expect(r.code).toBe(1);
    expect(r.json.error.next).toBe(`homelab secret set ${APP} API_TOKEN`);
    expect(r.writes).toEqual([]);
  });
});
