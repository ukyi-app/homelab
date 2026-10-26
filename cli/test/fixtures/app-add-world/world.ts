// 02 명령 시험이 같이 쓰는 가짜 GitHub·Infisical·GHCR 규칙(T12-02). 스텁은 규칙 순서대로 첫 일치를 쓰고
// 응답은 호출 순서대로 하나씩(다 쓰면 마지막 반복)이라, 상태가 바뀌는 흐름은 응답 배열로 표현한다.
import { argvFor as ghArgv } from "../../../src/core/github";
import { argvFor as infArgv } from "../../../src/core/infisical";
import { FAKE_PROJECT, FAKE_SHA, ghGet, ghResponse, ghSend, infisicalList, rule, type Resp, type Rule } from "../../harness";

export const R = "repos/ukyi-app/homelab";
export const MAIN = FAKE_SHA;
export const NEW_COMMIT = "c".repeat(40);
export const APP_HEAD = "1".repeat(40);
export const DIGEST = `sha256:${"a1".repeat(32)}`;
export const OLD_REV = "2".repeat(40);
export const OLD_DIGEST = `sha256:${"b2".repeat(32)}`;

export const b64 = (s: string) => Buffer.from(s).toString("base64");
export const fileJson = (content: string) => ({ type: "file", encoding: "base64", content: b64(content) });
export const contentsPath = (path: string, ref = MAIN) => `${R}/contents/${path}?ref=${ref}`;
export const pullsPath = (branch: string) => `${R}/pulls?head=${encodeURIComponent(`ukyi-app:${branch}`)}&state=open`;

export const imageYaml = (app: string, digest = DIGEST, revision = APP_HEAD, hold = false) => `repository: ghcr.io/ukyi-app/${app}\ndigest: ${digest}\nrevision: ${revision}\nhold: ${hold}\n`;

// homelab main과 그 파일들(null은 없음).
export function homelab(files: Record<string, string | null>): Rule[] {
  return [ghGet(`${R}/git/ref/heads/main`, 200, { object: { sha: MAIN } }), ...Object.entries(files).map(([p, c]) => (c === null ? ghGet(contentsPath(p), 404, {}) : ghGet(contentsPath(p), 200, fileJson(c))))];
}

export function chartTags(): Rule[] {
  return [
    ghGet(`${R}/git/matching-refs/tags/app-chart-v`, 200, [{ ref: "refs/tags/app-chart-v1.0.0" }, { ref: "refs/tags/app-chart-v1.1.0" }]),
    ghGet(`${R}/git/matching-refs/tags/data-chart-v`, 200, [{ ref: "refs/tags/data-chart-v1.0.0" }, { ref: "refs/tags/data-chart-v1.0.1" }]),
  ];
}

export const noPr = (branch: string): Rule => ghGet(pullsPath(branch), 200, []);
export const openPr = (number: number, head: string) => ghResponse(200, [{ number, head: { sha: head }, base: { ref: "main" } }]);

const contentRules = (files: Record<string, string | null>, ref: string) => Object.entries(files).map(([p, c]) => (c === null ? ghGet(contentsPath(p, ref), 404, {}) : ghGet(contentsPath(p, ref), 200, fileJson(c))));

// 열린 CLI PR이 이미 원하는 내용을 갖고 있다(재실행·대기). readOnly는 명령이 PR 시점 확인용으로 읽기만 하는 파일
// (PR 브랜치에서도 main과 같은 내용, 변경 목록에는 없다).
export function prOpen(branch: string, command: string, files: Record<string, string | null>, head = NEW_COMMIT, readOnly: Record<string, string | null> = {}): Rule[] {
  return [
    ghGet(pullsPath(branch), [openPr(12, head)]),
    ghGet(`${R}/git/commits/${head}`, 200, { message: `x\n\nHomelab-CLI: ${command}`, tree: { sha: "d".repeat(40) } }),
    ghGet(`${R}/compare/${MAIN}...${head}`, 200, { files: Object.keys(files).map((filename) => ({ filename })) }),
    ...contentRules({ ...files, ...readOnly }, head),
  ];
}

// 새 PR 만들기 한 번. 전체 읽기·직전 읽기·apply 안 PR 찾기는 없음, 재조회는 PR 7(머리 NEW_COMMIT, 원하는 내용).
// treeCode로 tree 만들기 실패를 넣는다.
export function prCreate(branch: string, command: string, files: Record<string, string | null>, opts: { treeCode?: number; readOnly?: Record<string, string | null> } = {}): Rule[] {
  return [
    ghGet(pullsPath(branch), [ghResponse(200, []), ghResponse(200, []), ghResponse(200, []), openPr(7, NEW_COMMIT)]),
    ghGet(`${R}/git/commits/${MAIN}`, 200, { message: "main", tree: { sha: "d".repeat(40) } }),
    ghGet(`${R}/git/ref/heads/${branch}`, 404, {}),
    opts.treeCode ? ghSend("POST", `${R}/git/trees`, opts.treeCode, { message: "boom" }) : ghSend("POST", `${R}/git/trees`, 201, { sha: "e".repeat(40) }),
    ghSend("POST", `${R}/git/commits`, 201, { sha: NEW_COMMIT }),
    ghSend("POST", `${R}/git/refs`, 201, {}),
    ghSend("POST", `${R}/pulls`, 201, { number: 7 }),
    ghGet(`${R}/git/commits/${NEW_COMMIT}`, 200, { message: `x\n\nHomelab-CLI: ${command}`, tree: { sha: "d".repeat(40) } }),
    ghGet(`${R}/compare/${MAIN}...${NEW_COMMIT}`, 200, { files: Object.keys(files).map((filename) => ({ filename })) }),
    ...contentRules({ ...files, ...(opts.readOnly ?? {}) }, NEW_COMMIT),
  ];
}

export function attestation(app: string, digest = DIGEST, revision = APP_HEAD, ref = "refs/heads/main") {
  const statement = {
    predicateType: "https://slsa.dev/provenance/v1",
    subject: [{ name: `ghcr.io/ukyi-app/${app}`, digest: { sha256: digest.slice("sha256:".length) } }],
    predicate: { buildDefinition: { externalParameters: { workflow: { repository: `https://github.com/ukyi-app/${app}`, ref } }, resolvedDependencies: [{ uri: `git+https://github.com/ukyi-app/${app}@${ref}`, digest: { gitCommit: revision } }] } },
  };
  return { attestations: [{ bundle: { dsseEnvelope: { payload: b64(JSON.stringify(statement)) } } }] };
}

export type AppRepoOpts = { visibility?: string; appMain?: boolean; built?: boolean; attest?: unknown; anon?: number; missing?: boolean };

// 앱 저장소(public, app-main active, main HEAD 이미지 있음, provenance 맞음)와 GHCR 익명 pull 200.
export function appRepo(app: string, o: AppRepoOpts = {}): Rule[] {
  if (o.missing) return [ghGet(`repos/ukyi-app/${app}`, 404, { message: "Not Found" }), rule(ghArgv.ghcr(app), { stdout: "401" })];
  return [
    ghGet(`repos/ukyi-app/${app}`, 200, { visibility: o.visibility ?? "public", default_branch: "main" }),
    ghGet(`repos/ukyi-app/${app}/rulesets`, 200, o.appMain === false ? [] : [{ name: "app-main", enforcement: "active" }]),
    ghGet(`repos/ukyi-app/${app}/git/ref/heads/main`, 200, { object: { sha: APP_HEAD } }),
    ghGet(`orgs/ukyi-app/packages/container/${app}/versions?per_page=100`, 200, o.built === false ? [] : [{ name: DIGEST, metadata: { container: { tags: [`sha-${APP_HEAD}`] } } }, { name: OLD_DIGEST, metadata: { container: { tags: [`sha-${OLD_REV}`] } } }]),
    ghGet(`repos/ukyi-app/${app}/actions/runs?branch=main&head_sha=${APP_HEAD}&per_page=5`, 200, { workflow_runs: [{ id: 99, status: "in_progress", conclusion: null }] }),
    ghGet(`repos/ukyi-app/${app}/attestations/${DIGEST}`, 200, o.attest ?? attestation(app)),
    rule(ghArgv.ghcr(app), { stdout: String(o.anon ?? 200) }),
  ];
}

// Infisical 0.44.2 폴더 목록 출력(core infisical.ts 실측): 항목 {folderId, folderName, folderPath}, 빈 목록은 null.
export const folderJson = (parent: string, names: string[]) => JSON.stringify(names.length === 0 ? null : names.map((name, i) => ({ folderId: `f${i}`, folderName: name, folderPath: `${parent === "/" ? "" : parent}/${name}` })));

// Infisical 폴더 목록(부모 → 자식 이름들).
export function folders(tree: Record<string, string[]>): Rule[] {
  return Object.entries(tree).map(([parent, names]) => rule(infArgv.folders(FAKE_PROJECT, parent), { stdout: folderJson(parent, names) }));
}

export function createFolder(parent: string, name: string, resp: Resp = {}): Rule {
  return rule(infArgv.createFolder(FAKE_PROJECT, parent, name), resp);
}

export { infisicalList };
