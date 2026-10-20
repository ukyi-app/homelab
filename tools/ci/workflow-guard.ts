// workflow-guard(설계 C.4.6, C.4.8, F D-26 조건 (2)). .github/workflows/의 워크플로 파일을 검사한다.
//
// 이것은 실수를 잡는 장치이고 경계가 아니다. 이 파일을 고치는 PR의 ci는 고친 코드로 돈다.
// 병합 키의 경계는 environment automerge의 배포 브랜치 정책(main)과 main을 바꾸는 사람 검토(ruleset B)다.
//
// YAML은 별칭(&·*)과 병합 키(<<)까지 푸는 파서로 읽는다. 원문 검색만으로는 *alias로 넣은 environment를 놓친다.
// uses의 SHA 고정과 버전 주석은 원문 줄로 본다(파싱하면 주석이 사라진다).
import { basename } from "node:path";
import { type Violation, parseAll } from "./lib";

export type WorkflowFile = { path: string; text: string };

export const RULES = [
  "parse",
  "env-expression",
  "automerge-scope",
  "deploy-merge-trigger",
  "deploy-merge-env",
  "reusable-call",
  "dynamic-secrets",
  "merge-key-scope",
  "env-trigger",
  "dispatch-secrets",
  "pull-request-target",
  "self-hosted",
  "pin",
] as const;
export type Rule = (typeof RULES)[number];

const MERGE_FILE = "deploy-merge.yaml";
const MERGE_JOB = "merge";
const MERGE_ENV = "automerge";
const MERGE_KEY = "HOMELAB_MERGE_KEY";
// 공통 워크플로를 태그로 부르는 앱 저장소 호출만 SHA 대신 태그를 쓴다(설계 C.4.5). homelab 안에서는 쓰지 않는다.
const SELF_TAG_CALL = /^ukyi-app\/homelab\/\.github\/workflows\/app-build\.yaml@app-build-v\d+\.\d+\.\d+$/;
const SHA_PIN = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(\/[^@\s]+)?@[0-9a-f]{40}$/;

function triggers(on: unknown): string[] {
  if (typeof on === "string") return [on];
  if (Array.isArray(on)) return on.map(String);
  if (on && typeof on === "object") return Object.keys(on);
  return [];
}

// 문자열 안의 표현식. if:는 ${{ }} 없이도 표현식이다.
function expressions(key: string | undefined, s: string): string[] {
  const found = [...s.matchAll(/\$\{\{([\s\S]*?)\}\}/g)].map((m) => m[1]);
  if (key === "if" && found.length === 0) return [s];
  return found;
}

type SecretRef = { name?: string; text: string };

// secrets 참조를 찾는다. secrets.<이름>만 정적 참조다. secrets[...], toJSON(secrets), secrets 단독은 동적이다.
function secretRefs(expr: string): SecretRef[] {
  const out: SecretRef[] = [];
  for (const m of expr.matchAll(/\bsecrets\b/gi)) {
    const rest = expr.slice((m.index ?? 0) + m[0].length);
    const prop = rest.match(/^\s*\.\s*([A-Za-z_][A-Za-z0-9_-]*)/);
    out.push(prop ? { name: prop[1], text: `secrets.${prop[1]}` } : { text: expr.trim() });
  }
  return out;
}

function walk(v: unknown, visit: (key: string | undefined, s: string, jobId: string | undefined) => void, key?: string, jobId?: string, depth = 0): void {
  if (typeof v === "string") visit(key, v, jobId);
  else if (Array.isArray(v)) for (const x of v) walk(x, visit, key, jobId, depth + 1);
  else if (v && typeof v === "object") {
    for (const [k, x] of Object.entries(v)) {
      // jobs.<id> 아래면 그 job id를 같이 넘긴다.
      const nextJob = depth === 1 && key === "jobs" ? k : jobId;
      walk(x, visit, k, nextJob, depth + 1);
    }
  }
}

function pins(file: WorkflowFile, parsedUses: number): Violation[] {
  const out: Violation[] = [];
  let lineUses = 0;
  file.text.split("\n").forEach((line, i) => {
    const m = line.match(/^\s*(?:-\s+)?uses:\s*(['"]?)([^'"\s#]+)\1\s*(#.*)?$/);
    if (!m) return;
    lineUses++;
    const ref = m[2];
    const where = `${file.path}:${i + 1}`;
    if (ref.startsWith("./")) return;
    if (ref.startsWith("docker://")) {
      if (!/@sha256:[0-9a-f]{64}$/.test(ref)) out.push({ rule: "pin", where, message: `docker 액션은 digest로 고정한다: ${ref}` });
      return;
    }
    if (SELF_TAG_CALL.test(ref)) return;
    if (!SHA_PIN.test(ref)) {
      out.push({ rule: "pin", where, message: `uses는 40자 커밋 SHA로 고정한다: ${ref} (L33)` });
      return;
    }
    if (!m[3] || !/#\s*v?\d/.test(m[3])) out.push({ rule: "pin", where, message: `SHA 옆에 버전 주석(# vX.Y.Z)을 단다: ${ref}` });
  });
  // 한 줄 블록 형식이 아닌 uses(흐름 매핑 등)는 원문 검사를 피한다. 개수가 다르면 실패로 둔다.
  if (lineUses !== parsedUses) {
    out.push({ rule: "pin", where: file.path, message: `uses ${parsedUses}개 중 ${lineUses}개만 줄 단위로 읽었다. "uses: <ref> # <버전>" 한 줄 형식으로 쓴다` });
  }
  return out;
}

export function checkWorkflow(file: WorkflowFile): Violation[] {
  const out: Violation[] = [];
  const add = (rule: Rule, where: string, message: string) => out.push({ rule, where, message });
  const name = basename(file.path);

  let wf: any;
  try {
    const docs = parseAll(file.text);
    if (docs.length !== 1 || typeof docs[0] !== "object" || Array.isArray(docs[0])) throw new Error("문서 하나짜리 매핑이 아니다");
    wf = docs[0];
  } catch (e) {
    add("parse", file.path, `YAML을 읽지 못했다: ${(e as Error).message}`);
    return out;
  }

  const on = triggers(wf.on);
  const jobs: Record<string, any> = wf.jobs && typeof wf.jobs === "object" ? wf.jobs : {};
  const isMergeFile = name === MERGE_FILE;
  let declaresEnv = false;
  let parsedUses = 0;
  const usedSecrets = new Set<string>();

  if (on.includes("pull_request_target")) add("pull-request-target", file.path, "pull_request_target를 쓰지 않는다(설계 C.4.10)");

  if (isMergeFile) {
    const wr = wf.on?.workflow_run;
    const ok =
      on.length === 1 &&
      on[0] === "workflow_run" &&
      JSON.stringify(wr?.workflows) === JSON.stringify(["ci"]) &&
      JSON.stringify(wr?.types) === JSON.stringify(["completed"]);
    if (!ok) add("deploy-merge-trigger", file.path, "deploy-merge의 트리거는 workflow_run(workflows: [ci], types: [completed]) 하나뿐이다");
  }

  for (const [jobId, job] of Object.entries(jobs)) {
    const where = `${file.path} jobs.${jobId}`;
    if (!job || typeof job !== "object") continue;
    if (Array.isArray(job.steps)) parsedUses += job.steps.filter((s: any) => s && typeof s === "object" && "uses" in s).length;
    if ("uses" in job) parsedUses++;

    const env = job.environment;
    if (env !== undefined) {
      declaresEnv = true;
      const envName = typeof env === "string" ? env : env && typeof env === "object" ? env.name : undefined;
      if (typeof envName !== "string") {
        add("env-expression", where, "environment 이름은 문자열 리터럴이어야 한다");
      } else {
        if (envName.includes("${{")) add("env-expression", where, `environment 이름에 표현식을 쓰지 않는다: ${envName}`);
        // environment 이름은 대소문자를 가리지 않는다(GitHub). AutoMerge도 같은 environment다.
        const isMerge = envName.trim().toLowerCase() === MERGE_ENV;
        const isMergeJob = isMergeFile && jobId === MERGE_JOB;
        if (isMerge && !isMergeJob) add("automerge-scope", where, `environment ${envName}는 ${MERGE_FILE}의 ${MERGE_JOB} job만 쓴다`);
        if (isMergeJob && !(isMerge && typeof env === "object" && env.deployment === false)) {
          add("deploy-merge-env", where, `${MERGE_JOB} job은 environment: {name: ${MERGE_ENV}, deployment: false}를 쓴다`);
        }
      }
    } else if (isMergeFile && jobId === MERGE_JOB) {
      add("deploy-merge-env", where, `${MERGE_JOB} job에 environment ${MERGE_ENV}가 없다`);
    }

    // caller가 넘긴 secret은 called job의 environment가 받는다. 다른 저장소의 reusable은 그 코드를 우리가 검토하지 않는다.
    if (job.secrets === "inherit") add("reusable-call", where, "secrets: inherit를 쓰지 않는다");
    if (typeof job.uses === "string" && !job.uses.startsWith("./")) add("reusable-call", where, `로컬(./)이 아닌 reusable 워크플로를 부르지 않는다: ${job.uses}`);

    const runsOn = JSON.stringify(job["runs-on"] ?? "");
    if (/self-hosted/i.test(runsOn)) add("self-hosted", where, "self-hosted runner를 쓰지 않는다(설계 C.4.10)");
  }

  walk(wf, (key, s, jobId) => {
    for (const expr of expressions(key, s)) {
      for (const ref of secretRefs(expr)) {
        const where = jobId ? `${file.path} jobs.${jobId}` : file.path;
        if (!ref.name) {
          add("dynamic-secrets", where, `secrets를 이름 없이 참조한다: ${ref.text}`);
          continue;
        }
        usedSecrets.add(ref.name.toUpperCase());
        if (ref.name.toUpperCase() === MERGE_KEY && !(isMergeFile && jobId === MERGE_JOB)) {
          add("merge-key-scope", where, `${MERGE_KEY}는 ${MERGE_FILE}의 ${MERGE_JOB} job만 쓴다`);
        }
      }
    }
  });

  // environment를 선언한 워크플로는 workflow_run만. environment secret을 쓰려면 environment를 선언해야 하므로
  // "environment secret을 쓰는 워크플로"보다 넓게 잡는다(F D-26 조건 (2)).
  if (declaresEnv && !(on.length === 1 && on[0] === "workflow_run")) {
    add("env-trigger", file.path, `environment를 선언한 워크플로의 트리거는 workflow_run 하나뿐이다: ${on.join(", ")}`);
  }
  // Codex Connector는 workflow_dispatch(actions write)와 repository_dispatch(contents write)를 일으킬 수 있다.
  usedSecrets.delete("GITHUB_TOKEN");
  const dispatch = on.filter((t) => t === "workflow_dispatch" || t === "repository_dispatch");
  if (dispatch.length > 0 && usedSecrets.size > 0) {
    add("dispatch-secrets", file.path, `${dispatch.join(", ")} 워크플로가 secret을 쓴다: ${[...usedSecrets].join(", ")}`);
  }

  out.push(...pins(file, parsedUses));
  return out;
}

export function checkWorkflows(files: WorkflowFile[]): Violation[] {
  if (files.length === 0) return [{ rule: "parse", where: ".github/workflows", message: "워크플로 파일이 0개다(L40)" }];
  return files.flatMap(checkWorkflow);
}
