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
import { RULES, checkWorkflow, checkWorkflows } from "./workflow-guard";

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

// 들여쓴 kind(목록 항목 안, List 매니페스트 등)도 잡는다. 따옴표로 감싼 값도.
const SECRET_KIND = /^\s*(-\s+)?kind:\s*["']?Secret["']?\s*(#.*)?$/m;

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
      // kind: Secret 매니페스트 0건(설계 C.6.2). Helm 템플릿도 원문으로 본다. 음성 fixture는 뺀다.
      for (const f of gitFiles("*.yaml", "*.yml", "*.tpl")) {
        if (f.startsWith("tools/ci/fixtures/") || f.startsWith("docs/")) continue;
        if (SECRET_KIND.test(readText(f))) out.push({ rule: "no-secret", where: f, message: "kind: Secret 매니페스트를 두지 않는다" });
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
      console.log(`워크플로 ${files.length}개`);
      return checkWorkflows(files);
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
          if (!got.includes(expect)) out.push({ rule: "fixture", where: f, message: `${expect}가 걸리지 않았다(걸린 것: ${got.join(", ") || "없음"})` });
        }
      }
      for (const r of RULES) if (!covered.has(r)) out.push({ rule: "fixture", where: "tools/ci/fixtures/workflow-guard", message: `규칙 ${r}의 음성 fixture가 없다` });
      console.log(`workflow-guard fixture ${files.length}개`);
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
        const fn = check ? checks[check] : undefined;
        if (!fn || (expect !== "pass" && expect !== "fail")) {
          out.push({ rule: "fixture", where: f, message: `머리 주석 # check:(${Object.keys(checks).join("|")})와 # expect:(pass|fail)가 필요하다` });
          continue;
        }
        const docs = parseAll(text).map((obj) => ({ origin: `fixture:${basename(f)}`, obj }));
        const got = fn(docs);
        if (expect === "pass" && got.length > 0) out.push({ rule: "fixture", where: f, message: `대조군이 걸렸다: ${got.map(fmt).join("; ")}` });
        if (expect === "fail") {
          covered.add(check!);
          if (got.length === 0) out.push({ rule: "fixture", where: f, message: `${check}가 걸리지 않았다` });
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
