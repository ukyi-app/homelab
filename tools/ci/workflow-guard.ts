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
  "permissions",
] as const;
export type Rule = (typeof RULES)[number];

const MERGE_FILE = "deploy-merge.yaml";
const MERGE_JOB = "merge";
const MERGE_ENV = "automerge";
const MERGE_KEY = "HOMELAB_MERGE_KEY";
const SHA_PIN = /^([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)(\/[^@\s]+)?@[0-9a-f]{40}$/;
// 액션 허용 목록(설계 C.4.10). 저장소 Actions 설정(selected: GitHub 소유, 검증된 제작자, Infisical/secrets-action)보다
// 좁게 적는다. 검증된 제작자 표시는 바뀔 수 있어 쓰는 제작자만 적는다. 더할 때는 이 목록과 infra/github의
// 허용 패턴을 같은 PR에서 바꾼다.
const ALLOWED_OWNERS = new Set(["actions", "github", "docker"]);
const ALLOWED_ACTIONS = new Set(["Infisical/secrets-action"]);
// GitHub 호스트 runner 레이블 리터럴만. group·표현식·배열은 self-hosted로 라우팅될 수 있어 받지 않는다.
const HOSTED_RUNNER = /^(ubuntu|windows|macos)-(latest|\d[\w.-]*)$/;

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

// 파싱한 uses 값마다 검사한다(원문 줄을 세지 않는다. run 블록 안의 "uses:" 글자는 액션이 아니다).
// 버전 주석은 파싱하면 사라지므로, 같은 값을 쓴 "uses: <값> # <버전>" 한 줄이 원문에 있어야 한다.
// 흐름 매핑({uses: ...})처럼 그 줄이 없으면 실패다.
function pins(file: WorkflowFile, uses: { where: string; ref: string }[]): Violation[] {
  const out: Violation[] = [];
  const lines = file.text.split("\n");
  for (const { where, ref } of uses) {
    if (ref.startsWith("./")) continue;
    if (ref.startsWith("docker://")) {
      if (!/@sha256:[0-9a-f]{64}$/.test(ref)) out.push({ rule: "pin", where, message: `docker 액션은 digest로 고정한다: ${ref}` });
      continue;
    }
    const pin = ref.match(SHA_PIN);
    if (!pin) {
      out.push({ rule: "pin", where, message: `uses는 40자 커밋 SHA로 고정한다: ${ref} (L33)` });
      continue;
    }
    if (!ALLOWED_OWNERS.has(pin[1]) && !ALLOWED_ACTIONS.has(`${pin[1]}/${pin[2]}`)) {
      out.push({ rule: "pin", where, message: `허용 목록 밖 액션이다: ${pin[1]}/${pin[2]} (설계 C.4.10)` });
    }
    const esc = ref.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&");
    const line = new RegExp(`^\\s*(-\\s+)?uses:\\s*(['"]?)${esc}\\2\\s*#\\s*v?\\d`);
    if (!lines.some((l) => line.test(l))) {
      out.push({ rule: "pin", where, message: `"uses: ${ref} # <버전>" 한 줄 형식이 아니거나 버전 주석이 없다` });
    }
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
  const uses: { where: string; ref: string }[] = [];
  const usedSecrets = new Set<string>();

  if (on.includes("pull_request_target")) add("pull-request-target", file.path, "pull_request_target를 쓰지 않는다(설계 C.4.10)");

  // 최소 권한(AGENTS.md): write-all 금지, 쓰기 권한은 워크플로 전체가 아니라 필요한 job에만.
  const perms = (p: unknown, where: string, top: boolean) => {
    if (p === "write-all") add("permissions", where, "permissions: write-all을 쓰지 않는다");
    if (top && p && typeof p === "object" && Object.values(p as Record<string, unknown>).some((v) => v === "write")) {
      add("permissions", where, "쓰기 권한은 워크플로 최상위가 아니라 job마다 준다");
    }
  };
  perms(wf.permissions, file.path, true);

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
    perms(job.permissions, where, false);
    if (Array.isArray(job.steps)) {
      job.steps.forEach((st: any, i: number) => {
        if (st && typeof st === "object" && "uses" in st) uses.push({ where: `${where} steps[${i}]`, ref: String(st.uses) });
      });
    }
    // 로컬 reusable 호출(./)만 받는다(reusable-call 규칙). 앱 저장소가 쓰는 태그 호출은 이 저장소 워크플로에 두지 않는다.
    if ("uses" in job) uses.push({ where, ref: String(job.uses) });

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

    // reusable 호출 job(uses)에는 runs-on이 없다.
    if (!("uses" in job)) {
      const runsOn = job["runs-on"];
      if (typeof runsOn !== "string" || !HOSTED_RUNNER.test(runsOn)) {
        add("self-hosted", where, `runs-on은 GitHub 호스트 runner 리터럴 하나만(group·표현식·배열 금지, 설계 C.4.10): ${JSON.stringify(runsOn)}`);
      }
    }
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

  out.push(...pins(file, uses));
  return out;
}

// 로컬 composite action 파일(action.yml). runs.steps의 uses를 워크플로 step과 같은 규칙으로 본다.
export function checkActionFile(file: WorkflowFile): Violation[] {
  let a: any;
  try {
    a = parseAll(file.text)[0];
  } catch (e) {
    return [{ rule: "parse", where: file.path, message: `YAML을 읽지 못했다: ${(e as Error).message}` }];
  }
  // docker action은 레지스트리 이미지를 digest로만. Dockerfile을 짓는 action은 FROM 태그가 움직여 쓰지 않는다.
  const out: Violation[] = [];
  if (a?.runs?.using === "docker") {
    const img = String(a.runs.image ?? "");
    if (!/^docker:\/\/.+@sha256:[0-9a-f]{64}$/.test(img)) out.push({ rule: "pin", where: file.path, message: `docker action 이미지는 docker://...@sha256으로 고정한다: ${img}` });
  }
  const steps: any[] = Array.isArray(a?.runs?.steps) ? a.runs.steps : [];
  const uses = steps
    .map((st, i) => (st && typeof st === "object" && "uses" in st ? { where: `${file.path} runs.steps[${i}]`, ref: String(st.uses) } : undefined))
    .filter((x): x is { where: string; ref: string } => !!x);
  return [...out, ...pins(file, uses)];
}

export function checkWorkflows(files: WorkflowFile[]): Violation[] {
  if (files.length === 0) return [{ rule: "parse", where: ".github/workflows", message: "워크플로 파일이 0개다(L40)" }];
  return files.flatMap(checkWorkflow);
}
