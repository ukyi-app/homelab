// homelab status 엔진 — 앱 목록/단일 앱/핸들(run·PR URL) 조회. 계층 계약(스펙):
// 레포(핀·바인딩·source-repo) + GitHub(최근 run·열린 PR)가 기본이고, KUBECONFIG가 있으면
// ArgoCD Application(<app>-prod, argocd ns) sync/health를 덧붙인다. KUBECONFIG 부재 시
// 라이브 구간은 "생략"(omitted)으로 명시된다 — 성공이지 skip이 아니다(부분 정보 제공이 계약).
// 실행 원칙은 doctor와 같다: 관측 전용(gh api 읽기·kubectl get만 — 테스트가 argv 원장으로
// 강제). GitHub 계층 오류는 fail-loud(빈 목록으로 위장하면 vacuous green — variant=failure),
// 라이브 계층 오류만 live.error로 보고한다(스펙이 선택 계층으로 선언한 유일한 구간).
import { existsSync, readFileSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { appPaths, appRel, readAppSurface } from "./app-surface.ts";
import { parseBranch } from "./bump-plan.ts";
import { LANES, isDispatchLaneBranch } from "./catalog-rows.ts";
import { compact } from "./contract.ts";
import { ghJson, sh } from "./exec.ts";
import { parseLedgerRows } from "./ledger-totals.ts";
import { HOMELAB_REPO } from "./platform.ts";
import { listUnits } from "./repo-walk.ts";

export type StatusInput = { app?: string; runUrl?: string; prUrl?: string; root?: string };
export type StatusOutcome = { variant: "success" | "failure"; omitted: string[]; result: Record<string, unknown> };

const RUN_URL_RE = /^https:\/\/github\.com\/([\w.-]+)\/([\w.-]+)\/actions\/runs\/(\d+)(?:\/.*)?$/;
const PR_URL_RE = /^https:\/\/github\.com\/([\w.-]+)\/([\w.-]+)\/pull\/(\d+)(?:\/.*)?$/;

// 이 앱을 대상으로 하는 homelab 변이 PR 브랜치 판정 — 두 SSOT의 분업:
//   · bump 레인 = tools/lib/bump-plan.ts(parseBranch — kind 인코딩 `bump-poll/<kind>/<name>-<tag>`,
//     구형 `bump-poll/<name>-<tag>`는 app 해석). catalog에 있던 파싱 전용 행은 18에서 폐기됐다
//     (두 번째 진실 금지 — 브랜치 문법 SSOT는 parseBranch뿐이다).
//   · 앱 키 디스패처 레인(create-app/update-secrets/teardown) = 레인 신원 행(catalog-rows)에서 파생 —
//     구조+run_id 형식을 행이 소유한다(isDispatchLaneBranch).
// 접두만 보면 하이픈 앱명에서 형제 앱을 오귀속하므로(page ↔ page-extra) tail 형식까지가 판정이다.
// db/cache 레인은 리소스명 키(keyKind: "resource")라 앱 필터 대상이 아니다 — 행 데이터가 말한다.
function isAppLaneBranch(head: string, app: string): boolean {
  // status는 apps 레인 조회다 — bespoke target의 bump 브랜치는 이 앱의 것이 아니다.
  const bump = parseBranch(head);
  if (bump !== null && bump.target.kind === "app" && bump.target.name === app) return true;
  for (const row of Object.values(LANES)) {
    if (row.keyKind === "app" && isDispatchLaneBranch(row.branchPattern, app, head)) return true;
  }
  return false;
}

// 모드 상호배타·핸들 URL 형식 검증 — CLI(usage 오류 exit 2)와 MCP(invalid params)가 같은 술어를 쓴다.
export function statusInputError(input: StatusInput): string | null {
  const modes = [input.app, input.runUrl, input.prUrl].filter((x) => x !== undefined).length;
  if (modes > 1) return "app 인자·--run·--pr는 상호배타다(하나만 지정)";
  if (input.runUrl !== undefined && !RUN_URL_RE.test(input.runUrl)) return `run URL 형식 불량(https://github.com/<o>/<r>/actions/runs/<id>): ${input.runUrl}`;
  if (input.prUrl !== undefined && !PR_URL_RE.test(input.prUrl)) return `PR URL 형식 불량(https://github.com/<o>/<r>/pull/<n>): ${input.prUrl}`;
  return null;
}

function defaultRoot(): string {
  return fileURLToPath(new URL("../..", import.meta.url));
}

type AppRow = Record<string, unknown>;

// 앱 표면(values.yaml image.{repo,tag,digest} · .bindings.json autoDeploy · source-repo 한 줄)의
// 읽기·부재 접기는 app-surface module 소유(d4) — 부재/파손 = null을 키 부재로 보고한다.
// autoDeploy 값 해석도 그 module(descriptorAutoDeploy 재사용 — 정확히 true만 승인)이 한다:
// bindings가 실재하는데 키가 불량이면 false로 보고된다(인가 의미론과 표시가 일치 — "미기록"은 파일 부재뿐).
function readAppRow(root: string, name: string): AppRow {
  const s = readAppSurface(root, name);
  const image = (s.values?.image ?? {}) as Record<string, unknown>;
  const tag = typeof image.tag === "string" ? image.tag : undefined;
  const digest = typeof image.digest === "string" ? image.digest : undefined;
  const autoDeploy = s.autoDeploy ?? undefined;
  const sourceRepo = s.sourceRepo ?? undefined;
  let ledgerMi: unknown;
  try {
    const rows = parseLedgerRows(readFileSync(`${root}/docs/memory-ledger.md`, "utf8"));
    ledgerMi = rows.find((r) => r.name === name)?.limitMi;
  } catch { /* 원장 부재 — 키 부재로 보고 */ }
  return compact({ name, tag, digest, autoDeploy, sourceRepo, ledgerMi });
}

// 열거는 공유 워커(repo-walk `apps` 유닛 스코프) 소유 — 의미론적 필터(deploy/prod 존재 =
// 배포되는 앱)는 소비자 몫(스코프 주석 규약: "소비자가 필요하면 /deploy/prod를 덧붙인다").
function listAppNames(root: string): string[] {
  return listUnits("apps", root)
    .filter((u) => {
      try { return statSync(appPaths(root, u.name).prod).isDirectory(); } catch { return false; }
    })
    .map((u) => u.name);
}

function statusList(root: string): StatusOutcome {
  const apps = listAppNames(root).map((n) => readAppRow(root, n));
  return { variant: "success", omitted: [], result: { mode: "list", apps, count: apps.length } };
}

function statusApp(root: string, app: string): StatusOutcome {
  if (!existsSync(appPaths(root, app).prod)) {
    return { variant: "failure", omitted: [], result: { mode: "app", error: `앱 '${app}'의 배포 산출물(${appRel(app).prod})이 없다` } };
  }
  const row = readAppRow(root, app);

  // GitHub 계층 — 최근 run(앱 레포)·열린 PR(homelab 변이 레인). 오류는 fail-loud.
  let runs: unknown[] = [];
  if (typeof row.sourceRepo === "string") {
    const got = ghJson(`repos/${row.sourceRepo}/actions/runs?per_page=3`,
      "[.workflow_runs[] | {name, status, conclusion, head_sha, html_url}]");
    if (got === null) return { variant: "failure", omitted: [], result: { mode: "app", error: `GitHub 계층 조회 실패 — ${row.sourceRepo}의 최근 run` } };
    runs = (got as Array<Record<string, unknown>>).map((r) =>
      compact({ name: r.name, status: r.status, conclusion: r.conclusion, headSha: r.head_sha, url: r.html_url }));
  }
  const prsGot = ghJson(`repos/${HOMELAB_REPO}/pulls?state=open&per_page=100`,
    "[.[] | {number, title, head: .head.ref, html_url, auto_merge: (.auto_merge != null)}]");
  if (prsGot === null) return { variant: "failure", omitted: [], result: { mode: "app", error: `GitHub 계층 조회 실패 — ${HOMELAB_REPO} 열린 PR` } };
  const openPrs = (prsGot as Array<Record<string, unknown>>)
    .filter((p) => isAppLaneBranch(String(p.head), app))
    .map((p) => compact({ number: p.number, title: p.title, head: p.head, url: p.html_url, autoMerge: p.auto_merge }));

  // 라이브 계층 — KUBECONFIG 부재는 생략(성공), 조회 실패는 live.error(관측 보고).
  const kc = process.env.KUBECONFIG ?? "";
  if (kc === "") {
    return { variant: "success", omitted: ["live"], result: { mode: "app", app: row, runs, openPrs } };
  }
  let live: Record<string, unknown>;
  const k = sh("kubectl", ["-n", "argocd", "get", "applications.argoproj.io", `${app}-prod`, "-o", "json"]);
  if (!k.ok) {
    live = { error: k.err.split("\n")[0] || "kubectl 실패" };
  } else {
    try {
      const st = (JSON.parse(k.out)?.status ?? {}) as Record<string, any>;
      live = { argocd: compact({
        sync: st.sync?.status ?? "Unknown",
        health: st.health?.status ?? "Unknown",
        revision: st.sync?.revision,
      }) };
    } catch { live = { error: "Application JSON 파싱 실패" }; }
  }
  return { variant: "success", omitted: [], result: { mode: "app", app: row, runs, openPrs, live } };
}

function statusRun(url: string): StatusOutcome {
  const m = url.match(RUN_URL_RE)!;
  const got = ghJson(`repos/${m[1]}/${m[2]}/actions/runs/${m[3]}`,
    "{name, status, conclusion, head_sha, html_url}");
  if (got === null) return { variant: "failure", omitted: [], result: { mode: "run", error: `run 핸들 조회 실패: ${url}` } };
  const r = got as Record<string, unknown>;
  return { variant: "success", omitted: [], result: { mode: "run", run: compact({ name: r.name, status: r.status, conclusion: r.conclusion, headSha: r.head_sha, url: r.html_url ?? url }) } };
}

function statusPr(url: string): StatusOutcome {
  const m = url.match(PR_URL_RE)!;
  const got = ghJson(`repos/${m[1]}/${m[2]}/pulls/${m[3]}`,
    "{number, state, merged, merge_commit_sha, title, head_ref: .head.ref, head_sha: .head.sha, auto_merge: (.auto_merge != null), html_url}");
  if (got === null) return { variant: "failure", omitted: [], result: { mode: "pr", error: `PR 핸들 조회 실패: ${url}` } };
  const p = got as Record<string, unknown>;
  return { variant: "success", omitted: [], result: { mode: "pr", pr: compact({
    number: p.number, state: p.state, merged: p.merged, autoMerge: p.auto_merge,
    title: p.title, headRef: p.head_ref, headSha: p.head_sha, mergeCommitSha: p.merge_commit_sha,
    url: p.html_url ?? url,
  }) } };
}

export function runStatus(input: StatusInput): StatusOutcome {
  const root = input.root ?? defaultRoot();
  if (input.runUrl !== undefined) return statusRun(input.runUrl);
  if (input.prUrl !== undefined) return statusPr(input.prUrl);
  if (input.app !== undefined) return statusApp(root, input.app);
  return statusList(root);
}
