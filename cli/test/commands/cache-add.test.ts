import { describe, expect, test } from "bun:test";
import { cacheOff, cacheOn, cacheOnSummary, persistentData, usesValkey } from "../../src/commands/cache-add";
import { FAKE_SECRETS, expectNoSecrets, expectPlanReadOnly, ghGet, ghResponse, infisicalSet, kubectlRule, runCli, type Rule } from "../harness";
import { MAIN, R, chartTags, contentsPath, fileJson, folders, homelab, infisicalList, noPr, prCreate, prOpen } from "../fixtures/app-add-world/world";

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
    expect(r.json.steps.find((s: any) => s.id === "pr").detail).toContain(`${A}: cache.enabled false → true, uses.valkey false → true, chart 1.1.0`);
    expect(CACHED).toContain("uses: { postgres: true, valkey: true }");
  });

  // T13 S3 #932: 표에 cache.enabled만 보이고 uses.valkey 변경이 빠졌다. 바뀌는 키만, 빠짐없이.
  test("PR 줄 요약: 바뀌는 키를 모두, 그대로인 키는 빼고", () => {
    expect(cacheOnSummary(BASE, CACHED)).toBe("cache.enabled false → true, uses.valkey false → true, chart 1.1.0");
    const valkeyOnly = "chartVersion: 1.1.0\nkind: web\nuses: { valkey: true }\n";
    expect(cacheOnSummary(valkeyOnly, cacheOn(valkeyOnly, "1.1.0"))).toBe("cache.enabled false → true");
    const cacheOnly = "chartVersion: 1.1.0\nkind: web\ncache: { enabled: true }\n";
    expect(cacheOnSummary(cacheOnly, cacheOn(cacheOnly, "1.1.0"))).toBe("uses.valkey false → true");
  });

  test("apply: 비밀번호 → PR, 실패 주입, 다 된 상태 same", async () => {
    const rules = (code = 0, sleep?: number): Rule[] => [...homelab({ [A]: BASE, [D]: null }), ...chartTags(), ...fold(), infisicalList(VK, [none, none, none, has]), infisicalSet(VK, { code, sleepMs: sleep }), ...prCreate(BRANCH, "cache add", { [A]: CACHED }, { readOnly: { [D]: null } })];
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

  test("이름 한도: 영속 38자, 캐시 51자, valkey 금지는 캐시·영속 둘 다(#884 2라운드 P2-3)", async () => {
    expect((await runCli(["cache", "add", "a".repeat(39), "--persistent"], [])).code).toBe(64);
    expect((await runCli(["cache", "add", "x-valkey"], [])).code).toBe(64);
    const r = await runCli(["cache", "add", "my-valkey", "--persistent", "--apply"], []);
    expect(r.code).toBe(64);
    expect(r.calls).toEqual([]);
  });

  test("꺼진 캐시(cache: { enabled: false })가 적힌 영속 앱은 전환 대상이 아니다: 연결을 지우지 않고 모두 same(#884 2라운드 P2-1, Connector 4373412607)", async () => {
    const disabled = `${ON}cache: { enabled: false }\n`;
    const rendered = [{ kind: "Deployment", name: APP }, { kind: "ExternalSecret", name: `${APP}-valkey-url` }];
    const r = await runCli(["cache", "add", APP, "--persistent", "--apply", "--json"], [...homelab({ [A]: disabled, [D]: DATA }), ...chartTags(), argoApp(rendered), ...fold(), infisicalList(VK, [has]), noPr(BRANCH)]);
    expect(r.code).toBe(0);
    expect(r.json.steps.map((s: any) => s.id)).toEqual(["registered", "cache-gone", "infisical-password", "pr"]);
    expect(r.json.steps.every((s: any) => s.state === "same")).toBe(true);
    expect(r.writes).toEqual([]);
  });

  test("PR 계산 때의 main에서 단계 전제를 다시 본다: 그사이 캐시가 켜졌으면 영속 PR을 만들지 않는다(#884 2라운드 P2-2)", async () => {
    const MAIN2 = "7".repeat(40);
    const rules = [
      // 명령 시작은 MAIN(캐시 꺼짐 → 단계 B), PR 계산은 MAIN2(그사이 캐시 등록이 병합됨).
      ghGet(`${R}/git/ref/heads/main`, [ghResponse(200, { object: { sha: MAIN } }), ghResponse(200, { object: { sha: MAIN2 } })]),
      ghGet(contentsPath(A), 200, fileJson(OFF)),
      ghGet(contentsPath(D), 404, {}),
      ghGet(contentsPath(A, MAIN2), 200, fileJson(CACHED)),
      ghGet(contentsPath(D, MAIN2), 404, {}),
      ...chartTags(),
      argoApp([{ kind: "Deployment", name: APP }]),
      ...fold(),
      infisicalList(VK, [has]),
      noPr(BRANCH),
    ];
    const r = await runCli(["cache", "add", APP, "--persistent", "--apply", "--json"], rules);
    expect(r.code).toBe(1);
    expect(r.json.error.message).toContain("그사이 main에 캐시 Valkey가 켜졌다");
    expect(r.writes).toEqual([]);
  });

  test("시작 때 없던 data 파일도 PR 계산 때의 main에서 읽는다: 그사이 영속이 등록됐으면 캐시 PR을 만들지 않는다(#890 1라운드 P2-1)", async () => {
    const MAIN2 = "7".repeat(40);
    const rules = [
      ghGet(`${R}/git/ref/heads/main`, [ghResponse(200, { object: { sha: MAIN } }), ghResponse(200, { object: { sha: MAIN2 } })]),
      ghGet(contentsPath(A), 200, fileJson(BASE)),
      ghGet(contentsPath(D), 404, {}),
      ghGet(contentsPath(A, MAIN2), 200, fileJson(BASE)),
      ghGet(contentsPath(D, MAIN2), 200, fileJson("chartVersion: 1.0.2\nvalkey: { persistent: true }\n")),
      ...chartTags(),
      ...fold(),
      infisicalList(VK, [has]),
      noPr(BRANCH),
    ];
    const r = await runCli(["cache", "add", APP, "--apply", "--json"], rules);
    expect(r.code).toBe(1);
    expect(r.json.error.message).toContain("그사이 main에 영속 Valkey가 켜졌다");
    expect(r.writes).toEqual([]);
  });

  test("읽기만 하는 data 파일이 없으면(null → null) tree에 넣지 않는다(없는 경로 삭제를 보내지 않는다, #890 1라운드 P2-4)", async () => {
    const r = await runCli(["cache", "add", APP, "--apply", "--json"], [...homelab({ [A]: BASE, [D]: null }), ...chartTags(), ...fold(), infisicalList(VK, [has]), ...prCreate(BRANCH, "cache add", { [A]: CACHED }, { readOnly: { [D]: null } })]);
    expect(r.code).toBe(3);
    const tree = r.calls.find((c) => c.argv.includes(`${R}/git/trees`))!;
    expect(JSON.parse(tree.stdin!).tree.map((t: any) => t.path)).toEqual([A]);
  });

  test("env 이름 충돌(values env.VALKEY_URL)은 쓰기 전에 멈춘다(#884 2라운드 P2-4)", async () => {
    const withEnv = `${BASE}env: { VALKEY_URL: redis://x }\n`;
    const r = await runCli(["cache", "add", APP, "--apply", "--json"], [...homelab({ [A]: withEnv, [D]: null }), ...chartTags(), ...fold(), infisicalList(VK, {}), noPr(BRANCH)]);
    expect(r.code).toBe(1);
    expect(r.json.error.message).toContain("VALKEY_URL");
    expect(r.writes).toEqual([]);
  });
});
