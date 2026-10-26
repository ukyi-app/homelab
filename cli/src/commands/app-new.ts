// homelab app new <app>: 템플릿으로 public 앱 저장소를 만들고 main에 app-main을 건다(설계 C.7, D-29, 런북 github.md 2절 "새 앱").
//
// 단계 목록은 main의 infra/github/app-repos.json에 앱이 있는지로 정한다.
// - 없으면: 템플릿 app-main 확인 → 같은 이름 저장소 없음 확인 → 목록 PR. 병합 전에 저장소를 만들면 목록 밖 public
//   저장소가 생겨 guard 8이 모든 github plan을 멈추므로, 이때는 생성 단계를 아예 만들지 않는다.
// - 있으면: 템플릿 app-main 확인 → 저장소 생성 → 보안 설정 셋 → app-main(래퍼 plan이 app_main["<app>"] 생성뿐일 때만 래퍼 apply).
// 템플릿 확인을 먼저 두는 이유: 검토 안 된 템플릿 내용이 새 앱 main에 그대로 들어간다(설계 C.7).
import { defineCommand, type Observation, type PlanChanges, type ReadCtx, type Step } from "../core/command";
import { APP_NAME } from "../core/names";
import { prStep } from "../core/pr";
import { UsageError } from "../core/result";

const OWNER = "ukyi-app";
const TEMPLATE = "homelab-app-template";
const LIST = "infra/github/app-repos.json";

function getJson(ctx: ReadCtx, path: string, what: string): any {
  const r = ctx.gh.get(path);
  if (r.status < 200 || r.status >= 300) throw new Error(`${what}: HTTP ${r.status}`);
  return r.json;
}

export function parseList(text: string | null): string[] {
  if (text === null) throw new Error(`main에 ${LIST}가 없다`);
  let v: unknown;
  try {
    v = JSON.parse(text);
  } catch {
    throw new Error(`${LIST}가 JSON이 아니다`);
  }
  if (!Array.isArray(v) || !v.every((x) => typeof x === "string")) throw new Error(`${LIST}가 문자열 배열이 아니다`);
  return v;
}

// 지금 파일 모양(정렬, 2칸 들여쓰기, 끝 줄바꿈)으로 쓴다. 그사이 병합된 다른 앱은 edit가 받은 현재 내용에 있어 지켜진다.
export function addApp(text: string | null, app: string): string {
  const list = parseList(text);
  if (!list.includes(app)) list.push(app);
  return `${JSON.stringify([...list].sort(), null, 2)}\n`;
}

// 래퍼 plan JSON 판정(AC-6). 관리 자원 변경이 app_main["<app>"] 생성 하나뿐이어야 한다.
// 함정: 새 app_main에 의존하는 guard 3·4(rulesets_app·bypass_app)는 plan에서 미뤄진 읽기(mode data, actions ["read"])로
// 나온다(U35). 이것까지 "다른 변경"으로 세면 정상인 경우가 늘 멈춘다. 미뤄진 guard는 래퍼 apply 끝의 verify가 본다.
export function judgePlan(app: string, pc: PlanChanges): Observation {
  const want = `github_repository_ruleset.app_main["${app}"]`;
  if ((pc.exitCode !== 0 && pc.exitCode !== 2) || pc.changes === null) {
    throw new Error(`래퍼 plan이 exit ${pc.exitCode}로 끝났다. guard 번호는 homelab github plan으로 본다`);
  }
  const changes = pc.changes.filter((c) => !(c.mode === "data" && c.actions.length === 1 && c.actions[0] === "read"));
  const isWant = (c: (typeof changes)[number]) => c.address === want && c.mode === "managed" && c.actions.length === 1 && c.actions[0] === "create" && !c.importing;
  const other = changes.filter((c) => !isWant(c));
  if (other.length > 0) {
    const list = other.slice(0, 10).map((c) => `${c.address}(${c.actions.join("/")}${c.importing ? ", import" : ""})`);
    throw new Error(`plan에 ${want} 생성 말고 변경이 있다: ${list.join(", ")}${other.length > 10 ? ` 외 ${other.length - 10}개` : ""}. homelab github plan으로 보고, 다른 변경을 먼저 apply하거나 되돌린 뒤 다시 실행한다`);
  }
  if (changes.length !== 1) throw new Error(`래퍼 plan에 ${want} 생성이 없다(GitHub에는 app-main이 안 보인다). homelab github plan으로 본다`);
  return { state: "missing", action: "create", detail: `plan: ${want} 생성만 (main ${(pc.sha ?? "").slice(0, 12)})` };
}

type RepoView = { exists: false } | { exists: true; json: any };

function repoView(ctx: ReadCtx, app: string): RepoView {
  const r = ctx.gh.get(`repos/${OWNER}/${app}`);
  if (r.status === 404) return { exists: false };
  if (r.status !== 200) throw new Error(`저장소 ${OWNER}/${app} 읽기: HTTP ${r.status}`);
  return { exists: true, json: r.json };
}

// guard 2와 같은 필드(secret scanning·push protection, PR 생성 정책). 꺼진 것 이름만 돌려준다.
function settingsOff(json: any): string[] {
  const sa = json?.security_and_analysis;
  const off: string[] = [];
  if (sa?.secret_scanning?.status !== "enabled") off.push("secret scanning");
  if (sa?.secret_scanning_push_protection?.status !== "enabled") off.push("push protection");
  if (json?.pull_request_creation_policy !== "collaborators_only") off.push("PR 생성 collaborators_only");
  return off;
}

function vulnReportingOn(ctx: ReadCtx, app: string): boolean {
  return getJson(ctx, `repos/${OWNER}/${app}/private-vulnerability-reporting`, "private vulnerability reporting 읽기")?.enabled === true;
}

function forkPolicy(ctx: ReadCtx, app: string): string {
  const p = getJson(ctx, `repos/${OWNER}/${app}/actions/permissions/fork-pr-contributor-approval`, "fork PR 승인 정책 읽기")?.approval_policy;
  return typeof p === "string" ? p : "(없음)";
}

const AFTER_REPO: Observation = { state: "missing", action: "create", detail: "저장소 생성 뒤" };

function templateStep(): Step {
  const base = `repos/${OWNER}/${TEMPLATE}`;
  return {
    id: "template-app-main",
    target: `${OWNER}/${TEMPLATE} main의 app-main`,
    async read(ctx) {
      const next = "템플릿 main에 app-main을 건다(homelab github plan·apply, 설계 C.4.7). 그 전에는 새 앱을 만들지 않는다";
      const rulesets = getJson(ctx, `${base}/rulesets?includes_parents=false&per_page=100`, "템플릿 ruleset 목록");
      const hits = Array.isArray(rulesets) ? rulesets.filter((r: any) => r?.name === "app-main") : [];
      if (hits.length !== 1) return { state: hits.length === 0 ? "missing" : "differs", action: "none", detail: hits.length === 0 ? "app-main이 없다" : `app-main이 ${hits.length}개다`, next };
      const { id, enforcement } = hits[0];
      if (enforcement !== "active") return { state: "differs", action: "none", detail: `app-main이 ${String(enforcement)}다`, next };
      // 목록의 enforcement만으로는 main에 실제로 걸렸는지 모른다(대상 조건). 브랜치에 적용된 규칙으로 한 번 더 본다.
      const rules = getJson(ctx, `${base}/rules/branches/main`, "템플릿 main 규칙");
      if (!Array.isArray(rules) || !rules.some((x: any) => x?.ruleset_id === id)) return { state: "differs", action: "none", detail: "app-main이 main에 걸려 있지 않다", next };
      return { state: "same", action: "none", detail: `app-main active (ruleset ${id})` };
    },
  };
}

function nameFreeStep(app: string): Step {
  return {
    id: "repo-absent",
    target: `${OWNER}/${app} 이름`,
    async read(ctx) {
      const v = repoView(ctx, app);
      if (!v.exists) return { state: "same", action: "none", detail: "같은 이름 저장소 없음" };
      return {
        state: "differs",
        action: "none",
        detail: `목록에 없는 저장소가 이미 있다(${String(v.json?.visibility ?? "?")})`,
        next: `다른 이름을 쓰거나 ${OWNER}/${app}을 확인한다. 목록 밖 public 저장소가 있으면 guard 8이 모든 github plan을 멈춘다`,
      };
    },
  };
}

function listPrStep(app: string): Step {
  return prStep({
    command: "app new",
    app,
    title: `feat(${app}): 앱 저장소 목록에 더하기`,
    body: [
      `\`homelab app new ${app}\`이 연 PR이다. \`${LIST}\`에 \`${app}\`을 더한다.`,
      "",
      `병합 뒤 \`homelab app new ${app} --apply\`를 다시 실행하면 템플릿으로 public 저장소를 만들고 보안 설정을 켠 뒤 \`homelab github apply\`로 \`app-main\`을 건다(설계 C.7).`,
      "병합부터 저장소 하드닝까지는 `homelab github plan`·`verify`가 guard 2·8로 exit 1인 것이 정상이다(docs/runbooks-public/github.md 2절).",
    ].join("\n"),
    files: [LIST],
    edit: (cur) => ({ [LIST]: addApp(cur[LIST], app) }),
    describe: () => `${app} 추가`,
  });
}

function repoStep(app: string): Step {
  return {
    id: "repo",
    target: `${OWNER}/${app}`,
    async read(ctx) {
      const v = repoView(ctx, app);
      if (!v.exists) return { state: "missing", action: "create", detail: `템플릿 ${TEMPLATE}에서 public으로 만든다` };
      const problems: string[] = [];
      if (v.json?.visibility !== "public") problems.push(`visibility ${String(v.json?.visibility)}`);
      if (v.json?.default_branch !== "main") problems.push(`기본 브랜치 ${String(v.json?.default_branch)}`);
      if (v.json?.template_repository?.full_name !== `${OWNER}/${TEMPLATE}`) problems.push("템플릿에서 만든 저장소가 아니다");
      // 손으로 만든 저장소를 이 명령의 결과로 보지 않는다(설정만 덮어 "된 것"처럼 보이게 하지 않는다).
      if (problems.length > 0) throw new Error(`이미 있는 저장소가 app new의 결과와 다르다(${problems.join(", ")}). 확인한 뒤 런북 github.md 2절 "새 앱"대로 맞춘다`);
      return { state: "same", action: "none", detail: "있음 (public, 템플릿에서 만듦)" };
    },
    async apply(w) {
      w.appRepo!.createFromTemplate(app);
    },
  };
}

function settingsStep(app: string): Step {
  return {
    id: "repo-settings",
    target: `${OWNER}/${app} 보안 설정`,
    async read(ctx) {
      const v = repoView(ctx, app);
      if (!v.exists) return AFTER_REPO;
      const off = settingsOff(v.json);
      if (off.length === 0) return { state: "same", action: "none", detail: "secret scanning·push protection 켬, PR 생성 collaborators_only" };
      return { state: "differs", action: "update", detail: `${off.join("·")} → 켬` };
    },
    async apply(w) {
      w.appRepo!.setRepoSettings(app);
    },
  };
}

function vulnStep(app: string): Step {
  return {
    id: "vuln-reporting",
    target: `${OWNER}/${app} private vulnerability reporting`,
    async read(ctx) {
      if (!repoView(ctx, app).exists) return AFTER_REPO;
      return vulnReportingOn(ctx, app) ? { state: "same", action: "none", detail: "켬" } : { state: "differs", action: "update", detail: "꺼짐 → 켬" };
    },
    async apply(w) {
      w.appRepo!.enableVulnReporting(app);
    },
  };
}

function forkStep(app: string): Step {
  return {
    id: "fork-pr-approval",
    target: `${OWNER}/${app} fork PR 승인`,
    async read(ctx) {
      if (!repoView(ctx, app).exists) return AFTER_REPO;
      const p = forkPolicy(ctx, app);
      return p === "all_external_contributors" ? { state: "same", action: "none", detail: p } : { state: "differs", action: "update", detail: `${p} → all_external_contributors` };
    },
    async apply(w) {
      w.appRepo!.setForkPrApproval(app);
    },
  };
}

function appMainStep(app: string): Step {
  return {
    id: "app-main",
    target: `${OWNER}/${app} main의 app-main`,
    async read(ctx) {
      const v = repoView(ctx, app);
      if (!v.exists) return { state: "missing", action: "create", detail: "저장소·보안 설정 뒤 래퍼 plan으로 판정" };
      // 이미 걸렸으면 래퍼를 부르지 않는다(재실행과 apply 뒤 확인이 가볍고, 래퍼가 묻는 값도 없다).
      const rulesets = getJson(ctx, `repos/${OWNER}/${app}/rulesets?includes_parents=false&per_page=100`, "앱 ruleset 목록");
      const hits = Array.isArray(rulesets) ? rulesets.filter((r: any) => r?.name === "app-main") : [];
      if (hits.length === 1 && hits[0].enforcement === "active") return { state: "same", action: "none", detail: `app-main active (ruleset ${hits[0].id})` };
      // 하드닝 전에는 guard 2가 plan을 멈춘다. 래퍼를 돌리지 않고 앞 단계를 기다린다.
      if (settingsOff(v.json).length > 0 || !vulnReportingOn(ctx, app) || forkPolicy(ctx, app) !== "all_external_contributors") {
        return { state: "missing", action: "create", detail: "보안 설정 뒤 래퍼 plan으로 판정" };
      }
      return judgePlan(app, ctx.github!.planChanges());
    },
    async apply(w) {
      // 래퍼 apply는 plan을 다시 만들어 보여 주고 사람이 yes로 답한다. 끝에 verify를 다시 돈다.
      const code = w.github!.apply();
      if (code !== 0) throw new Error(`래퍼 apply가 exit ${code}로 끝났다. 래퍼 메시지를 보고 docs/runbooks-public/github.md 3절을 따른다`);
    },
  };
}

export default defineCommand({
  path: ["app", "new"],
  summary: "템플릿으로 public 앱 저장소 만들기(목록 PR → 병합 뒤 생성·보안 설정·app-main)",
  kind: "change",
  wrapper: "plan-json",
  args: [{ name: "app", required: true, help: "앱 이름", pattern: APP_NAME }],
  flags: [],
  async run(ctx, input) {
    const app = input.args.app!;
    if (app === "homelab" || app === TEMPLATE) throw new UsageError(`${app}은 예약된 저장소 이름이다`);
    const listed = parseList(ctx.repo.readFile(LIST, ctx.repo.mainSha())).includes(app);
    if (!listed) {
      return ctx.engine({
        command: "app new",
        app,
        steps: [templateStep(), nameFreeStep(app), listPrStep(app)],
        notes: [
          `PR 병합 뒤 같은 명령을 다시 --apply하면 저장소 생성 → 보안 설정 → app-main 적용을 이어 한다`,
          "병합부터 저장소 하드닝까지 homelab github plan·verify는 guard 2·8로 exit 1이 정상이다. 병합 뒤 바로 다시 실행한다(런북 github.md 2절)",
        ],
      });
    }
    const notes: string[] = [];
    if (!repoView(ctx, app).exists) {
      notes.push(
        "저장소 생성부터 app-main 적용까지 새 main에 보호가 없다. 자동 병합은 조건 9가 막는다(설계 C.7)",
        "app-main 단계에서 래퍼가 plan(판정)과 apply로 돈다. HOMELAB_ADMIN_PROJECT_ID·R2_ENDPOINT·TF_STATE_BACKUP_DIR를 export해 두면 다시 묻지 않는다",
        "fine-grained PAT를 쓰면 apply 전에 PAT의 선택 저장소에 새 저장소를 더한다(런북 github.md 2절)",
      );
    }
    return ctx.engine({ command: "app new", app, steps: [templateStep(), repoStep(app), settingsStep(app), vulnStep(app), forkStep(app), appMainStep(app)], notes });
  },
});
