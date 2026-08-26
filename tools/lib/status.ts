// homelab status 엔진 — 앱 목록/단일 앱/핸들(run·PR URL) 조회. 계층 계약(스펙):
// 레포(핀·바인딩·source-repo) + GitHub(최근 run·열린 PR)가 기본이고, KUBECONFIG가 있으면
// ArgoCD Application(<app>-prod, argocd ns) sync/health를 덧붙인다. KUBECONFIG 부재 시
// 라이브 구간은 "생략"(omitted)으로 명시된다 — 성공이지 skip이 아니다(부분 정보 제공이 계약).
// 실행 원칙은 doctor와 같다: 관측 전용(gh api 읽기·kubectl get만 — 테스트가 argv 원장으로
// 강제). GitHub 계층 오류는 fail-loud(빈 목록으로 위장하면 vacuous green — variant=failure),
// 라이브 계층 오류만 live.error로 보고한다(스펙이 선택 계층으로 선언한 유일한 구간).
import { existsSync, readFileSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { parse as parseYaml } from "yaml";
import { parseBranch } from "./bump-plan.ts";
import { compact } from "./contract.ts";
import { ghJson, sh } from "./exec.ts";
import { parseLedgerRows } from "./ledger-totals.ts";
import { HOMELAB_REPO } from "./platform.ts";
import { listUnits } from "./repo-walk.ts";

export type StatusInput = { app?: string; runUrl?: string; prUrl?: string; root?: string };
export type StatusOutcome = { variant: "success" | "failure"; omitted: string[]; result: Record<string, unknown> };

const RUN_URL_RE = /^https:\/\/github\.com\/([\w.-]+)\/([\w.-]+)\/actions\/runs\/(\d+)(?:\/.*)?$/;
const PR_URL_RE = /^https:\/\/github\.com\/([\w.-]+)\/([\w.-]+)\/pull\/(\d+)(?:\/.*)?$/;

// 이 앱을 대상으로 하는 homelab 변이 PR 브랜치 판정 — 명명 SSOT:
//   bump-poll은 tools/lib/bump-plan.ts(branchFor/parseBranch — kind 인코딩 `bump-poll/<kind>/<name>-<tag>`,
//   구형 `bump-poll/<name>-<tag>`는 app 해석) · create-app/<app>-<run_id> ·
//   update-secrets/<app>-<run_id> · teardown/teardown-app-<app>-<run_id>(_teardown-app.yaml).
// 접두만 보면 하이픈 앱명에서 형제 앱을 오귀속한다(page의 `bump-poll/page-`가 page-extra의
// `bump-poll/page-extra-sha-…`에 참) — parseBranch/잔여 형식(run_id) 검증이 그 오귀속을 막는다.
// db/cache 브랜치는 리소스명 키라 앱 필터 대상이 아니다.
function isAppLaneBranch(head: string, app: string): boolean {
  const tail = (prefix: string): string | null => (head.startsWith(prefix) ? head.slice(prefix.length) : null);
  // status는 apps 레인 조회다 — bespoke target의 bump 브랜치는 이 앱의 것이 아니다.
  const bump = parseBranch(head);
  if (bump !== null && bump.target.kind === "app" && bump.target.name === app) return true;
  for (const action of ["create-app", "update-secrets"]) {
    const t = tail(`${action}/${app}-`);
    if (t !== null && /^\d+$/.test(t)) return true;
  }
  const td = tail(`teardown/teardown-app-${app}-`);
  return td !== null && /^\d+$/.test(td);
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

// create-app.ts 산출 형상(values.yaml image.{repo,tag,digest} · .bindings.json autoDeploy ·
// source-repo 한 줄)을 읽는다. 파일/키 부재는 키 부재로 보고한다(fail-closed 의미 부여는 소비자 —
// autoDeploy 누락을 승인 레인으로 접는 것은 bump-poll의 계약).
function readAppRow(root: string, name: string): AppRow {
  const dir = `${root}/apps/${name}/deploy/prod`;
  let tag: unknown, digest: unknown, autoDeploy: unknown, sourceRepo: unknown;
  try {
    const image = (parseYaml(readFileSync(`${dir}/values.yaml`, "utf8")) ?? {})?.image ?? {};
    tag = typeof image.tag === "string" ? image.tag : undefined;
    digest = typeof image.digest === "string" ? image.digest : undefined;
  } catch { /* values.yaml 부재/파손 — 핀 키 부재로 보고 */ }
  try {
    const b = JSON.parse(readFileSync(`${dir}/.bindings.json`, "utf8"));
    autoDeploy = typeof b.autoDeploy === "boolean" ? b.autoDeploy : undefined;
  } catch { /* 바인딩 부재/파손 — autoDeploy 키 부재로 보고 */ }
  try {
    const s = readFileSync(`${dir}/source-repo`, "utf8").trim();
    sourceRepo = s.length > 0 ? s : undefined;
  } catch { /* source-repo 부재(인레포 앱) */ }
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
      try { return statSync(`${root}/${u.dir}/deploy/prod`).isDirectory(); } catch { return false; }
    })
    .map((u) => u.name);
}

function statusList(root: string): StatusOutcome {
  const apps = listAppNames(root).map((n) => readAppRow(root, n));
  return { variant: "success", omitted: [], result: { mode: "list", apps, count: apps.length } };
}

function statusApp(root: string, app: string): StatusOutcome {
  if (!existsSync(`${root}/apps/${app}/deploy/prod`)) {
    return { variant: "failure", omitted: [], result: { mode: "app", error: `앱 '${app}'의 배포 산출물(apps/${app}/deploy/prod)이 없다` } };
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
