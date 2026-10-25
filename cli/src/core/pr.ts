// GitHub API PR 작성기(PLAN D3). 로컬 체크아웃 없이 tree·commit을 API로 만들어 cli/<동사>-<app> 브랜치에 올리고 PR을 연다.
// 작성자는 사람의 gh 로그인이고 병합하지 않는다(사람이 검토 후 병합, 설계 C.7·C.4.7).
//
// 파일 내용은 고정 문자열이 아니라 edit(현재 내용) 함수로 받는다(#873 2라운드 P2). 읽을 때와 apply 때 모두 그 시점의
// main 스냅샷 하나에서 파일을 읽어 다시 계산하고, 커밋 tree도 같은 스냅샷 위에 만든다. 그래서 그사이 병합된 변경을
// 되돌리지 않는다(예: app-repos.json에 다른 PR이 alpha를 더했으면 beta 계산에 alpha가 들어간다).
//
// 브랜치 갱신: 머리 커밋에 Homelab-CLI 트레일러가 없으면(사람이 push한 커밋) 멈춘다(lead 결정 2026-10-23).
// force는 쓰지 않는다(#873 1라운드). 새 커밋의 부모를 [main 스냅샷, 확인한 브랜치 머리]로 두고 fast-forward로만 옮긴다.
// 확인과 PATCH 사이에 사람이 push하면 새 커밋이 그 push의 자손이 아니라 GitHub가 422로 거부한다.
import { jsonStringify } from "./intrinsics";
import type { Observation, ReadCtx, RepoRead, Step, WriteCtx } from "./command";
import type { Exec } from "./exec";
import { HOMELAB_REPO, ghGetRaw, ghSend, ok } from "./github";
import { GIT_SHA, fullMatch, repoPathProblem } from "./names";
import { writeExecOf } from "./runtime-internal";
import { containsTracked, isSecret } from "./secret";

export const TRAILER = "Homelab-CLI";
const OWNER = HOMELAB_REPO.split("/")[0];

export function branchName(commandPath: string, app: string): string {
  return `cli/${commandPath.trim().split(/\s+/).join("-")}-${app}`;
}

function encodePath(path: string): string {
  return path.split("/").map(encodeURIComponent).join("/");
}

export function repoRead(exec: Exec): RepoRead {
  return {
    mainSha() {
      const sha = ok(ghGetRaw(exec, `repos/${HOMELAB_REPO}/git/ref/heads/main`), "main 읽기").json?.object?.sha;
      if (typeof sha !== "string" || !fullMatch(GIT_SHA, sha)) throw new Error("main SHA 형식이 아니다");
      return sha;
    },
    readFile(path, ref = "main") {
      const problem = repoPathProblem(path);
      if (problem) throw new Error(problem);
      if (!/^[A-Za-z0-9._\/-]+$/.test(ref)) throw new Error("ref 형식이 아니다");
      const r = ghGetRaw(exec, `repos/${HOMELAB_REPO}/contents/${encodePath(path)}?ref=${encodeURIComponent(ref)}`);
      if (r.status === 404) return null;
      ok(r, `${path} 읽기`);
      if (r.json?.type !== "file") throw new Error(`${path}: 파일이 아니다`);
      // contents API는 1MB를 넘으면 content를 비운다. 이 저장소의 values 파일은 작아 그 경우를 오류로 둔다.
      if (r.json.encoding !== "base64" || typeof r.json.content !== "string") throw new Error(`${path}: 내용을 받지 못했다(1MB 초과?)`);
      return Buffer.from(r.json.content, "base64").toString("utf8");
    },
  };
}

type OpenPr = { number: number; headSha: string };

function openPr(ctx: ReadCtx | WriteCtx, branch: string): OpenPr | null {
  const r = ok(ctx.gh.get(`repos/${HOMELAB_REPO}/pulls?head=${encodeURIComponent(`${OWNER}:${branch}`)}&state=open`), "열린 PR 찾기");
  const list = Array.isArray(r.json) ? r.json : [];
  if (list.length > 1) throw new Error(`${branch}에 열린 PR이 ${list.length}개다. 하나만 남기고 닫는다`);
  if (list.length === 0) return null;
  // base가 main이 아닌 PR을 같다고 보면 main에 반영할 PR 없이 영원히 기다린다(Connector 3라운드).
  if (list[0].base?.ref !== "main") throw new Error(`PR #${list[0].number}의 base가 main이 아니다. 닫거나 base를 main으로 바꾼 뒤 다시 실행한다`);
  const headSha = list[0].head?.sha;
  if (typeof headSha !== "string" || !fullMatch(GIT_SHA, headSha)) throw new Error(`PR #${list[0].number} 머리 SHA를 읽지 못했다`);
  return { number: list[0].number, headSha };
}

// 브랜치 머리 커밋이 CLI가 만든 것인지. 아니면 던진다(사람 커밋을 덮지도, 같다고 보고하지도 않는다).
function requireCliHead(ctx: ReadCtx | WriteCtx, branch: string, sha: string): void {
  const msg = ok(ctx.gh.get(`repos/${HOMELAB_REPO}/git/commits/${sha}`), "브랜치 머리 커밋 읽기").json?.message ?? "";
  if (!new RegExp(`^${TRAILER}: `, "m").test(msg)) {
    throw new Error(`${branch} 머리 커밋에 ${TRAILER} 트레일러가 없다(사람이 push한 커밋을 덮지 않는다). 그 커밋을 옮기거나 브랜치를 지운 뒤 다시 실행한다`);
  }
}

// PR이 main 스냅샷에 대해 바꾸는 파일 목록(merge-base 기준).
function changedFiles(ctx: ReadCtx | WriteCtx, base: string, head: string): string[] {
  const r = ok(ctx.gh.get(`repos/${HOMELAB_REPO}/compare/${base}...${head}`), "PR 변경 목록");
  const files = Array.isArray(r.json?.files) ? r.json.files : [];
  // compare는 파일 300개까지 준다. CLI PR은 몇 개뿐이라 그보다 많으면 사람 변경이 섞인 것으로 본다.
  if (files.length >= 300) throw new Error("PR 변경 파일이 300개 이상이다(CLI가 만든 PR이 아니다)");
  // rename은 새 경로가 filename, 원래 경로가 previous_filename이다. 둘 다 센다. 원래 경로를 빼면 명령 밖 파일을 명령의
  // 경로로 옮긴 PR이 "같음"으로 보이고, 병합하면 원래 파일이 사라진다(Connector 4360396722).
  return files.flatMap((f: { filename: string; previous_filename?: string }) => (typeof f.previous_filename === "string" ? [f.filename, f.previous_filename] : [f.filename]));
}

export type FileContents = Record<string, string | null>;

export type PrSpec = {
  // 명령 경로(예 "db add"). 브랜치 이름과 트레일러에 쓴다.
  command: string;
  app: string;
  title: string;
  body: string;
  // 이 PR이 다루는 파일. edit는 이 파일들의 현재 내용(없으면 null)을 받아 원하는 내용(지우려면 null)을 같은 키로 돌려준다.
  files: string[];
  edit(current: FileContents): FileContents;
  // 바뀌는 파일마다 사람용 요약(예 "uses.postgres: false → true"). 있으면 plan detail에 붙인다(설계 D 5번 상자, 02 R8).
  describe?(path: string, before: string | null, after: string | null): string;
};

function snapshot(repo: RepoRead, files: string[], ref: string): FileContents {
  return Object.fromEntries(files.map((f) => [f, repo.readFile(f, ref)]));
}

function desiredOf(spec: PrSpec, current: FileContents): FileContents {
  const out = spec.edit({ ...current });
  const keys = Object.keys(out ?? {}).sort();
  if (jsonStringify(keys) !== jsonStringify([...spec.files].sort())) throw new Error("edit()는 files의 파일마다 내용을 하나씩 돌려줘야 한다");
  for (const [path, content] of Object.entries(out)) {
    if (isSecret(content)) throw new Error(`${path}: 파일 내용에 시크릿 객체를 넣으려 했다`);
    if (content !== null && typeof content !== "string") throw new Error(`${path}: 파일 내용은 문자열이나 null이다`);
    // 공개 저장소에 들어가는 내용이다. 추적 중인 시크릿 원문이 섞이면 만들지 않는다.
    if (content !== null && containsTracked(content)) throw new Error(`${path}: 파일 내용에 시크릿 값이 섞였다`);
  }
  return out;
}

const sameContents = (a: FileContents, b: FileContents) => Object.keys(a).every((k) => a[k] === b[k]);

// main 대비 바뀌는 파일의 요약. 요약에도 값이 섞이면 출력 계층이 막는다.
function summaryOf(spec: PrSpec, current: FileContents, desired: FileContents): string {
  if (!spec.describe) return "";
  const parts = spec.files.filter((f) => current[f] !== desired[f]).map((f) => `${f}: ${spec.describe!(f, current[f], desired[f])}`);
  return parts.length ? `; ${parts.join("; ")}` : "";
}

export function prStep(spec: PrSpec): Step {
  if (spec.files.length === 0) throw new Error("PR에 넣을 파일이 없다");
  if (new Set(spec.files).size !== spec.files.length) throw new Error("같은 파일을 두 번 적었다");
  for (const f of spec.files) {
    const problem = repoPathProblem(f);
    if (problem) throw new Error(problem);
  }
  const branch = branchName(spec.command, spec.app);
  if (!fullMatch(/cli\/[a-z0-9-]+/, branch)) throw new Error("브랜치 이름 형식이 아니다");
  const paths = new Set(spec.files);
  const target = `PR ${HOMELAB_REPO}`;

  const read = async (ctx: ReadCtx): Promise<Observation> => {
    const base = ctx.repo.mainSha();
    const current = snapshot(ctx.repo, spec.files, base);
    const desired = desiredOf(spec, current);
    const onMain = sameContents(desired, current);
    // 열린 PR을 main 비교보다 먼저 본다(Connector 2라운드): main에 이미 반영됐어도 위험한 PR이 열려 있을 수 있다.
    const pr = openPr(ctx, branch);
    if (pr) {
      requireCliHead(ctx, branch, pr.headSha);
      const extra = changedFiles(ctx, base, pr.headSha).filter((f) => !paths.has(f));
      if (onMain) {
        if (extra.length > 0) throw new Error(`main에 이미 반영됐는데 PR #${pr.number}에 이 명령 밖 파일 ${extra.length}개가 있다. 확인한 뒤 닫는다`);
        return { state: "same", action: "none", detail: "main과 같음", warn: `PR #${pr.number}은 이제 필요 없다. 닫는다: gh pr close ${pr.number}` };
      }
      const onBranch = sameContents(desired, snapshot(ctx.repo, spec.files, pr.headSha));
      if (extra.length === 0 && onBranch) return { state: "same", action: "none", detail: `PR #${pr.number} 열림, 내용 같음`, wait: `PR #${pr.number} 검토·병합 대기` };
      return { state: "differs", action: "update", detail: `PR #${pr.number} 갱신 (브랜치 ${branch}${extra.length ? `, 이 명령 밖 파일 ${extra.length}개를 뺀다` : ""})${summaryOf(spec, current, desired)}` };
    }
    if (onMain) return { state: "same", action: "none", detail: "main과 같음 (PR 필요 없음)" };
    return { state: "missing", action: "create", detail: `새로 (브랜치 ${branch})${summaryOf(spec, current, desired)}` };
  };

  const apply = async (w: WriteCtx): Promise<void> => {
    const exec = writeExecOf(w);
    // 이 apply의 스냅샷 하나: base에서 파일을 읽어 다시 계산하고, tree도 base 위에 만든다.
    const base = w.repo.mainSha();
    const desired = desiredOf(spec, snapshot(w.repo, spec.files, base));
    const baseTree = ok(w.gh.get(`repos/${HOMELAB_REPO}/git/commits/${base}`), "main 커밋 읽기").json?.tree?.sha;
    if (typeof baseTree !== "string") throw new Error("main tree를 읽지 못했다");

    const ref = w.gh.get(`repos/${HOMELAB_REPO}/git/ref/heads/${branch}`);
    let head: string | null = null;
    if (ref.status !== 404) {
      head = ok(ref, "브랜치 읽기").json?.object?.sha;
      if (typeof head !== "string" || !fullMatch(GIT_SHA, head)) throw new Error(`${branch} 머리 SHA를 읽지 못했다`);
      requireCliHead(w, branch, head);
    }

    // tree 항목에 내용을 직접 넣으면 blob을 따로 만들지 않아도 된다. sha null은 삭제.
    const tree = spec.files.map((path) => (desired[path] === null ? { path, mode: "100644", type: "blob", sha: null } : { path, mode: "100644", type: "blob", content: desired[path] }));
    const treeSha = ok(ghSend(exec, "POST", `repos/${HOMELAB_REPO}/git/trees`, { base_tree: baseTree, tree }), "tree 만들기").json?.sha;
    const message = `${spec.title}\n\n${TRAILER}: ${spec.command}`;
    const parents = head ? [base, head] : [base];
    const commit = ok(ghSend(exec, "POST", `repos/${HOMELAB_REPO}/git/commits`, { message, tree: treeSha, parents }), "커밋 만들기").json?.sha;
    if (typeof commit !== "string" || !fullMatch(GIT_SHA, commit)) throw new Error("커밋 SHA를 받지 못했다");

    if (head === null) {
      // 그사이 누가 같은 브랜치를 만들었으면 422로 거부된다(덮지 않는다).
      const created = ghSend(exec, "POST", `repos/${HOMELAB_REPO}/git/refs`, { ref: `refs/heads/${branch}`, sha: commit });
      if (created.status === 422) throw new Error(`${branch}가 그사이 생겼다. 덮지 않았다. 다시 실행해 상태를 읽는다`);
      ok(created, "브랜치 만들기");
    } else {
      const moved = ghSend(exec, "PATCH", `repos/${HOMELAB_REPO}/git/refs/heads/${branch}`, { sha: commit, force: false });
      if (moved.status === 422) throw new Error(`${branch}가 확인 뒤 바뀌었다(사람 push?). 덮지 않았다. 다시 실행해 상태를 읽는다`);
      ok(moved, "브랜치 옮기기");
    }

    const pr = openPr(w, branch);
    if (pr) ok(ghSend(exec, "PATCH", `repos/${HOMELAB_REPO}/pulls/${pr.number}`, { title: spec.title, body: spec.body }), "PR 갱신");
    else ok(ghSend(exec, "POST", `repos/${HOMELAB_REPO}/pulls`, { title: spec.title, head: branch, base: "main", body: spec.body }), "PR 만들기");
  };

  return { id: "pr", target, read, apply };
}
