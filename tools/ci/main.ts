// 필수 검사 ci의 본체(설계 C.4.6). CI와 로컬이 같은 명령 `bun run ci` 하나를 쓴다(L42).
// 도구(gitleaks, actionlint, shellcheck, helm, kustomize, kubeconform, terraform)는 PATH에서 찾는다.
// 로컬은 mise install, CI는 .github/workflows/ci.yaml이 .tool-versions의 버전을 sha256과 대조해 깐다.
//
// 모든 단계를 끝까지 돌리고 위반을 모아 한 번에 보인다. 하나라도 있으면 exit 1.
// 로컬에서 일부만: bun run ci --only workflows,render
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { checkAlerting } from "./alerting";
import { checkSecretPaths, checkValkeyWiring, checkVendoredCharts } from "./data";
import { type Doc, type Violation, ARGOCD_SOURCE_OVERRIDE, ROOT, endGroup, errorLine, fmt, gitFiles, group, parseAll, readText, run, tempDir } from "./lib";
import { checkAll, checkIngress, checkNoSecrets, checkReadonlyRbac, checkRevisions, checkSandbox, checkWorkloads } from "./policy";
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

// helm template 실패 출력을 오류 단위로 나눈다. schema 위반은 최상위 "- at ..." 항목마다(들여쓴 하위 줄 포함),
// 템플릿 fail은 "Error:" 줄 하나다. schema 위반은 한 번에 모두 나오므로 섞인 위반도 보인다.
function helmErrors(stderr: string): string[] {
  const lines = stderr.split("\n");
  if (!stderr.includes("don't meet the specifications of the schema")) return lines.filter((l) => l.startsWith("Error:"));
  const errs: string[] = [];
  for (const l of lines) {
    if (l.startsWith("- at ")) errs.push(l);
    else if (l.startsWith("  ") && errs.length > 0) errs[errs.length - 1] += ` ${l.trim()}`;
  }
  return errs;
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

// 작업 트리 검사와 룰 시험이 같은 인자를 쓴다. 그래서 룰 시험의 gitleaks:allow 경우가 CI 호출의 플래그도 보증한다.
// --ignore-gitleaks-allow: 같은 줄의 gitleaks:allow 주석으로 룰을 비켜 가지 못하게 한다(.gitleaks.toml 머리 주석).
const GITLEAKS_DIR = ["gitleaks", "dir", "--config", join(ROOT, ".gitleaks.toml"), "--no-banner", "--ignore-gitleaks-allow"];

// .gitleaksignore의 fingerprint는 어느 룰의 finding이든 버린다. --gitleaks-ignore-path를 빈 곳으로 돌려도 gitleaks가
// 스캔 루트의 파일을 따로 읽어(v8.30.1 실측) 막지 못하므로, 루트에 있거나 어디든 추적되면 거부한다.
function gitleaksIgnoreFiles(dir: string, tracked: string[]): string[] {
  const found = tracked.filter((f) => basename(f) === ".gitleaksignore");
  if (existsSync(join(dir, ".gitleaksignore")) && !found.includes(".gitleaksignore")) found.push(".gitleaksignore");
  return found;
}

const steps: Step[] = [
  {
    name: "gitleaks",
    // 작업 트리만 본다. 히스토리 전체를 보면 옛 커밋의 오탐이나 이미 폐기한 옛 값 하나가 모든 PR을 막는다.
    // push된 커밋은 저장소의 secret scanning·push protection이 먼저 본다.
    run: () => [
      ...gitleaksIgnoreFiles(ROOT, gitFiles()).map((f) => ({ rule: "gitleaks", where: f, message: ".gitleaksignore를 두지 않는다(gitleaks finding을 버린다)" })),
      ...tool("gitleaks", [...GITLEAKS_DIR, "--redact", "--exit-code", "1", "."]),
    ],
  },
  {
    name: "gitleaks rules",
    // .gitleaks.toml의 D-23 룰(tailnet 이름, IPv4, IPv6)이 실제 꼴은 잡고 자리표시·면제 값은 놓아주는지. 실제 꼴의 값은 여기서 조립해
    // 임시 폴더에만 쓴다. 저장소에 그대로 적으면 위 gitleaks 단계가 이 파일을 잡는다.
    run: () => {
      const out: Violation[] = [];
      const ts = ["ts", "net"].join(".");
      const ip = (...o: number[]) => o.join(".");
      const host = "tail" + "1a2b3c";
      const v6 = ["fd7a", "115c", "a1e0"].join(":");
      const allow = "gitleaks" + ":allow";
      // [경로, 내용, 기대 룰(없으면 걸리지 않아야 함)]
      const cases: [string, string, string | undefined][] = [
        ["host.md", `${host}.${ts}`, "tailnet-hostname"],
        ["fqdn.md", `nuc.${host}.${ts}`, "tailnet-hostname"],
        ["upper.md", `${host.toUpperCase()}.${ts.toUpperCase()}`, "tailnet-hostname"],
        ["hyphen.md", `cobra-ghost.${ts}`, "tailnet-hostname"],
        ["underscore.md", `_${host}.${ts}_`, "tailnet-hostname"],
        ["allow-comment.md", `${host}.${ts} # ${allow}`, "tailnet-hostname"],
        ["example-elsewhere.md", `example.${ts}`, "tailnet-hostname"],
        ["tools/go-redirect.test.sh", `${host}.${ts}`, "tailnet-hostname"],
        ["placeholder.md", `<tailnet>.${ts} <서비스>.<tailnet>.${ts} *.${ts} .${ts}`, undefined],
        ["tools/go-redirect.test.sh", `example.${ts} example-tailnet.${ts} Example.${ts}`, undefined],
        // 면제 값 바로 뒤의 실제 값(뒤 경계를 소비하면 빠진다), 반대 순서, 밑줄.
        ["tools/go-redirect.test.sh", `example.${ts} ${host}.${ts}`, "tailnet-hostname"],
        ["tools/go-redirect.test.sh", `${host}.${ts} example.${ts}`, "tailnet-hostname"],
        ["tools/go-redirect.test.sh", `_example.${ts}_ _${host}.${ts}_`, "tailnet-hostname"],
        ["two-names.md", `a.${ts} b.${ts}`, "tailnet-hostname"],
        ["other-domain.md", `foo.${ts}work cdn.${ts}-mirror.example foo.${ts}.example _bar.${ts}.example.org_`, undefined],
        ["trailing-dot.md", `${host}.${ts}.`, "tailnet-hostname"],
        ["after-other-domain.md", `foo.${ts}.example ${host}.${ts}`, "tailnet-hostname"],
        ["ip.md", ip(100, 101, 2, 3), "tailscale-ip"],
        ["ip-low.md", ip(100, 64, 0, 1), "tailscale-ip"],
        ["ip-high.md", ip(100, 127, 255, 254), "tailscale-ip"],
        ["ip-other-cidr.md", `${ip(100, 64, 0, 0)}/12`, "tailscale-ip"],
        ["ip-underscore.md", `_${ip(100, 101, 2, 3)}_`, "tailscale-ip"],
        ["ip-allow-comment.md", `${ip(100, 101, 2, 3)} // ${allow}`, "tailscale-ip"],
        ["ip-outside.md", `${ip(100, 63, 255, 255)} ${ip(100, 128, 0, 1)} ${ip(1100, 64, 1, 1)}`, undefined],
        ["ip-not-ip.md", `${ip(100, 64, 999, 999)} ${ip(100, 64, 1, 2, 3)} ${ip(100, 64, 1, 256)} ${ip(100, 64, 1, 1000)} ${ip(100, 64, 0, 0)}/33 ${ip(5, 100, 64, 1, 1)}`, undefined],
        ["ip-cidr32.md", `${ip(100, 101, 2, 3)}/32`, "tailscale-ip"],
        ["ip-sentence-end.md", `주소는 ${ip(100, 101, 2, 3)}.`, "tailscale-ip"],
        ["ip-after-range.md", `${ip(100, 64, 0, 0)}/10 ${ip(100, 101, 2, 3)}`, "tailscale-ip"],
        ["ip-before-range.md", `${ip(100, 101, 2, 3)} ${ip(100, 64, 0, 0)}/10`, "tailscale-ip"],
        ["ip-after-quad100.md", `${ip(100, 100, 100, 100)},${ip(100, 101, 2, 3)}`, "tailscale-ip"],
        ["ip-after-not-ip.md", `${ip(100, 64, 999, 1)} ${ip(100, 101, 2, 3)}`, "tailscale-ip"],
        ["ip-underscore-pair.md", `_${ip(100, 64, 0, 0)}/10_ _${ip(100, 101, 2, 3)}_`, "tailscale-ip"],
        ["ip-range.md", `${ip(100, 64, 0, 0)}/10 ${ip(100, 100, 100, 100)}`, undefined],
        ["v6.md", `${v6}:ab12:4843:cd96:6258:b240`, "tailscale-ipv6"],
        ["v6-full-zero.md", `${v6}:0:0:0:0:1`, "tailscale-ipv6"],
        ["v6-short.md", `${v6}::1234:5678`, "tailscale-ipv6"],
        ["v6-upper.md", `${v6.toUpperCase()}::AB12`, "tailscale-ipv6"],
        ["v6-allow-comment.md", `${v6}::1 # ${allow}`, "tailscale-ipv6"],
        ["v6-range.md", `${v6}::/48 '${v6}:'`, undefined],
        ["v6-magicdns.md", `${v6}::53 ${v6.toUpperCase()}::53`, undefined],
        ["v6-after-magicdns.md", `${v6}::53 ${v6}::1234`, "tailscale-ipv6"],
        ["v6-magicdns-longer.md", `${v6}::5353`, "tailscale-ipv6"],
        ["v6-not-ip.md", `x${v6}::1 ${v6}::12345 ${v6}:::1 ${v6}::1::2 ${v6}:1:2:3:4:5:6 ${v6}:1:2:3:4:5:6:7 ${v6}::1: ${v6}::1g ${v6}:1:2:3:4:5:: ${v6}::1:2:3:4:5`, undefined],
        ["v6-trailing-double-colon.md", `${v6}:1:2:3:4::`, "tailscale-ipv6"],
        ["v6-underscore.md", `_${v6}::1_`, "tailscale-ipv6"],
        ["v6-cidr128.md", `${v6}::1/128`, "tailscale-ipv6"],
        ["v6-after-not-ip.md", `${v6}::12345 ${v6}::1`, "tailscale-ipv6"],
      ];
      // 경우마다 따로 스캔한다. 면제의 paths는 스캔 루트 기준이라 저장소와 같은 상대 경로에 둬야 한다.
      const reports = tempDir("gitleaks-report");
      cases.forEach(([path, text, want], i) => {
        const dir = tempDir("gitleaks-rules");
        mkdirSync(dirname(join(dir, path)), { recursive: true });
        writeFileSync(join(dir, path), `${text}\n`);
        const report = join(reports, `${i}.json`);
        const r = run([...GITLEAKS_DIR, "--exit-code", "0", "--report-format", "json", "--report-path", report, "."], { cwd: dir });
        if (r.code !== 0) {
          out.push({ rule: "gitleaks-rules", where: `${i}:${path}`, message: `gitleaks exit ${r.code}: ${(r.stdout + r.stderr).trim()}` });
          return;
        }
        const rules = [...new Set((JSON.parse(readFileSync(report, "utf8")) as { RuleID: string }[]).map((x) => x.RuleID))];
        const ok = want ? rules.length === 1 && rules[0] === want : rules.length === 0;
        if (!ok) out.push({ rule: "gitleaks-rules", where: `${i}:${path}`, message: `기대 ${want ?? "없음"}, 결과 ${rules.join(",") || "없음"}` });
      });
      // .gitleaksignore 우회: 실제로 finding을 버리는지(거부가 필요한 이유)와 ci·pre-commit 훅이 그 파일을 거부하는지.
      const ign = tempDir("gitleaks-ignore");
      writeFileSync(join(ign, "f.md"), `${host}.${ts}\n`);
      const fpReport = join(reports, "ignore.json");
      run([...GITLEAKS_DIR, "--exit-code", "0", "--report-format", "json", "--report-path", fpReport, "."], { cwd: ign });
      const fp = (JSON.parse(readFileSync(fpReport, "utf8")) as { Fingerprint: string }[])[0]?.Fingerprint;
      if (!fp) out.push({ rule: "gitleaks-rules", where: "gitleaksignore", message: "우회 시험 값이 처음부터 걸리지 않았다" });
      writeFileSync(join(ign, ".gitleaksignore"), `${fp}\n`);
      if (run([...GITLEAKS_DIR, "--exit-code", "1", "."], { cwd: ign }).code !== 0) {
        console.log("참고: .gitleaksignore가 finding을 버리지 않았다(gitleaks 동작 변화). 거부는 그대로 둔다");
      }
      if (gitleaksIgnoreFiles(ign, []).length !== 1) out.push({ rule: "gitleaks-rules", where: "gitleaksignore", message: "ci가 루트 .gitleaksignore를 거부하지 않는다" });
      if (gitleaksIgnoreFiles(ROOT, ["a/b/.gitleaksignore"]).length === 0) out.push({ rule: "gitleaks-rules", where: "gitleaksignore", message: "ci가 추적된 하위 .gitleaksignore를 거부하지 않는다" });
      // pre-commit 훅: 설정의 entry를 그대로 .gitleaksignore가 있는 폴더에서 돌린다. gitleaks까지 가기 전에 멈춰야 한다.
      // 인라인 면제도 받지 않아야 한다(이 시험의 gitleaks 호출은 dir뿐이라 훅 인자는 원문으로 본다).
      const hook = parseAll(readText(".pre-commit-config.yaml"))[0].repos.flatMap((r: { hooks: { id: string; entry?: string }[] }) => r.hooks).find((h: { id: string }) => h.id === "gitleaks");
      const entry: string = hook?.entry ?? "";
      if (!entry.includes("--ignore-gitleaks-allow")) out.push({ rule: "gitleaks-rules", where: ".pre-commit-config.yaml", message: "gitleaks 훅에 --ignore-gitleaks-allow가 없다" });
      const h = run(["bash", "-c", entry], { cwd: ign });
      if (h.code === 0 || !h.stderr.includes(".gitleaksignore")) out.push({ rule: "gitleaks-rules", where: ".pre-commit-config.yaml", message: `gitleaks 훅이 .gitleaksignore를 거부하지 않는다(exit ${h.code})` });
      console.log(`gitleaks D-23 룰 ${cases.length}경우`);
      return out;
    },
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
        if (ARGOCD_SOURCE_OVERRIDE.test(b)) out.push({ rule: "argocd-source", where: f, message: ".argocd-source*.yaml을 두지 않는다(Argo CD가 source 매개변수를 덮어 ci 렌더와 실제 배포가 달라진다)" });
      }
      return out;
    },
  },
  { name: "actionlint", run: () => tool("actionlint", ["actionlint"]) },
  {
    name: "shellcheck",
    // 추적한 셸 스크립트 전부. -x로 source하는 파일까지 따라간다(host/lib.sh 등).
    run: () => {
      const files = gitFiles("*.sh");
      if (files.length === 0) return [{ rule: "shellcheck", where: ".", message: "셸 스크립트가 0개다(L40)" }];
      return tool("shellcheck", ["shellcheck", "-x", "-P", "SCRIPTDIR", ...files]);
    },
  },
  {
    name: "tf-github wrapper",
    // tools/tf-github.sh의 거부 규칙을 가짜 gh·infisical·terraform으로 시험한다(자격 없음).
    run: () => tool("tf-github", ["bash", "tools/tf-github.test.sh"]),
  },
  {
    name: "temp cleanup",
    // tempDir 폴더가 어떻게 끝나든 지워지는지(lib.ts). 자식 프로세스를 빈 TMPDIR로 돌려 끝난 뒤 남은 것을 센다.
    run: () => {
      const out: Violation[] = [];
      const cases: [string, number][] = [["ok", 0], ["exit", 3], ["throw", 1], ["reject", 1], ["sigterm", 143]];
      for (const [mode, want] of cases) {
        const tmp = tempDir("cleanup-test");
        const r = run(["bun", "tools/ci/temp-cleanup-child.ts", mode], { env: { PATH: process.env.PATH, HOME: process.env.HOME, TMPDIR: tmp } });
        const left = readdirSync(tmp);
        if (!r.stdout.includes("made 2")) out.push({ rule: "temp-cleanup", where: mode, message: `자식이 폴더를 만들지 못했다: ${(r.stdout + r.stderr).trim()}` });
        if (r.code !== want) out.push({ rule: "temp-cleanup", where: mode, message: `exit ${r.code}, 기대 ${want}` });
        if (left.length > 0) out.push({ rule: "temp-cleanup", where: mode, message: `남은 임시 폴더: ${left.join(", ")}` });
      }
      console.log(`임시 폴더 정리 ${cases.length}경우`);
      return out;
    },
  },
  {
    name: "app-build deploy-pr",
    // app-build.yaml 배포 PR 단계를 그대로 꺼내 가짜 gh·git으로 돌린다(배포 브랜치 404·200·500의 lease, 설계 B.8 E5).
    run: () => tool("app-build", ["bash", "tools/app-build.test.sh"]),
  },
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
    // expect "pass"는 patch를 얹어도 모두 참이어야 하는 대조군이다(입력 해석의 정상 경로, 예: CODEOWNERS 404 뒤 다음 후보).
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
        if (fx.expect === "pass") {
          if (got.length > 0) out.push({ rule: "fixture", where: f, message: `대조군이 걸렸다: 조건 ${[...new Set(got)].join(", ")}` });
          continue;
        }
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
      return [...r.violations, ...checkAll(r.docs), ...checkSecretPaths(r.docs), ...kubeconform(r.targets)];
    },
  },
  {
    name: "vendored charts",
    // 공유 차트에 커밋한 외부 차트 tgz와 Chart.yaml의 버전·sha256 주석(tools/ci/data.ts).
    run: checkVendoredCharts,
  },
  {
    name: "valkey wiring",
    // 앱마다 캐시와 영속 Valkey 중 하나만, uses.valkey면 그중 하나가 있어야 한다(tools/ci/data.ts).
    run: checkValkeyWiring,
  },
  {
    name: "alerting",
    // 경보 룰 단위 시험과 Alertmanager 설정 검사(tools/ci/alerting.ts).
    run: checkAlerting,
  },
  {
    name: "chart fixtures",
    // 공유 차트의 음성 values(tools/ci/fixtures/charts/<차트>/*.yaml). 렌더가 실패해야 한다.
    // schema와 템플릿 검사(go·vm-go 예약, 63자, 다른 앱 이미지 등)가 빠지면 여기서 드러난다.
    run: () => {
      const out: Violation[] = [];
      const files = gitFiles("tools/ci/fixtures/charts/*/*.yaml");
      for (const f of files) {
        const chart = basename(dirname(f));
        const chartDir = `platform/charts/${chart}`;
        if (!existsSync(join(ROOT, chartDir, "Chart.yaml"))) {
          out.push({ rule: "fixture", where: f, message: `${chartDir}가 없다` });
          continue;
        }
        const text = readText(f);
        const match = header(text, "match");
        if (header(text, "expect") !== "fail" || !match) {
          out.push({ rule: "fixture", where: f, message: "머리 주석 # expect: fail과 # match:(기대 오류 문구 일부)가 필요하다(정상 values는 차트의 ci/에 둔다)" });
          continue;
        }
        const r = run(["helm", "template", chart, chartDir, "--namespace", `app-${chart}`, "-f", f]);
        if (r.code === 0) {
          out.push({ rule: "fixture", where: f, message: "렌더가 성공했다. 막아야 할 values다" });
          continue;
        }
        // 오류가 모두 기대한 것이어야 한다. 다른 오류가 섞이면 대상 검사가 사라져도 fixture가 실패로 남는다.
        const errs = helmErrors(r.stderr);
        if (!errs.some((e) => e.includes(match))) out.push({ rule: "fixture", where: f, message: `기대한 오류(${match})가 없다: ${errs.join(" / ")}` });
        const other = errs.filter((e) => !e.includes(match));
        if (other.length > 0) out.push({ rule: "fixture", where: f, message: `기대하지 않은 오류: ${other.join(" / ")}` });
      }
      for (const c of gitFiles(":(glob)platform/charts/*/Chart.yaml").map((p) => basename(dirname(p)))) {
        if (!files.some((f) => basename(dirname(f)) === c)) out.push({ rule: "fixture", where: `platform/charts/${c}`, message: "음성 values fixture가 없다(tools/ci/fixtures/charts/<차트>/)" });
      }
      console.log(`chart fixture ${files.length}개`);
      return out;
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
        sandbox: checkSandbox,
        "secret-path": checkSecretPaths,
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
        // # ns: 렌더한 Application의 destination namespace(render.ts가 Doc.ns로 넘기는 값)를 흉내 낸다.
        const ns = header(text, "ns");
        // # origin: 렌더 출처(render.ts의 Doc.origin)를 흉내 낸다. 출처로 허용을 가르는 검사(secret-path)용.
        const origin = header(text, "origin") ?? `fixture:${basename(f)}`;
        const docs = parseAll(text).map((obj) => ({ origin, obj, ns }));
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
      // 캐시를 정하지 않으면 사용자 캐시 폴더를 쓴다. 없으면 root마다, 실행마다 provider를 새로 받아 사본에 풀었다.
      // 캐시의 provider는 .terraform.lock.hcl 해시와 맞을 때만 쓰인다(lockfile=readonly). 동시 실행 두 개가 같은
      // provider를 처음 받는 순간만 겹칠 수 있다(Terraform 문서: 캐시는 동시 쓰기에 안전하지 않다).
      const pluginCache = process.env.TF_PLUGIN_CACHE_DIR || join(process.env.XDG_CACHE_HOME || join(process.env.HOME ?? tmpdir(), ".cache"), "homelab-ci", "terraform-plugins");
      mkdirSync(pluginCache, { recursive: true });
      const env: Record<string, string | undefined> = { PATH: process.env.PATH, HOME: process.env.HOME, TF_IN_AUTOMATION: "1", TF_INPUT: "0", TF_PLUGIN_CACHE_DIR: pluginCache };
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
