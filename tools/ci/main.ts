// 필수 검사 ci의 본체(설계 C.4.6). CI와 로컬이 같은 명령 `bun run ci` 하나를 쓴다(L42).
// 도구(gitleaks, actionlint, shellcheck, helm, kustomize, kubeconform, terraform)는 PATH에서 찾는다.
// 로컬은 mise install, CI는 .github/workflows/ci.yaml이 .tool-versions의 버전을 sha256과 대조해 깐다.
//
// 모든 단계를 끝까지 돌리고 위반을 모아 한 번에 보인다. 하나라도 있으면 exit 1.
// 로컬에서 일부만: bun run ci --only workflows,render
import { cpSync, existsSync, mkdirSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { type Doc, type Violation, ROOT, endGroup, errorLine, fmt, gitFiles, group, parseAll, readText, run, tempDir } from "./lib";
import { checkAll, checkIngress, checkNoSecrets, checkReadonlyRbac, checkRevisions, checkWorkloads } from "./policy";
import { kubeconform, renderAll } from "./render";
import { RULES, checkActionFile, checkWorkflow, checkWorkflows } from "./workflow-guard";
import { type Facts, evaluate } from "../deploy-merge/conditions";

type Step = { name: string; run: () => Violation[] };

function tool(rule: string, cmd: string[], env?: Record<string, string | undefined>): Violation[] {
  const r = run(cmd, { env });
  const out = (r.stdout + r.stderr).trim();
  if (out) console.log(out);
  return r.code === 0 ? [] : [{ rule, where: cmd[0], message: `exit ${r.code}` }];
}

// fixture 머리 주석: "# <키>: <값>"
function header(text: string, key: string): string | undefined {
  return text.match(new RegExp(`^# ${key}: (.+)$`, "m"))?.[1].trim();
}

// YAML로 읽히는 파일은 구조로(흐름 매핑 {kind: Secret} 포함), Helm 템플릿처럼 읽히지 않는 파일은 원문으로 본다.
const SECRET_KIND = /^\s*(-\s+)?["']?kind["']?\s*:\s*["']?Secret["']?\s*(#.*)?$/m;
// 흐름 매핑 안의 kind: Secret({apiVersion: v1, kind: Secret, ...}). 파싱되지 않는 템플릿에서 쓴다.
const SECRET_KIND_FLOW = /[{,]\s*["']?kind["']?\s*:\s*["']?Secret["']?\s*[,}]/;
function hasSecret(v: unknown): boolean {
  if (Array.isArray(v)) return v.some(hasSecret);
  if (v && typeof v === "object") {
    const o = v as Record<string, unknown>;
    if (o.kind === "Secret" && typeof o.apiVersion === "string" && o.apiVersion === "v1") return true;
    return Object.values(o).some(hasSecret);
  }
  return false;
}

const steps: Step[] = [
  {
    name: "gitleaks",
    // 작업 트리만 본다. 히스토리 전체를 보면 옛 커밋의 오탐이나 이미 폐기한 옛 값 하나가 모든 PR을 막는다.
    // push된 커밋은 저장소의 secret scanning·push protection이 먼저 본다.
    run: () => tool("gitleaks", ["gitleaks", "dir", "--config", ".gitleaks.toml", "--redact", "--no-banner", "--exit-code", "1", "."]),
  },
  {
    name: "tracked files",
    run: () => {
      const out: Violation[] = [];
      // kind: Secret 매니페스트 0건(설계 C.6.2). Helm 템플릿도 원문으로 본다. 음성 fixture만 뺀다(docs/도 본다).
      // JSON도 본다. plain 디렉터리 source는 .json 매니페스트도 배포한다.
      for (const f of gitFiles("*.yaml", "*.yml", "*.tpl", "*.json")) {
        if (f.startsWith("tools/ci/fixtures/")) continue;
        const text = readText(f);
        let found = SECRET_KIND.test(text) || SECRET_KIND_FLOW.test(text);
        if (!found) {
          try {
            found = hasSecret(parseAll(text));
          } catch {
            // 템플릿 등 YAML이 아닌 파일은 원문 검사만.
          }
        }
        if (found) out.push({ rule: "no-secret", where: f, message: "kind: Secret 매니페스트를 두지 않는다" });
      }
      // apps/<앱>/image.yaml은 app-build의 deploy-pr이 줄 단위로 읽는다(셸, 의존성 없음). 같은 형식을 여기서 강제한다:
      // 네 키가 한 줄씩 한 번, 그 밖에는 주석·빈 줄뿐. 사람이 롤백으로 고칠 때도 이 형식을 지킨다.
      for (const f of gitFiles("apps/*/image.yaml")) {
        const app = basename(dirname(f));
        const lines = readText(f).split("\n").filter((l) => !/^\s*(#.*)?$/.test(l));
        const want = [
          new RegExp(`^repository: ghcr\\.io/ukyi-app/${app}$`),
          /^digest: sha256:[0-9a-f]{64}$/,
          /^revision: [0-9a-f]{40}$/,
          /^hold: (true|false)$/,
        ];
        const ok = lines.length === want.length && want.every((re) => lines.filter((l) => re.test(l)).length === 1);
        if (!ok) out.push({ rule: "image-yaml", where: f, message: `repository: ghcr.io/ukyi-app/${app}, digest: sha256:<64자>, revision: <40자>, hold: true|false 네 줄만 둔다` });
      }
      // override 파일은 일반 .tf 위에 병합돼 리소스를 덮고, tfvars에는 자격이 들어가기 쉽다(설계 C.3.9, 옛 R41).
      for (const f of gitFiles()) {
        const b = basename(f);
        if (/override\.tf/.test(b) || /\.tfvars/.test(b)) out.push({ rule: "terraform-files", where: f, message: "*override.tf*·*.tfvars* 파일을 커밋하지 않는다" });
      }
      return out;
    },
  },
  { name: "actionlint", run: () => tool("actionlint", ["actionlint"]) },
  {
    name: "workflows",
    run: () => {
      const files = gitFiles(".github/workflows/*.yaml", ".github/workflows/*.yml").map((path) => ({ path, text: readText(path) }));
      // 로컬 composite action(action.yml)의 step uses도 같은 고정·허용 목록 규칙을 받는다. actionlint는 그 step을 보지 않는다.
      const actions = gitFiles("**/action.yml", "**/action.yaml", "action.yml", "action.yaml").map((path) => ({ path, text: readText(path) }));
      console.log(`워크플로 ${files.length}개, 로컬 action ${actions.length}개`);
      return [...checkWorkflows(files), ...actions.flatMap(checkActionFile)];
    },
  },
  {
    name: "workflow-guard fixtures",
    // 음성 fixture마다 기대한 규칙이 걸리는지, 대조군은 아무것도 걸리지 않는지 본다. 규칙마다 음성 fixture가 하나 이상 있어야 한다.
    run: () => {
      const out: Violation[] = [];
      const covered = new Set<string>();
      const files = gitFiles("tools/ci/fixtures/workflow-guard/*.yaml");
      for (const f of files) {
        const text = readText(f);
        const path = header(text, "path");
        const expect = header(text, "expect");
        if (!path || !expect) {
          out.push({ rule: "fixture", where: f, message: "머리 주석 # path:와 # expect:가 필요하다" });
          continue;
        }
        const got = checkWorkflow({ path, text }).map((v) => v.rule);
        if (expect === "pass") {
          if (got.length > 0) out.push({ rule: "fixture", where: f, message: `대조군이 걸렸다: ${got.join(", ")}` });
        } else {
          covered.add(expect);
          // 기대 규칙만 걸려야 한다. 다른 위반이 섞이면 기대 규칙이 사라져도 fixture가 초록으로 남는다.
          if (!got.includes(expect)) out.push({ rule: "fixture", where: f, message: `${expect}가 걸리지 않았다(걸린 것: ${got.join(", ") || "없음"})` });
          const other = [...new Set(got.filter((r) => r !== expect))];
          if (other.length > 0) out.push({ rule: "fixture", where: f, message: `기대하지 않은 규칙도 걸렸다: ${other.join(", ")}` });
        }
      }
      for (const r of RULES) if (!covered.has(r)) out.push({ rule: "fixture", where: "tools/ci/fixtures/workflow-guard", message: `규칙 ${r}의 음성 fixture가 없다` });
      console.log(`workflow-guard fixture ${files.length}개`);
      return out;
    },
  },
  {
    name: "deploy-merge fixtures",
    // 자동 병합 조건 9개(tools/deploy-merge/conditions.ts). ok.json은 모두 참인 대조군이고, 나머지는 ok.json에
    // patch 하나를 얹어 기대한 조건 하나만 거짓이 되는지 본다. 조건마다 음성 fixture가 하나 이상 있어야 한다.
    run: () => {
      const out: Violation[] = [];
      const dir = "tools/deploy-merge/fixtures";
      const files = gitFiles(`${dir}/*.json`);
      if (!files.includes(`${dir}/ok.json`)) return [{ rule: "fixture", where: dir, message: "대조군 ok.json이 없다" }];
      const base = JSON.parse(readText(`${dir}/ok.json`));
      const merge = (a: any, b: any): any => {
        if (b && typeof b === "object" && !Array.isArray(b) && a && typeof a === "object" && !Array.isArray(a)) {
          const o = { ...a };
          for (const [k, v] of Object.entries(b)) o[k] = merge(a[k], v);
          return o;
        }
        return b;
      };
      const okFailures = evaluate(base as Facts).failures;
      if (okFailures.length > 0) out.push({ rule: "fixture", where: `${dir}/ok.json`, message: `대조군이 걸렸다: ${JSON.stringify(okFailures)}` });
      const covered = new Set<number>();
      for (const f of files.filter((x) => !x.endsWith("/ok.json"))) {
        const fx = JSON.parse(readText(f));
        const got = evaluate(merge(base, fx.patch) as Facts).failures.map((x) => x.cond);
        covered.add(fx.expect);
        if (!got.includes(fx.expect)) out.push({ rule: "fixture", where: f, message: `조건 ${fx.expect}가 걸리지 않았다(걸린 것: ${got.join(", ") || "없음"})` });
        const others = [...new Set(got.filter((c) => c !== fx.expect))];
        if (others.length > 0) out.push({ rule: "fixture", where: f, message: `다른 조건도 걸렸다: ${others.join(", ")}` });
      }
      for (let c = 1; c <= 9; c++) if (!covered.has(c)) out.push({ rule: "fixture", where: dir, message: `조건 ${c}의 음성 fixture가 없다` });
      console.log(`deploy-merge fixture ${files.length}개`);
      return out;
    },
  },
  {
    name: "render, policy, kubeconform",
    run: () => {
      const r = renderAll();
      for (const t of r.targets) console.log(`렌더: ${t.origin}`);
      for (const s of r.skipped) console.log(`외부 차트(렌더하지 않음): ${s}`);
      return [...r.violations, ...checkAll(r.docs), ...kubeconform(r.targets)];
    },
  },
  {
    name: "policy fixtures",
    run: () => {
      const checks: Record<string, (d: Doc[]) => Violation[]> = {
        "no-secret": checkNoSecrets,
        workload: checkWorkloads,
        revision: checkRevisions,
        "readonly-rbac": checkReadonlyRbac,
        ingress: checkIngress,
      };
      const out: Violation[] = [];
      const covered = new Set<string>();
      const files = gitFiles("tools/ci/fixtures/policy/*.yaml");
      for (const f of files) {
        const text = readText(f);
        const check = header(text, "check");
        const expect = header(text, "expect");
        const rule = header(text, "rule");
        const match = header(text, "match");
        const fn = check ? checks[check] : undefined;
        if (!fn || (expect !== "pass" && expect !== "fail") || (expect === "fail" && (!rule || !match))) {
          out.push({ rule: "fixture", where: f, message: `머리 주석 # check:(${Object.keys(checks).join("|")}), # expect:(pass|fail), 음성이면 # rule:과 # match:(메시지 일부)가 필요하다` });
          continue;
        }
        const docs = parseAll(text).map((obj) => ({ origin: `fixture:${basename(f)}`, obj }));
        const got = fn(docs);
        if (expect === "pass" && got.length > 0) out.push({ rule: "fixture", where: f, message: `대조군이 걸렸다: ${got.map(fmt).join("; ")}` });
        if (expect === "fail") {
          covered.add(check!);
          // 모든 위반이 기대한 규칙·메시지여야 한다. 다른 위반이 섞이면 대상 검사가 사라져도 fixture가 초록으로 남는다.
          if (!got.some((v) => v.rule === rule && v.message.includes(match!))) out.push({ rule: "fixture", where: f, message: `${rule}(${match})가 걸리지 않았다` });
          const other = got.filter((v) => v.rule !== rule || !v.message.includes(match!));
          if (other.length > 0) out.push({ rule: "fixture", where: f, message: `기대하지 않은 위반: ${other.map(fmt).join("; ")}` });
        }
      }
      for (const c of Object.keys(checks)) if (!covered.has(c)) out.push({ rule: "fixture", where: "tools/ci/fixtures/policy", message: `검사 ${c}의 음성 fixture가 없다` });
      console.log(`policy fixture ${files.length}개`);
      return out;
    },
  },
  {
    name: "terraform",
    // 자격 없이 하는 것만(설계 C.3.9): fmt, backend 없는 init, validate, tests/가 있는 root의 terraform test(mock).
    // plan은 하지 않는다. 작업 사본의 .terraform(owner의 backend 설정)을 건드리지 않게 추적 파일만 임시 사본으로 옮겨 돈다.
    run: () => {
      const out: Violation[] = [];
      const fmtRes = tool("terraform-fmt", ["terraform", "fmt", "-check", "-recursive", "-diff", "infra"]);
      out.push(...fmtRes);
      const roots = [...new Set(gitFiles(":(glob)infra/*/*.tf").map(dirname))];
      if (roots.length === 0) out.push({ rule: "terraform", where: "infra", message: "Terraform root가 0개다(L40)" });
      const work = tempDir("terraform");
      // 자격이 들어가는 환경 변수는 넘기지 않는다. provider 캐시만 공유한다.
      const env: Record<string, string | undefined> = { PATH: process.env.PATH, HOME: process.env.HOME, TF_IN_AUTOMATION: "1", TF_INPUT: "0" };
      if (process.env.TF_PLUGIN_CACHE_DIR) env.TF_PLUGIN_CACHE_DIR = process.env.TF_PLUGIN_CACHE_DIR;
      for (const root of roots) {
        const dst = join(work, root);
        for (const f of gitFiles(`${root}/`)) {
          mkdirSync(dirname(join(work, f)), { recursive: true });
          cpSync(join(ROOT, f), join(work, f));
        }
        const tf = (args: string[], rule: string) => {
          const r = run(["terraform", `-chdir=${dst}`, ...args], { env });
          if (r.code !== 0) {
            console.log((r.stdout + r.stderr).trim());
            out.push({ rule, where: root, message: `terraform ${args[0]} exit ${r.code}` });
            return false;
          }
          return true;
        };
        console.log(`terraform: ${root}`);
        // lockfile=readonly: .terraform.lock.hcl 변경은 사람이 확인한다. CI가 몰래 고친 해시로 지나가지 않게 한다.
        if (!tf(["init", "-backend=false", "-lockfile=readonly", "-input=false", "-no-color"], "terraform-init")) continue;
        tf(["validate", "-no-color"], "terraform-validate");
        if (existsSync(join(dst, "tests"))) {
          const r = run(["terraform", `-chdir=${dst}`, "test", "-no-color"], { env });
          console.log((r.stdout + r.stderr).trim());
          if (r.code !== 0) out.push({ rule: "terraform-test", where: root, message: `terraform test exit ${r.code}` });
        }
      }
      return out;
    },
  },
];

function main(): number {
  const only = process.argv.find((a) => a.startsWith("--only="))?.slice("--only=".length) ?? (process.argv.includes("--only") ? process.argv[process.argv.indexOf("--only") + 1] : undefined);
  const wanted = only ? new Set(only.split(",")) : undefined;
  const selected = wanted ? steps.filter((s) => wanted.has(s.name) || wanted.has(s.name.split(/[ ,]/)[0])) : steps;
  if (selected.length === 0) {
    errorLine(`--only에 맞는 단계가 없다. 단계: ${steps.map((s) => s.name).join(" | ")}`);
    return 2;
  }
  const failed: { step: string; v: Violation }[] = [];
  for (const s of selected) {
    group(s.name);
    let vs: Violation[];
    try {
      vs = s.run();
    } catch (e) {
      vs = [{ rule: "error", where: s.name, message: (e as Error).message }];
    }
    endGroup();
    for (const v of vs) failed.push({ step: s.name, v });
    console.log(`${vs.length === 0 ? "통과" : `실패 ${vs.length}건`}: ${s.name}`);
  }
  if (failed.length > 0) {
    console.log("");
    for (const f of failed) errorLine(`${f.step}: ${fmt(f.v)}`);
    console.log(`\nci 실패: ${failed.length}건`);
    return 1;
  }
  console.log(`\nci 통과(${selected.length}단계)`);
  return 0;
}

process.exit(main());
