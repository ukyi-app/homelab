import { describe, expect, test } from "bun:test";
import { esSyncVersion } from "../../src/core/kubectl";
import { FAKE_SECRETS, expectNoSecrets, expectPlanReadOnly, kubectlRule, runCli, sha256, type Resp, type Rule } from "../harness";
import { b64, folders, homelab, infisicalList } from "../fixtures/app-add-world/world";
import { World, runIn } from "../fixtures/rotate-world/world";
import type { WriteCtx } from "../../src/core/command";
import { ExecTimeout } from "../../src/core/exec";
import cmd from "../../src/commands/secret-sync";

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

function world(o: { secret: Resp[]; deploy: Resp[]; patchCode?: number; rollout?: number; values?: string; es?: Resp[]; app?: Resp[] }): Rule[] {
  return [
    ...homelab({ [`apps/${APP}/values.yaml`]: o.values ?? VALUES }),
    ...folders({ "/apps": [APP] }),
    infisicalList(`/apps/${APP}`, { API_TOKEN: FAKE_SECRETS[0] }),
    // 스텁의 메타데이터는 고정이라 그 메타데이터의 동기화 버전을 ESO가 썼다고 둔다(core forceSync의 완료 판정).
    kubectlRule(["-n", NS, "get", "externalsecrets.external-secrets.io", `${APP}-app`, "-o", "json"], o.es ?? { stdout: JSON.stringify({ metadata: ES_META, status: { syncedResourceVersion: esSyncVersion(ES_META), conditions: [{ type: "Ready", status: "True" }] } }) }),
    kubectlRule(["-n", NS, "get", "secret", `${APP}-app`, "-o", "json"], o.secret),
    // 앱 Application은 ExternalSecret이 없을 때만 읽는다(argo 확인 단계).
    kubectlRule(["-n", "argocd", "get", "applications.argoproj.io", APP, "-o", "json"], o.app ?? [notFound(`applications.argoproj.io "${APP}"`)]),
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
    expect(r.json.steps.map((s: any) => s.state)).toEqual(["same", "same", "same", "differs", "differs"]);
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

  // T12-05 F3: app add PR(secrets 추가) 병합 직후 Argo CD가 아직 반영하지 않으면 ExternalSecret이 없다. 반영이 진행 중인
  // 모양은 실패가 아니라 대기다. ApplicationSet은 values를 helm.valuesObject로 넣는다(argo 확인 단계 주석).
  const withSecrets = { helm: { valuesObject: { kind: "web", secrets: ["API_TOKEN"] } } };
  const noSecrets = { helm: { valuesObject: { kind: "web" } } };
  const application = (o: { spec?: object; sync?: string; compared?: object; op?: object; conditions?: object[] }): Resp => ({
    stdout: JSON.stringify({ spec: { source: o.spec ?? withSecrets }, status: { sync: { status: o.sync ?? "Synced", comparedTo: { source: o.compared ?? o.spec ?? withSecrets } }, operationState: o.op ?? { phase: "Succeeded" }, conditions: o.conditions ?? [] } }),
  });
  const delays: [string, Resp, Resp, string][] = [
    ["새 앱: Application 없음(Deployment도 없음)", notFound(`applications.argoproj.io "${APP}"`), notFound(`deployments.apps "${APP}"`), "ApplicationSet이 앱 Application을 만들기를 기다림"],
    ["앱 있음: ApplicationSet이 values 반영 전", application({ spec: noSecrets }), deploy(null), "ApplicationSet이 values의 secrets를 앱 Application에 넣기를 기다림"],
    ["동기화 진행 중(재시도 3회)", application({ sync: "OutOfSync", compared: noSecrets, op: { phase: "Running", retryCount: 3 } }), deploy(null), "Argo CD 동기화가 끝나기를 기다림"],
    ["옛 source의 실패 뒤 새 source 동기화 전", application({ sync: "OutOfSync", compared: noSecrets, op: { phase: "Failed", retryCount: 10, syncResult: { source: noSecrets } } }), deploy(null), "Argo CD가 values의 secrets를 동기화하기를 기다림"],
  ];
  for (const [shape, app, deployResp, hold] of delays) {
    test(`T12-05 F3 정상 지연(${shape}): 대기(3), 쓰기 0, 다시 치면 잇는다`, async () => {
      const before = world({ es: [notFound(`externalsecrets.external-secrets.io "${APP}-app"`)], app: [app], secret: [notFound(`secrets "${APP}-app"`)], deploy: [deployResp] });
      const plan = await runCli(["secret", "sync", APP, "--json"], before);
      expect(plan.code).toBe(0);
      expectPlanReadOnly(plan);
      expect(plan.json.status).toBe("pending");
      expect(plan.json.notes).toEqual([`Argo CD ${APP}: ${hold}. 뒤 단계는 대기가 끝난 뒤 실행한다`]);

      const r = await runCli(["secret", "sync", APP, "--apply", "--json"], before);
      expect(r.code).toBe(3);
      expect(r.json.status).toBe("waiting");
      expect(r.json.steps.map((x: any) => x.result)).toEqual(["skipped", "skipped", "waiting", "not-run", "not-run"]);
      expect(r.json.next).toBe(`${hold}. 끝나면 다시: homelab secret sync ${APP} --apply`);
      expect(r.writes).toEqual([]);

      // Argo CD가 반영한 뒤 같은 명령: 동기화·재시작으로 끝난다
      const old = secret("old-value-1234567890");
      const again = await runCli(["secret", "sync", APP, "--apply", "--json"], world({ secret: [old, old, secret(FAKE_SECRETS[0])], deploy: [deploy(null), deploy(null), deploy(null), deploy(MARK)] }));
      expect(again.code).toBe(0);
      expect(again.json.status).toBe("done");
    });
  }

  // #913 r1 P2-1: Argo CD가 끝났는데 ExternalSecret을 만들지 못했으면 기다려도 오지 않는다. 실패와 원인 확인 행동.
  const stuckShapes: [string, Resp, string][] = [
    ["재시도 소진(Failed, 10회, 같은 source)", application({ sync: "OutOfSync", op: { phase: "Failed", retryCount: 10, syncResult: { source: withSecrets } } }), "ExternalSecret 없음, 동기화 Failed(재시도 10회 뒤 멈춤)"],
    ["동기화 오류(Error)", application({ sync: "OutOfSync", op: { phase: "Error", retryCount: 0, syncResult: { source: withSecrets } } }), "ExternalSecret 없음, 동기화 Error(재시도 0회 뒤 멈춤)"],
    ["비교 오류(ComparisonError)", application({ sync: "Unknown", conditions: [{ type: "ComparisonError", message: "x" }] }), "ExternalSecret 없음, 앱 Application ComparisonError"],
    ["Synced인데 없음", application({}), "ExternalSecret 없음, 앱 Application은 Synced"],
  ];
  for (const [shape, app, detail] of stuckShapes) {
    test(`#913 r1 P2-1: ${shape}이면 대기가 아니라 실패(1), 원인 확인·명시 sync 안내, 쓰기 0`, async () => {
      const rules = world({ es: [notFound(`externalsecrets.external-secrets.io "${APP}-app"`)], app: [app], secret: [notFound(`secrets "${APP}-app"`)], deploy: [deploy(null)] });
      for (const args of [["secret", "sync", APP, "--json"], ["secret", "sync", APP, "--apply", "--json"]]) {
        const r = await runCli(args, rules);
        expect(r.code).toBe(1);
        expect(r.json.steps.find((x: any) => x.id === "argo").detail).toBe(detail);
        expect(r.json.error.next).toBe(`kubectl -n argocd get application ${APP} -o yaml로 원인(status.conditions·operationState)을 보고, 고친 뒤 명시 sync한다(Argo CD가 다시 시도하지 않는다). 그 뒤 같은 명령을 다시 실행한다`);
        expect(r.json.notes).toEqual([]);
        expect(r.writes).toEqual([]);
      }
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

// #913 r1 P2-2: 실행 뒤 재조회는 대기로 넘어가지 않는다. 상태가 있는 가짜 세계에 실제 명령·엔진을 돌리고 forceSync만 바꿔 끼운다.
describe("secret sync: 실행 뒤 재조회(가짜 세계)", () => {
  const ES_ID = `${NS}/${APP}-app`;
  function syncWorld(onForceSync: (w: World) => void): World {
    const w = new World({ [`apps/${APP}/values.yaml`]: VALUES });
    w.setValue(`/apps/${APP}`, "API_TOKEN", FAKE_SECRETS[0]);
    w.producers.set(ES_ID, () => {
      const v = w.value(`/apps/${APP}`, "API_TOKEN");
      return v ? { API_TOKEN: v } : null;
    });
    w.secrets.set(ES_ID, { data: { API_TOKEN: "old-value-1234567890" }, rv: ++w.rv });
    w.put("externalsecret", NS, `${APP}-app`, { metadata: { name: `${APP}-app` } });
    w.deploys.set(`${NS}/${APP}`, { secrets: [`${APP}-app`], annot: null, rolledOut: true, env: {} });
    w.restart(`${NS}/${APP}`);
    w.writes = [];
    const base = w.writeCtx.bind(w);
    w.writeCtx = (ctx: any) => {
      const x = base(ctx);
      return {
        ...x,
        k8s: {
          ...x.k8s,
          forceSync(ns: string, es: string) {
            w.writes.push(`forceSync ${ns}/${es}`);
            onForceSync(w);
            throw new ExecTimeout(`ExternalSecret ${es}: 동기화 대기 시간 초과`);
          },
        },
      } as WriteCtx;
    };
    return w;
  }

  test("forceSync 시간 초과 뒤 ExternalSecret이 사라지면 결과 미상 실패, '반영 확인' 없음, 재시작 안 함", async () => {
    const w = syncWorld((x) => x.objects.delete(`externalsecret/${ES_ID}`));
    const r = await runIn(w, cmd, "apply", { app: APP });
    expect(r.status).toBe("failed");
    expect(r.error?.message).toBe(`ExternalSecret ${ES_ID}: 시간 초과 뒤 다시 읽었지만 아직 반영되지 않았다(결과 미상, 재시도하지 않았다)`);
    expect(r.notes.join(" ")).not.toContain("반영된 것을 확인했다");
    expect(r.steps.map((s) => s.result)).toEqual(["skipped", "skipped", "skipped", "failed", "not-run"]);
    expect(w.writes).toEqual([`forceSync ${ES_ID}`]);
  });

  test("forceSync 시간 초과라도 다시 읽은 Secret이 Infisical과 같으면 그때만 '반영 확인'하고 재시작까지 간다", async () => {
    const w = syncWorld((x) => x.sync(ES_ID));
    const r = await runIn(w, cmd, "apply", { app: APP });
    expect(r.status).toBe("done");
    expect(r.notes).toEqual(["sync: 시간 초과 뒤 다시 읽어 반영된 것을 확인했다"]);
    expect(w.writes).toEqual([`forceSync ${ES_ID}`, `restartForSecrets ${NS}/${APP}`]);
  });
});
