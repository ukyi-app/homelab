// GitHub API PR 작성기(PLAN D3). 로컬 체크아웃 없이 blob·tree·commit을 API로 만들어 cli/<동사>-<app> 브랜치에 올리고 PR을 연다.
// 작성자는 사람의 gh 로그인이고 병합하지 않는다(사람이 검토 후 병합, 설계 C.7·C.4.7).
// 브랜치 갱신(lead 결정 2026-10-23): 커밋 부모는 항상 최신 main, ref는 force로 옮긴다. 브랜치 머리 커밋에
// Homelab-CLI 트레일러가 없으면(사람이 push한 커밋) 덮지 않고 멈춘다.
import type { Ctx, Observation, Step } from "./command";
import { HOMELAB_REPO, ghGet, ghSend, ok } from "./github";
import { GIT_SHA, fullMatch, repoPathProblem } from "./names";
import { containsTracked, isSecret } from "./secret";

export type FileChange = { path: string; content: string | null };

export const TRAILER = "Homelab-CLI";
const OWNER = HOMELAB_REPO.split("/")[0];

export function branchName(commandPath: string, app: string): string {
  return `cli/${commandPath.trim().split(/\s+/).join("-")}-${app}`;
}

function encodePath(path: string): string {
  return path.split("/").map(encodeURIComponent).join("/");
}

export function mainSha(ctx: Ctx): string {
  const sha = ok(ghGet(ctx, `repos/${HOMELAB_REPO}/git/ref/heads/main`), "main 읽기").json?.object?.sha;
  if (typeof sha !== "string" || !fullMatch(GIT_SHA, sha)) throw new Error("main SHA 형식이 아니다");
  return sha;
}

// 저장소 파일 원문. 없으면 null. ref는 브랜치 이름이나 SHA.
export function readRepoFile(ctx: Ctx, path: string, ref = "main"): string | null {
  const problem = repoPathProblem(path);
  if (problem) throw new Error(problem);
  const r = ghGet(ctx, `repos/${HOMELAB_REPO}/contents/${encodePath(path)}?ref=${encodeURIComponent(ref)}`);
  if (r.status === 404) return null;
  ok(r, `${path} 읽기`);
  if (r.json?.type !== "file") throw new Error(`${path}: 파일이 아니다`);
  // contents API는 1MB를 넘으면 content를 비운다. 이 저장소의 values 파일은 작아 그 경우를 오류로 둔다.
  if (r.json.encoding !== "base64" || typeof r.json.content !== "string") throw new Error(`${path}: 내용을 받지 못했다(1MB 초과?)`);
  return Buffer.from(r.json.content, "base64").toString("utf8");
}

type OpenPr = { number: number; headSha: string };

function openPr(ctx: Ctx, branch: string): OpenPr | null {
  const r = ok(ghGet(ctx, `repos/${HOMELAB_REPO}/pulls?head=${encodeURIComponent(`${OWNER}:${branch}`)}&state=open`), "열린 PR 찾기");
  const list = Array.isArray(r.json) ? r.json : [];
  if (list.length > 1) throw new Error(`${branch}에 열린 PR이 ${list.length}개다. 하나만 남기고 닫는다`);
  if (list.length === 0) return null;
  return { number: list[0].number, headSha: list[0].head?.sha };
}

function validate(changes: FileChange[]): void {
  if (changes.length === 0) throw new Error("PR에 넣을 파일 변경이 없다");
  const seen = new Set<string>();
  for (const c of changes) {
    const problem = repoPathProblem(c.path);
    if (problem) throw new Error(problem);
    if (seen.has(c.path)) throw new Error(`같은 파일을 두 번 바꾼다: ${c.path}`);
    seen.add(c.path);
    // 공개 저장소에 들어가는 내용이다. 시크릿이 섞이면 만들지 않는다.
    if (isSecret(c.content)) throw new Error(`${c.path}: 파일 내용에 시크릿 객체를 넣으려 했다`);
    if (c.content !== null && containsTracked(c.content)) throw new Error(`${c.path}: 파일 내용에 시크릿 값이 섞였다`);
  }
}

export type PrSpec = {
  // 명령 경로(예 "db add"). 브랜치 이름과 트레일러에 쓴다.
  command: string;
  app: string;
  title: string;
  body: string;
  changes: FileChange[];
};

export function prStep(spec: PrSpec): Step {
  validate(spec.changes);
  const branch = branchName(spec.command, spec.app);
  if (!fullMatch(/cli\/[a-z0-9-]+/, branch)) throw new Error(`브랜치 이름이 아니다: ${JSON.stringify(branch)}`);
  const target = `PR ${HOMELAB_REPO}`;

  const read = async (ctx: Ctx): Promise<Observation> => {
    const base = mainSha(ctx);
    const onMain = spec.changes.every((c) => readRepoFile(ctx, c.path, base) === c.content);
    if (onMain) return { state: "same", action: "none", detail: "main과 같음 (PR 필요 없음)" };
    const pr = openPr(ctx, branch);
    if (!pr) return { state: "missing", action: "create", detail: `새로 (브랜치 ${branch})` };
    const onBranch = spec.changes.every((c) => readRepoFile(ctx, c.path, pr.headSha) === c.content);
    if (onBranch) return { state: "same", action: "none", detail: `PR #${pr.number} 열림, 내용 같음`, wait: `PR #${pr.number} 검토·병합 대기` };
    return { state: "differs", action: "update", detail: `PR #${pr.number} 갱신 (브랜치 ${branch})` };
  };

  const apply = async (ctx: Ctx): Promise<void> => {
    const base = mainSha(ctx);
    const baseTree = ok(ghGet(ctx, `repos/${HOMELAB_REPO}/git/commits/${base}`), "main 커밋 읽기").json?.tree?.sha;
    if (typeof baseTree !== "string") throw new Error("main tree를 읽지 못했다");
    // tree 항목에 내용을 직접 넣으면 blob을 따로 만들지 않아도 된다. sha null은 삭제.
    const tree = spec.changes.map((c) => (c.content === null ? { path: c.path, mode: "100644", type: "blob", sha: null } : { path: c.path, mode: "100644", type: "blob", content: c.content }));
    const treeSha = ok(ghSend(ctx, "POST", `repos/${HOMELAB_REPO}/git/trees`, { base_tree: baseTree, tree }), "tree 만들기").json?.sha;
    const message = `${spec.title}\n\n${TRAILER}: ${spec.command}`;
    const commit = ok(ghSend(ctx, "POST", `repos/${HOMELAB_REPO}/git/commits`, { message, tree: treeSha, parents: [base] }), "커밋 만들기").json?.sha;
    if (typeof commit !== "string" || !fullMatch(GIT_SHA, commit)) throw new Error("커밋 SHA를 받지 못했다");

    const ref = ghGet(ctx, `repos/${HOMELAB_REPO}/git/ref/heads/${branch}`);
    if (ref.status === 404) {
      ok(ghSend(ctx, "POST", `repos/${HOMELAB_REPO}/git/refs`, { ref: `refs/heads/${branch}`, sha: commit }), "브랜치 만들기");
    } else {
      const head = ok(ref, "브랜치 읽기").json?.object?.sha;
      const headMsg = ok(ghGet(ctx, `repos/${HOMELAB_REPO}/git/commits/${head}`), "브랜치 머리 커밋 읽기").json?.message ?? "";
      if (!new RegExp(`^${TRAILER}: `, "m").test(headMsg)) {
        throw new Error(`${branch} 머리 커밋에 ${TRAILER} 트레일러가 없다(사람이 push한 커밋을 덮지 않는다). 그 커밋을 옮기거나 브랜치를 지운 뒤 다시 실행한다`);
      }
      ok(ghSend(ctx, "PATCH", `repos/${HOMELAB_REPO}/git/refs/heads/${branch}`, { sha: commit, force: true }), "브랜치 옮기기");
    }

    const pr = openPr(ctx, branch);
    if (pr) ok(ghSend(ctx, "PATCH", `repos/${HOMELAB_REPO}/pulls/${pr.number}`, { title: spec.title, body: spec.body }), "PR 갱신");
    else ok(ghSend(ctx, "POST", `repos/${HOMELAB_REPO}/pulls`, { title: spec.title, head: branch, base: "main", body: spec.body }), "PR 만들기");
  };

  return { id: "pr", target, read, apply };
}
