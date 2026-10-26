import { describe, expect, test } from "bun:test";
import { cacheOff, cacheOn, persistentData, usesValkey } from "../../src/commands/cache-add";
import { FAKE_SECRETS, expectNoSecrets, expectPlanReadOnly, infisicalSet, kubectlRule, runCli, type Rule } from "../harness";
import { chartTags, folders, homelab, infisicalList, noPr, prCreate, prOpen } from "../fixtures/app-add-world/world";

// 타임아웃 주입(스텁 5초 지연 > exec 상한 3초)이 든 시험은 3초를 넘는다. bun 기본 시험 제한(5초)에 걸리지 않게 늘린다.
const SLOW = 20_000;
const APP = "memo";
const BRANCH = `cli/cache-add-${APP}`;
const A = `apps/${APP}/values.yaml`;
const D = `data/${APP}/values.yaml`;
const VK = `/apps/${APP}/valkey`;
const BASE = "chartVersion: 1.0.0\nkind: web\nport: 8080\nresources: { cpu: 50m, memory: 64Mi }\nuses: { postgres: true }\n";
const CACHED = cacheOn(BASE, "1.1.0")!;
const fold = () => folders({ "/apps": [APP], [`/apps/${APP}`]: ["valkey"] });
const has = { stdout: JSON.stringify([{ secretKey: "PASSWORD", secretValue: FAKE_SECRETS[0] }]) };
const none = { stdout: "[]" };
const argoApp = (resources: { kind: string; name: string }[]) => kubectlRule(["-n", "argocd", "get", "applications.argoproj.io", APP, "-o", "json"], { stdout: JSON.stringify({ status: { resources } }) });

describe("cache add(캐시)", () => {
  test("plan: 차트 1.0.0 → 1.1.0, cache·uses.valkey", async () => {
    const r = await runCli(["cache", "add", APP, "--json"], [...homelab({ [A]: BASE, [D]: null }), ...chartTags(), ...fold(), infisicalList(VK, {}), noPr(BRANCH)]);
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.steps.find((s: any) => s.id === "pr").detail).toContain("cache.enabled false → true, chart 1.1.0");
    expect(CACHED).toContain("uses: { postgres: true, valkey: true }");
  });

  test("apply: 비밀번호 → PR, 실패 주입, 다 된 상태 same", async () => {
    const rules = (code = 0, sleep?: number): Rule[] => [...homelab({ [A]: BASE, [D]: null }), ...chartTags(), ...fold(), infisicalList(VK, [none, none, none, has]), infisicalSet(VK, { code, sleepMs: sleep }), ...prCreate(BRANCH, "cache add", { [A]: CACHED })];
    const ok = await runCli(["cache", "add", APP, "--apply", "--json"], rules());
    expect(ok.code).toBe(3);
    expectNoSecrets(ok);
    const failed = await runCli(["cache", "add", APP, "--apply", "--json"], rules(1));
    expect(failed.code).toBe(1);
    expect(failed.json.steps.find((s: any) => s.id === "pr").result).toBe("not-run");
    const slow = await runCli(["cache", "add", APP, "--apply", "--json"], rules(0, 5000));
    expect(slow.code).toBe(3);
    const done = await runCli(["cache", "add", APP, "--apply", "--json"], [...homelab({ [A]: CACHED, [D]: null }), ...chartTags(), ...fold(), infisicalList(VK, [has]), noPr(BRANCH)]);
    expect(done.code).toBe(0);
    expect(done.json.steps.every((s: any) => s.state === "same")).toBe(true);
    expect(done.writes).toEqual([]);
  }, SLOW);

  test("이미 영속이면 캐시를 켜지 않는다", async () => {
    const r = await runCli(["cache", "add", APP, "--json"], [...homelab({ [A]: usesValkey(BASE)!, [D]: "chartVersion: 1.0.1\nvalkey: { persistent: true }\n" }), ...chartTags(), ...fold(), infisicalList(VK, [has]), noPr(BRANCH)]);
    expect(r.code).toBe(1);
    expectPlanReadOnly(r);
  });
});

describe("cache add --persistent(캐시 → 영속, PR 둘)", () => {
  const OFF = cacheOff(CACHED)!;
  const DATA = persistentData(null, "1.0.1")!;
  const ON = usesValkey(OFF)!;

  test("단계 A: 캐시가 켜져 있으면 캐시 끄기 PR만(T11 #859)", async () => {
    expect(OFF).toBe("chartVersion: 1.1.0\nkind: web\nport: 8080\nresources: { cpu: 50m, memory: 64Mi }\nuses: { postgres: true }\n");
    const r = await runCli(["cache", "add", APP, "--persistent", "--apply", "--json"], [...homelab({ [A]: CACHED, [D]: null }), ...chartTags(), ...prCreate(BRANCH, "cache add", { [A]: OFF })]);
    expect(r.code).toBe(3);
    expect(r.json.steps.map((s: any) => s.id)).toEqual(["registered", "pr"]);
    expect(r.json.notes.join(" ")).toContain("영속 전환 1/2");
    expect(r.calls.some((c) => c.argv[0] === "infisical")).toBe(false);
  });

  test("단계 B: 앱 Application에 캐시 서버 리소스가 남아 있으면 대기(3), 뒤 단계 not-run, 쓰기 0건", async () => {
    const rules = [...homelab({ [A]: OFF, [D]: null }), ...chartTags(), argoApp([{ kind: "ExternalSecret", name: `${APP}-valkey-auth` }, { kind: "ExternalSecret", name: `${APP}-valkey-url` }, { kind: "Deployment", name: APP }]), ...fold(), infisicalList(VK, [has]), noPr(BRANCH)];
    const plan = await runCli(["cache", "add", APP, "--persistent", "--json"], rules);
    expect(plan.code).toBe(0);
    expectPlanReadOnly(plan);
    const r = await runCli(["cache", "add", APP, "--persistent", "--apply", "--json"], rules);
    expect(r.code).toBe(3);
    const byId = Object.fromEntries(r.json.steps.map((s: any) => [s.id, s.result]));
    expect(byId["cache-gone"]).toBe("waiting");
    expect(byId.pr).toBe("not-run");
    expect(r.writes).toEqual([]);
  });

  test("단계 B: 정리됐으면 캐시 때 비밀번호를 재사용하고 영속 PR(T11 #860)", async () => {
    const rules = [...homelab({ [A]: OFF, [D]: null }), ...chartTags(), argoApp([{ kind: "Deployment", name: APP }]), ...fold(), infisicalList(VK, [has]), ...prCreate(BRANCH, "cache add", { [D]: DATA, [A]: ON })];
    const r = await runCli(["cache", "add", APP, "--persistent", "--apply", "--json"], rules);
    expect(r.code).toBe(3);
    expect(r.calls.some((c) => c.argv[0] === "infisical" && c.argv[2] === "set")).toBe(false);
    expect(DATA).toContain("valkey: { persistent: true }");
    expectNoSecrets(r);
  });

  test("다 됐으면(영속이 데이터 Application 몫) 모두 same. 앱 몫인 연결 ExternalSecret <app>-valkey-url은 기다리지 않는다(#884 P2-1)", async () => {
    // app 차트 1.1.0의 영속 연결 렌더 그대로(helm template로 확인).
    const rendered = [{ kind: "NetworkPolicy", name: APP }, { kind: "Service", name: APP }, { kind: "Deployment", name: APP }, { kind: "ExternalSecret", name: `${APP}-valkey-url` }];
    const rules = [...homelab({ [A]: ON, [D]: DATA }), ...chartTags(), argoApp(rendered), ...fold(), infisicalList(VK, [has]), noPr(BRANCH)];
    const r = await runCli(["cache", "add", APP, "--persistent", "--apply", "--json"], rules);
    expect(r.code).toBe(0);
    expect(r.json.steps.every((s: any) => s.state === "same")).toBe(true);
    expect(r.writes).toEqual([]);
  });

  test("영속 단계 A의 PR이 열려 있으면 대기", async () => {
    const r = await runCli(["cache", "add", APP, "--persistent", "--apply", "--json"], [...homelab({ [A]: CACHED, [D]: null }), ...chartTags(), ...prOpen(BRANCH, "cache add", { [A]: OFF })]);
    expect(r.code).toBe(3);
    expect(r.writes).toEqual([]);
  });

  test("이름 한도: 영속 38자, 캐시 51자·valkey 금지", async () => {
    expect((await runCli(["cache", "add", "a".repeat(39), "--persistent"], [])).code).toBe(64);
    expect((await runCli(["cache", "add", "x-valkey"], [])).code).toBe(64);
  });
});
