import { describe, expect, test } from "bun:test";
import { argvFor as ghArgv } from "../../src/core/github";
import { FAKE_SECRETS, expectPlanReadOnly, ghGet, kubectlRule, rule, runCli, type Rule } from "../harness";
import { DIGEST, MAIN, R, folders, homelab, imageYaml, infisicalList, pullsPath } from "../fixtures/app-add-world/world";

const APP = "memo";
const NS = `app-${APP}`;
const VALUES = `chartVersion: 1.1.0\nkind: web\nport: 8080\nresources: { cpu: 50m, memory: 64Mi }\npublic: { host: memo.ukyi.app }\nsecrets: [API_TOKEN]\nuses: { postgres: true, valkey: true }\nmigration: { command: [bun, migrate.ts] }\n`;
const DATA = "chartVersion: 1.0.1\npostgres: { enabled: true }\nvalkey: { persistent: true }\n";
const json = (x: unknown) => ({ stdout: JSON.stringify(x) });
const get = (ns: string, res: string, name: string, x: unknown | null) => kubectlRule(["-n", ns, "get", res, name, "-o", "json"], x === null ? { code: 1, stderr: `Error from server (NotFound): ${res} "${name}" not found` } : json(x));
const READY = { conditions: [{ type: "Ready", status: "True" }] };
const synced = { status: { sync: { status: "Synced", revision: MAIN }, health: { status: "Healthy" } } };

const READY_POD = { metadata: {}, status: { phase: "Running", conditions: [{ type: "Ready", status: "True" }], containerStatuses: [{ imageID: `ghcr.io/ukyi-app/${APP}@${DIGEST}` }] } };
// 이 앱(postgres + 영속 Valkey + secrets)이 가져야 할 ExternalSecret(app 차트 셋 + 데이터 차트 둘). pg-role은 database ns.
const ALL_ES = [`${APP}-app`, `${APP}-db`, `${APP}-valkey-url`, `${APP}-valkey-auth`, `${APP}-valkey-backup-r2`];
// 차트가 만드는 ExternalSecret은 모두 store infisical-apps를 쓴다(app·app-data 차트 _helpers.tpl).
const STORE_REF = { secretStoreRef: { kind: "ClusterSecretStore", name: "infisical-apps" } };
const STORES = ["get", "clustersecretstores.external-secrets.io", "-A", "-o", "json"];
// Argo CD가 ExternalSecret 실패로 sync를 재시도하는 중(T13 S6·S7 실측 모양).
const RETRYING = { status: { sync: { status: "OutOfSync", revision: MAIN }, health: { status: "Degraded" }, operationState: { phase: "Running", message: "one or more synchronization tasks completed unsuccessfully. Retrying attempt #2 at 4:36AM." } } };
const storeDown = (reason: string) => ({ conditions: [{ type: "Ready", status: "False", reason, message: "unable to create client" }] });
type Opts = { esList?: string[]; pods?: unknown[]; esReady?: boolean; infisicalKeys?: Record<string, string>; migrate?: "ok" | "failed"; http?: number; argo?: unknown; store?: unknown; storesRead?: Rule };
function world(o: Opts = {}): Rule[] {
  const es = (name: string, ns = NS) => ({ metadata: { name, namespace: ns }, spec: STORE_REF, status: name === `${APP}-app` && o.esReady === false ? { conditions: [{ type: "Ready", status: "False", reason: "SecretSyncedError" }] } : READY });
  return [
    ...homelab({ [`apps/${APP}/values.yaml`]: VALUES, [`apps/${APP}/image.yaml`]: imageYaml(APP), [`data/${APP}/values.yaml`]: DATA }),
    ghGet(`repos/ukyi-app/${APP}/actions/runs?branch=main&per_page=1`, 200, { workflow_runs: [{ id: 5, run_number: 7, status: "completed", conclusion: "success" }] }),
    ghGet(pullsPath(`deploy/${APP}`), 200, []),
    get("argocd", "applications.argoproj.io", APP, "argo" in o ? o.argo : synced),
    get("argocd", "applications.argoproj.io", `${APP}-data`, synced),
    kubectlRule(["-n", NS, "get", "pods", "-l", `homelab.ukyi.app/app=${APP}`, "-o", "json"], json({ items: o.pods ?? [READY_POD] })),
    kubectlRule(["-n", NS, "get", "externalsecrets.external-secrets.io", "-o", "json"], json({ items: (o.esList ?? ALL_ES).map((n) => es(n)) })),
    get("database", "externalsecrets.external-secrets.io", `pg-role-${APP}`, es(`pg-role-${APP}`, "database")),
    o.storesRead ?? kubectlRule(STORES, json({ items: [{ metadata: { name: "infisical-apps" }, status: o.store ?? READY }] })),
    ...folders({ "/apps": [APP] }),
    infisicalList(`/apps/${APP}`, o.infisicalKeys ?? { API_TOKEN: FAKE_SECRETS[0] }),
    get("database", "databaseroles.postgresql.cnpg.io", APP, { status: { applied: true } }),
    get("database", "databases.postgresql.cnpg.io", APP, { status: { applied: true } }),
    get(NS, "jobs.batch", `${APP}-migrate`, { status: o.migrate === "failed" ? { failed: 1 } : { succeeded: 1 } }),
    get(NS, "deployments.apps", `${APP}-valkey`, { status: { availableReplicas: 1 } }),
    get(NS, "cronjobs.batch", `${APP}-valkey-backup`, { status: { lastSuccessfulTime: "2026-10-25T18:30:00Z" } }),
    rule(ghArgv.web("memo.ukyi.app", "/healthz"), { stdout: String(o.http ?? 200) }),
  ];
}

describe("status <app>", () => {
  test("모두 준비됨: exit 0, 다음 없음, 쓰기 0건, 값 없음", async () => {
    const r = await runCli(["status", APP, "--json"], world());
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.steps.map((s: any) => s.id)).toEqual(["registered", "build", "deploy-pr", `argocd-${APP}`, `argocd-${APP}-data`, "pods", "secrets", "postgres", "valkey", "public"]);
    expect(r.json.steps.every((s: any) => s.state === "same")).toBe(true);
    expect(r.json.next).toBeNull();
    const h = await runCli(["status", APP], world());
    expect(h.stdout.split("\n")[0]).toBe(`homelab status ${APP}`);
    expect(h.stdout).toContain("6/6 Ready");
  });

  test("시나리오 6: Infisical에 없는 키를 이름으로 보이고 secret set으로 안내(exit 1)", async () => {
    const r = await runCli(["status", APP, "--json"], world({ esReady: false, infisicalKeys: {} }));
    expect(r.code).toBe(1);
    expectPlanReadOnly(r);
    const s = r.json.steps.find((x: any) => x.id === "secrets");
    expect(s.detail).toContain("Infisical에 없음: API_TOKEN");
    expect(r.json.error.next).toBe(`homelab secret set ${APP} API_TOKEN`);
  });

  // T13 S6: 앞 줄(Argo CD)이 이 실패로 재시도 중이라 다음이 "잠시 뒤 다시"였다. 원인을 아는 줄이 먼저다.
  test("시나리오 6: Argo CD 재시도 중이어도 다음은 secret set(T13 S6)", async () => {
    const rules = world({ esReady: false, infisicalKeys: {}, argo: RETRYING });
    const r = await runCli(["status", APP, "--json"], rules);
    expect(r.code).toBe(1);
    expectPlanReadOnly(r);
    expect(r.json.steps.find((x: any) => x.id === `argocd-${APP}`).result).toBe("failed");
    expect(r.json.error).toEqual({ message: `시크릿(ExternalSecret): 5/6 Ready: ${APP}-app. Infisical에 없음: API_TOKEN`, next: `homelab secret set ${APP} API_TOKEN` });
    expect(r.json.next).toBe(`homelab secret set ${APP} API_TOKEN`);
    const h = await runCli(["status", APP], rules);
    expect(h.stdout).toContain(`다음: homelab secret set ${APP} API_TOKEN`);
    expect(h.stdout).not.toContain("잠시 뒤 다시");
  });

  // T13 S7: ExternalSecret 실패만 보이고 원인(Infisical 인증 실패)을 말하지 않았다.
  test("시나리오 7: Store Ready=False면 원인 줄과 부트스트랩 Secret 안내(T13 S7)", async () => {
    const r = await runCli(["status", APP, "--json"], world({ esReady: false, store: storeDown("InvalidProviderConfig"), argo: RETRYING }));
    expect(r.code).toBe(1);
    expectPlanReadOnly(r);
    const detail = `5/6 Ready: ${APP}-app. Infisical 인증 실패: ClusterSecretStore infisical-apps Ready=False InvalidProviderConfig`;
    expect(r.json.steps.find((x: any) => x.id === "secrets").detail).toBe(detail);
    const next = "부트스트랩 Secret external-secrets/infisical-universal-auth의 ESO 자격을 확인한다(docs/runbooks-public/rotate.md 1절)";
    expect(r.json.error).toEqual({ message: `시크릿(ExternalSecret): ${detail}`, next });
    // 키도 빠졌으면 둘 다 보이고 다음은 Store가 먼저다(인증이 풀리기 전에는 키를 넣어도 동기화되지 않는다).
    const both = await runCli(["status", APP, "--json"], world({ esReady: false, store: storeDown("InvalidProviderConfig"), infisicalKeys: {} }));
    expect(both.json.steps.find((x: any) => x.id === "secrets").detail).toBe(`${detail}. Infisical에 없음: API_TOKEN`);
    expect(both.json.next).toBe(next);
    // 다른 이유(폴더 없음 등)는 이유 이름과 Store를 보는 명령.
    const other = await runCli(["status", APP, "--json"], world({ esReady: false, store: storeDown("ValidationFailed") }));
    expect(other.json.steps.find((x: any) => x.id === "secrets").detail).toContain("ClusterSecretStore infisical-apps Ready=False ValidationFailed");
    expect(other.json.next).toContain("kubectl get clustersecretstore infisical-apps -o yaml");
    expect(other.json.next).toContain("docs/runbooks-public/bootstrap.md 2.2");
  });

  test("Store가 Ready면 원인으로 보지 않고, Store 읽기 실패는 그 줄의 읽기 실패다", async () => {
    const r = await runCli(["status", APP, "--json"], world({ esReady: false }));
    expect(r.code).toBe(1);
    expect(r.json.next).toBe(`kubectl -n ${NS} describe externalsecret ${APP}-app`);
    const down = await runCli(["status", APP, "--json"], world({ esReady: false, storesRead: kubectlRule(STORES, { code: 1, stderr: "Unable to connect to the server" }) }));
    expect(down.code).toBe(1);
    expectPlanReadOnly(down);
    const s = down.json.steps.find((x: any) => x.id === "secrets");
    expect([s.detail, s.result]).toEqual(["읽지 못함", "failed"]);
    expect(down.json.error.message).toContain("시크릿(ExternalSecret)");
  });

  test("ExternalSecret이 모두 Ready면 Store를 읽지 않는다", async () => {
    const r = await runCli(["status", APP, "--json"], world());
    expect(r.code).toBe(0);
    expect(r.calls.some((c) => c.argv.includes("clustersecretstores.external-secrets.io"))).toBe(false);
  });

  test("마이그레이션 실패는 logs --job migrate로, 공개 URL 실패도 문제로", async () => {
    const r = await runCli(["status", APP, "--json"], world({ migrate: "failed", http: 502 }));
    expect(r.code).toBe(1);
    expect(r.json.error.next).toBe(`homelab logs ${APP} --job migrate`);
    expect(r.json.steps.find((x: any) => x.id === "public").state).toBe("differs");
  });

  test("Application이 아직 없으면 missing + 기다림 안내", async () => {
    const r = await runCli(["status", APP, "--json"], world({ argo: null }));
    expect(r.code).toBe(1);
    expect(r.json.steps.find((x: any) => x.id === `argocd-${APP}`).state).toBe("missing");
  });

  test("GitHub 조회 실패(403·429)를 '기록 없음'·'PR 없음'으로 숨기지 않는다(#884 P2-5)", async () => {
    const swap = (match: string, status: number) => world().map((x) => (String(x.argv.at(-1)) === match ? ghGet(match, status, { message: "x" }) : x));
    for (const [path, id] of [[`repos/ukyi-app/${APP}/actions/runs?branch=main&per_page=1`, "build"], [pullsPath(`deploy/${APP}`), "deploy-pr"]] as const) {
      for (const status of [403, 429]) {
        const r = await runCli(["status", APP, "--json"], swap(path, status));
        expect(r.code).toBe(1);
        expect(r.json.steps.find((s: any) => s.id === id).result).toBe("failed");
        expect(r.json.error.message).toContain(`HTTP ${status}`);
      }
    }
    // 정상 빈 목록은 실패가 아니다.
    const empty = await runCli(["status", APP, "--json"], world().map((x) => (String(x.argv.at(-1)) === `repos/ukyi-app/${APP}/actions/runs?branch=main&per_page=1` ? ghGet(`repos/ukyi-app/${APP}/actions/runs?branch=main&per_page=1`, 200, { workflow_runs: [] }) : x)));
    expect(empty.code).toBe(0);
    expect(empty.json.steps.find((s: any) => s.id === "build").detail).toBe("기록 없음");
  });

  test("DB 역할 ExternalSecret·백업 CronJob이 없으면 준비됨으로 보지 않는다(없음을 정상으로 읽지 않기)", async () => {
    const noRole = world().map((x) => (x.argv.includes(`pg-role-${APP}`) ? get("database", "externalsecrets.external-secrets.io", `pg-role-${APP}`, null) : x));
    const a = await runCli(["status", APP, "--json"], noRole);
    expect(a.code).toBe(1);
    expect(a.json.steps.find((s: any) => s.id === "secrets").detail).toContain(`pg-role-${APP}`);
    const noCron = world().map((x) => (x.argv.includes(`${APP}-valkey-backup`) ? get(NS, "cronjobs.batch", `${APP}-valkey-backup`, null) : x));
    const b = await runCli(["status", APP, "--json"], noCron);
    expect(b.code).toBe(1);
    expect(b.json.steps.find((s: any) => s.id === "valkey").state).toBe("missing");
  });

  test("values가 선언한 앱 ExternalSecret(<app>-app)이 없으면 0/0 Ready로 보지 않는다(#884 2라운드 P2-6)", async () => {
    const r = await runCli(["status", APP, "--json"], world({ esList: ALL_ES.filter((n) => n !== `${APP}-app`) }));
    expect(r.code).toBe(1);
    const s = r.json.steps.find((x: any) => x.id === "secrets");
    expect(s.state).toBe("differs");
    expect(s.detail).toContain(`${APP}-app`);
  });

  test("영속 Valkey(데이터 차트)의 -valkey-auth·-valkey-backup-r2가 없으면 준비 안 됨(#890 1라운드 P2-2)", async () => {
    for (const lost of [`${APP}-valkey-auth`, `${APP}-valkey-backup-r2`]) {
      const r = await runCli(["status", APP, "--json"], world({ esList: ALL_ES.filter((n) => n !== lost) }));
      expect(r.code).toBe(1);
      expectPlanReadOnly(r);
      const s = r.json.steps.find((x: any) => x.id === "secrets");
      expect(s.state).toBe("differs");
      expect(s.detail).toContain(lost);
    }
  });

  test("끝난 파드(퇴거된 옛 ReplicaSet 파드 Failed)는 준비 집계에서 뺀다(Connector 4373412611)", async () => {
    const evicted = { metadata: {}, status: { phase: "Failed", reason: "Evicted", conditions: [{ type: "Ready", status: "False" }], containerStatuses: [] } };
    const r = await runCli(["status", APP, "--json"], world({ pods: [READY_POD, evicted] }));
    expect(r.code).toBe(0);
    expect(r.json.steps.find((x: any) => x.id === "pods").detail).toBe("1/1 Ready, imageID = image.yaml");
  });

  test("등록 안 된 앱은 app add로 안내하고 클러스터를 읽지 않는다", async () => {
    const rules = [...homelab({ [`apps/${APP}/values.yaml`]: null, [`apps/${APP}/image.yaml`]: null, [`data/${APP}/values.yaml`]: null }), ghGet(`repos/ukyi-app/${APP}/actions/runs?branch=main&per_page=1`, 200, { workflow_runs: [] }), ghGet(pullsPath(`deploy/${APP}`), 200, [])];
    const r = await runCli(["status", APP, "--json"], rules);
    expect(r.code).toBe(1);
    expect(r.json.error.next).toBe(`homelab app add ${APP}`);
    expect(r.calls.some((c) => c.argv[0] === "kubectl")).toBe(false);
  });
});

describe("status(전체·--platform)", () => {
  test("전체 보기는 data/도 연다: 앱 없는 데이터·<app>-data 장애를 보인다(#884 P2-4)", async () => {
    const degraded = { status: { sync: { status: "OutOfSync" }, health: { status: "Degraded" } } };
    const rules = [
      ...homelab({}),
      ghGet(`${R}/contents/apps?ref=${MAIN}`, 200, [{ name: APP, type: "dir" }]),
      ghGet(`${R}/contents/data?ref=${MAIN}`, 200, [{ name: APP, type: "dir" }, { name: "db-only", type: "dir" }]),
      get("argocd", "applications.argoproj.io", APP, synced),
      get("argocd", "applications.argoproj.io", `${APP}-data`, degraded),
      get("argocd", "applications.argoproj.io", "db-only-data", degraded),
    ];
    const r = await runCli(["status", "--json"], rules);
    expect(r.code).toBe(1);
    expectPlanReadOnly(r);
    expect(r.json.steps.map((s: any) => [s.id, s.state])).toEqual([["argocd-db-only-data", "differs"], [`argocd-${APP}`, "same"], [`argocd-${APP}-data`, "differs"]]);
    const fail = rules.map((x) => (String(x.argv.at(-1)) === `${R}/contents/data?ref=${MAIN}` ? ghGet(`${R}/contents/data?ref=${MAIN}`, 500, {}) : x));
    expect((await runCli(["status", "--json"], fail)).code).toBe(1);
  });

  test("앱마다 Argo CD 한 줄, --platform은 플랫폼 줄", async () => {
    const rules = [
      ...homelab({}),
      ghGet(`${R}/contents/apps?ref=${MAIN}`, 200, [{ name: APP, type: "dir" }]),
      ghGet(`${R}/contents/data?ref=${MAIN}`, 200, [{ name: APP, type: "dir" }]),
      get("argocd", "applications.argoproj.io", `${APP}-data`, synced),
      get("argocd", "applications.argoproj.io", APP, synced),
      kubectlRule(["-n", "argocd", "get", "applications.argoproj.io", "-o", "json"], json({ items: [{ metadata: { name: "traefik" }, spec: { project: "platform" }, ...synced }, { metadata: { name: "memo" }, spec: { project: "apps" }, status: {} }] })),
      kubectlRule(["get", "nodes", "-A", "-o", "json"], json({ items: [{ metadata: { name: "nuc" }, status: READY }] })),
      get("database", "clusters.postgresql.cnpg.io", "pg", { status: { phase: "Cluster in healthy state" } }),
      kubectlRule(["get", "clustersecretstores.external-secrets.io", "-A", "-o", "json"], json({ items: [{ metadata: { name: "infisical-apps" }, status: READY }] })),
    ];
    const all = await runCli(["status", "--json"], rules);
    expect(all.code).toBe(0);
    expectPlanReadOnly(all);
    expect(all.json.steps.map((s: any) => s.id)).toEqual([`argocd-${APP}`, `argocd-${APP}-data`]);
    const plat = await runCli(["status", "--platform", "--json"], rules);
    expect(plat.code).toBe(0);
    expectPlanReadOnly(plat);
    expect(plat.json.steps.map((s: any) => s.detail)).toEqual(["1개 Synced·Healthy", "1개 Ready", "Cluster in healthy state", "1개 Ready"]);
  });

  // T13 S7: Store가 Degraded면 플랫폼 Application 줄이 먼저 실패한다. 다음은 원인(Store)의 것이다.
  test("--platform: Store Ready=False면 원인 줄과 부트스트랩 Secret 안내", async () => {
    const down = storeDown("InvalidProviderConfig");
    const rules = [
      ...homelab({}),
      kubectlRule(["-n", "argocd", "get", "applications.argoproj.io", "-o", "json"], json({ items: [{ metadata: { name: "external-secrets-stores" }, spec: { project: "platform" }, status: { sync: { status: "Synced" }, health: { status: "Degraded" } } }] })),
      kubectlRule(["get", "nodes", "-A", "-o", "json"], json({ items: [{ metadata: { name: "nuc" }, status: READY }] })),
      get("database", "clusters.postgresql.cnpg.io", "pg", { status: { phase: "Cluster in healthy state" } }),
      kubectlRule(STORES, json({ items: [{ metadata: { name: "infisical-apps" }, status: down }, { metadata: { name: "infisical-platform" }, status: down }] })),
    ];
    const r = await runCli(["status", "--platform", "--json"], rules);
    expect(r.code).toBe(1);
    expectPlanReadOnly(r);
    const detail = "Infisical 인증 실패: ClusterSecretStore infisical-apps Ready=False InvalidProviderConfig, Infisical 인증 실패: ClusterSecretStore infisical-platform Ready=False InvalidProviderConfig";
    expect(r.json.steps.find((s: any) => s.id === "secret-stores").detail).toBe(detail);
    expect(r.json.error).toEqual({ message: `ClusterSecretStore: ${detail}`, next: "부트스트랩 Secret external-secrets/infisical-universal-auth의 ESO 자격을 확인한다(docs/runbooks-public/rotate.md 1절)" });
  });
});
