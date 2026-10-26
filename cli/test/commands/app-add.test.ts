import { describe, expect, test } from "bun:test";
import { attestationMatches, passwordStep } from "../../src/commands/app-add";
import { appValues, dataValues, describeFile, imageText, parseImage } from "../../src/commands/app-add-values";
import { argvFor as infArgv } from "../../src/core/infisical";
import { FAKE_PROJECT, FAKE_SECRETS, applyWith, expectNoSecrets, expectPlanReadOnly, ghGet, ghResponse, infisicalSet, kubectlRule, runCli, testCtx, type Rule } from "../harness";
import { APP_HEAD, DIGEST, appRepo, attestation, chartTags, createFolder, folders, homelab, imageYaml, infisicalList, noPr, prCreate, prOpen } from "../fixtures/app-add-world/world";

// 타임아웃 주입(스텁 5초 지연 > exec 상한 3초)이 든 시험은 3초를 넘는다. bun 기본 시험 제한(5초)에 걸리지 않게 늘린다.
const SLOW = 20_000;
const APP = "memo";
const BRANCH = `cli/app-add-${APP}`;
const P = { values: `apps/${APP}/values.yaml`, image: `apps/${APP}/image.yaml`, data: `data/${APP}/values.yaml` };
const FLAGS = { public: "memo.ukyi.app", postgres: true, cache: "persistent" as const };
const ARGS = ["app", "add", APP, "--public", "memo.ukyi.app", "--postgres", "--cache=persistent"];

const wantValues = appValues(null, FLAGS, { secrets: [], latestChart: "1.1.0" })!;
const wantData = dataValues(null, FLAGS, "1.0.1")!;
const wantImage = imageText({ repository: `ghcr.io/ukyi-app/${APP}`, digest: DIGEST, revision: APP_HEAD, hold: false });
const done = { [P.values]: wantValues, [P.image]: wantImage, [P.data]: wantData };

// --cache=persistent의 캐시 정리 대기(cache-gone)가 읽는 앱 Application. 기본은 캐시 리소스 없음.
const argo = (resources: { kind: string; name: string }[] = []) => kubectlRule(["-n", "argocd", "get", "applications.argoproj.io", APP, "-o", "json"], { stdout: JSON.stringify({ status: { resources } }) });
const pg = `/apps/${APP}/postgres`;
const vk = `/apps/${APP}/valkey`;
const allFolders = () => folders({ "/apps": [APP], [`/apps/${APP}`]: ["postgres", "valkey"] });

// 다 된 상태: main에 세 파일, Infisical에 두 비밀번호(값은 가짜 시크릿).
function doneWorld(): Rule[] {
  return [...homelab(done), ...chartTags(), argo(), ...appRepo(APP), ...allFolders(), infisicalList(`/apps/${APP}`, {}), infisicalList(pg, { PASSWORD: FAKE_SECRETS[0] }), infisicalList(vk, { PASSWORD: FAKE_SECRETS[1] }), noPr(BRANCH)].flat();
}

// 새 앱: main에 아무것도 없고 폴더는 있지만 비밀번호는 없다. 비밀번호 목록은 [전체 읽기, 직전 읽기, apply 안, 재조회] 순서.
function newWorld(opts: { setCode?: number; setSleep?: number; tree?: number } = {}): Rule[] {
  const none = { stdout: "[]" };
  const has = (v: string) => ({ stdout: JSON.stringify([{ secretKey: "PASSWORD", secretValue: v }]) });
  return [
    ...homelab({ [P.values]: null, [P.image]: null, [P.data]: null }),
    ...chartTags(), argo(),
    ...appRepo(APP),
    ...allFolders(),
    infisicalList(`/apps/${APP}`, {}),
    infisicalList(pg, [none, none, none, has(FAKE_SECRETS[0])]),
    infisicalList(vk, [none, none, none, has(FAKE_SECRETS[1])]),
    infisicalSet(pg, { code: opts.setCode ?? 0, sleepMs: opts.setSleep }),
    infisicalSet(vk),
    ...prCreate(BRANCH, "app add", done, { treeCode: opts.tree }),
  ].flat();
}

describe("app add", () => {
  test("plan: 새 앱의 단계와 파일 요약, 쓰기 0건", async () => {
    const r = await runCli([...ARGS, "--json"], newWorld());
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.status).toBe("pending");
    const byId = Object.fromEntries(r.json.steps.map((s: any) => [s.id, s]));
    expect(byId["app-repo"].state).toBe("same");
    expect(byId.image.detail).toContain("main HEAD");
    expect(byId["infisical-postgres"].state).toBe("missing");
    expect(byId.pr.state).toBe("missing");
    expect(byId.pr.detail).toContain(`${P.data}: 생성`);
    expect(r.json.notes.join(" ")).toContain("memo.ukyi.app은 공개된다");
    expect(r.json.next).toBe(`homelab ${ARGS.join(" ")} --apply`);
  });

  test("사람용 plan 출력에 값이 없다", async () => {
    const r = await runCli(ARGS, newWorld());
    expect(r.code).toBe(0);
    expect(r.stdout.split("\n")[0]).toBe("계획 (아무것도 바꾸지 않았다)");
    expectPlanReadOnly(r);
  });

  test("다 된 상태에서 apply: 모든 단계 same, 쓰기 0건(AC-1)", async () => {
    const r = await runCli([...ARGS, "--apply", "--json"], doneWorld());
    expect(r.code).toBe(0);
    expect(r.json.status).toBe("same");
    expect(r.json.steps.every((s: any) => s.state === "same")).toBe(true);
    expect(r.writes).toEqual([]);
    expectNoSecrets(r);
  });

  test("플래그를 덜 준 재실행도 same(더하기만 한다)", async () => {
    const r = await runCli(["app", "add", APP, "--json", "--apply"], doneWorld());
    expect(r.code).toBe(0);
    expect(r.json.steps.every((s: any) => s.state === "same")).toBe(true);
    expect(r.writes).toEqual([]);
  });

  test("apply 새로: 비밀번호 둘 → PR → 대기(3), 값은 stdin으로만", async () => {
    const r = await runCli([...ARGS, "--apply", "--json"], newWorld());
    expect(r.code).toBe(3);
    expect(r.json.status).toBe("waiting");
    const sets = r.calls.filter((c) => c.argv.join(" ").startsWith("infisical secrets set"));
    expect(sets.map((c) => c.argv)).toEqual([infArgv.set(FAKE_PROJECT, pg), infArgv.set(FAKE_PROJECT, vk)]);
    expect(sets.every((c) => c.stdinLength > "PASSWORD=".length + 16)).toBe(true);
    const tree = r.calls.find((c) => c.argv.includes("repos/ukyi-app/homelab/git/trees"))!;
    const files = Object.fromEntries(JSON.parse(tree.stdin!).tree.map((t: any) => [t.path, t.content]));
    expect(files).toEqual(done);
    expectNoSecrets(r);
  });

  test("중간 실패: 첫 비밀번호 쓰기가 실패하면 exit 1, 뒤 단계 not-run, PR 쓰기 없음", async () => {
    const r = await runCli([...ARGS, "--apply", "--json"], newWorld({ setCode: 1 }));
    expect(r.code).toBe(1);
    const byId = Object.fromEntries(r.json.steps.map((s: any) => [s.id, s.result]));
    expect(byId["infisical-postgres"]).toBe("failed");
    expect(byId["infisical-valkey"]).toBe("not-run");
    expect(byId.pr).toBe("not-run");
    expect(r.calls.some((c) => c.argv.includes("repos/ukyi-app/homelab/git/trees"))).toBe(false);
  });

  test("재실행: 비밀번호가 이미 있으면 재사용하고 PR로 이어 간다", async () => {
    const rules = [...homelab({ [P.values]: null, [P.image]: null, [P.data]: null }), ...chartTags(), argo(), ...appRepo(APP), ...allFolders(), infisicalList(`/apps/${APP}`, {}), infisicalList(pg, { PASSWORD: FAKE_SECRETS[0] }), infisicalList(vk, { PASSWORD: FAKE_SECRETS[1] }), ...prCreate(BRANCH, "app add", done)];
    const r = await runCli([...ARGS, "--apply", "--json"], rules);
    expect(r.code).toBe(3);
    expect(r.calls.some((c) => c.argv[0] === "infisical" && c.argv[2] === "set")).toBe(false);
    const byId = Object.fromEntries(r.json.steps.map((s: any) => [s.id, s.result]));
    expect(byId["infisical-postgres"]).toBe("skipped");
    expect(byId.pr).toBe("waiting");
  });

  test("Infisical 쓰기 타임아웃: 재시도하지 않고 다시 읽어 반영을 확인한다", async () => {
    const r = await runCli([...ARGS, "--apply", "--json"], newWorld({ setSleep: 5000 }));
    expect(r.code).toBe(3);
    expect(r.calls.filter((c) => c.argv.join(" ") === infArgv.set(FAKE_PROJECT, pg).join(" ")).length).toBe(1);
    expect(r.json.notes.join(" ")).toContain("infisical-postgres: 시간 초과 뒤 다시 읽어");
  }, SLOW);

  test("PR 쓰기 실패: tree 만들기가 실패하면 exit 1(비밀번호는 남고 재실행이 PR부터 잇는다)", async () => {
    const r = await runCli([...ARGS, "--apply", "--json"], newWorld({ tree: 500 }));
    expect(r.code).toBe(1);
    expect(r.json.steps.find((s: any) => s.id === "pr").result).toBe("failed");
  });

  test("열린 PR이 같은 내용이면 same + 대기, 새 커밋 없음", async () => {
    const rules = [...homelab({ [P.values]: null, [P.image]: null, [P.data]: null }), ...chartTags(), argo(), ...appRepo(APP), ...allFolders(), infisicalList(`/apps/${APP}`, {}), infisicalList(pg, { PASSWORD: FAKE_SECRETS[0] }), infisicalList(vk, { PASSWORD: FAKE_SECRETS[1] }), ...prOpen(BRANCH, "app add", done)];
    const r = await runCli([...ARGS, "--apply", "--json"], rules);
    expect(r.code).toBe(3);
    expect(r.json.steps.every((s: any) => s.state === "same")).toBe(true);
    expect(r.writes).toEqual([]);
  });

  test("private 저장소·익명 pull 불가·provenance 불일치·이미지 없음은 아무것도 쓰기 전에 멈춘다", async () => {
    const base = (o: Parameters<typeof appRepo>[1]) => [...homelab({ [P.values]: null, [P.image]: null, [P.data]: null }), ...chartTags(), argo(), ...appRepo(APP, o), ...allFolders(), infisicalList(`/apps/${APP}`, {}), infisicalList(pg, {}), infisicalList(vk, {}), noPr(BRANCH)];
    for (const [o, id] of [
      [{ visibility: "private" }, "app-repo"],
      [{ anon: 401 }, "ghcr-anon"],
      [{ attest: attestation(APP, DIGEST, APP_HEAD, "refs/heads/feature") }, "image"],
      [{ built: false }, "image"],
    ] as const) {
      const r = await runCli([...ARGS, "--apply", "--json"], base(o));
      expect(r.code).toBe(1);
      expect(r.writes).toEqual([]);
      expect(r.json.steps.find((s: any) => s.id === id).result).toBe("failed");
    }
  });

  test("GitHub 조회 실패를 'app-main 없음'·'이미지 없음'·'provenance 불일치'로 읽지 않는다(#884 P2-5 같은 부류)", async () => {
    const swap = (path: string, status: number) => newWorld().map((x) => (String(x.argv.at(-1)) === path ? ghGet(path, status, { message: "x" }) : x));
    for (const path of [`repos/ukyi-app/${APP}/rulesets`, `orgs/ukyi-app/packages/container/${APP}/versions?per_page=100`, `repos/ukyi-app/${APP}/attestations/${DIGEST}`, `repos/ukyi-app/${APP}/git/ref/heads/main`]) {
      const r = await runCli([...ARGS, "--apply", "--json"], swap(path, 503));
      expect(r.code).toBe(1);
      expect(r.writes).toEqual([]);
      expect(JSON.stringify(r.json.error)).toContain("HTTP 503");
    }
    // 정상 404: 패키지가 아직 없으면 이미지 없음(빌드 대기).
    const r = await runCli([...ARGS, "--json"], swap(`orgs/ukyi-app/packages/container/${APP}/versions?per_page=100`, 404));
    expect(r.json.steps.find((s: any) => s.id === "image").detail).toContain("이미지가 없다");
  });

  test("이미 등록된 앱(image.yaml 있음)은 HEAD 이미지를 찾지 않는다", async () => {
    const rules = [...homelab({ [P.values]: wantValues, [P.image]: imageYaml(APP, DIGEST, "9".repeat(40)), [P.data]: wantData }), ...chartTags(), argo(), ...appRepo(APP, { built: false }), ...allFolders(), infisicalList(`/apps/${APP}`, {}), infisicalList(pg, { PASSWORD: FAKE_SECRETS[0] }), infisicalList(vk, { PASSWORD: FAKE_SECRETS[1] }), noPr(BRANCH)];
    const r = await runCli([...ARGS, "--json"], rules);
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.status).toBe("same");
    expect(r.calls.some((c) => c.argv.some((a) => a.includes("/packages/container/")))).toBe(false);
  });

  test("영속 요청인데 캐시가 켜져 있으면 cache add --persistent로 안내한다", async () => {
    const cached = appValues(null, { postgres: false, cache: "cache" }, { secrets: [], latestChart: "1.1.0" })!;
    const rules = [...homelab({ [P.values]: cached, [P.image]: wantImage, [P.data]: null }), ...chartTags(), argo(), ...appRepo(APP), ...allFolders(), infisicalList(`/apps/${APP}`, {}), infisicalList(pg, {}), infisicalList(vk, {}), noPr(BRANCH)];
    const r = await runCli(["app", "add", APP, "--cache=persistent", "--json"], rules);
    expect(r.code).toBe(1);
    expect(r.json.error.next).toBe(`homelab cache add ${APP} --persistent`);
    expectPlanReadOnly(r);
  });

  test("Infisical 키가 차트 env(PORT)와 겹치면 쓰기 전에 멈춘다(#884 2라운드 P2-4)", async () => {
    const rules = newWorld().map((x) => (x.argv.join(" ") === infArgv.list(FAKE_PROJECT, `/apps/${APP}`).join(" ") ? infisicalList(`/apps/${APP}`, { PORT: FAKE_SECRETS[0] }) : x));
    const r = await runCli([...ARGS, "--apply", "--json"], rules);
    expect(r.code).toBe(1);
    expect(r.json.error.message).toContain("PORT");
    expect(r.writes).toEqual([]);
    expectNoSecrets(r);
  });

  test("기존 worker에 --public·--internal을 붙이지 않는다(#884 2라운드 P2-5)", async () => {
    const worker = "chartVersion: 1.1.0\nkind: worker\nresources: { cpu: 50m, memory: 64Mi }\nprobes: { readiness: { command: [true] } }\n";
    for (const flag of [["--public", "memo.ukyi.app"], ["--internal", "memo"]]) {
      const rules = [...homelab({ [P.values]: worker, [P.image]: wantImage, [P.data]: null }), ...chartTags(), argo(), ...appRepo(APP), ...allFolders(), infisicalList(`/apps/${APP}`, {}), noPr(BRANCH)];
      const r = await runCli(["app", "add", APP, ...flag, "--apply", "--json"], rules);
      expect(r.code).toBe(1);
      expect(r.json.error.message).toContain("worker");
      expect(r.writes).toEqual([]);
    }
  });

  test("--cache=persistent: 앱 Application에 캐시 서버가 남아 있으면 대기(3), 비밀번호·PR not-run(Connector 4373412609)", async () => {
    const rules = newWorld().map((x) => (x.argv.includes("applications.argoproj.io") ? argo([{ kind: "Deployment", name: `${APP}-valkey` }]) : x));
    const r = await runCli([...ARGS, "--apply", "--json"], rules);
    expect(r.code).toBe(3);
    const byId = Object.fromEntries(r.json.steps.map((s: any) => [s.id, s.result]));
    expect(byId["cache-gone"]).toBe("waiting");
    expect([byId["infisical-postgres"], byId.pr]).toEqual(["not-run", "not-run"]);
    expect(r.writes).toEqual([]);
  });

  test("PR 계산 때의 main에 그사이 캐시가 켜졌으면 영속 등록 PR을 만들지 않는다(#884 2라운드 P2-2)", async () => {
    const cached = appValues(null, { postgres: false, cache: "cache" }, { secrets: [], latestChart: "1.1.0" })!;
    const MAIN2 = "8".repeat(40);
    const rules = newWorld().flatMap((x) => (x.argv.join(" ").endsWith("git/ref/heads/main") && x.argv.join(" ").includes("repos/ukyi-app/homelab/")
      ? [ghGet("repos/ukyi-app/homelab/git/ref/heads/main", [ghResponse(200, { object: { sha: "a".repeat(40) } }), ghResponse(200, { object: { sha: MAIN2 } })]), ghGet(`repos/ukyi-app/homelab/contents/${P.values}?ref=${MAIN2}`, 200, { type: "file", encoding: "base64", content: Buffer.from(cached).toString("base64") }), ghGet(`repos/ukyi-app/homelab/contents/${P.image}?ref=${MAIN2}`, 404, {}), ghGet(`repos/ukyi-app/homelab/contents/${P.data}?ref=${MAIN2}`, 404, {})]
      : [x]));
    const r = await runCli(["app", "add", APP, "--cache=persistent", "--json"], rules);
    expect(r.code).toBe(1);
    expect(r.json.error.message).toContain("그사이 main에 캐시 Valkey가 켜졌다");
    expect(r.writes).toEqual([]);
  });

  test("--cache: 시작 때 없던 data 파일도 PR 계산 때 읽어, 그사이 영속이 등록됐으면 캐시 PR을 만들지 않는다(#890 1라운드 P2-1)", async () => {
    const MAIN2 = "8".repeat(40);
    const values = "chartVersion: 1.1.0\nkind: web\nport: 8080\nresources: { cpu: 50m, memory: 64Mi }\n";
    const b64 = (t: string) => ({ type: "file", encoding: "base64", content: Buffer.from(t).toString("base64") });
    const rules = [
      ghGet("repos/ukyi-app/homelab/git/ref/heads/main", [ghResponse(200, { object: { sha: "a".repeat(40) } }), ghResponse(200, { object: { sha: MAIN2 } })]),
      ...homelab({ [P.values]: values, [P.image]: wantImage, [P.data]: null }).slice(1),
      ghGet(`repos/ukyi-app/homelab/contents/${P.values}?ref=${MAIN2}`, 200, b64(values)),
      ghGet(`repos/ukyi-app/homelab/contents/${P.image}?ref=${MAIN2}`, 200, b64(wantImage)),
      ghGet(`repos/ukyi-app/homelab/contents/${P.data}?ref=${MAIN2}`, 200, b64("chartVersion: 1.0.2\nvalkey: { persistent: true }\n")),
      ...chartTags(), argo(), ...appRepo(APP), ...allFolders(), infisicalList(`/apps/${APP}`, {}), infisicalList(vk, { PASSWORD: FAKE_SECRETS[1] }), noPr(BRANCH),
    ];
    const r = await runCli(["app", "add", APP, "--cache", "--apply", "--json"], rules);
    expect(r.code).toBe(1);
    expect(r.json.error.message).toContain("그사이 main에 영속 Valkey가 켜졌다");
    expect(r.writes).toEqual([]);
  });

  test("DB·Valkey 없는 app add는 없는 data 파일을 tree에 넣지 않는다(#890 1라운드 P2-4)", async () => {
    const plain = { [P.values]: appValues(null, { public: "memo.ukyi.app", postgres: false, cache: "none" }, { secrets: [], latestChart: "1.1.0" })!, [P.image]: wantImage };
    const rules = [...homelab({ [P.values]: null, [P.image]: null, [P.data]: null }), ...chartTags(), argo(), ...appRepo(APP), ...allFolders(), infisicalList(`/apps/${APP}`, {}), ...prCreate(BRANCH, "app add", plain, { readOnly: { [P.data]: null } })];
    const r = await runCli(["app", "add", APP, "--public", "memo.ukyi.app", "--apply", "--json"], rules);
    expect(r.code).toBe(3);
    const tree = r.calls.find((c) => c.argv.includes("repos/ukyi-app/homelab/git/trees"))!;
    expect(JSON.parse(tree.stdin!).tree.map((t: any) => t.path).sort()).toEqual([P.image, P.values]);
  });

  test("사용법: 이름 한도·내부 이름 예약어는 64", async () => {
    expect((await runCli(["app", "add", "a".repeat(39), "--cache=persistent"], [])).code).toBe(64);
    expect((await runCli(["app", "add", "my-valkey", "--cache"], [])).code).toBe(64);
    expect((await runCli(["app", "add", APP, "--internal", "go"], [])).code).toBe(64);
    expect((await runCli(["app", "add", APP, "--cache", "--cache"], [])).code).toBe(64);
    // 영속에서도 이름의 valkey 금지(데이터 차트 data.persistentValkey, #884 2라운드 P2-3).
    const r = await runCli(["app", "add", "my-valkey", "--cache=persistent", "--apply"], []);
    expect(r.code).toBe(64);
    expect(r.calls).toEqual([]);
  });

  test("비밀번호 단계: 폴더가 없으면 바깥부터 만들고 쓴다", async () => {
    const { ctx, calls } = testCtx("apply", [
      folders({ "/apps": [], "/": ["apps"], [`/apps/${APP}`]: [] }),
      createFolder("/apps", APP),
      createFolder(`/apps/${APP}`, "postgres"),
      infisicalList(pg, {}),
      infisicalSet(pg),
    ].flat());
    const step = passwordStep(APP, "postgres");
    expect((await step.read(ctx)).state).toBe("missing");
    await applyWith(ctx, (w) => step.apply!(w, { state: "missing", action: "create", detail: "" }));
    const argvs = calls().calls.map((c) => c.argv.join(" "));
    expect(argvs).toContain(infArgv.createFolder(FAKE_PROJECT, "/apps", APP).join(" "));
    expect(argvs).toContain(infArgv.set(FAKE_PROJECT, pg).join(" "));
  });
});

describe("app add 파일 계산", () => {
  const PROBE = `# E5 시험 앱
chartVersion: 1.1.0
kind: web
port: 8080
resources: { cpu: 50m, memory: 64Mi }
# T11 시나리오 2
uses: { postgres: true, valkey: true }
migration:
  command:
    - bun
    - -e
    - 'await Bun.sql\`select 1\`'
`;

  test("T11 probe values: 같은 기능이면 그대로(주석·migration 보존), 공개를 더하면 그 줄만", () => {
    expect(appValues(PROBE, { postgres: true, cache: "none" }, { secrets: [], latestChart: "1.1.0" })).toBe(PROBE);
    const out = appValues(PROBE, { public: "probe.ukyi.app", postgres: false, cache: "none" }, { secrets: [], latestChart: "1.1.0" })!;
    expect(out).toContain("# T11 시나리오 2\nuses: { postgres: true, valkey: true }\nmigration:\n  command:");
    expect(out).toContain("public: { host: probe.ukyi.app }");
    expect(describeFile(P.values, PROBE, out)).toBe("수정 (public probe.ukyi.app)");
  });

  test("캐시를 더하면 차트가 1.1.0보다 낮을 때만 최신으로", () => {
    const old = "chartVersion: 1.0.0\nkind: web\nport: 8080\nresources: { cpu: 50m, memory: 64Mi }\n";
    const out = appValues(old, { postgres: false, cache: "cache" }, { secrets: [], latestChart: "1.2.0" })!;
    expect(out).toContain("chartVersion: 1.2.0");
    expect(out).toContain("cache: { enabled: true }");
    expect(appValues(PROBE, { postgres: false, cache: "cache" }, { secrets: [], latestChart: "1.2.0" })).toContain("chartVersion: 1.1.0");
  });

  test("secrets는 기존 목록과 Infisical 키의 합집합", () => {
    const out = appValues("chartVersion: 1.1.0\nkind: web\nport: 8080\nresources: { cpu: 50m, memory: 64Mi }\nsecrets: [B_KEY]\n", { postgres: false, cache: "none" }, { secrets: ["A_KEY"], latestChart: "1.1.0" })!;
    expect(out).toContain("secrets: [A_KEY, B_KEY]");
  });

  test("image.yaml은 4줄 고정만 읽는다", () => {
    expect(parseImage(imageYaml(APP), APP).digest).toBe(DIGEST);
    expect(() => parseImage(`${imageYaml(APP)}extra: 1\n`, APP)).toThrow();
    expect(() => parseImage(imageYaml("other"), APP)).toThrow();
  });

  test("provenance는 저장소·ref·커밋·digest가 모두 맞아야 한다", () => {
    expect(attestationMatches(attestation(APP), APP, DIGEST, APP_HEAD)).toBe(true);
    expect(attestationMatches(attestation("other"), APP, DIGEST, APP_HEAD)).toBe(false);
    expect(attestationMatches(attestation(APP, DIGEST, "3".repeat(40)), APP, DIGEST, APP_HEAD)).toBe(false);
    expect(attestationMatches({ attestations: [{ bundle: { dsseEnvelope: { payload: "!!" } } }] }, APP, DIGEST, APP_HEAD)).toBe(false);
  });
});
