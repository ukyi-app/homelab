import { describe, expect, test } from "bun:test";
import { matches } from "../../src/commands/rollback";
import { expectPlanReadOnly, ghGet, ghResponse, ghSend, runCli, type Rule } from "../harness";
import { APP_HEAD, DIGEST, MAIN, NEW_COMMIT, OLD_DIGEST, OLD_REV, R, contentsPath, fileJson, homelab, imageYaml, noPr, prCreate, prOpen, pullsPath } from "../fixtures/app-add-world/world";

const APP = "memo";
const P = `apps/${APP}/image.yaml`;
const BRANCH = `cli/rollback-${APP}`;
const C1 = "3".repeat(40);
const C2 = "4".repeat(40);
const NOW = imageYaml(APP);
const BACK = imageYaml(APP, OLD_DIGEST, OLD_REV, true);

function world(current: string, extra: Rule[], o: { deployPr?: boolean; packages?: string[] } = {}): Rule[] {
  return [
    ...homelab({ [P]: current }),
    ghGet(`${R}/commits?path=${P}&sha=main&per_page=30`, 200, [{ sha: C1 }, { sha: C2 }]),
    ghGet(contentsPath(P, C1), 200, fileJson(NOW)),
    ghGet(contentsPath(P, C2), 200, fileJson(imageYaml(APP, OLD_DIGEST, OLD_REV))),
    ghGet(`orgs/ukyi-app/packages/container/${APP}/versions?per_page=100`, 200, (o.packages ?? [DIGEST, OLD_DIGEST]).map((name) => ({ name }))),
    ghGet(pullsPath(`deploy/${APP}`), 200, o.deployPr ? [{ number: 40, head: { sha: "5".repeat(40) }, base: { ref: "main" } }] : []),
    ...extra,
  ];
}

describe("rollback", () => {
  test("plan --to <접두>: 이전 이미지 + hold true, 열린 배포 PR이면 경고", async () => {
    const r = await runCli(["rollback", APP, "--to", OLD_REV.slice(0, 7), "--json"], world(NOW, [noPr(BRANCH)], { deployPr: true }));
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.steps.find((s: any) => s.id === "pr").detail).toContain(`${APP_HEAD.slice(0, 7)} hold false → ${OLD_REV.slice(0, 7)} hold true`);
    expect(r.json.notes.join(" ")).toContain("gh pr close 40");
  });

  test("apply --to digest: PR, 다 된 상태는 same", async () => {
    const r = await runCli(["rollback", APP, "--to", OLD_DIGEST, "--apply", "--json"], world(NOW, prCreate(BRANCH, "rollback", { [P]: BACK })));
    expect(r.code).toBe(3);
    const tree = r.calls.find((c) => c.argv.includes(`${R}/git/trees`))!;
    expect(JSON.parse(tree.stdin!).tree[0].content).toBe(BACK);
    const done = await runCli(["rollback", APP, "--to", OLD_DIGEST, "--apply", "--json"], world(BACK, [noPr(BRANCH)]));
    expect(done.code).toBe(0);
    expect(done.json.steps.every((s: any) => s.state === "same")).toBe(true);
    expect(done.writes).toEqual([]);
  });

  test("--release: hold false만, PR 쓰기 실패는 exit 1, 열린 PR은 대기", async () => {
    const plan = await runCli(["rollback", APP, "--release", "--json"], world(BACK, [noPr(BRANCH)]));
    expect(plan.json.steps.find((s: any) => s.id === "pr").detail).toContain("hold true → ");
    const failed = await runCli(["rollback", APP, "--release", "--apply", "--json"], world(BACK, prCreate(BRANCH, "rollback", { [P]: imageYaml(APP, OLD_DIGEST, OLD_REV, false) }, { treeCode: 500 })));
    expect(failed.code).toBe(1);
    const open = await runCli(["rollback", APP, "--release", "--apply", "--json"], world(BACK, prOpen(BRANCH, "rollback", { [P]: imageYaml(APP, OLD_DIGEST, OLD_REV, false) })));
    expect(open.code).toBe(3);
    expect(open.writes).toEqual([]);
  });

  // T12-05 F4: 기록 = [롤백 커밋(C0), 배포 App 커밋(C1, NOW = APP_HEAD), 그 전 배포(C2)]. 최신 배포는 C1의 이미지다.
  function releaseWorld(current: string, commits: Rule): Rule[] {
    return world(current, [noPr(BRANCH)]).map((x) => (String(x.argv.at(-1)).includes("/commits?path=") ? commits : x));
  }
  const C0 = "5".repeat(40);
  const deployLog = ghGet(`${R}/commits?path=${P}&sha=main&per_page=30`, 200, [
    { sha: C0, commit: { message: `rollback: ${APP} → ${OLD_REV.slice(0, 7)} (#9)` } },
    { sha: C1, commit: { message: `deploy(${APP}): ${APP_HEAD.slice(0, 12)} (#8)\n\ndigest ${DIGEST}` } },
    { sha: C2, commit: { message: `deploy(${APP}): ${OLD_REV.slice(0, 12)} (#7)` } },
  ]);

  test("T12-05 F4: --release는 hold만 푼다고 알리고, 최신 배포가 아니면 --to <최신> 뒤 --release를 next로", async () => {
    const r = await runCli(["rollback", APP, "--release", "--json"], releaseWorld(BACK, deployLog));
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.notes[0]).toBe(`--release는 hold만 푼다. 이미지는 지금 것(revision ${OLD_REV.slice(0, 7)})이 그대로 남고 다음 빌드의 배포 PR부터 바뀐다`);
    expect(r.json.notes[1]).toContain(`최신 배포(revision ${APP_HEAD.slice(0, 12)})가 아니다`);
    expect(r.json.next).toBe(`homelab rollback ${APP} --to ${APP_HEAD.slice(0, 12)} --apply 뒤 homelab rollback ${APP} --release --apply`);
    // 최신 배포 커밋 하나만 읽는다(롤백 커밋·그 전 배포는 읽지 않는다)
    const read = r.calls.map((c) => c.argv.at(-1));
    expect(read).toContain(contentsPath(P, C1));
    expect(read).not.toContain(contentsPath(P, C2));
  });

  test("T12-05 F4: 지금 이미지가 최신 배포면 안내 한 줄만, next는 해제 apply", async () => {
    const r = await runCli(["rollback", APP, "--release", "--json"], releaseWorld(imageYaml(APP, DIGEST, APP_HEAD, true), deployLog));
    expect(r.code).toBe(0);
    expectPlanReadOnly(r);
    expect(r.json.notes).toEqual([`--release는 hold만 푼다. 이미지는 지금 것(revision ${APP_HEAD.slice(0, 7)})이 그대로 남고 다음 빌드의 배포 PR부터 바뀐다`]);
    expect(r.json.next).toBe(`homelab rollback ${APP} --release --apply`);
  });

  test("T12-05 F4: 기록을 못 읽어도 해제는 막지 않고 비교하지 못했다고 알린다", async () => {
    const r = await runCli(["rollback", APP, "--release", "--json"], releaseWorld(BACK, ghGet(`${R}/commits?path=${P}&sha=main&per_page=30`, 403, { message: "Forbidden" })));
    expect(r.code).toBe(0);
    expect(r.json.status).toBe("pending");
    expect(r.json.notes[1]).toBe("최신 배포 이미지와 비교하지 못했다(apps/memo/image.yaml 기록을 읽지 못했다(HTTP 403))");
    expect(r.json.next).toBe(`homelab rollback ${APP} --release --apply`);
  });

  test("--release는 PR 계산 때의 main 이미지에서 hold만 푼다(시작 뒤 병합된 롤백을 되돌리지 않는다, #884 P2-2)", async () => {
    const MAIN2 = "6".repeat(40);
    const later = imageYaml(APP, DIGEST, APP_HEAD, true);
    const rules = [
      // 첫 main 읽기(명령 시작)는 MAIN, 그 뒤(prStep)는 MAIN2. MAIN2에는 다른 롤백(APP_HEAD, hold true)이 병합돼 있다.
      ghGet(`${R}/git/ref/heads/main`, [ghResponse(200, { object: { sha: MAIN } }), ghResponse(200, { object: { sha: MAIN2 } })]),
      ghGet(contentsPath(P), 200, fileJson(BACK)),
      ghGet(contentsPath(P, MAIN2), 200, fileJson(later)),
      ghGet(pullsPath(`deploy/${APP}`), 200, []),
      noPr(BRANCH),
    ];
    const r = await runCli(["rollback", APP, "--release", "--json"], rules);
    expect(r.code).toBe(0);
    expect(r.json.steps.find((s: any) => s.id === "pr").detail).toContain(`${APP_HEAD.slice(0, 7)} hold true → ${APP_HEAD.slice(0, 7)} hold false`);
  });

  // #892 1라운드 P2: 전체 읽기·직전 읽기 뒤 apply의 main 스냅샷이 이미 원하는 내용(hold false)이 된 경합.
  // main 조회 순서: 명령 시작, 전체 읽기, 직전 읽기(MAIN) → apply, 재조회(MAIN2).
  function raceWorld(openPrAtStart: boolean): Rule[] {
    const MAIN2 = "6".repeat(40);
    const HEAD12 = "5".repeat(40);
    const released = imageYaml(APP, DIGEST, APP_HEAD, false);
    const stale = imageYaml(APP, OLD_DIGEST, OLD_REV, true);
    const commitMsg = (sha: string) => ghGet(`${R}/git/commits/${sha}`, 200, { message: "x\n\nHomelab-CLI: rollback", tree: { sha: "d".repeat(40) } });
    const pr = (head: string) => ghResponse(200, [{ number: 12, head: { sha: head }, base: { ref: "main" } }]);
    return [
      ghGet(`${R}/commits?path=${P}&sha=main&per_page=30`, 200, []),
      ghGet(`${R}/git/ref/heads/main`, [...Array(3).fill(ghResponse(200, { object: { sha: MAIN } })), ghResponse(200, { object: { sha: MAIN2 } })]),
      ghGet(contentsPath(P), 200, fileJson(imageYaml(APP, DIGEST, APP_HEAD, true))),
      ghGet(contentsPath(P, MAIN2), 200, fileJson(released)),
      ghGet(pullsPath(`deploy/${APP}`), 200, []),
      ...(openPrAtStart
        ? [
            ghGet(pullsPath(BRANCH), [pr(HEAD12), pr(HEAD12), pr(HEAD12), pr(HEAD12), pr(NEW_COMMIT)]),
            commitMsg(HEAD12),
            commitMsg(NEW_COMMIT),
            ghGet(`${R}/compare/${MAIN}...${HEAD12}`, 200, { files: [{ filename: P }] }),
            ghGet(`${R}/compare/${MAIN2}...${NEW_COMMIT}`, 200, { files: [] }),
            ghGet(contentsPath(P, HEAD12), 200, fileJson(stale)),
            ghGet(`${R}/git/ref/heads/${BRANCH}`, 200, { object: { sha: HEAD12 } }),
          ]
        : [noPr(BRANCH), ghGet(`${R}/git/ref/heads/${BRANCH}`, 404, {})]),
      ghGet(`${R}/git/commits/${MAIN2}`, 200, { message: "main", tree: { sha: "f".repeat(40) } }),
      ghSend("POST", `${R}/git/trees`, 201, { sha: "e".repeat(40) }),
      ghSend("POST", `${R}/git/commits`, 201, { sha: NEW_COMMIT }),
      ghSend("PATCH", `${R}/git/refs/heads/${BRANCH}`, 200, {}),
      ghSend("PATCH", `${R}/pulls/12`, 200, {}),
    ];
  }

  test("빈 변경 경합 + 열린 CLI PR: 그 브랜치를 main tree 그대로의 커밋으로 옮기고 '닫는다'를 notes에(#892 1라운드 P2)", async () => {
    const r = await runCli(["rollback", APP, "--release", "--apply", "--json"], raceWorld(true));
    expect(r.code).toBe(0);
    expect(r.unmatched).toEqual([]);
    // tree는 만들지 않고 main tree를 그대로 쓴다. 부모는 [새 main, PR 머리], force 없음.
    expect(r.calls.some((c) => c.argv.includes(`${R}/git/trees`))).toBe(false);
    const commit = JSON.parse(r.calls.find((c) => c.argv.includes(`${R}/git/commits`) && c.argv.includes("POST"))!.stdin!);
    expect([commit.tree, commit.parents]).toEqual(["f".repeat(40), ["6".repeat(40), "5".repeat(40)]]);
    expect(JSON.parse(r.calls.find((c) => c.argv.includes(`${R}/git/refs/heads/${BRANCH}`))!.stdin!)).toEqual({ sha: NEW_COMMIT, force: false });
    expect(r.calls.some((c) => c.argv.includes(`${R}/pulls/12`))).toBe(true);
    expect(r.json.notes.join(" ")).toContain("PR #12은 이제 필요 없다. 닫는다: gh pr close 12");
  });

  test("빈 변경 경합 + PR 없음: 아무것도 쓰지 않는다(브랜치·PR을 새로 만들지 않는다)", async () => {
    const r = await runCli(["rollback", APP, "--release", "--apply", "--json"], raceWorld(false));
    expect(r.code).toBe(0);
    expect(r.unmatched).toEqual([]);
    expect(r.writes).toEqual([]);
  });

  test("GitHub 조회 실패(403)를 '지워졌다'·'배포 PR 없음'으로 읽지 않는다(#884 P2-5 같은 부류)", async () => {
    const pkg = world(NOW, [noPr(BRANCH)]).map((x) => (String(x.argv.at(-1)).includes("/packages/") ? ghGet(`orgs/ukyi-app/packages/container/${APP}/versions?per_page=100`, 403, { message: "Forbidden" }) : x));
    const a = await runCli(["rollback", APP, "--to", OLD_REV, "--json"], pkg);
    expect(a.code).toBe(1);
    expect(a.json.error.message).toContain("HTTP 403");
    const prs = world(BACK, [noPr(BRANCH)]).map((x) => (String(x.argv.at(-1)) === pullsPath(`deploy/${APP}`) ? ghGet(pullsPath(`deploy/${APP}`), 403, { message: "Forbidden" }) : x));
    const b = await runCli(["rollback", APP, "--release", "--json"], prs);
    expect(b.code).toBe(1);
    expect(b.json.steps.find((s: any) => s.id === "deploy-pr").result).toBe("failed");
  });

  test("기록에 없거나 GHCR에서 지워졌으면 쓰지 않고 멈춘다", async () => {
    const none = await runCli(["rollback", APP, "--to", "9999999", "--apply", "--json"], world(NOW, [noPr(BRANCH)]));
    expect(none.code).toBe(1);
    expect(none.writes).toEqual([]);
    const gone = await runCli(["rollback", APP, "--to", OLD_REV, "--apply", "--json"], world(NOW, [noPr(BRANCH)], { packages: [DIGEST] }));
    expect(gone.code).toBe(1);
    expect(gone.json.error.message).toContain("GHCR에");
  });

  test("사용법: --to와 --release는 하나만, 하나는 필수", async () => {
    expect((await runCli(["rollback", APP], [])).code).toBe(64);
    expect((await runCli(["rollback", APP, "--to", OLD_REV, "--release"], [])).code).toBe(64);
    expect((await runCli(["rollback", APP, "--to", "abc"], [])).code).toBe(64);
  });

  test("접두가 서로 다른 이미지 둘에 맞으면 고르지 않는다", () => {
    const a = { repository: "r", digest: DIGEST, revision: `abcdef1${"0".repeat(33)}`, hold: false };
    const b = { ...a, digest: OLD_DIGEST, revision: `abcdef1${"1".repeat(33)}` };
    expect(matches([a, b, a], "abcdef1").length).toBe(2);
    expect(matches([a, b, a], a.revision).length).toBe(1);
  });
});
