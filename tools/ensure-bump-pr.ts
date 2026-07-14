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
//   gh pr list --head <branch> --state open --limit <PR_QUERY_LIMIT> \
//     --json number,isCrossRepository,mergeStateStatus,author,headRefOid,autoMergeRequest  ← writer 토큰
//   git ls-remote --heads origin <branch>                                  ← 원격 브랜치 존재/OID
//
// ★ 조회는 **경계**가 있다 — 그래서 "부재"를 증명해야 한다(structure 게이트 high-2) ─────────────
// `gh pr list`의 기본 상한은 **30건**이고, `--head`는 owner 한정 필터를 지원하지 않는다("<owner>:<branch>"
// syntax not supported). 실측한 질의 형태(GH_DEBUG=api):
//   repository.pullRequests(states:$state, headRefName:$headBranch, first:$limit, after:$endCursor,
//                           orderBy:{field: CREATED_AT, direction: DESC})
// → 같은 브랜치명으로 **공개 포크가 연 PR도 같은 페이지를 놓고 경쟁**하고, 정렬이 최신순(CREATED_AT DESC)이라
//   나중에 열린 포크 PR 30건이면 **먼저 열린 writer PR이 페이지 밖으로 밀려난다**. 그러면 실행기는 자기
//   브랜치를 "고아"로 오인해 force-push하고 PR을 또 만들려 든다 → 공격자가 멱등성을 깬다(억제/교란).
// 그래서 조회 결과가 **완전한 열거**임을 증명한 뒤에만 판정한다:
//   · 상한을 legit 상한보다 훨씬 크게 잡는다(PR_QUERY_LIMIT). GitHub은 같은 head→base 쌍에 열린 PR을
//     **1개만** 허용하므로 신뢰 PR의 legit 최대치는 1이다 — 나머지는 전부 포크다.
//   · 클라이언트 필터를 **하나도** 걸지 않으므로(전부 서버측 head/state 인자) `count < limit`은
//     "커넥션이 소진됐다 = 열거가 완전하다"와 동치다 → 그때만 **부재가 권위 있다**.
//   · `count >= limit`(포화)이면 밀려난 PR이 있을 수 있다 = **부재를 증명할 수 없다** → fail-closed
//     (push·create·무장·해제 전부 0). 조용한 오탐(고아 오인 → force-push + 중복 create)보다 시끄러운 정지가 낫다.
// ⚠️ `--author <writer>`(서버측 작성자 필터)는 **쓰지 않는다**. 실측(GH_DEBUG=api): `--author`를 주는 순간
//    gh가 검색 API(`search(...)`)로 갈아탄다 — 검색 인덱스는 **결과적 일관성**이라, 직전 주기(10분 전)가 만든
//    PR이 아직 인덱싱되지 않으면 **공격자 없이도** 거짓 부재가 난다(→ 고아 오인 경로). 이 도구의 판정은
//    강한 일관성이 필요하므로 커넥션 질의(위)를 유지하고, 대신 **완전성**으로 부재를 증명한다.
// 신뢰 판정은 **서버 필터에 맡기지 않는다**(심층 방어) — 아래 isTrusted가 동일-레포 + writer를 재검증한다.
//
// ── 레인(--action)과 판정(action)은 **다른 축**이다 ────────────────────────────────────────────
// · 레인 = 플래너(poll-ghcr)가 .bindings.json의 autoDeploy로 정한 배포 승인 모델:
//     autoDeploy:true  → "bump"       (자동 배포 — auto-merge 무장)
//     autoDeploy:false → "propose-pr" (승인 레인 — **사람 머지 = 배포 승인**)
//   호출부는 플래너의 `.action`을 **그대로** `--action`으로 넘긴다(재해석 금지).
// · 판정 = 이 도구가 관측 사실로 정하는 변이 경로(create/adopt/skip/rebuild).
// ⚠️ auto-merge 무장 여부는 **오직 레인**이 정한다(`--action bump`일 때만). 승인 레인을 무장시킬 수 있는
//    별도 플래그는 **존재하지 않는다** — `--auto-merge` 같은 우회 스위치를 두면 호출부가 두 레인 모두에
//    무조건 넘기는 것만으로 `autoDeploy:false` 앱이 자동 배포된다(승인 게이트 우회, plan r5 R-11).
//    승인 레인을 무장시키려면 **플래너를 속여야** 한다 = .bindings.json(autoDeploy SSOT)을 고쳐야 한다.
//
// 신뢰 경계: 이 레포는 **공개**다. 포크(cross-repo) PR은 같은 브랜치명을 쓸 수 있고 아무나 연다 →
// 절대 신뢰하지 않는다. 신뢰하면 포크 PR 하나로 배포를 무기한 억제할 수 있다(억제 = 공격 표면).
// 신뢰하는 제안은 **동일-레포(isCrossRepository=false) + writer App 작성자**뿐이다.
//
// 판정표. push는 **정확히 이 세 argv뿐**:
//   신뢰 PR 없음 + 원격 브랜치 없음            → create   git push origin HEAD:refs/heads/<b>                                → gh pr create
//   신뢰 PR 없음 + 원격 브랜치 **있음**(고아)   → adopt    git push --force-with-lease=refs/heads/<b>:<원격 OID> origin HEAD:refs/heads/<b> → gh pr create
//   신뢰 PR + CLEAN/BEHIND/BLOCKED/UNKNOWN    → skip     push·create 둘 다 하지 않는다
//   신뢰 PR + DIRTY(충돌)                     → rebuild  git push --force-with-lease=refs/heads/<b>:<headRefOid> origin HEAD:refs/heads/<b> (PR 재사용 — create 금지)
//   조회 실패·깨진 JSON                        → fail-closed(비-0 종료 — 조용한 create 금지)
// ⚠️ UNKNOWN은 DIRTY가 아니다(GitHub 지연 계산 — 라이브에서 흔하다). rebuild로 오분류하면 매 폴링 force-push.
// ⚠️ push argv는 **완전 형태**가 계약이다(plan r3): lease 플래그만 맞고 `origin HEAD:refs/heads/<b>`를
//    빠뜨리면 라이브에선 아무것도 밀지 못한다 → 테스트 stub이 계약 밖 push argv를 exit 3으로 죽인다.
//    · 목적지를 `refs/heads/<b>`로 완전 수식 → lease의 <refname>과 **글자 그대로 같은 ref**(refname_match 모호성 0).
//    · 소스는 `HEAD`(호출부가 재구축해 체크아웃해 둔 상태) → 로컬 브랜치명 표기에 의존하지 않는다.
//    · `-u`(upstream)는 소비자가 없다 — PR 생성은 `gh pr create --head <b>`가, auto-merge는 브랜치명이 몫.
// ⚠️ `--force-with-lease`는 반드시 `<ref>:<expected-oid>` 형태다(plan r2 R-5). bare lease는 그 브랜치의
//    원격 추적 참조가 없으면(워크플로 checkout은 main만 가져온다) stale로 거부돼 회복이 영구 실패한다.
//    반대로 명시 형태는 원격 추적 참조도, 그 OID의 로컬 오브젝트도 필요 없다 — git-push(1):
//    "…or we do not even have to have such a remote-tracking branch when this form is used"
//    (bare 원격 레포로 실측: bare lease=stale 거부 / 명시 lease=forced update 성공).
// DIRTY를 rebuild로 되살리지 않으면 유일한 PR이 충돌난 순간 이후 폴링이 영원히 skip →
// 깨끗한 대체 PR이 영영 안 생겨 배포가 조용히 멈춘다(pr-sweeper는 DIRTY를 안 건드린다).
//
// auto-merge 무장도 **desired state**다(plan r5 R-10). "PR 생성 직후 1회 무장"은 무장이 실패하거나
// (또는 그 사이 프로세스가 죽으면) 영영 복구되지 않는다: 다음 폴링은 그 **무장 안 된 PR**을 신뢰하고
// skip해버리고, pr-sweeper는 `autoMergeRequest`가 **이미 있는** PR만 다룬다 → autoDeploy 배포가 조용히
// 정지한다. 그래서 무장 여부(`autoMergeRequest`)를 사실로 관측한다.
//
// ★ 무장 계약(정확히) — 무장 축은 위 판정표와 **직교**하고, **양방향**이다. 판정은 브랜치/PR의 존재로,
//   무장은 레인과 `autoMergeRequest`로 각각 독립적으로 정해진다:
//     lane=bump      + 신뢰 PR + 무장 없음 → 그 run의 **판정이 무엇이든**(skip이든 rebuild든) 재무장한다
//     lane=bump      + 신뢰 PR + 무장 있음 → 손대지 않는다(멱등 — force-push는 무장을 지우지 않는다:
//                                            autoMergeRequest는 head OID가 아니라 PR에 붙는다)
//     lane=bump      + create/adopt(PR 신규) → 생성 직후 무장한다
//     lane=propose-pr + 신뢰 PR + 무장 **있음** → **해제한다**(gh pr merge --disable-auto <번호>)
//     lane=propose-pr + 그 외                   → 무장하지 않는다(멱등 — 해제할 것도 없다)
// ⚠️ 재무장을 skip 경로에만 매달면 **DIRTY + 미무장**에서 새 나간다(라이브에서 실제로 겹치는 조합이다:
//    run 1이 무장에서 죽어 무장 없는 PR이 남고, 이후 main 이동이 그 PR을 충돌시킨다). rebuild만 하고
//    무장 갭을 남기면 PR은 깨끗해지는데 auto-merge가 영영 안 붙어 배포가 정지한다.
//
// ★★ 무장이 desired state라면 **해제도 desired state여야 한다**(structure 게이트 high-1) ────────────
// 무장을 "arm만 있고 disarm은 없는" 단방향으로 다루면 **낡은 머지 인가가 살아남는다**:
//   run 1: .bindings.json에 autoDeploy:true → 플래너가 bump 레인 → PR을 열고 **무장**한다.
//   그 사이 owner가 autoDeploy를 **false로 바꾼다**(= 이제부터 사람 머지 = 배포 승인). 그런데 그 결정적
//   PR은 **아직 열려 있다**(같은 app+tag = 같은 브랜치 = 같은 PR).
//   run 2: 플래너가 이제 propose-pr 레인을 준다. 단방향 구현은 "propose-pr이니 무장하지 않는다"로 끝낸다 —
//          그런데 **기존 무장은 그대로 살아 있다** → gate가 green이 되는 순간 GitHub이 **사람 승인 없이 머지**한다.
//          skip(CLEAN/BLOCKED)이든 rebuild(DIRTY)든 똑같이 샌다: 무장은 PR에 붙지 head OID에 붙지 않는다.
// → 승인 레인의 desired state는 "무장 없음"이다. 관측된 무장이 있으면 **그 run에서 즉시 해제**한다.
// ⚠️ 해제는 **첫 변이**다(push/create보다 먼저). 무장된 PR은 gate가 green이 되는 어느 순간에도 머지될 수
//    있으므로, 낡은 인가를 들고 있는 시간을 최소화한다. 특히 rebuild(force-push)를 먼저 하면 그 push가
//    체크를 green으로 만들어 **해제하기 전에** 머지가 성사될 수 있다.
// ⚠️ 해제 대상은 브랜치명이 아니라 **관측된 신뢰 PR 번호**다. `gh pr merge <branch>`는 같은 브랜치명의
//    포크 PR로 해석될 여지가 있다 — 번호는 그 모호성이 0이다.
//
// 사실은 파싱·검증해 stdout의 `observed`에(무장 여부 포함), 실제 실행한 명령은 `executed`에 실어
// 호출부/테스트가 "무엇을 관측하고 무엇을 변이했는가"를 검증할 수 있게 한다
// (tools/tests/test_ensure-bump-pr.bats가 argv 원장으로 이 계약을 고정한다).
import { spawnSync } from "node:child_process";
import path from "node:path";
import { TAG_RE } from "./lib/image-pin.ts";

const USAGE = `ensure-bump-pr — bump PR 멱등 실행기(조회 → 결정 → 변이; 같은 bump = 같은 브랜치 = 열린 PR 1개)
사용법: bun tools/ensure-bump-pr.ts --app <app> --tag <sha-tag> --action <lane> --title <t> --body <b> [옵션]
  --app <app>       앱 이름(소문자/숫자/하이픈)
  --tag <tag>       후보 배포 핀 tag(sha-<7..40 hex>) — 브랜치는 bump-poll/<app>-<tag>(RUN_ID 없음)
  --action <lane>   플래너(poll-ghcr)의 .action을 **그대로** — bump | propose-pr (필수, 기본값 없음)
                      bump       = autoDeploy:true  → auto-merge 무장(desired state — 없으면 재무장)
                      propose-pr = autoDeploy:false → **절대 무장하지 않는다**(사람 머지 = 배포 승인)
  --title <t>       gh pr create --title
  --body <b>        gh pr create --body
  --base <branch>   PR base (기본 main)
  --remote <name>   git 원격 (기본 origin)
  --writer <slug>   신뢰하는 writer App slug(기본 ukyi-homelab-writer)
  --help, -h        이 도움말
⚠️ auto-merge를 켜는 **별도 플래그는 없다** — 레인이 유일한 입력이다(승인 게이트 우회 방지, plan r5 R-11).
전제: 호출부가 <branch>를 **최신 main에서 재구축**해 로컬 커밋을 얹어 둔 상태(원격 변이만 이 도구 몫).
출력(stdout): {"action":"create"|"adopt"|"skip"|"rebuild","lane":"bump"|"propose-pr","reason":"…","branch":"…","observed":{…},"executed":[…]}`;

// 기본 writer App slug. gh는 App 작성자를 `app/<slug>`로, REST/GraphQL은 `<slug>[bot]`로 준다 →
// 아래 normalizeLogin이 두 표기를 모두 같은 slug로 정규화한다.
const DEFAULT_WRITER = "ukyi-homelab-writer";
const APP_RE = /^[a-z0-9-]+$/;
const OID_RE = /^[0-9a-f]{40}$/;

// 조회 상한 — "부재의 권위"를 만드는 상수다(위 헤더의 ★ 참고). gh 기본값은 30이라 포크 PR 30건이면
// writer PR이 페이지 밖으로 밀린다. legit 최대치는 1(GitHub은 같은 head→base에 열린 PR을 1개만 허용)이므로
// 이 상한에 **닿는다는 것 자체가 이상 신호**다 → 닿으면 판정하지 않고 fail-closed한다(아래 포화 가드).
// 100 = GraphQL 페이지 상한(왕복 1회).
const PR_QUERY_LIMIT = 100;

// 배포 승인 레인 — poll-ghcr.ts가 내는 값과 **글자 그대로** 같다(`s.autoDeploy ? "bump" : "propose-pr"`).
// 호출부가 이 값을 재해석하지 않고 그대로 넘기므로, 승인 레인(propose-pr)을 자동 배포로 바꾸려면
// .bindings.json의 autoDeploy(SSOT)를 고치는 수밖에 없다 — 워크플로 편집만으론 불가능하다.
const LANES = ["bump", "propose-pr"] as const;
type Lane = (typeof LANES)[number];
function isLane(v: string): v is Lane {
  return (LANES as readonly string[]).includes(v);
}

const args: {
  app?: string; tag?: string; title?: string; body?: string; lane?: Lane;
  writer: string; base: string; remote: string;
} = { writer: DEFAULT_WRITER, base: "main", remote: "origin" };
const argv = process.argv.slice(2);
if (argv.includes("--help") || argv.includes("-h")) { console.log(USAGE); process.exit(0); }
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--app") args.app = argv[++i];
  else if (a === "--tag") args.tag = argv[++i];
  else if (a === "--title") args.title = argv[++i];
  else if (a === "--body") args.body = argv[++i];
  else if (a === "--action") {
    const v = argv[++i] ?? "";
    if (!isLane(v)) usageError(`--action 형식 위반: '${v}' (${LANES.join(" | ")})`);
    args.lane = v;
  }
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
// 레인은 **기본값 없이 필수**다 — 기본값을 두면(무엇이든) 호출부가 레인을 빼먹었을 때 조용히 한쪽으로
// 흘러간다. bump로 기본하면 승인 앱이 자동 배포되고, propose-pr로 기본하면 autoDeploy 배포가 멈춘다.
if (!args.lane) usageError(`--action 필수 (${LANES.join(" | ")}) — 플래너의 .action을 그대로 넘긴다`);
const lane: Lane = args.lane;
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
//
// autoMergeRequest(R-10) — 라이브 실측 스키마(`gh pr list --json autoMergeRequest`, 이 레포):
//   무장 안 됨: null
//   무장 됨   : {"authorEmail":null,"commitBody":null,"commitHeadline":null,"mergeMethod":"SQUASH",
//                "enabledAt":"2026-07-13T06:35:24Z",
//                "enabledBy":{"is_bot":true,"login":"app/ukyi-homelab-writer"}}
// → 무장 여부의 유일한 신호는 **null 여부**다(내부 필드는 보지 않는다 — 무장은 있거나 없거나다).
type RawPr = {
  number: number; isCrossRepository: boolean; mergeStateStatus: string;
  headRefOid: string; author: { login: string; is_bot?: boolean };
  autoMerge: boolean;
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
    // 무장 여부는 **필드 존재**까지 계약이다(R-10). 필드명이 드리프트해 undefined가 되면 "무장 안 됨"으로
    // 읽혀 매 폴링 재무장(소음)하거나, 반대로 "무장됨"으로 읽혀 무장 갭이 영영 안 닫힌다 → 둘 다 조용한
    // 오동작이라 fail-closed로 막는다(headRefOid·isCrossRepository 드리프트 가드와 동형).
    if (!("autoMergeRequest" in pr)) {
      inputError(`${at}.autoMergeRequest 필드 없음 — 무장 여부를 모르면 재무장을 판정할 수 없다(필드명 드리프트)`);
    }
    const amr = pr.autoMergeRequest;
    if (amr !== null && (typeof amr !== "object" || Array.isArray(amr))) {
      inputError(`${at}.autoMergeRequest가 null도 객체도 아님(무장=객체 / 미무장=null)`);
    }
    return {
      number: pr.number,
      isCrossRepository: pr.isCrossRepository,
      mergeStateStatus: pr.mergeStateStatus,
      headRefOid: pr.headRefOid,
      author: { login: pr.author.login, is_bot: pr.author.is_bot },
      autoMerge: amr !== null,
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
// `--limit`은 **부재를 권위 있게** 만드는 계약이다(헤더 ★): 클라이언트 필터가 0이므로 반환 수가 상한
// 미만이면 커넥션이 소진된 것 = 열거가 완전하다. 상한을 빼먹으면 gh 기본값 30으로 조용히 되돌아가
// 포크 크라우딩에 다시 뚫린다 → 상한은 argv 계약의 일부다(테스트가 argv 배열로 못박는다).
const prs = parsePrs(run(
  "gh",
  ["pr", "list", "--head", branch, "--state", "open", "--limit", String(PR_QUERY_LIMIT),
    "--json", "number,isCrossRepository,mergeStateStatus,author,headRefOid,autoMergeRequest"],
  "gh pr list",
));
// 포화 가드 — 상한에 닿았다 = 밀려난 PR이 있을 수 있다 = **부재를 증명할 수 없다**.
// 여기서 조용히 진행하면 신뢰 PR을 못 본 채 "고아 브랜치"로 오인해 force-push + 중복 create를 낸다
// (= 공격자가 포크 PR 다발로 멱등성을 깨는 경로). 판정도 변이도 하지 않는다.
if (prs.length >= PR_QUERY_LIMIT) {
  inputError(
    `열린 PR이 조회 상한(${PR_QUERY_LIMIT})에 닿았다 — 같은 브랜치명 '${branch}'에 PR이 그만큼 열려 있다(포크 크라우딩?). `
    + "밀려난 신뢰 PR이 있을 수 있어 '열린 PR 없음'을 증명할 수 없다",
  );
}
const remoteBranch = parseLsRemote(run("git", ["ls-remote", "--heads", args.remote, branch], "git ls-remote"));

const observedPrs = prs.map((pr) => ({ ...pr, trusted: isTrusted(pr, args.writer) }));
const trustedAll = observedPrs.filter((pr) => pr.trusted);
// GitHub은 같은 head→base 쌍에 열린 PR을 1개만 허용한다 → 신뢰 PR이 2개 이상이면 우리의 신뢰 경계나
// GitHub의 계약 중 하나가 깨진 것이다. 아무거나 고르면 나머지 하나는 조용히 방치된다(무장 갭·좀비).
if (trustedAll.length > 1) {
  inputError(
    `신뢰 PR이 ${trustedAll.length}건이다(#${trustedAll.map((p) => p.number).join(", #")}) — `
    + "같은 브랜치의 열린 신뢰 PR은 1건이어야 한다(어느 하나를 고르면 나머지가 방치된다)",
  );
}
const trusted = trustedAll[0] ?? null;

// ── ② 결정 — 관측 사실만으로 정한다(부작용 0) ──────────────────────────────────────────────
// 축 1(판정): 신뢰 PR의 **존재**가 최우선이다. 신뢰 PR이 있으면 원격 브랜치는 당연히 있으므로
// (그 PR의 head가 그것이다) 고아 판정으로 내려가지 않는다.
//   신뢰 PR + DIRTY  → rebuild (PR 재사용 — create 금지)
//   신뢰 PR + 그 외  → skip    (CLEAN/BEHIND/BLOCKED/UNKNOWN … 변이 0)
//   신뢰 PR 없음 + 고아 원격 브랜치 → adopt
//   신뢰 PR 없음 + 원격 브랜치 없음 → create
// ⚠️ DIRTY만이 rebuild다. UNKNOWN(GitHub의 지연 계산)을 충돌로 오분류하면 매 폴링 force-push가 난다.
type Decision = "create" | "adopt" | "skip" | "rebuild";
let action: Decision;
let reason: string;
if (trusted !== null) {
  if (trusted.mergeStateStatus === "DIRTY") {
    action = "rebuild";
    reason = `열린 신뢰 PR #${trusted.number}이 DIRTY(충돌) — 최신 main에서 재구축해 leased force-push(같은 PR 재사용, create 금지)`;
  } else {
    action = "skip";
    reason = `열린 신뢰 PR #${trusted.number}(${trusted.mergeStateStatus}) — 이미 진행 중이므로 변이하지 않는다(중복 PR 금지)`;
  }
} else if (remoteBranch !== null) {
  action = "adopt";
  reason = `열린 신뢰 PR은 없는데 원격 브랜치가 남아 있다(고아 ${remoteBranch.oid}) — 원격 OID를 기대값으로 leased force-push 후 PR 생성`;
} else {
  action = "create";
  reason = "열린 신뢰 PR도 원격 브랜치도 없다 — 정상 경로(push → PR 생성)";
}

// 축 2(무장) — **판정과 직교**하고 **양방향**이다(R-10/R-11 + structure high-1). 레인이 원하는 무장 상태를
// 정하고, 관측된 무장 상태를 그쪽으로 **수렴**시킨다(단방향 arm-only는 낡은 인가를 보존한다 — 헤더 ★★).
//   lane=bump       의 desired = 무장 **있음**
//     · create/adopt = PR을 새로 만든다 → 생성 직후 무장(그 PR엔 무장이 있을 수 없다)
//     · skip/rebuild = 이미 있는 신뢰 PR → 무장이 **없을 때만** 재무장(있으면 손대지 않음 — 멱등)
//   lane=propose-pr 의 desired = 무장 **없음**(사람 머지 = 배포 승인)
//     · 신뢰 PR에 무장이 **남아 있으면**(autoDeploy:true 시절에 열려 무장된 PR이 그대로 열려 있는 경우)
//       → **해제**한다. 판정이 skip이든 rebuild든 똑같다(무장은 PR에 붙지 head OID에 붙지 않는다).
//     · 무장이 없으면 아무것도 하지 않는다(멱등 — 승인 레인의 정상 상태다).
//     · create/adopt엔 해제할 대상이 없다(방금 만든 PR은 이 레인에서 무장되지 않는다).
const createsPr = action === "create" || action === "adopt";
const armGap = trusted !== null && !trusted.autoMerge;
const shouldArm = lane === "bump" && (createsPr || armGap);
// 낡은 머지 인가(stale authorization) — 승인 레인인데 무장이 살아 있다.
const staleArm = trusted !== null && trusted.autoMerge;
const shouldDisarm = lane === "propose-pr" && staleArm;

// ── ③ 변이(원격) — 판정이 허락한 것만, 계약된 argv 그대로 ───────────────────────────────────
// push는 세 경로의 argv가 **완전 형태**로 못박혀 있다(plan r3): 목적지를 `refs/heads/<b>`로 완전 수식하고
// lease는 항상 `<ref>:<기대 OID>` 명시 형태다(bare lease는 원격 추적 참조 없는 checkout에서 stale 거부).
// skip은 여기서 **아무것도 하지 않는다** — 그게 이 픽스의 flip이다(중복 PR 금지).
//
// 해제가 **첫 변이**다: 낡은 인가를 들고 있는 시간을 최소화한다. rebuild(force-push)를 먼저 하면 그 push가
// 체크를 다시 돌려 green으로 만들고, 해제하기 전에 GitHub이 **사람 승인 없이** 머지해버릴 수 있다.
// 대상은 브랜치명이 아니라 **관측된 신뢰 PR 번호**다(같은 브랜치명의 포크 PR 오조준 방지).
// 무장(arm)과 달리 공유 스크립트(auto-merge-or-fail.sh)를 쓰지 않는다 — 그 스크립트는 races-6 폴백
// ("--auto는 이미 CLEAN인 PR에 에러" → 직접 머지)이 본질이고, 그건 **머지를 성사시키는** 경로다.
// 해제는 정반대(인가 회수)라 폴백이 있어선 안 된다: 실패하면 fail-closed로 시끄럽게 죽는 게 맞다.
if (shouldDisarm) {
  mutate("gh", ["pr", "merge", "--disable-auto", String(trusted!.number)], "gh pr merge --disable-auto");
}
if (action === "create") {
  mutate("git", ["push", args.remote, `HEAD:${ref}`], "git push");
} else if (action === "adopt") {
  // 고아 브랜치 접수: 기대값은 **원격에 실제로 있는 OID**(ls-remote 관측값)다.
  mutate("git", ["push", `--force-with-lease=${ref}:${remoteBranch!.oid}`, args.remote, `HEAD:${ref}`], "git push");
} else if (action === "rebuild") {
  // DIRTY 회복: 기대값은 **그 PR의 head OID**(gh pr list 관측값)다 — PR은 재사용하므로 create는 없다.
  mutate("git", ["push", `--force-with-lease=${ref}:${trusted!.headRefOid}`, args.remote, `HEAD:${ref}`], "git push");
}
if (createsPr) {
  mutate("gh", [
    "pr", "create", "--base", args.base, "--head", branch,
    "--title", args.title, "--body", args.body,
  ], "gh pr create");
}
// 무장은 **레인만** 본다 — propose-pr(승인 레인)은 어떤 경로로도 여기 들어오지 못한다(R-11).
// 새 PR이면 생성 직후, 기존 PR이면 무장 갭이 있을 때만(판정이 skip이든 rebuild든) 수렴시킨다(R-10).
if (shouldArm) {
  // races-6 폴백(gh pr merge --auto는 이미 CLEAN인 PR에 에러) — 검증된 공유 스크립트를 재사용한다.
  const script = path.join(import.meta.dir, "..", "scripts", "auto-merge-or-fail.sh");
  mutate("bash", [script, branch], "auto-merge-or-fail");
}

console.log(JSON.stringify({
  action,
  lane, // 배포 승인 레인(입력) — 판정(action)과 다른 축이다
  reason,
  branch,
  observed: {
    prs: observedPrs,
    trusted: trusted
      ? {
        number: trusted.number,
        mergeStateStatus: trusted.mergeStateStatus,
        headRefOid: trusted.headRefOid,
        // R-10: 무장은 **양방향** desired state다 — bump는 없으면 무장(armGap), propose-pr은 있으면 해제(staleArm).
        autoMerge: trusted.autoMerge,
      }
      : null,
    remoteBranch,
  },
  executed,
}, null, 2));
