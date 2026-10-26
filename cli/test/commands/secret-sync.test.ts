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

// 정상 ApplicationSet apps(생성 오류 없음). ApplicationSet condition은 status가 있어 False는 오류가 아니다.
const APPSET_OK: Resp = { stdout: JSON.stringify({ status: { conditions: [{ type: "ErrorOccurred", status: "False", reason: "ApplicationSetUpToDate" }, { type: "ParametersGenerated", status: "True" }] } }) };

// deploy 응답은 Deployment 조회(같은 argv)마다 하나씩 쓴다: argo 확인(읽을 때마다 1), restart 읽기(1), 재시작 표식 계산(1).
// 그래서 apply가 끝까지 가면 [전체 읽기 argo, 전체 읽기 restart, apply argo, apply restart, 표식, 실행 뒤 restart] 여섯 번이다.
const UNTIL_DONE = (last: Resp): Resp[] => [deploy(null), deploy(null), deploy(null), deploy(null), deploy(null), last];

function world(o: { secret: Resp[]; deploy: Resp[]; patchCode?: number; rollout?: number; values?: string; es?: Resp[]; app?: Resp[]; appset?: Resp[] }): Rule[] {
  return [
    ...homelab({ [`apps/${APP}/values.yaml`]: o.values ?? VALUES }),
    ...folders({ "/apps": [APP] }),
    infisicalList(`/apps/${APP}`, { API_TOKEN: FAKE_SECRETS[0] }),
    // 스텁의 메타데이터는 고정이라 그 메타데이터의 동기화 버전을 ESO가 썼다고 둔다(core forceSync의 완료 판정).
    kubectlRule(["-n", NS, "get", "externalsecrets.external-secrets.io", `${APP}-app`, "-o", "json"], o.es ?? { stdout: JSON.stringify({ metadata: ES_META, status: { syncedResourceVersion: esSyncVersion(ES_META), conditions: [{ type: "Ready", status: "True" }] } }) }),
    kubectlRule(["-n", NS, "get", "secret", `${APP}-app`, "-o", "json"], o.secret),
    // 앱 Application은 ExternalSecret이나 Deployment가 없을 때만 읽고, 부모 ApplicationSet은 자식이 없거나 values 전달 전일 때만 읽는다.
    kubectlRule(["-n", "argocd", "get", "applications.argoproj.io", APP, "-o", "json"], o.app ?? [notFound(`applications.argoproj.io "${APP}"`)]),
    kubectlRule(["-n", "argocd", "get", "applicationsets.argoproj.io", "apps", "-o", "json"], o.appset ?? [APPSET_OK]),
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
    const r = await runCli(["secret", "sync", APP, "--apply", "--json"], world({ secret: [old, old, secret(FAKE_SECRETS[0])], deploy: UNTIL_DONE(deploy(MARK)) }));
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
    const again = await runCli(["secret", "sync", APP, "--apply", "--json"], world({ secret: [secret(FAKE_SECRETS[0])], deploy: UNTIL_DONE(deploy(MARK)) }));
    expect(again.code).toBe(0);
    expect(again.json.steps.find((s: any) => s.id === "sync").result).toBe("skipped");
    expect(again.writes.map((c) => c.argv[3])).toEqual(["patch"]);
  });

  // T12-05 F3: app add PR(secrets 추가) 병합 직후 Argo CD가 아직 반영하지 않으면 ExternalSecret이 없다. 반영이 진행 중인
  // 모양은 실패가 아니라 대기다. ApplicationSet은 values를 helm.valuesObject로 넣는다(argo 확인 단계 주석).
  const withSecrets = { helm: { valuesObject: { kind: "web", secrets: ["API_TOKEN"] } } };
  const noSecrets = { helm: { valuesObject: { kind: "web" } } };
  // status.sync.revision은 차트 태그가 가리키는 커밋이다. syncResult.revision과 함께 Argo CD의 "이미 시도함" 판정에 쓰인다.
  const REV = "a".repeat(40);
  const application = (o: { spec?: object; sync?: string; compared?: object; op?: object; conditions?: object[] }): Resp => ({
    stdout: JSON.stringify({ spec: { source: o.spec ?? withSecrets }, status: { sync: { status: o.sync ?? "Synced", revision: REV, comparedTo: { source: o.compared ?? o.spec ?? withSecrets } }, operationState: o.op ?? { phase: "Succeeded" }, conditions: o.conditions ?? [] } }),
  });
  const delays: [string, Resp, Resp, string][] = [
    ["새 앱: Application 없음(Deployment도 없음)", notFound(`applications.argoproj.io "${APP}"`), notFound(`deployments.apps "${APP}"`), "ApplicationSet이 앱 Application을 만들기를 기다림"],
    ["앱 있음: ApplicationSet이 values 반영 전", application({ spec: noSecrets }), deploy(null), "ApplicationSet이 values의 secrets를 앱 Application에 넣기를 기다림"],
    ["동기화 진행 중(재시도 3회)", application({ sync: "OutOfSync", op: { phase: "Running", retryCount: 3 } }), deploy(null), "Argo CD 동기화가 끝나기를 기다림"],
    ["옛 source의 실패 뒤 새 source 비교 전", application({ sync: "OutOfSync", compared: noSecrets, op: { phase: "Failed", retryCount: 10, syncResult: { source: noSecrets, revision: REV } } }), deploy(null), "Argo CD가 새 source를 비교하기를 기다림"],
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
      const again = await runCli(["secret", "sync", APP, "--apply", "--json"], world({ secret: [old, old, secret(FAKE_SECRETS[0])], deploy: UNTIL_DONE(deploy(MARK)) }));
      expect(again.code).toBe(0);
      expect(again.json.status).toBe("done");
    });
  }

  // #913 r1 P2-1: Argo CD가 끝났는데 ExternalSecret을 만들지 못했으면 기다려도 오지 않는다. 실패와 원인 확인 행동.
  const stuckShapes: [string, Resp, string][] = [
    ["재시도 소진(Failed, 10회, 같은 source)", application({ sync: "OutOfSync", op: { phase: "Failed", retryCount: 10, syncResult: { source: withSecrets, revision: REV } } }), "ExternalSecret 없음, 동기화 Failed(재시도 10회 뒤 멈춤)"],
    ["동기화 오류(Error)", application({ sync: "OutOfSync", op: { phase: "Error", retryCount: 0, syncResult: { source: withSecrets, revision: REV } } }), "ExternalSecret 없음, 동기화 Error(재시도 0회 뒤 멈춤)"],
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

  const ES_GONE = [notFound(`externalsecrets.external-secrets.io "${APP}-app"`)];
  const SECRET_GONE = [notFound(`secrets "${APP}-app"`)];
  const DEPLOY_GONE = notFound(`deployments.apps "${APP}"`);
  const STUCK_NEXT = `kubectl -n argocd get application ${APP} -o yaml로 원인(status.conditions·operationState)을 보고, 고친 뒤 명시 sync한다(Argo CD가 다시 시도하지 않는다). 그 뒤 같은 명령을 다시 실행한다`;
  const APPSET_NEXT = `kubectl -n argocd get applicationset apps -o yaml로 status.conditions를 보고 원인(보통 apps/${APP}/ 파일)을 고친다. ApplicationSet이 60초 안에 다시 만들므로 명시 sync는 필요 없다. 그 뒤 같은 명령을 다시 실행한다`;
  async function expectWaiting(rules: Rule[], hold: string) {
    const plan = await runCli(["secret", "sync", APP, "--json"], rules);
    expect(plan.code).toBe(0);
    expectPlanReadOnly(plan);
    expect(plan.json.status).toBe("pending");
    expect(plan.json.notes).toEqual([`Argo CD ${APP}: ${hold}. 뒤 단계는 대기가 끝난 뒤 실행한다`]);
    const r = await runCli(["secret", "sync", APP, "--apply", "--json"], rules);
    expect(r.code).toBe(3);
    expect(r.json.status).toBe("waiting");
    expect(r.json.next).toBe(`${hold}. 끝나면 다시: homelab secret sync ${APP} --apply`);
    expect(r.writes).toEqual([]);
  }
  async function expectFailed(rules: Rule[], detail: string, next: string) {
    for (const args of [["secret", "sync", APP, "--json"], ["secret", "sync", APP, "--apply", "--json"]]) {
      const r = await runCli(args, rules);
      expect(r.code).toBe(1);
      expect(r.json.steps.find((x: any) => x.id === "argo").detail).toBe(detail);
      expect(r.json.error.next).toBe(next);
      expect(r.writes).toEqual([]);
    }
  }

  // #913 r2 P2-1: 실패한 과거 동기화가 지금 시도를 막는지는 Argo CD v3.5.5 alreadyAttemptedSync처럼 revision과 source 전체로
  // 가른다. secrets 키가 같아도 차트 버전만 바뀌었으면 새 시도다(회복 경로). 키 비교로 되돌리면 이 시험이 실패한다.
  describe("#913 r2 P2-1: 차트 버전만 바꾼 회복 경로", () => {
    const v110 = { repoURL: "https://github.com/ukyi-app/homelab", path: "platform/charts/app", targetRevision: "app-chart-v1.1.0", helm: { valuesObject: { kind: "web", secrets: ["API_TOKEN"] } } };
    const v100 = { ...v110, targetRevision: "app-chart-v1.0.0" };
    const failedOn = (source: object, revision = REV) => ({ phase: "Failed", retryCount: 10, syncResult: { source, revision } });
    const rules = (app: Resp) => world({ es: ES_GONE, app: [app], secret: SECRET_GONE, deploy: [deploy(null)] });

    test("새 source 조정 전(comparedTo가 옛 차트, 옛 Failed·SyncError가 남음): 대기(3), 쓰기 0, 반영 뒤 다시 치면 끝난다", async () => {
      await expectWaiting(rules(application({ spec: v110, compared: v100, sync: "OutOfSync", op: failedOn(v100), conditions: [{ type: "SyncError", message: "Failed last sync attempt" }] })), "Argo CD가 새 source를 비교하기를 기다림");
      const old = secret("old-value-1234567890");
      const again = await runCli(["secret", "sync", APP, "--apply", "--json"], world({ secret: [old, old, secret(FAKE_SECRETS[0])], deploy: UNTIL_DONE(deploy(MARK)) }));
      expect(again.code).toBe(0);
      expect(again.json.status).toBe("done");
    });

    test("새 source 조정 뒤 새 동기화 시작 전(마지막 결과는 옛 차트의 Failed): 대기(3)", async () => {
      await expectWaiting(rules(application({ spec: v110, sync: "OutOfSync", op: failedOn(v100) })), "Argo CD가 지금 source로 동기화를 시작하기를 기다림");
    });

    test("source는 같고 revision만 바뀜(태그가 다른 커밋): 새 시도라 대기(3)", async () => {
      await expectWaiting(rules(application({ spec: v110, sync: "OutOfSync", op: failedOn(v110, "b".repeat(40)) })), "Argo CD가 지금 source로 동기화를 시작하기를 기다림");
    });

    test("새 차트 태그가 깨져 비교가 실패하면(comparedTo는 새 차트, ComparisonError) 대기로 숨기지 않고 실패(1)", async () => {
      await expectFailed(rules(application({ spec: v110, sync: "Unknown", op: failedOn(v100), conditions: [{ type: "ComparisonError", message: "Failed to load target state" }] })), "ExternalSecret 없음, 앱 Application ComparisonError", STUCK_NEXT);
    });

    test("지금 revision·source로 실패한 동기화면 그대로 실패(1)", async () => {
      await expectFailed(rules(application({ spec: v110, sync: "OutOfSync", op: failedOn(v110) })), "ExternalSecret 없음, 동기화 Failed(재시도 10회 뒤 멈춤)", STUCK_NEXT);
    });

    test("status.sync.revision이 없으면 source만 보고 같은 source의 실패는 실패(1)로 둔다(r1 재시도 소진이 대기로 되돌아가지 않게)", async () => {
      const noRev: Resp = { stdout: JSON.stringify({ spec: { source: v110 }, status: { sync: { status: "OutOfSync", comparedTo: { source: v110 } }, operationState: failedOn(v110), conditions: [] } }) };
      await expectFailed(rules(noRev), "ExternalSecret 없음, 동기화 Failed(재시도 10회 뒤 멈춤)", STUCK_NEXT);
    });
  });

  // #913 r2 P2-2: 자식 Application이 없거나 values 전달 전이면 부모 ApplicationSet apps의 생성 오류를 본다.
  // 오류를 안 보면(되돌리면) 몇 번을 다시 쳐도 대기(3)로 끝난다.
  describe("#913 r2 P2-2: ApplicationSet 생성 오류", () => {
    const appsetError = (status: string): Resp => ({ stdout: JSON.stringify({ status: { conditions: [{ type: "ErrorOccurred", status, reason: "ApplicationGenerationFromParamsError", message: "x" }, { type: "ParametersGenerated", status: status === "True" ? "False" : "True" }] } }) });
    const noApp = [notFound(`applications.argoproj.io "${APP}"`)];

    test("자식 Application 없음 + ErrorOccurred=True: 실패(1), ApplicationSet 원인 확인 안내, 쓰기 0", async () => {
      await expectFailed(world({ es: ES_GONE, app: noApp, appset: [appsetError("True")], secret: SECRET_GONE, deploy: [DEPLOY_GONE] }), "ExternalSecret 없음, ApplicationSet apps ErrorOccurred(ApplicationGenerationFromParamsError)", APPSET_NEXT);
    });

    test("자식은 옛 values로 Synced + ErrorOccurred=True: 실패(1)", async () => {
      await expectFailed(world({ es: ES_GONE, app: [application({ spec: noSecrets })], appset: [appsetError("True")], secret: SECRET_GONE, deploy: [deploy(null)] }), "ExternalSecret 없음, ApplicationSet apps ErrorOccurred(ApplicationGenerationFromParamsError)", APPSET_NEXT);
    });

    test("ErrorOccurred=False는 오류가 아니다: 대기(3)", async () => {
      await expectWaiting(world({ es: ES_GONE, app: noApp, appset: [appsetError("False")], secret: SECRET_GONE, deploy: [DEPLOY_GONE] }), "ApplicationSet이 앱 Application을 만들기를 기다림");
    });

    test("ApplicationSet apps 자체가 없으면 실패(1), root 쪽 Application을 보라고 안내", async () => {
      await expectFailed(world({ es: ES_GONE, app: noApp, appset: [notFound(`applicationsets.argoproj.io "apps"`)], secret: SECRET_GONE, deploy: [DEPLOY_GONE] }), "ExternalSecret 없음, ApplicationSet apps 없음", "kubectl -n argocd get application appset-apps -o yaml로 ApplicationSet apps를 만드는 root 쪽 Application을 본다. 고친 뒤 같은 명령을 다시 실행한다");
    });
  });

  // #913 r2 기존: 첫 배포는 ExternalSecret(wave 0)이 먼저 생기고 Deployment(wave 2)는 마이그레이션 Job(wave 1) 뒤다.
  // 그 사이는 반영 중이라 대기다. Deployment 부재로 전체 읽기가 실패하던(failed/1) 것을 되돌리면 이 시험이 실패한다.
  describe("#913 r2: 첫 배포 wave 0 뒤 Deployment 전", () => {
    const esOnly = (app: Resp) => world({ app: [app], secret: [secret(FAKE_SECRETS[0])], deploy: [DEPLOY_GONE] });

    test("동기화 진행 중(ExternalSecret만 있음): 대기(3), 쓰기 0, Deployment가 생긴 뒤 다시 치면 끝난다", async () => {
      await expectWaiting(esOnly(application({ sync: "OutOfSync", op: { phase: "Running", retryCount: 0 } })), "Argo CD 동기화가 끝나기를 기다림");
      const again = await runCli(["secret", "sync", APP, "--apply", "--json"], world({ secret: [secret(FAKE_SECRETS[0])], deploy: UNTIL_DONE(deploy(MARK)) }));
      expect(again.code).toBe(0);
      expect(again.json.status).toBe("done");
    });

    test("마이그레이션 Job 실패로 동기화가 지금 source에서 멈춤: 실패(1)", async () => {
      await expectFailed(esOnly(application({ sync: "OutOfSync", op: { phase: "Failed", retryCount: 10, syncResult: { source: withSecrets, revision: REV } } })), "Deployment 없음, 동기화 Failed(재시도 10회 뒤 멈춤)", STUCK_NEXT);
    });

    test("Synced인데 Deployment 없음: 실패(1)", async () => {
      await expectFailed(esOnly(application({})), "Deployment 없음, 앱 Application은 Synced", STUCK_NEXT);
    });

    test("Deployment 조회가 없음이 아닌 이유로 실패하면 대기로 바꾸지 않는다", async () => {
      const r = await runCli(["secret", "sync", APP, "--json"], world({ secret: [secret(FAKE_SECRETS[0])], deploy: [deploy(null), { code: 1, stderr: "Unable to connect to the server\n" }] }));
      expect(r.code).toBe(1);
      expect(r.json.steps.find((x: any) => x.id === "restart").result).toBe("failed");
      expect(r.writes).toEqual([]);
    });
  });

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
    // argo 확인 단계는 Deployment가 있는지 get으로 본다. 가짜 세계의 deploys 표는 get에 보이지 않아 객체로도 둔다.
    w.put("deployment", NS, APP, { metadata: { name: APP } });
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
