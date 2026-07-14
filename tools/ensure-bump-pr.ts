// bump PR 멱등 **실행기** — 조회 → 결정 → 변이(push/PR)를 한 seam에 모은다(중복 PR 버그의 수정 seam).
//
// 배경(라이브 버그): bump-poll.yaml은 run마다 새 브랜치 `bump-poll/<app>-<RUN_ID>`로 PR을 연다.
// 플래너(poll-ghcr)는 "GHCR 최신 vs main의 배포 핀"만 보는데 PR이 머지되기 전엔 main이 여전히
// 옛 digest다 → 매 10분 주기가 같은 후보로 새 PR을 낸다(page sha-815abb…: 11분에 PR 3개,
// 1개만 머지되고 나머지는 충돌 잔류).
//
// 왜 도구가 **실행**까지 하는가(plan r2 R-4): 결정만 하는 도구는 GREEN이 돼도 프로덕션은 그대로일 수
// 있다 — 워크플로가 도구를 부르기 **전에** 이미 push/create를 해버리면 그만이다. 또한 "브랜치 push는
// 성공했는데 `gh pr create`가 실패"한 run이 남기는 **고아 원격 브랜치**는, 다음 폴링이 "열린 PR 없음"으로
// 보고 create를 택하는 순간 non-fast-forward로 충돌해 배포를 정지시킨다. 조회·결정·변이가 한 프로세스
// 안에 있어야 그 순서와 부작용(skip이면 push도 create도 없음)을 테스트로 증명할 수 있다.
//
// 관측 사실(변이 이전에 반드시 수집):
//   gh pr list --head <branch> --state open \
//     --json number,isCrossRepository,mergeStateStatus,author,headRefOid   ← writer 토큰
//   git ls-remote --heads origin <branch>                                  ← 원격 브랜치 존재/OID
//
// 신뢰 경계: 이 레포는 **공개**다. 포크(cross-repo) PR은 같은 브랜치명을 쓸 수 있고 아무나 연다 →
// 절대 신뢰하지 않는다. 신뢰하면 포크 PR 하나로 배포를 무기한 억제할 수 있다(억제 = 공격 표면).
// 신뢰하는 제안은 **동일-레포(isCrossRepository=false) + writer App 작성자**뿐이다.
//
// 판정표(수정 후 목표 — 지금은 아래 red-capture 블록이 이걸 무시한다):
//   신뢰 PR 없음 + 원격 브랜치 없음            → create   push(-u) → gh pr create
//   신뢰 PR 없음 + 원격 브랜치 **있음**(고아)   → adopt    push --force-with-lease=<ref>:<원격 OID> → gh pr create
//   신뢰 PR + CLEAN/BEHIND/BLOCKED/UNKNOWN    → skip     push·create 둘 다 하지 않는다
//   신뢰 PR + DIRTY(충돌)                     → rebuild  push --force-with-lease=<ref>:<headRefOid> (PR 재사용 — create 금지)
//   조회 실패·깨진 JSON                        → fail-closed(비-0 종료 — 조용한 create 금지)
// ⚠️ UNKNOWN은 DIRTY가 아니다(GitHub 지연 계산 — 라이브에서 흔하다). rebuild로 오분류하면 매 폴링 force-push.
// ⚠️ `--force-with-lease`는 반드시 `<ref>:<expected-oid>` 형태다(plan r2 R-5). bare lease는 그 브랜치의
//    원격 추적 참조가 없으면(워크플로 checkout은 main만 가져온다) stale로 거부돼 회복이 영구 실패한다.
// DIRTY를 rebuild로 되살리지 않으면 유일한 PR이 충돌난 순간 이후 폴링이 영원히 skip →
// 깨끗한 대체 PR이 영영 안 생겨 배포가 조용히 멈춘다(pr-sweeper는 DIRTY를 안 건드린다).
//
// ⚠️ 현재는 **red-capture 상태**다 — 판정 로직은 아직 없고 관측 사실과 무관하게 **항상 create 경로를
// 실행**한다(= 버그 재현: 중복 PR + 고아 브랜치 충돌 + lease 없는 push). 사실은 파싱·검증해 stdout의
// `observed`에, 실제 실행한 명령은 `executed`에 실어 배선이 살아 있음을 증명한다. 회귀 테스트
// (tools/tests/test_ensure-bump-pr.bats, test_tags=regression)가 이 RED를 고정한다.
import { spawnSync } from "node:child_process";
import path from "node:path";
import { TAG_RE } from "./lib/image-pin.ts";

const USAGE = `ensure-bump-pr — bump PR 멱등 실행기(조회 → 결정 → 변이; 같은 bump = 같은 브랜치 = 열린 PR 1개)
사용법: bun tools/ensure-bump-pr.ts --app <app> --tag <sha-tag> --title <t> --body <b> [옵션]
  --app <app>       앱 이름(소문자/숫자/하이픈)
  --tag <tag>       후보 배포 핀 tag(sha-<7..40 hex>) — 브랜치는 bump-poll/<app>-<tag>(RUN_ID 없음)
  --title <t>       gh pr create --title
  --body <b>        gh pr create --body
  --auto-merge      PR 생성 후 scripts/auto-merge-or-fail.sh로 auto-merge 무장(autoDeploy 앱만)
  --base <branch>   PR base (기본 main)
  --remote <name>   git 원격 (기본 origin)
  --writer <slug>   신뢰하는 writer App slug(기본 ukyi-homelab-writer)
  --help, -h        이 도움말
전제: 호출부가 <branch>를 **최신 main에서 재구축**해 로컬 커밋을 얹어 둔 상태(원격 변이만 이 도구 몫).
출력(stdout): {"action":"create"|"adopt"|"skip"|"rebuild","reason":"…","branch":"…","observed":{…},"executed":[…]}`;

// 기본 writer App slug. gh는 App 작성자를 `app/<slug>`로, REST/GraphQL은 `<slug>[bot]`로 준다 →
// 아래 normalizeLogin이 두 표기를 모두 같은 slug로 정규화한다.
const DEFAULT_WRITER = "ukyi-homelab-writer";
const APP_RE = /^[a-z0-9-]+$/;
const OID_RE = /^[0-9a-f]{40}$/;

const args: {
  app?: string; tag?: string; title?: string; body?: string;
  writer: string; base: string; remote: string; autoMerge: boolean;
} = { writer: DEFAULT_WRITER, base: "main", remote: "origin", autoMerge: false };
const argv = process.argv.slice(2);
if (argv.includes("--help") || argv.includes("-h")) { console.log(USAGE); process.exit(0); }
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--app") args.app = argv[++i];
  else if (a === "--tag") args.tag = argv[++i];
  else if (a === "--title") args.title = argv[++i];
  else if (a === "--body") args.body = argv[++i];
  else if (a === "--auto-merge") args.autoMerge = true;
  else if (a === "--base") args.base = argv[++i] ?? "";
  else if (a === "--remote") args.remote = argv[++i] ?? "";
  else if (a === "--writer") args.writer = argv[++i] ?? "";
  else {
    console.error(`알 수 없는 옵션: ${a}`);
    process.exit(2);
  }
}

// 사용법 위반(인자)은 exit 2. 비신뢰 입력(gh/git 출력)·조회 실패는 exit 1 — 셋 다 fail-closed
// (조용한 create 금지: "조회 실패 = 중복 PR"이 되면 버그가 그대로 재현된다).
function usageError(msg: string): never {
  console.error(`ensure-bump-pr: ${msg}`);
  process.exit(2);
}
function inputError(msg: string): never {
  console.error(`ensure-bump-pr: 신뢰할 수 없는 조회 출력 — ${msg} (fail-closed: 판정도 변이도 하지 않는다)`);
  process.exit(1);
}
function execError(msg: string): never {
  console.error(`ensure-bump-pr: ${msg} (fail-closed: 변이하지 않는다)`);
  process.exit(1);
}

if (!args.app) usageError("--app 필수");
if (!args.tag) usageError("--tag 필수");
if (!args.title) usageError("--title 필수");
if (!args.body) usageError("--body 필수");
if (!APP_RE.test(args.app)) usageError(`--app 형식 위반: '${args.app}' (소문자/숫자/하이픈만)`);
if (!TAG_RE.test(args.tag)) usageError(`--tag 형식 위반: '${args.tag}' (sha-<7..40 hex>)`);

// 결정적 브랜치명 — 같은 bump는 항상 같은 브랜치로 수렴한다(RUN_ID 제거가 중복 PR 픽스의 토대다:
// run마다 브랜치가 달라지면 "이 bump의 열린 PR"을 조회할 대상 자체가 없다).
const branch = `bump-poll/${args.app}-${args.tag}`;
const ref = `refs/heads/${branch}`;

// 실행한 명령 원장 — stdout JSON에 실어 호출부/테스트가 "무엇을 변이했는가"를 검증한다.
const executed: string[] = [];

function run(cmd: string, a: string[], what: string): string {
  executed.push([cmd, ...a].join(" "));
  const r = spawnSync(cmd, a, { encoding: "utf8" });
  if (r.error) execError(`${what} 실행 실패: ${r.error.message}`);
  if (r.stderr) process.stderr.write(r.stderr);
  if (r.status !== 0) execError(`${what} 실패(exit ${r.status})`);
  return r.stdout ?? "";
}
// 변이 명령의 stdout은 stderr로 흘린다 — 이 도구의 stdout은 결과 JSON 전용(호출부가 jq로 읽는다).
function mutate(cmd: string, a: string[], what: string): void {
  const out = run(cmd, a, what);
  if (out) process.stderr.write(out);
}

// gh pr list --json이 주는 원시 스키마. author는 봇일 때 {is_bot, login}만 오고(id/name 없음),
// 사람일 때 {id, is_bot, login, name}이 온다 → login/is_bot만 신뢰한다(라이브 확인 완료).
// headRefOid는 DIRTY rebuild의 `--force-with-lease=<ref>:<oid>` 기대값이다(R-5) — 없으면 fail-closed.
type RawPr = {
  number: number; isCrossRepository: boolean; mergeStateStatus: string;
  headRefOid: string; author: { login: string; is_bot?: boolean };
};

// 비신뢰 입력 검증 — 빈 문자열/깨진 JSON/배열 아님/필드 누락·타입 위반은 전부 fail-closed.
function parsePrs(raw: string): RawPr[] {
  if (raw.trim() === "") inputError("gh pr list 빈 출력(--json은 최소 '[]'를 준다 → 조회 실패로 본다)");
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    inputError(`gh pr list JSON 파싱 실패: ${(e as Error).message}`);
  }
  if (!Array.isArray(parsed)) inputError("gh pr list 최상위가 배열이 아님");
  return parsed.map((pr: any, i: number): RawPr => {
    const at = `[${i}]`;
    if (pr === null || typeof pr !== "object") inputError(`${at} 객체가 아님`);
    if (!Number.isInteger(pr.number)) inputError(`${at}.number 정수 아님`);
    if (typeof pr.isCrossRepository !== "boolean") inputError(`${at}.isCrossRepository 불리언 아님`);
    if (typeof pr.mergeStateStatus !== "string" || pr.mergeStateStatus === "") inputError(`${at}.mergeStateStatus 문자열 아님`);
    if (typeof pr.headRefOid !== "string" || !OID_RE.test(pr.headRefOid)) inputError(`${at}.headRefOid가 40-hex OID 아님(lease 기대값 필수)`);
    if (pr.author === null || typeof pr.author !== "object") inputError(`${at}.author 객체가 아님`);
    if (typeof pr.author.login !== "string" || pr.author.login === "") inputError(`${at}.author.login 문자열 아님`);
    return {
      number: pr.number,
      isCrossRepository: pr.isCrossRepository,
      mergeStateStatus: pr.mergeStateStatus,
      headRefOid: pr.headRefOid,
      author: { login: pr.author.login, is_bot: pr.author.is_bot },
    };
  });
}

// `git ls-remote --heads origin <branch>` → "<40-hex>\trefs/heads/<branch>"(없으면 빈 출력).
// 고아 브랜치(= 열린 PR 없이 남은 원격 브랜치)의 OID가 adopt 경로의 lease 기대값이다(R-4).
function parseLsRemote(raw: string): { oid: string } | null {
  for (const line of raw.split("\n")) {
    const t = line.trim();
    if (t === "") continue;
    const parts = t.split(/\s+/);
    if (parts.length < 2) inputError(`git ls-remote 출력 파싱 실패: '${t}'`);
    const oid = parts[0]!;
    const refName = parts[1]!;
    if (!OID_RE.test(oid)) inputError(`git ls-remote OID 형식 위반: '${oid}'`);
    if (refName === ref) return { oid };
  }
  return null;
}

// gh는 App 작성자를 `app/<slug>`로, REST/GraphQL은 `<slug>[bot]`로 표기한다 — 둘 다 같은 slug로 정규화.
// (라이브 확인: `gh pr list --json author` → {"login":"app/ukyi-homelab-writer","is_bot":true})
function normalizeLogin(login: string): string {
  return login.replace(/^app\//, "").replace(/\[bot\]$/, "").toLowerCase();
}

// 신뢰하는 제안 = 동일-레포(포크 아님) + writer App 작성자. 그 외(포크·타인)는 사실로만 관측하고
// 판정 근거로 쓰지 않는다 — 억제(suppression)에 악용될 수 있는 표면이기 때문.
function isTrusted(pr: RawPr, writer: string): boolean {
  if (pr.isCrossRepository) return false;
  return normalizeLogin(pr.author.login) === normalizeLogin(writer);
}

// ── ① 조회 — 변이보다 **먼저**, 전부 수집한다(순서 자체가 계약이다: R-4) ─────────────────────
const prs = parsePrs(run(
  "gh",
  ["pr", "list", "--head", branch, "--state", "open",
    "--json", "number,isCrossRepository,mergeStateStatus,author,headRefOid"],
  "gh pr list",
));
const remoteBranch = parseLsRemote(run("git", ["ls-remote", "--heads", args.remote, branch], "git ls-remote"));

const observedPrs = prs.map((pr) => ({ ...pr, trusted: isTrusted(pr, args.writer) }));
const trusted = observedPrs.find((pr) => pr.trusted) ?? null;

// ── ② 결정 ────────────────────────────────────────────────────────────────────────────────
// ⚠️ red-capture: 여기가 수정 seam이다. 지금은 판정을 버그 상태로 동결한다 — 신뢰하는 열린 PR이
// 있어도, 고아 원격 브랜치가 있어도 무조건 create 경로를 실행한다(= 매 주기 중복 PR + 고아 충돌).
// 수정 시 위 판정표대로 action을 정하고 ③의 변이를 분기하도록 이 두 블록만 바꾸면 된다.
const action = "create" as const;
const reason =
  "red-capture: 판정 미구현 — 신뢰 PR·고아 브랜치와 무관하게 항상 create(중복 PR·lease 없는 push 재현)";

// ── ③ 변이(원격) ───────────────────────────────────────────────────────────────────────────
// 동결된 create 경로: lease 없는 push + 무조건 PR 생성. (수정 후: skip이면 이 블록을 통째로 건너뛴다.)
mutate("git", ["push", "-u", args.remote, branch], "git push");
mutate("gh", [
  "pr", "create", "--base", args.base, "--head", branch,
  "--title", args.title, "--body", args.body,
], "gh pr create");
if (args.autoMerge) {
  // races-6 폴백(gh pr merge --auto는 이미 CLEAN인 PR에 에러) — 검증된 스크립트를 재사용한다.
  const script = path.join(import.meta.dir, "..", "scripts", "auto-merge-or-fail.sh");
  mutate("bash", [script, branch], "auto-merge-or-fail");
}

console.log(JSON.stringify({
  action,
  reason,
  branch,
  observed: {
    prs: observedPrs,
    trusted: trusted
      ? { number: trusted.number, mergeStateStatus: trusted.mergeStateStatus, headRefOid: trusted.headRefOid }
      : null,
    remoteBranch,
  },
  executed,
}, null, 2));
