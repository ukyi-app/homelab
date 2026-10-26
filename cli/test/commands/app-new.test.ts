// homelab app new 시험. 스텁 응답은 호출 순서대로 쓰이고 다 쓰면 마지막을 반복한다(같은 GET이 run·전체 읽기·직전 읽기·재조회에서 다시 불린다).
import { describe, expect, test } from "bun:test";
import { addApp, judgePlan } from "../../src/commands/app-new";
import { FAKE_SHA, REST, expectNoSecrets, expectPlanReadOnly, ghGet, ghResponse, ghSend, rule, runCli, type Resp, type Rule } from "../harness";

const R = "repos/ukyi-app/homelab";
const T = "repos/ukyi-app/homelab-app-template";
const A = "repos/ukyi-app/smoke";
const LIST = "infra/github/app-repos.json";
const BASE = ["files", "homelab-bot", "homelab-probe"];
const NEW_COMMIT = "c".repeat(40);
const PLAN_SHA = "b".repeat(40);
const WANT = 'github_repository_ruleset.app_main["smoke"]';

const file = (content: string) => ({ type: "file", encoding: "base64", content: Buffer.from(content).toString("base64") });
const listText = (apps: string[]) => `${JSON.stringify(apps, null, 2)}\n`;
const mainAt = ghGet(`${R}/git/ref/heads/main`, 200, { object: { sha: FAKE_SHA } });
const listOnMain = (apps: string[]) => ghGet(`${R}/contents/${LIST}?ref=${FAKE_SHA}`, 200, file(listText(apps)));
const pulls = `${R}/pulls?head=${encodeURIComponent("ukyi-app:cli/app-new-smoke")}&state=open`;

const templateOk = (enforcement = "active", onMain = true): Rule[] => [
  ghGet(`${T}/rulesets?includes_parents=false&per_page=100`, 200, [{ id: 11, name: "app-main", enforcement }]),
  ghGet(`${T}/rules/branches/main`, 200, onMain ? [{ type: "deletion", ruleset_id: 11 }] : [{ type: "deletion", ruleset_id: 99 }]),
];

// 저장소 GET 응답 꼴.
const repo = (settings: "off" | "on", extra: Record<string, unknown> = {}) => ({
  name: "smoke",
  visibility: "public",
  default_branch: "main",
  template_repository: { full_name: "ukyi-app/homelab-app-template" },
  security_and_analysis: { secret_scanning: { status: settings === "on" ? "enabled" : "disabled" }, secret_scanning_push_protection: { status: settings === "on" ? "enabled" : "disabled" } },
  pull_request_creation_policy: settings === "on" ? "collaborators_only" : "all",
  ...extra,
});
const repoGet = (resps: Resp[]) => ghGet(A, resps);
const pvr = (resps: boolean[]) => ghGet(`${A}/private-vulnerability-reporting`, resps.map((enabled) => ghResponse(200, { enabled })));
const fork = (resps: string[]) => ghGet(`${A}/actions/permissions/fork-pr-contributor-approval`, resps.map((approval_policy) => ghResponse(200, { approval_policy })));
const appRulesets = (resps: unknown[][]) => ghGet(`${A}/rulesets?includes_parents=false&per_page=100`, resps.map((j) => ghResponse(200, j)));
const ACTIVE = [{ id: 21, name: "app-main", enforcement: "active" }];
// 앱 main에 실제로 걸린 규칙(#882 리뷰 1). 21이 있어야 완료다.
const appRules = (resps: unknown[][]) => ghGet(`${A}/rules/branches/main`, resps.map((j) => ghResponse(200, j)));
const APPLIED = [{ type: "deletion", ruleset_id: 21 }];

const clone = rule(["git", REST], { materialize: { "tools/tf-github.sh": "stub" } });
const planJson = (changes: unknown[]) => JSON.stringify({ schema: "tf-github-plan/v1", sha: PLAN_SHA, changes });
const ONLY_CREATE = [
  { address: WANT, mode: "managed", actions: ["create"], importing: false, moved: false },
  // 새 app_main에 의존하는 guard 3·4의 미뤄진 읽기(U35). 판정은 무시해야 한다.
  { address: 'data.github_rest_api.rulesets_app["smoke"]', mode: "data", actions: ["read"], importing: false, moved: false },
  { address: 'data.github_rest_api.bypass_app["smoke"]', mode: "data", actions: ["read"], importing: false, moved: false },
];
const wrapperPlan = (code: number, changes: unknown[] = ONLY_CREATE) => rule(["tf-github.sh", "plan", "--plan-json", REST], { code, writeLastArg: code === 0 || code === 2 ? planJson(changes) : undefined }, { noStdin: true });
const wrapperApply = (code = 0) => rule(["tf-github.sh", "apply"], { code }, { noStdin: true });

const wrapperCalls = (r: { calls: { argv: string[] }[] }) => r.calls.filter((c) => c.argv[0].endsWith("tf-github.sh")).map((c) => c.argv[1]);
const stepsOf = (json: any) => Object.fromEntries(json.steps.map((s: any) => [s.id, s]));

// 다 된 상태(homelab-probe처럼): 목록에 있음, 저장소·설정·app-main 모두 됨.
const allDone = (): Rule[] => [mainAt, listOnMain([...BASE, "smoke"]), ...templateOk(), repoGet([ghResponse(200, repo("on"))]), pvr([true]), fork(["all_external_contributors"]), appRulesets([ACTIVE]), appRules([APPLIED])];

describe("app new: 목록 PR 단계(앱이 main 목록에 없음)", () => {
  const phaseA = (): Rule[] => [mainAt, listOnMain(BASE), ...templateOk(), repoGet([ghResponse(404, {})])];

  test("plan: 템플릿 확인·이름 확인·PR 계획, 쓰기 0건, 래퍼 안 부름", async () => {
    const r = await runCli(["app", "new", "smoke", "--json"], [...phaseA(), ghGet(pulls, 200, [])]);
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.status).toBe("pending");
    expect(r.json.steps.map((s: any) => [s.id, s.state])).toEqual([
      ["template-app-main", "same"],
      ["repo-absent", "same"],
      ["pr", "missing"],
    ]);
    expect(stepsOf(r.json).pr.detail).toContain(`${LIST}: smoke 추가`);
    expect(r.json.next).toBe("homelab app new smoke --apply");
    expect(r.json.notes.join(" ")).toContain("PR 병합 뒤 같은 명령을 다시 --apply");
    expect(wrapperCalls(r)).toEqual([]);
  });

  test("사람용 plan 출력", async () => {
    const r = await runCli(["app", "new", "smoke"], [...phaseA(), ghGet(pulls, 200, [])]);
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.stdout.split("\n")[0]).toBe("계획 (아무것도 바꾸지 않았다)");
    expect(r.stdout).toContain("app-main active (ruleset 11)");
    expect(r.stdout).toContain("다음: homelab app new smoke --apply");
  });

  test("apply: 목록 PR(정렬·지금 파일 모양)을 열고 병합 대기(3)", async () => {
    const want = listText([...BASE, "smoke"]);
    const rules: Rule[] = [
      ...phaseA(),
      // 전체 읽기·직전 읽기·apply 안 PR 찾기는 없음, 재조회는 PR 7.
      ghGet(pulls, [ghResponse(200, []), ghResponse(200, []), ghResponse(200, []), ghResponse(200, [{ number: 7, head: { sha: NEW_COMMIT }, base: { ref: "main" } }])]),
      ghGet(`${R}/git/commits/${NEW_COMMIT}`, 200, { message: "x\n\nHomelab-CLI: app new", tree: { sha: "d".repeat(40) } }),
      ghGet(`${R}/compare/${FAKE_SHA}...${NEW_COMMIT}`, 200, { files: [{ filename: LIST }] }),
      ghGet(`${R}/contents/${LIST}?ref=${NEW_COMMIT}`, 200, file(want)),
      ghGet(`${R}/git/ref/heads/cli/app-new-smoke`, 404, {}),
      ghGet(`${R}/git/commits/${FAKE_SHA}`, 200, { message: "main", tree: { sha: "d".repeat(40) } }),
      ghSend("POST", `${R}/git/trees`, 201, { sha: "e".repeat(40) }),
      ghSend("POST", `${R}/git/commits`, 201, { sha: NEW_COMMIT }),
      ghSend("POST", `${R}/git/refs`, 201, {}),
      ghSend("POST", `${R}/pulls`, 201, { number: 7 }),
    ];
    const r = await runCli(["app", "new", "smoke", "--apply", "--json"], rules);
    expect(r.code).toBe(3);
    expect(r.json.status).toBe("waiting");
    expect(r.unmatched).toEqual([]);
    const tree = JSON.parse(r.calls.find((c) => c.argv.includes(`${R}/git/trees`))!.stdin!);
    expect(tree.tree).toEqual([{ path: LIST, mode: "100644", type: "blob", content: want }]);
    const pr = JSON.parse(r.calls.find((c) => c.argv.includes(`${R}/pulls`) && c.stdin !== undefined)!.stdin!);
    expect(pr).toMatchObject({ head: "cli/app-new-smoke", base: "main" });
    expect(pr.body).toContain("homelab app new smoke --apply");
    // 병합 전에는 저장소를 만들지 않는다(guard 8).
    expect(r.calls.some((c) => c.argv.includes(`${T}/generate`))).toBe(false);
    expect(wrapperCalls(r)).toEqual([]);
    expectNoSecrets(r);
  });

  test("PR 만들기가 시간 초과면 재시도하지 않고 다시 읽어 PR이 있으면 대기로 끝난다", async () => {
    const want = listText([...BASE, "smoke"]);
    const rules: Rule[] = [
      ...phaseA(),
      ghGet(pulls, [ghResponse(200, []), ghResponse(200, []), ghResponse(200, []), ghResponse(200, [{ number: 7, head: { sha: NEW_COMMIT }, base: { ref: "main" } }])]),
      ghGet(`${R}/git/commits/${NEW_COMMIT}`, 200, { message: "x\n\nHomelab-CLI: app new", tree: { sha: "d".repeat(40) } }),
      ghGet(`${R}/compare/${FAKE_SHA}...${NEW_COMMIT}`, 200, { files: [{ filename: LIST }] }),
      ghGet(`${R}/contents/${LIST}?ref=${NEW_COMMIT}`, 200, file(want)),
      ghGet(`${R}/git/ref/heads/cli/app-new-smoke`, 404, {}),
      ghGet(`${R}/git/commits/${FAKE_SHA}`, 200, { message: "main", tree: { sha: "d".repeat(40) } }),
      ghSend("POST", `${R}/git/trees`, 201, { sha: "e".repeat(40) }),
      ghSend("POST", `${R}/git/commits`, 201, { sha: NEW_COMMIT }),
      ghSend("POST", `${R}/git/refs`, 201, {}),
      ghSend("POST", `${R}/pulls`, [{ ...ghResponse(201, { number: 7 }), sleepMs: 4000 }]),
    ];
    const r = await runCli(["app", "new", "smoke", "--apply", "--json"], rules);
    expect(r.code).toBe(3);
    expect(r.json.notes.join(" ")).toContain("시간 초과 뒤 다시 읽어");
    expect(r.calls.filter((c) => c.argv.includes(`${R}/pulls`) && c.stdin !== undefined)).toHaveLength(1);
  });

  test("템플릿 app-main이 disabled면 쓰기 전에 실패(1)", async () => {
    const rules = [mainAt, listOnMain(BASE), ...templateOk("disabled"), repoGet([ghResponse(404, {})]), ghGet(pulls, 200, [])];
    const r = await runCli(["app", "new", "smoke", "--apply", "--json"], rules);
    expect(r.code).toBe(1);
    expect(r.writes).toEqual([]);
    expect(r.json.error.message).toContain("app-main이 disabled다");
    expect(r.json.error.next).toContain("템플릿 main에 app-main을 건다");
  });

  test("템플릿 app-main이 없거나 main에 안 걸렸으면 plan이 실패(1), 쓰기 0건", async () => {
    for (const [tpl, msg] of [
      [[ghGet(`${T}/rulesets?includes_parents=false&per_page=100`, 200, []), ghGet(`${T}/rules/branches/main`, 200, [])], "app-main이 없다"],
      [templateOk("active", false), "main에 걸려 있지 않다"],
    ] as const) {
      const r = await runCli(["app", "new", "smoke", "--json"], [mainAt, listOnMain(BASE), ...tpl, repoGet([ghResponse(404, {})]), ghGet(pulls, 200, [])]);
      expect(r.code).toBe(1);
      expectPlanReadOnly(r);
      expect(r.json.error.message).toContain(msg);
    }
  });

  test("목록에 없는 같은 이름 저장소가 있으면 plan이 실패(1)", async () => {
    const r = await runCli(["app", "new", "smoke", "--json"], [mainAt, listOnMain(BASE), ...templateOk(), repoGet([ghResponse(200, { visibility: "private" })]), ghGet(pulls, 200, [])]);
    expect(r.code).toBe(1);
    expectPlanReadOnly(r);
    expect(r.json.error.message).toContain("목록에 없는 저장소가 이미 있다(private)");
  });

  test("예약된 이름(homelab, homelab-app-template)은 사용법 오류(64), 아무것도 부르지 않는다", async () => {
    for (const name of ["homelab", "homelab-app-template"]) {
      const r = await runCli(["app", "new", name], []);
      expect(r.code).toBe(64);
      expect(r.calls).toEqual([]);
    }
  });
});

describe("app new: 생성 단계(앱이 main 목록에 있음)", () => {
  test("다 된 상태: plan은 모두 same, 래퍼 안 부름", async () => {
    const r = await runCli(["app", "new", "smoke", "--json"], allDone());
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.status).toBe("same");
    expect(r.json.steps.map((s: any) => s.id)).toEqual(["template-app-main", "repo", "repo-settings", "vuln-reporting", "fork-pr-approval", "app-main"]);
    expect(r.json.steps.every((s: any) => s.state === "same")).toBe(true);
    expect(r.json.notes).toEqual([]);
    expect(wrapperCalls(r)).toEqual([]);
  });

  test("다 된 상태에서 apply: 모든 state same, 쓰기 0건, exit 0", async () => {
    const r = await runCli(["app", "new", "smoke", "--apply", "--json"], allDone());
    expect(r.code).toBe(0);
    expect(r.json.status).toBe("same");
    expect(r.json.steps.every((s: any) => s.state === "same" && s.result === "skipped")).toBe(true);
    expect(r.writes).toEqual([]);
    expect(wrapperCalls(r)).toEqual([]);
  });

  test("plan: 저장소가 없으면 생성·설정은 missing, app-main은 래퍼 없이 '뒤에 판정', 쓰기 0건", async () => {
    const r = await runCli(["app", "new", "smoke", "--json"], [mainAt, listOnMain([...BASE, "smoke"]), ...templateOk(), repoGet([ghResponse(404, {})])]);
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    const s = stepsOf(r.json);
    expect(s.repo.state).toBe("missing");
    expect(s["repo-settings"].detail).toBe("저장소 생성 뒤");
    expect(s["app-main"].detail).toBe("저장소·보안 설정 뒤 래퍼 plan으로 판정");
    expect(r.json.notes.join(" ")).toContain("새 main에 보호가 없다");
    expect(wrapperCalls(r)).toEqual([]);
  });

  test("plan: 하드닝까지 됐고 app-main만 없으면 래퍼 plan JSON으로 'app_main 생성만' 판정(AC-6), 쓰기 0건", async () => {
    const rules = [mainAt, listOnMain([...BASE, "smoke"]), ...templateOk(), repoGet([ghResponse(200, repo("on"))]), pvr([true]), fork(["all_external_contributors"]), appRulesets([[]]), clone, wrapperPlan(2)];
    const r = await runCli(["app", "new", "smoke", "--json"], rules);
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.status).toBe("pending");
    expect(stepsOf(r.json)["app-main"]).toMatchObject({ state: "missing", action: "create", detail: `plan: ${WANT} 생성만 (main ${PLAN_SHA.slice(0, 12)})` });
    expect(wrapperCalls(r)).toEqual(["plan"]);
    // stdout은 결과 JSON 하나다(래퍼 출력은 stderr로).
    expect(r.json.schema).toBe("homelab-cli/v1");
  });

  test("app-main이 active여도 main에 걸려 있지 않으면 완료로 보지 않고 래퍼 plan으로 판정한다(드리프트는 생성이 아니라 멈춤, #882 리뷰 1)", async () => {
    const drift = [{ address: WANT, mode: "managed", actions: ["update"], importing: false, moved: false }];
    for (const args of [["app", "new", "smoke", "--json"], ["app", "new", "smoke", "--apply", "--json"]]) {
      const rules = [mainAt, listOnMain([...BASE, "smoke"]), ...templateOk(), repoGet([ghResponse(200, repo("on"))]), pvr([true]), fork(["all_external_contributors"]), appRulesets([ACTIVE]), appRules([[]]), clone, wrapperPlan(2, drift), wrapperApply(0)];
      const r = await runCli(args, rules);
      expect(r.code).toBe(1);
      expect(r.writes).toEqual([]);
      expect(r.json.status).toBe("failed");
      expect(r.json.error.message).toContain(`${WANT}(update)`);
      expect(wrapperCalls(r)).toEqual(["plan"]);
    }
  });

  test("plan: 래퍼 plan에 주소 이동(moved)·root output 변경이 섞이면 실패(1), 쓰기 0건(#882 리뷰 2)", async () => {
    const mixed = [
      ...ONLY_CREATE,
      { address: "github_repository_ruleset.main_review_v2", mode: "managed", actions: ["no-op"], importing: false, moved: true },
      { address: "data.terraform_remote_state.renamed", mode: "data", actions: ["read"], importing: false, moved: true },
      { address: "output.ruleset_ids", mode: "managed", actions: ["update"], importing: false, moved: false },
    ];
    const rules = [mainAt, listOnMain([...BASE, "smoke"]), ...templateOk(), repoGet([ghResponse(200, repo("on"))]), pvr([true]), fork(["all_external_contributors"]), appRulesets([[]]), clone, wrapperPlan(2, mixed)];
    const r = await runCli(["app", "new", "smoke", "--json"], rules);
    expect(r.code).toBe(1);
    expectPlanReadOnly(r);
    expect(r.json.error.message).toContain("github_repository_ruleset.main_review_v2(주소 이동)");
    expect(r.json.error.message).toContain("output.ruleset_ids(update)");
    expect(r.json.error.message).toContain("data.terraform_remote_state.renamed(주소 이동, read)");
  });

  test("plan: 래퍼 plan에 다른 관리 변경이 있으면 실패(1), 주소를 보이고 쓰기 0건", async () => {
    const other = [...ONLY_CREATE, { address: "github_repository_ruleset.main_review", mode: "managed", actions: ["update"], importing: false, moved: false }];
    const rules = [mainAt, listOnMain([...BASE, "smoke"]), ...templateOk(), repoGet([ghResponse(200, repo("on"))]), pvr([true]), fork(["all_external_contributors"]), appRulesets([[]]), clone, wrapperPlan(2, other)];
    const r = await runCli(["app", "new", "smoke", "--json"], rules);
    expect(r.code).toBe(1);
    expectPlanReadOnly(r);
    expect(r.json.error.message).toContain("github_repository_ruleset.main_review(update)");
  });

  test("이미 있는 저장소가 템플릿에서 만든 것이 아니면 plan이 실패(1)", async () => {
    const rules = [mainAt, listOnMain([...BASE, "smoke"]), ...templateOk(), repoGet([ghResponse(200, repo("on", { template_repository: null }))]), pvr([true]), fork(["all_external_contributors"]), appRulesets([ACTIVE]), appRules([APPLIED])];
    const r = await runCli(["app", "new", "smoke", "--json"], rules);
    expect(r.code).toBe(1);
    expectPlanReadOnly(r);
    expect(r.json.error.message).toContain("템플릿에서 만든 저장소가 아니다");
  });

  // 저장소 GET 순서: run 1, 전체 읽기 5(repo·설정·PVR·fork·app-main), repo 직전 읽기 1 → 404 7번.
  // 생성 뒤 repo 재조회·설정 직전 읽기 → 설정 꺼짐 2번, 그 뒤는 켜짐.
  const fromNothing = (over: { settings?: Resp[]; generate?: Resp[]; apply?: number } = {}): Rule[] => [
    mainAt,
    listOnMain([...BASE, "smoke"]),
    ...templateOk(),
    repoGet([...Array(7).fill(ghResponse(404, {})), ghResponse(200, repo("off")), ghResponse(200, repo("off")), ghResponse(200, repo("on"))]),
    pvr([false, true]),
    fork(["first_time_contributors", "all_external_contributors"]),
    appRulesets([[], ACTIVE]),
    appRules([APPLIED]),
    ghSend("POST", `${T}/generate`, over.generate ?? 201, {}),
    ghSend("PATCH", A, over.settings ?? 200, {}),
    ghSend("PUT", `${A}/private-vulnerability-reporting`, 204, {}),
    ghSend("PUT", `${A}/actions/permissions/fork-pr-contributor-approval`, 204, {}),
    clone,
    wrapperPlan(2),
    wrapperApply(over.apply ?? 0),
  ];

  test("apply 처음부터: 생성 → 설정 셋 → 래퍼 plan 판정 → 래퍼 apply 순서, exit 0", async () => {
    const r = await runCli(["app", "new", "smoke", "--apply", "--json"], fromNothing());
    expect(r.code).toBe(0);
    expect(r.unmatched).toEqual([]);
    expect(r.json.status).toBe("done");
    expect(r.json.steps.map((s: any) => [s.id, s.result])).toEqual([
      ["template-app-main", "skipped"],
      ["repo", "applied"],
      ["repo-settings", "applied"],
      ["vuln-reporting", "applied"],
      ["fork-pr-approval", "applied"],
      ["app-main", "applied"],
    ]);
    const order = r.writes.map((c) => (c.argv[0].endsWith("tf-github.sh") ? `tf-github.sh ${c.argv[1]}` : `${c.argv[4]} ${c.argv[5]}`));
    expect(order).toEqual([`POST ${T}/generate`, `PATCH ${A}`, `PUT ${A}/private-vulnerability-reporting`, `PUT ${A}/actions/permissions/fork-pr-contributor-approval`, "tf-github.sh apply"]);
    // 래퍼 plan은 app-main 실행 직전 한 번만 돈다(전체 읽기 때는 저장소가 없어 부르지 않는다).
    expect(wrapperCalls(r)).toEqual(["plan", "apply"]);
    expectNoSecrets(r);
  });

  test("중간 쓰기 실패(설정 PATCH 500) → exit 1, 뒤 단계 not-run, 재실행하면 이어서 끝난다", async () => {
    const r = await runCli(["app", "new", "smoke", "--apply", "--json"], fromNothing({ settings: [ghResponse(500, { message: "boom" })] }));
    expect(r.code).toBe(1);
    const res = r.json.steps.map((s: any) => s.result);
    expect(res).toEqual(["skipped", "applied", "failed", "not-run", "not-run", "not-run"]);
    expect(wrapperCalls(r)).toEqual([]);

    // 재실행: 저장소는 이미 있고 설정이 꺼진 상태부터.
    const again: Rule[] = [
      mainAt,
      listOnMain([...BASE, "smoke"]),
      ...templateOk(),
      // run 1, 전체 읽기 5, repo 직전 1, 설정 직전 1 → 꺼짐 8번, 그 뒤 켜짐.
      repoGet([...Array(8).fill(ghResponse(200, repo("off"))), ghResponse(200, repo("on"))]),
      pvr([false, false, true]),
      fork(["first_time_contributors", "first_time_contributors", "all_external_contributors"]),
      // 저장소가 있어 전체 읽기에서도 app-main 목록을 본다: 전체 읽기·직전 읽기 없음, 재조회 active.
      appRulesets([[], [], ACTIVE]),
      appRules([APPLIED]),
      ghSend("PATCH", A, 200, {}),
      ghSend("PUT", `${A}/private-vulnerability-reporting`, 204, {}),
      ghSend("PUT", `${A}/actions/permissions/fork-pr-contributor-approval`, 204, {}),
      clone,
      wrapperPlan(2),
      wrapperApply(0),
    ];
    const r2 = await runCli(["app", "new", "smoke", "--apply", "--json"], again);
    expect(r2.code).toBe(0);
    expect(r2.unmatched).toEqual([]);
    expect(r2.json.steps.map((s: any) => s.result)).toEqual(["skipped", "skipped", "applied", "applied", "applied", "applied"]);
    expect(r2.writes.some((c) => c.argv.includes(`${T}/generate`))).toBe(false);
    // 하드닝 전(전체 읽기 때 설정 꺼짐)에는 래퍼 plan을 부르지 않는다. app-main 직전 한 번과 apply 한 번뿐이다.
    expect(wrapperCalls(r2)).toEqual(["plan", "apply"]);
  });

  test("저장소 생성이 시간 초과면 재시도하지 않고 다시 읽어 생겼으면 이어 간다", async () => {
    const r = await runCli(["app", "new", "smoke", "--apply", "--json"], fromNothing({ generate: [{ ...ghResponse(201, {}), sleepMs: 4000 }] }));
    expect(r.code).toBe(0);
    expect(r.json.notes.join(" ")).toContain("repo: 시간 초과 뒤 다시 읽어");
    expect(r.calls.filter((c) => c.argv.includes(`${T}/generate`))).toHaveLength(1);
  });

  test("래퍼 apply가 실패하면 app-main 단계가 실패(1)", async () => {
    const r = await runCli(["app", "new", "smoke", "--apply", "--json"], fromNothing({ apply: 1 }));
    expect(r.code).toBe(1);
    expect(stepsOf(r.json)["app-main"].result).toBe("failed");
    expect(r.json.error.message).toContain("래퍼 apply가 exit 1");
  });
});

describe("app new: 판정과 목록 편집(순수 함수)", () => {
  const pc = (exitCode: number, changes: any[] | null) => ({ exitCode, sha: PLAN_SHA, changes });

  test("생성 하나 + 미뤄진 guard 읽기는 통과", () => {
    expect(judgePlan("smoke", pc(2, ONLY_CREATE)).state).toBe("missing");
  });

  test("막는 경우: 래퍼 실패, 변경 없음, 다른 앱의 app_main, import, delete, data의 다른 동작, 생성 + 다른 변경", () => {
    const c = (address: string, actions: string[], extra: Record<string, unknown> = {}) => ({ address, mode: "managed", actions, importing: false, moved: false, ...extra });
    const cases: [number, any[] | null, string][] = [
      [1, null, "0·2가 아닌 코드"],
      [0, [], "생성이 없다"],
      [2, [c('github_repository_ruleset.app_main["other"]', ["create"])], "생성 말고 변경"],
      [2, [c(WANT, ["create"], { importing: true })], "생성 말고 변경"],
      [2, [c(WANT, ["delete", "create"])], "생성 말고 변경"],
      [2, [{ address: 'data.github_rest_api.x["smoke"]', mode: "data", actions: ["create"], importing: false, moved: false }], "생성 말고 변경"],
      [2, [c(WANT, ["create"]), c("github_repository_environment.automerge", ["update"])], "automerge(update)"],
      [2, [c(WANT, ["create"]), c("github_repository_ruleset.renamed", ["no-op"], { moved: true })], "renamed(주소 이동)"],
      // 미뤄진 data read와 이동이 겹친 항목. data read 예외보다 이동을 먼저 센다(#882 리뷰 2라운드).
      [2, [c(WANT, ["create"]), c("data.terraform_remote_state.renamed", ["read"], { mode: "data", moved: true })], "renamed(주소 이동, read)"],
      [2, [c(WANT, ["create"], { moved: true })], "생성 말고 변경"],
      [2, [c(WANT, ["create"]), c("output.o", ["update"])], "output.o(update)"],
    ];
    for (const [code, changes, msg] of cases) expect(() => judgePlan("smoke", pc(code, changes))).toThrow(msg);
  });

  test("목록 편집: 정렬·2칸 들여쓰기·끝 줄바꿈, 이미 있으면 그대로, 형식이 아니면 던진다", () => {
    expect(addApp(listText(["files", "zeta"]), "alpha")).toBe(listText(["alpha", "files", "zeta"]));
    expect(addApp(listText(BASE), "files")).toBe(listText(BASE));
    expect(() => addApp(null, "x")).toThrow("없다");
    expect(() => addApp('{"a":1}', "x")).toThrow("문자열 배열");
  });
});
