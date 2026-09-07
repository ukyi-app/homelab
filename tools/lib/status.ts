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
import { revisionFields, syncRevisionOf } from "./argocd.ts";
import { parseBranch } from "./bump-plan.ts";
import { LANES, isDispatchLaneBranch } from "./catalog-rows.ts";
import { compact } from "./contract.ts";
import { ghRead, sh, type GhRead } from "./exec.ts";
import { APP_NAME_RE } from "./identity.ts";
import { laneBranchInputError, lanePrRef, parseLaneBranch, readLanePrs, type LanePrRow } from "./lane-pr.ts";
import { parseLedgerRows } from "./ledger-totals.ts";
import { LAYOUT_DIRS, classifyArtifact } from "./resource-layout.ts";
import { HOMELAB_REPO } from "./platform.ts";
import { listUnits } from "./repo-walk.ts";

// branch — run 모드의 **좌표 보강**(모드가 아니다). 변이 pending이 실어 보낸 레인 브랜치를 받아
// 그 레인 PR을 정확 조회한다(티켓 09). 단독 모드로 열지 않는 이유는 statusInputError 주석 참조.
export type StatusInput = { app?: string; runUrl?: string; prUrl?: string; branch?: string; root?: string };
// race — 브랜치 하나에 PR이 2개면 신원 판정 불가다(fail-closed, exit 3). 변이 엔진의 같은 축과
// 같은 어휘를 쓴다 — 리더가 임의로 하나를 고르면 그 뒤의 모든 보고가 오귀속이 된다.
export type StatusOutcome = { variant: "success" | "failure" | "race"; omitted: string[]; result: Record<string, unknown> };

// 핸들 URL의 owner/repo — GitHub 명명 규칙으로 좁힌다(티켓 27). 종전 `[\w.-]+`는 `.`·`..`를
// 통과시켰고 그 캡처가 `repos/${owner}/${repo}/…`로 gh api 경로에 조립됐다
// (`https://github.com/../../pull/1` → `repos/../../pulls/1`). identity.ts:5가 'path traversal
// 1차 게이트에 분기를 두지 않는다'를 원칙으로 두고 APP_NAME_RE가 `..`를 거르는데 핸들 축만 그
// 원칙 밖이었다(MCP는 문자열을 그대로 전달한다). 읽기 전용·사용자 자신의 토큰이라 권한 확대는
// 아니지만, 조립 전에 형식으로 닫는 것이 이 레포의 규약이다.
//   · owner — 영숫자 시작 + 영숫자/하이픈, ≤39자(GitHub 계정 규칙).
//   · repo  — 영숫자/`.`/`_`/`-`, ≤100자. 선두 부정 lookahead가 `.`·`..` **전체**를 거른다
//     (`.github` 같은 정당한 점-접두 이름은 그대로 통과한다 — 뒤에 `/`나 끝이 오지 않으므로).
const RUN_URL_RE = /^https:\/\/github\.com\/([A-Za-z0-9][A-Za-z0-9-]{0,38})\/((?!\.{1,2}(?:\/|$))[A-Za-z0-9._-]{1,100})\/actions\/runs\/(\d+)(?:\/.*)?$/;
const PR_URL_RE = /^https:\/\/github\.com\/([A-Za-z0-9][A-Za-z0-9-]{0,38})\/((?!\.{1,2}(?:\/|$))[A-Za-z0-9._-]{1,100})\/pull\/(\d+)(?:\/.*)?$/;

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
  // 앱 이름은 형제 술어(verbs·secrets·init)와 같은 문구·같은 SSOT다. status는 리더지만 app을 그대로
  // apps/<app>/deploy/prod 경로·kubectl 리소스명에 조립하므로 identity.ts가 '분기 금지'로 못 박은
  // traversal 1차 게이트가 여기에도 선다(오타는 '산출물 없음' failure가 아니라 usage로 층이 갈린다).
  if (input.app !== undefined && !APP_NAME_RE.test(input.app)) return `앱 이름 형식 불량(소문자 kebab, 2..40): ${input.app}`;
  const modes = [input.app, input.runUrl, input.prUrl].filter((x) => x !== undefined).length;
  if (modes > 1) return "app 인자·--run·--pr는 상호배타다(하나만 지정)";
  if (input.runUrl !== undefined && !RUN_URL_RE.test(input.runUrl)) return `run URL 형식 불량(https://github.com/<o>/<r>/actions/runs/<id>): ${input.runUrl}`;
  if (input.prUrl !== undefined && !PR_URL_RE.test(input.prUrl)) return `PR URL 형식 불량(https://github.com/<o>/<r>/pull/<n>): ${input.prUrl}`;
  if (input.branch !== undefined) {
    // --branch는 모드가 아니라 run 모드의 좌표 보강이다. 단독 조회로 열면 '어느 run의 브랜치인가'가
    // 입력에서 사라져 형제 오귀속을 가를 축이 없어진다(그리고 correlation 핸들 모드와 같은 재개 조건
    // 문제를 반복한다 — owner 결정 Q2: 그 모드는 열지 않는다).
    if (input.runUrl === undefined) return "--branch는 --run과 함께 쓴다(레인 브랜치 PR의 정확 조회 — run 좌표가 있어야 형제 오귀속을 가른다)";
    const be = laneBranchInputError(input.branch);
    if (be !== null) return be;                    // 임의 ref가 gh 질의 문자열로 새지 않는 1차 게이트
    // 브랜치는 run id의 파생이다(레인 행 branchPattern `…-{runId}`) — 둘이 어긋나면 입력 자체가
    // 모순이므로 조회 전에 죽인다(형제 브랜치 `…-5011`을 runId 501 조회에 붙이는 오귀속의 정면).
    const parsed = parseLaneBranch(input.branch)!;
    const runId = input.runUrl.match(RUN_URL_RE)![3];
    if (String(parsed.runId) !== runId) return `--branch의 run id(${parsed.runId})가 --run URL의 run id(${runId})와 다르다 — 브랜치는 그 run의 좌표다`;
  }
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
  // 앱↔리소스 배선(conns) — values.envFrom의 secretRef 중 data-conn 컴포넌트가 내는 핸들만 추린다.
  // 판정은 레이아웃 SSOT(classifyArtifact)에 위임한다: 이름 정책(-ro 접미·예약 이름·kind 접두)이
  // 두 벌이 되면 감사(audit-orphans)와 관측이 서로 다른 집합을 말하게 된다. 앱 자기 봉인본
  // (<app>-secrets)은 배선이 아니라 자기 시크릿이라 자연히 빠진다.
  // ⚠️ 배선 **자동화**는 하지 않는다 — audit-orphans:315가 '이름≠앱' 케이스를 비차단 근거로
  // 명시했고, 자동 배선은 엉뚱한 DB를 물린다. 이 필드는 관측(사실 표면화)뿐이다.
  const envFrom = Array.isArray((s.values as Record<string, unknown> | null)?.envFrom)
    ? ((s.values as Record<string, unknown>).envFrom as unknown[])
    : [];
  const conns = envFrom
    .map((e) => (e as { secretRef?: { name?: unknown } } | null)?.secretRef?.name)
    .filter((n): n is string => typeof n === "string" && n !== ""
      && classifyArtifact(`${LAYOUT_DIRS.dataConn}/${n}.sealed.yaml`) !== null);
  return compact({ name, tag, digest, autoDeploy, sourceRepo, ledgerMi, conns: conns.length > 0 ? conns : undefined });
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

// GitHub 계층 실패의 **사유 한 줄**(티켓 15) — 3상 리더(ghRead)의 종류를 그대로 층으로 옮긴다.
// 종전에는 ghJson의 null 접힘이 gh 미설치·미인증·404·rate limit·망 단절·파싱 깨짐을 한 문장으로
// 만들었고, 그 넷은 처방이 전부 다르다(재인증 / 이름·접근권 / 대기 / 재시도). 같은 statusApp 안에서
// kubectl 실패는 이미 사유를 싣는데 GitHub 레그만 지워지던 비대칭의 해소이기도 하다.
//   parse  — rc 0인데 JSON이 아니다. '조회 실패'로 위장하면 스칼라 jq 오용이 망 문제로 읽힌다.
//   not-found — reason이 `spawnSync gh ENOENT`라 운영자에게 무의미하므로 처방으로 번역한다.
function ghCause(g: Exclude<GhRead, { kind: "ok" }>): string {
  if (g.kind === "parse") return `응답 파싱 실패(${g.reason})`;
  if (g.errKind === "not-found") return "gh CLI가 PATH에 없다 — 설치 필요";
  return g.reason;
}

// 열린 PR 목록 1회 조회 — app 모드의 두 분기(산출물 실재/부재)가 같은 질의를 공유한다.
// 3상 리더를 그대로 돌려준다(fail-loud 판정과 사유 문구는 콜사이트 — GitHub 계층은 선택 계층이 아니다).
function openHomelabPrs(): GhRead {
  return ghRead(`repos/${HOMELAB_REPO}/pulls?state=open&per_page=100`,
    "[.[] | {number, title, head: .head.ref, html_url, auto_merge: (.auto_merge != null)}]");
}
const openPrRow = (p: Record<string, unknown>): Record<string, unknown> =>
  compact({ number: p.number, title: p.title, head: p.head, url: p.html_url, autoMerge: p.auto_merge });

// Application status.conditions 투영(티켓 16) — 'Degraded'만 보고하면 '왜'의 답이 전부 CLI 밖
// (kubectl·ArgoCD UI)에서 시작된다. sync/비교 실패 사유가 바로 이 배열에 있다.
//   정렬은 **원본 배열 순서**로 고정한다 — 임의 정렬(시각·심각도)은 골든을 비결정적으로 만든다.
//   상한 3건 — 결과는 보고서지 로그 덤프가 아니다(같은 이유로 메시지도 단일 줄 + 길이 상한).
// ⚠️ `health.message`는 넣지 않는다: 라이브 실측(argocd v3.4.4 + resourceHealthSource:appTree)에서
//    Application.status에 그 키가 **존재하지 않았다**(21/21건). 없는 필드를 읽는 코드는 영원히
//    무증인이다. `operationState.message`가 필요해지면 health와 섞지 말고 별도 키로 만든다.
const LIVE_CONDITIONS_MAX = 3;
const LIVE_CONDITION_MSG_MAX = 200;
function liveConditions(raw: unknown): Array<Record<string, string>> | undefined {
  if (!Array.isArray(raw) || raw.length === 0) return undefined;
  const rows = raw.slice(0, LIVE_CONDITIONS_MAX).map((c) => {
    const o = (c ?? {}) as Record<string, unknown>;
    const msg = String(o.message ?? "").replace(/\s+/g, " ").trim().slice(0, LIVE_CONDITION_MSG_MAX);
    return compact({ type: typeof o.type === "string" ? o.type : undefined, message: msg === "" ? undefined : msg }) as Record<string, string>;
  }).filter((r) => Object.keys(r).length > 0);
  return rows.length > 0 ? rows : undefined;
}

function statusApp(root: string, app: string): StatusOutcome {
  if (!existsSync(appPaths(root, app).prod)) {
    // 산출물 부재는 그린필드의 **정상 전이**일 수 있다: create-app PR이 열려 있고(수동 머지 대기)
    // 그 PR이 바로 이 디렉토리를 만든다. 종전에는 이 상태가 '앱 없음' 한 줄이라 재개 좌표가 0이었다
    // (mcp-4). 읽기 1회로 그 레인 PR을 별도 필드에 실어 준다 — 수동 머지 원칙은 그대로다.
    // 조회 실패는 여기서 fail-loud로 승격하지 않는다(주 사유는 산출물 부재이고, 부가 관측의 부재는
    // 키 부재로 보고된다 — 없는 것과 못 본 것을 결과가 뒤섞지 않게 필드를 만들지 않는다).
    const g = openHomelabPrs();
    const prs = g.kind === "ok" ? (g.value as Array<Record<string, unknown>>) : [];
    const createPrs = prs
      .filter((p) => isDispatchLaneBranch(LANES["create-app"].branchPattern, app, String(p.head)))
      .map(openPrRow);
    return { variant: "failure", omitted: [], result: compact({ mode: "app", error: `앱 '${app}'의 배포 산출물(${appRel(app).prod})이 없다`, createPrs: createPrs.length > 0 ? createPrs : undefined }) };
  }
  const row = readAppRow(root, app);

  // GitHub 계층 — 최근 run(앱 레포)·열린 PR(homelab 변이 레인). 오류는 fail-loud.
  let runs: unknown[] = [];
  if (typeof row.sourceRepo === "string") {
    const g = ghRead(`repos/${row.sourceRepo}/actions/runs?per_page=3`,
      "[.workflow_runs[] | {name, status, conclusion, head_sha, html_url}]");
    if (g.kind !== "ok") return { variant: "failure", omitted: [], result: { mode: "app", error: `GitHub 계층 조회 실패 — ${row.sourceRepo}의 최근 run: ${ghCause(g)}` } };
    runs = (g.value as Array<Record<string, unknown>>).map((r) =>
      compact({ name: r.name, status: r.status, conclusion: r.conclusion, headSha: r.head_sha, url: r.html_url }));
  }
  const prsGot = openHomelabPrs();
  if (prsGot.kind !== "ok") return { variant: "failure", omitted: [], result: { mode: "app", error: `GitHub 계층 조회 실패 — ${HOMELAB_REPO} 열린 PR: ${ghCause(prsGot)}` } };
  const openPrs = (prsGot.value as Array<Record<string, unknown>>).filter((p) => isAppLaneBranch(String(p.head), app)).map(openPrRow);

  // 라이브 계층 — KUBECONFIG 부재는 생략(성공), 조회 실패는 live.error(관측 보고).
  const kc = process.env.KUBECONFIG ?? "";
  if (kc === "") {
    return { variant: "success", omitted: ["live"], result: { mode: "app", app: row, runs, openPrs } };
  }
  let live: Record<string, unknown>;
  // `--ignore-not-found` — NotFound를 exit 1이 아니라 **exit 0 + 빈 stdout**으로 받는다. 없으면
  // 'appset이 아직 Application을 안 만들었다 / prune이 끝났다'가 조회 실패로 접혀 **상태가 관측
  // 실패로 위장**한다(create-app·teardown 머지 직후가 정확히 그 창이다). 같은 레포의 teardown
  // absence 수렴이 이미 이 형태다(mutation.ts).
  const k = sh("kubectl", ["-n", "argocd", "get", "applications.argoproj.io", `${app}-prod`, "-o", "json", "--ignore-not-found"]);
  if (!k.ok) {
    live = { error: k.err.split("\n")[0] || "kubectl 실패" };
  } else if (k.out.trim() === "") {
    // ⚠️ 빈 stdout 검사는 반드시 parse **앞**이다 — `JSON.parse("")`는 throw라서 아래 catch로 흘러
    // 부재가 '파싱 실패'로 위장한다(부재를 상태로 만들려던 이 분기 자체가 무력해진다).
    live = { absent: true };
  } else {
    try {
      const st = (JSON.parse(k.out)?.status ?? {}) as Record<string, any>;
      // 리비전은 공유 리더(argocd.ts) — 앱 Application은 멀티소스라 단수 필드가 비고 revisions[]만 있다.
      // resolved면 revision, 아니면(skew·non-sha) 관측 원본 revisions — 변이 엔진의 행과 같은 모양.
      live = { argocd: compact({
        sync: st.sync?.status ?? "Unknown",
        health: st.health?.status ?? "Unknown",
        ...revisionFields(syncRevisionOf(st)),
        conditions: liveConditions(st.conditions),
      }) };
    } catch { live = { error: "Application JSON 파싱 실패" }; }
  }
  return { variant: "success", omitted: [], result: { mode: "app", app: row, runs, openPrs, live } };
}

function statusRun(url: string, branch?: string): StatusOutcome {
  const m = url.match(RUN_URL_RE)!;
  const g0 = ghRead(`repos/${m[1]}/${m[2]}/actions/runs/${m[3]}`,
    "{name, status, conclusion, head_sha, html_url}");
  if (g0.kind !== "ok") return { variant: "failure", omitted: [], result: { mode: "run", error: `run 핸들 조회 실패: ${url} — ${ghCause(g0)}` } };
  const r = g0.value as Record<string, unknown>;
  const run = compact({ name: r.name, status: r.status, conclusion: r.conclusion, headSha: r.head_sha, url: r.html_url ?? url });
  if (branch === undefined) return { variant: "success", omitted: [], result: { mode: "run", run } };
  // 좌표가 있으면 그 레인 브랜치의 PR을 **정확 조회**한다(변이 엔진과 같은 질의·투영 — lane-pr.ts).
  // GitHub 계층은 fail-loud다(status.ts 헤더) — 빈 목록으로 위장하면 '아직 PR이 없다'와 구별되지 않는다.
  const g = readLanePrs(branch);
  if (g.kind !== "ok") return { variant: "failure", omitted: [], result: { mode: "run", error: `GitHub 계층 조회 실패 — 브랜치(${branch})의 PR 목록: ${g.reason}` } };
  const rows = g.value as LanePrRow[];
  if (rows.length >= 2) {
    return { variant: "race", omitted: [], result: { mode: "run", branch, observedPrs: rows.length, error: `브랜치 ${branch}에 PR이 ${rows.length}개 — 신원 판정 불가(fail-closed)` } };
  }
  // 0건은 오류가 아니다 — run은 성공했어도 PR이 아직 안 났거나(멱등 no-op) 그 사이 닫혔을 수 있다.
  // 값 없음 = 키 부재 규약대로 pr 키를 만들지 않는다(부재와 실패를 결과가 구별한다).
  return { variant: "success", omitted: [], result: { mode: "run", run: compact({ ...run, branch, pr: rows[0] === undefined ? undefined : lanePrRef(rows[0]) }) } };
}

function statusPr(url: string): StatusOutcome {
  const m = url.match(PR_URL_RE)!;
  const g = ghRead(`repos/${m[1]}/${m[2]}/pulls/${m[3]}`,
    "{number, state, merged, merge_commit_sha, title, head_ref: .head.ref, head_sha: .head.sha, auto_merge: (.auto_merge != null), html_url}");
  if (g.kind !== "ok") return { variant: "failure", omitted: [], result: { mode: "pr", error: `PR 핸들 조회 실패: ${url} — ${ghCause(g)}` } };
  const p = g.value as Record<string, unknown>;
  return { variant: "success", omitted: [], result: { mode: "pr", pr: compact({
    number: p.number, state: p.state, merged: p.merged, autoMerge: p.auto_merge,
    title: p.title, headRef: p.head_ref, headSha: p.head_sha, mergeCommitSha: p.merge_commit_sha,
    url: p.html_url ?? url,
  }) } };
}

export function runStatus(input: StatusInput): StatusOutcome {
  const root = input.root ?? defaultRoot();
  if (input.runUrl !== undefined) return statusRun(input.runUrl, input.branch);
  if (input.prUrl !== undefined) return statusPr(input.prUrl);
  if (input.app !== undefined) return statusApp(root, input.app);
  return statusList(root);
}
