import { appendFileSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, isAbsolute } from "node:path";
import { isolatedSpawnSync } from "./exec.ts";

const REPOSITORY = "ukyi-app/homelab";
const REPOSITORY_ID = 1265054638;
// 2026-09-14 GET /repos/ukyi-app/homelab/actions/workflows/build.yaml 읽기 조회로 확인했다.
export const BUILD_WORKFLOW_ID = 293145411;
const BUILD_PATH = ".github/workflows/build.yaml";
const REMOTE = `https://github.com/${REPOSITORY}.git`;
const FULL_SHA = /^[0-9a-f]{40}$/;
const SWEEP_BRANCH = /^(bump|create-database|create-cache|create-app|update-secrets)\/[a-zA-Z0-9/_-]+$/;
type Obj = Record<string, unknown>;
function obj(value: unknown): Obj {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("객체 응답 필요");
  return value as Obj;
}
function equal(actual: unknown, expected: unknown, field: string): void {
  if (actual !== expected) throw new Error(`${field}: 불일치`);
}
function positive(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1) throw new Error("양의 정수 필요");
  return value;
}
function sha(value: unknown): string {
  if (typeof value !== "string" || !FULL_SHA.test(value)) throw new Error("full SHA 필요");
  return value;
}
function repo(value: unknown): void {
  const r = obj(value);
  equal(r.id, REPOSITORY_ID, "repository.id");
  equal(r.full_name, REPOSITORY, "repository.full_name");
}

// 후보는 object로만 읽는다. checkout·hooks·filter·외부 merge driver와 호스트 Git 설정을 쓰지 않는다.
// 로컬 remote 인자는 실제 bare-repo 테스트용 의존성이다. CLI는 항상 고정 HTTPS remote만 쓴다.
export class ObjectGit {
  readonly directory = mkdtempSync(join(tmpdir(), "homelab-writeback-"));
  private readonly env: NodeJS.ProcessEnv;
  private readonly options: string[];
  private readonly remote: string;
  constructor(token: string, remote = REMOTE) {
    if (remote !== REMOTE && !isAbsolute(remote)) throw new Error("고정 HTTPS 또는 로컬 bare remote 필요");
    this.remote = remote;
    this.env = {
      PATH: process.env.PATH, HOME: this.directory, XDG_CONFIG_HOME: this.directory,
      LC_ALL: "C", GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null",
      GIT_ATTR_NOSYSTEM: "1", GIT_TERMINAL_PROMPT: "0", GIT_NO_REPLACE_OBJECTS: "1",
      GIT_AUTHOR_NAME: "ukyi-homelab-writer[bot]", GIT_COMMITTER_NAME: "ukyi-homelab-writer[bot]",
      GIT_AUTHOR_EMAIL: "293311924+ukyi-homelab-writer[bot]@users.noreply.github.com",
      GIT_COMMITTER_EMAIL: "293311924+ukyi-homelab-writer[bot]@users.noreply.github.com",
      // 인증은 환경으로만 공급한다. argv·원장·오류 출력에 토큰을 넣지 않는다.
      GIT_CONFIG_COUNT: "1", GIT_CONFIG_KEY_0: "http.https://github.com/.extraheader",
      GIT_CONFIG_VALUE_0: `AUTHORIZATION: basic ${Buffer.from(`x-access-token:${token}`).toString("base64")}`,
    };
    this.options = ["-c", "core.hooksPath=/dev/null", "-c", "core.attributesFile=/dev/null",
      "-c", "credential.helper=", "-c", "commit.gpgSign=false", "-c", "merge.renormalize=false",
      "-c", "protocol.allow=never", "-c", `protocol.${remote === REMOTE ? "https" : "file"}.allow=always`];
    try { this.git(["init", "--bare", "--template=", this.directory]); }
    catch (error) { this.close(); throw error; }
  }
  private result(args: string[]) {
    return isolatedSpawnSync("git", [...this.options, "-C", this.directory, ...args], {
      encoding: "utf8", env: this.env, timeout: 120_000, maxBuffer: 8 * 1024 * 1024,
    });
  }
  git(args: string[]): string {
    const r = this.result(args);
    // remote stderr에는 비신뢰 텍스트가 들어갈 수 있어 그대로 출력하지 않는다.
    if (r.error || r.status !== 0) throw new Error(`Git ${args[0]} 실패(exit=${r.status ?? "실행 오류"}; 충돌/lease/권한/연결 확인)`);
    return r.stdout.trim();
  }
  fetchMain(): string {
    this.git(["fetch", "--no-tags", this.remote, "+refs/heads/main:refs/heads/trusted-main"]);
    return sha(this.git(["rev-parse", "refs/heads/trusted-main^{commit}"]));
  }
  ancestor(head: string, main: string): boolean {
    sha(head); sha(main);
    const r = this.result(["merge-base", "--is-ancestor", head, main]);
    if (r.error || (r.status !== 0 && r.status !== 1)) throw new Error("main ancestry 조회 실패");
    return r.status === 0;
  }
  mergeHead(branch: string, head: string, main: string): string {
    if (!SWEEP_BRANCH.test(branch)) throw new Error("writer 전용 sweep ref 밖의 변경 거부");
    sha(head); sha(main);
    const ref = `refs/heads/${branch}`;
    this.git(["check-ref-format", ref]);
    this.git(["fetch", "--no-tags", this.remote, `+${ref}:refs/heads/selected`]);
    equal(this.git(["rev-parse", "refs/heads/selected^{commit}"]), head, "head lease(fetch)");
    if (this.ancestor(main, head)) return head;
    const tree = sha(this.git(["merge-tree", "--write-tree", "--no-messages", head, main]));
    const commit = sha(this.git(["commit-tree", tree, "-p", head, "-p", main, "-m", "chore: 고정 main 변경을 봇 PR에 병합"]));
    this.push(ref, head, commit);
    return commit;
  }
  push(ref: string, head: string, commit: string): void {
    if (!ref.startsWith("refs/heads/") || !SWEEP_BRANCH.test(ref.slice(11))) throw new Error("sweep push ref 거부");
    sha(head); sha(commit);
    if (!this.ancestor(head, commit)) throw new Error("기존 head를 보존하지 않는 push 거부");
    this.git(["push", "--porcelain", `--force-with-lease=${ref}:${head}`, this.remote, `${commit}:${ref}`]);
  }
  close(): void { rmSync(this.directory, { recursive: true, force: true }); }
}

export function sweepCandidates(value: unknown, git: ObjectGit): void {
  if (!Array.isArray(value)) throw new Error("sweep 후보 배열 필요");
  // PR base는 입력으로 받지 않는다. main은 한 번만 고정하고 모든 병합이 그 object를 쓴다.
  const main = git.fetchMain();
  const failed: number[] = [];
  for (const entry of value) {
    const p = obj(entry), number = positive(p.number);
    try {
      if (typeof p.headRefName !== "string") throw new Error("head ref 필요");
      const commit = git.mergeHead(p.headRefName, sha(p.headRefOid), main);
      console.log(`PR #${number}: 고정 main ${main} → head ${commit}`);
    } catch (error) {
      console.error(`PR #${number}: ${error instanceof Error ? error.message : "병합 실패"}`);
      failed.push(number);
    }
  }
  if (failed.length) throw new Error(`sweep 실패 PR: ${failed.join(", ")}`);
}

type Get = (path: string) => Promise<unknown>;
function runIdentity(value: unknown, expected: Obj, owner: string): Obj {
  const r = obj(value);
  repo(r.repository); repo(r.head_repository);
  equal(r.id, positive(expected.id), "run.id");
  equal(r.run_attempt, positive(expected.run_attempt), "run.attempt");
  equal(r.head_sha, sha(expected.head_sha), "run.head_sha");
  equal(r.workflow_id, BUILD_WORKFLOW_ID, "run.workflow_id");
  equal(r.status, "completed", "run.status"); equal(r.conclusion, "success", "run.conclusion");
  equal(r.head_branch, "main", "run.head_branch");
  if (r.event !== "push" && r.event !== "workflow_dispatch") throw new Error("build event 거부");
  equal(r.event, expected.event, "run.event");
  // ref suffix는 보조 검사다. suffix 없는 정상 응답도 반드시 workflow ID와 main ancestry를 증명한다.
  if (r.path !== BUILD_PATH && r.path !== `${BUILD_PATH}@refs/heads/main`) throw new Error("build workflow path 거부");
  if (!owner) throw new Error("HOMELAB_OWNER 필요");
  const actor = obj(r.actor).login, triggering = obj(r.triggering_actor).login;
  if (r.event === "workflow_dispatch" && (typeof actor !== "string" || actor.toLowerCase() !== owner.toLowerCase())) throw new Error("build dispatch actor 거부");
  if ((r.run_attempt as number) > 1 || r.event === "workflow_dispatch") {
    if (typeof triggering !== "string" || triggering.toLowerCase() !== owner.toLowerCase()) throw new Error("build 재실행 개시자 거부");
  }
  return r;
}

// API는 GET만 쓴다. 후보 artifact나 checkout을 실행하지 않고 고정 식별자와 object graph를 확인한다.
export async function verifyBuild(event: unknown, owner: string, get: Get, git: Pick<ObjectGit, "fetchMain" | "ancestor">) {
  const payload = obj(event); repo(payload.repository);
  const expected = obj(payload.workflow_run);
  runIdentity(expected, expected, owner);
  const id = positive(expected.id), attempt = positive(expected.run_attempt);
  const workflow = obj(await get(`/actions/workflows/${BUILD_WORKFLOW_ID}`));
  equal(workflow.id, BUILD_WORKFLOW_ID, "workflow.id"); equal(workflow.path, BUILD_PATH, "workflow.path");
  equal(workflow.state, "active", "workflow.state");
  runIdentity(await get(`/actions/runs/${id}`), expected, owner);
  const run = runIdentity(await get(`/actions/runs/${id}/attempts/${attempt}`), expected, owner);
  const main = git.fetchMain(), head = sha(run.head_sha);
  if (!git.ancestor(head, main)) throw new Error("build head가 보호 main의 ancestor가 아님");
  const started = Date.parse(String(run.run_started_at)), ended = Date.parse(String(run.updated_at));
  if (!Number.isFinite(started) || !Number.isFinite(ended) || ended < started) throw new Error("build 실행 시간 불량");
  const artifacts: Obj[] = [];
  let total: number | undefined;
  for (let page = 1; ; page++) {
    if (page > 100) throw new Error("artifact pagination 상한 초과");
    const data = obj(await get(`/actions/runs/${id}/artifacts?per_page=100&page=${page}`));
    if (!Number.isSafeInteger(data.total_count) || (data.total_count as number) < 0 || !Array.isArray(data.artifacts)) throw new Error("artifact 목록 불량");
    total ??= data.total_count as number;
    equal(data.total_count, total, "artifact 목록 변경");
    artifacts.push(...data.artifacts.map(obj));
    if (artifacts.length === total) break;
    if (!data.artifacts.length || artifacts.length > total) throw new Error("artifact 목록 불완전");
  }
  const ids: number[] = [], names = new Set<string>();
  for (const a of artifacts) {
    if (typeof a.name !== "string" || !a.name.startsWith("built-")) continue;
    if (!/^built-[a-z0-9-]+$/.test(a.name) || names.has(a.name)) throw new Error("built marker 이름 중복/불량");
    names.add(a.name); equal(a.expired, false, "artifact.expired");
    const source = obj(a.workflow_run);
    equal(source.id, id, "artifact.run.id"); equal(source.repository_id, REPOSITORY_ID, "artifact.repository_id");
    equal(source.head_repository_id, REPOSITORY_ID, "artifact.head_repository_id"); equal(source.head_sha, head, "artifact.head_sha");
    const created = Date.parse(String(a.created_at));
    if (!Number.isFinite(created) || created < started || created > ended) throw new Error("이전 attempt/실행 밖 artifact 거부");
    ids.push(positive(a.id));
  }
  if (new Set(ids).size !== ids.length) throw new Error("artifact ID 중복");
  // 목록을 읽는 동안 시작된 새 attempt도 차단한다. 다운로드는 검증한 불변 ID만 받는다.
  runIdentity(await get(`/actions/runs/${id}`), expected, owner);
  return { head_sha: head, run_id: id, run_attempt: attempt, main_sha: main, artifact_ids: ids.sort((a, b) => a - b).join(",") };
}

if (import.meta.main) {
  let git: ObjectGit | undefined;
  try {
    equal(process.env.GITHUB_REPOSITORY, REPOSITORY, "repository");
    equal(process.env.GITHUB_REPOSITORY_ID, String(REPOSITORY_ID), "repository_id");
    equal(process.env.GITHUB_REF, "refs/heads/main", "ref");
    if (!process.env.GH_TOKEN) throw new Error("GH_TOKEN 필요");
    git = new ObjectGit(process.env.GH_TOKEN);
    if (process.argv[2] === "sweep") {
      if (!process.env.SWEEP_CANDIDATES) throw new Error("SWEEP_CANDIDATES 필요");
      sweepCandidates(JSON.parse(readFileSync(process.env.SWEEP_CANDIDATES, "utf8")), git);
    } else if (process.argv[2] === "verify-build") {
      equal(process.env.GITHUB_EVENT_NAME, "workflow_run", "event");
      if (!process.env.GITHUB_EVENT_PATH || !process.env.GITHUB_OUTPUT) throw new Error("event/output 경로 필요");
      const get: Get = async (path) => {
        const response = await fetch(`https://api.github.com/repos/${REPOSITORY}${path}`, {
          method: "GET", redirect: "error", signal: AbortSignal.timeout(30_000),
          headers: { Authorization: `Bearer ${process.env.GH_TOKEN}`, Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "Cache-Control": "no-cache" },
        });
        if (!response.ok) throw new Error(`build API 조회 실패: HTTP ${response.status}`);
        return response.json();
      };
      const receipt = await verifyBuild(JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, "utf8")), process.env.HOMELAB_OWNER ?? "", get, git);
      if (process.env.EXPECTED_ARTIFACT_IDS !== undefined) equal(receipt.artifact_ids, process.env.EXPECTED_ARTIFACT_IDS, "artifact IDs 재검증");
      for (const [key, value] of Object.entries(receipt)) appendFileSync(process.env.GITHUB_OUTPUT, `${key}=${value}\n`);
      console.log(JSON.stringify(receipt));
    } else throw new Error("sweep|verify-build 필요");
  } catch (error) {
    console.error(`ci-writeback: ${error instanceof Error ? error.message : "실패"}`);
    process.exitCode = 1;
  } finally { git?.close(); }
}
