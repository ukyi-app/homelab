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
//   gh api graphql --paginate --slurp … (headRefName=<branch>, states:OPEN — **상한 없는 완전 열거**)
//   git ls-remote --heads origin <branch>                                  ← 원격 브랜치 존재/OID
//
// ★ 조회는 **상한이 없어야** 한다 — 경계된 조회는 배포 정지 무기가 된다(structure 게이트 r2/r4) ────
// 처음엔 `gh pr list --head <b>`를 썼다. 그건 **경계된** 질의다(기본 30건, `--limit`으로만 늘어난다):
//   repository.pullRequests(headRefName:$h, first:$limit, orderBy:{CREATED_AT, DESC})   ← GH_DEBUG=api 실측
// 결정적 브랜치명은 **공개**고 `--head`는 owner 한정 필터를 지원하지 않는다 → **포크가 같은 브랜치명으로 연
// PR이 같은 페이지를 놓고 경쟁**하고, 최신순이라 나중에 열린 포크 PR들이 **먼저 열린 writer PR을 페이지 밖으로
// 밀어낸다**. 두 가지 실패가 여기서 갈라진다:
//   ① 상한을 믿고 진행 → 자기 PR을 "고아"로 오인 → force-push + 중복 create (멱등성 파괴)
//   ② 상한에 닿으면 fail-closed → **포크로 페이지를 채우는 것만으로 모든 폴링이 죽는다**(배포 정지 무기).
// 둘 다 공격자 통제다. 유일한 출구는 **상한을 없애는 것**이다: 끝까지 페이지네이션해 전부 열거하면,
// 포크가 몇 건이든 우리 PR은 반드시 그 안에 있다 → 포크는 아무것도 막지 못한다.
//   `gh api graphql --paginate`가 `pageInfo{hasNextPage,endCursor}` + `$endCursor` 변수를 요구하며
//   hasNextPage=false까지 자동으로 따라간다(라이브 실증: first:1로도 전 페이지 열거). `--slurp`이 배열로 묶는다.
//   완전 열거의 증명 = **마지막 페이지의 hasNextPage === false**(아니면 fail-closed).
// ⚠️ 검색 API는 금지다: `gh pr list --author`는 내부적으로 `search(...)`로 갈아탄다(GH_DEBUG=api 실측).
//    검색 인덱스는 **결과적 일관성**이라 직전 주기가 만든 PR이 안 잡히면 **공격자 없이도** 거짓 부재가 난다.
//    connection 질의는 primary datastore = **강한 일관성**이다.
// ⚠️ 모호성 fail-closed는 유지한다: **신뢰 PR이 2건 이상**이면 에러(GitHub 계약상 불가능 — 무언가 깨진 것이다).
// 신뢰 판정은 **서버 필터에 맡기지 않는다**(심층 방어) — isTrusted가 동일-레포 + writer Bot + base를 재검증한다.
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
//
// ★★★ 무장·해제의 대상은 **언제나 인증된 PR 번호**다(브랜치명 금지) ────────────────────────────
// `gh pr merge <branch>` / `gh pr view <branch>`는 브랜치명을 **셀렉터**로 해석한다 — 그런데 이 레포는
// 공개고, 포크는 **같은 결정적 브랜치명**으로 PR을 열 수 있다. 브랜치 셀렉터로 무장하면 그 조회가
// **동명 포크 PR을 지목**할 수 있고, 그러면 **공격자의 코드가 auto-merge된다**(신뢰 경계를 조회 단계에서만
// 지키고 변이 단계에서 흘린 셈이다). 그래서 인증된 셀렉터를 변이 경로 **끝까지** 들고 간다:
//     skip/rebuild(기존 PR) → trusted.number          (조회에서 신뢰 판정을 통과한 그 PR)
//     create/adopt(새 PR)   → gh pr create가 낸 URL의 번호 (gh가 "방금 내가 만든 PR"이라고 알려준 값)
//     해제(propose-pr)      → trusted.number
// 번호를 확정할 수 없으면 **fail-closed** — 브랜치명으로 폴백하지 않는다(폴백이 곧 이 결함이다).
// 공유 스크립트 `auto-merge-or-fail.sh`는 인자를 `gh pr merge`/`gh pr view`에 그대로 넘기는 **패스스루**라
// (브랜치명 자체를 쓰는 로직이 없다) 번호를 넘기는 것만으로 모호성이 사라진다 — 스크립트는 손대지 않는다.
// (다른 호출자 bump.yaml·pr-first-commit은 계속 브랜치를 넘긴다 — 그 경로엔 포크 PR이 끼어들 수 없다.)
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

// ── 조회 = **상한 없는 완전 열거**(GraphQL connection, 끝까지 페이지네이션) ──────────────────────
// `gh pr list`는 쓰지 않는다. 그건 `--limit`으로 **경계된** 질의라, 부재를 증명하려면 "상한에 닿으면
// fail-closed"밖에 방법이 없는데 — 결정적 브랜치명은 **공개**고 같은 head의 **포크 PR은 공격자가 무한정
// 열 수 있다** → 페이지를 채우는 것만으로 **모든 폴링이 화해 전에 죽는다**(배포 정지 원시 무기).
// 상한을 없애면 그 무기가 사라진다: 포크가 몇 건이든 전부 열거하고, 그 사이에서 우리 PR을 정확히 찾는다.
//
// `gh api graphql --paginate`는 `pageInfo{hasNextPage,endCursor}` + `$endCursor: String` 변수를 요구하고,
// hasNextPage가 false가 될 때까지 **자동으로 끝까지** 따라간다(라이브 실증: `first:1`로 강제해도 전 페이지 열거).
// `--slurp`은 페이지별 응답을 **배열 하나**로 묶어 준다.
// ⚠️ 검색 API는 금지다 — `gh pr list --author`는 내부적으로 search(...)로 갈아타는데(GH_DEBUG=api 실측),
//    검색 인덱스는 **결과적 일관성**이라 직전 주기가 만든 PR이 안 잡히면 **거짓 부재**가 난다(고아 오인 →
//    force-push). connection 질의는 primary datastore = **강한 일관성**이다.
//
// ★ base를 **서버 필터로 걸지 않는다**(중요) — head로만 열거하고 base는 **클라이언트에서** 본다.
//   식별(우리 PR인가?)은 (head, base) 쌍이지만, **소유권**(이 브랜치를 force-push해도 되는가?)은 base와
//   무관하게 "이 head에 열린 동일-레포 PR이 하나라도 있는가"로 정해진다. base로 서버 필터를 걸면 다른 base를
//   향한 동일-레포 PR이 **보이지 않게 되고**, 그러면 파괴 가드(r3)가 눈이 멀어 그 PR의 브랜치를 force-push로
//   덮어쓴다. 그래서 열거는 head 전체, 판정은 base까지 본다.
const PR_QUERY = `query($owner:String!,$repo:String!,$head:String!,$endCursor:String){
  repository(owner:$owner,name:$repo){
    pullRequests(headRefName:$head, states:OPEN, first:100, after:$endCursor){
      pageInfo{ hasNextPage endCursor }
      nodes{
        number isCrossRepository mergeStateStatus headRefOid baseRefName
        author{ login __typename }
        autoMergeRequest{ enabledAt }
      }
    }
  }
}`;

// GraphQL 노드의 원시 스키마(라이브 실측 — 이 레포의 실제 bump PR):
//   {"number":350,"isCrossRepository":false,"mergeStateStatus":"DIRTY","headRefOid":"5bb77fc…",
//    "baseRefName":"main","author":{"login":"ukyi-homelab-writer","__typename":"Bot"},
//    "autoMergeRequest":{"enabledAt":"2026-07-13T06:35:20Z"}}
// ★★ author 표기는 **표면마다 다르다**(라이브 확인) — 여기서 틀리면 신뢰 판정이 조용히 죽는다:
//     gh pr list  → "app/ukyi-homelab-writer"     (is_bot: true)
//     REST        → "ukyi-homelab-writer[bot]"
//     GraphQL     → "ukyi-homelab-writer"          (__typename: "Bot")   ← 지금 쓰는 표면
//   normalizeLogin이 셋을 모두 같은 slug로 접는다.
// ★★ __typename도 **신뢰 조건**이다: GraphQL은 App 봇을 `Bot`으로, 사람을 `User`로 준다. login만 보면
//   `ukyi-homelab-writer`라는 **사람 계정**(봇 계정은 `<slug>[bot]`이므로 이 이름은 사람이 가질 수 있다)이
//   writer로 오인될 수 있다 → 타입까지 봐야 신뢰 경계가 닫힌다.
// autoMergeRequest: 무장=객체({enabledAt}) / 미무장=null — 유일한 신호는 **null 여부**다.
type RawPr = {
  number: number; isCrossRepository: boolean; mergeStateStatus: string;
  headRefOid: string; baseRefName: string;
  author: { login: string; type: string } | null;
  autoMerge: boolean;
};

// `gh api graphql --paginate --slurp` 출력 = **페이지 응답의 배열**. 각 원소는 {data:{repository:{pullRequests:…}}}.
// 완전 열거의 증명은 **마지막 페이지의 hasNextPage === false**다 — true로 끝났다면 gh가 페이지를 다 따라가지
// 못한 것이므로 "열린 PR 없음"을 증명할 수 없다 → fail-closed(조용한 create/adopt 금지).
function parsePrs(raw: string): RawPr[] {
  if (raw.trim() === "") inputError("gh api graphql 빈 출력(조회 실패로 본다)");
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    inputError(`gh api graphql JSON 파싱 실패: ${(e as Error).message}`);
  }
  if (!Array.isArray(parsed)) inputError("gh api graphql --slurp 최상위가 배열(페이지 목록)이 아님");
  const pages = parsed as any[];
  if (pages.length === 0) inputError("gh api graphql이 페이지를 하나도 주지 않았다(조회 실패로 본다)");

  const out: RawPr[] = [];
  pages.forEach((page: any, p: number) => {
    const at = `page[${p}]`;
    if (page === null || typeof page !== "object") inputError(`${at} 객체가 아님`);
    if (page.errors !== undefined) inputError(`${at}.errors — GraphQL 오류 응답: ${JSON.stringify(page.errors)}`);
    const conn = page?.data?.repository?.pullRequests;
    if (conn === null || typeof conn !== "object") {
      inputError(`${at}.data.repository.pullRequests 없음(레포 해석 실패 또는 스키마 드리프트)`);
    }
    // 완전 열거 증명 — 마지막 페이지가 "더 있다"고 하면 열거가 끊긴 것이다.
    const info = conn.pageInfo;
    if (info === null || typeof info !== "object" || typeof info.hasNextPage !== "boolean") {
      inputError(`${at}.pageInfo.hasNextPage 불리언 아님 — 완전 열거를 증명할 수 없다`);
    }
    if (p === pages.length - 1 && info.hasNextPage === true) {
      inputError(
        "마지막 페이지가 hasNextPage=true다 — 페이지네이션이 끝까지 가지 못했다. "
        + "열거가 불완전하면 '열린 PR 없음'을 증명할 수 없다(--paginate 배선 확인)",
      );
    }
    const nodes = conn.nodes;
    if (!Array.isArray(nodes)) inputError(`${at}.nodes가 배열이 아님`);

    nodes.forEach((pr: any, i: number) => {
      const nat = `${at}.nodes[${i}]`;
      if (pr === null || typeof pr !== "object") inputError(`${nat} 객체가 아님`);
      if (!Number.isInteger(pr.number)) inputError(`${nat}.number 정수 아님`);
      if (typeof pr.isCrossRepository !== "boolean") inputError(`${nat}.isCrossRepository 불리언 아님`);
      if (typeof pr.mergeStateStatus !== "string" || pr.mergeStateStatus === "") inputError(`${nat}.mergeStateStatus 문자열 아님`);
      if (typeof pr.headRefOid !== "string" || !OID_RE.test(pr.headRefOid)) inputError(`${nat}.headRefOid가 40-hex OID 아님(lease 기대값 필수)`);
      // base는 **식별**의 절반이다(head, base) — 없으면 우리 PR인지 판정할 수 없다.
      if (typeof pr.baseRefName !== "string" || pr.baseRefName === "") inputError(`${nat}.baseRefName 문자열 아님(식별은 (head, base) 쌍이다)`);
      // author는 **null일 수 있다**(계정 삭제) → 신뢰하지 않을 뿐, fail-closed는 아니다(영구 억제 방지).
      let author: { login: string; type: string } | null = null;
      if (pr.author !== null) {
        if (typeof pr.author !== "object") inputError(`${nat}.author가 객체도 null도 아님`);
        if (typeof pr.author.login !== "string" || pr.author.login === "") inputError(`${nat}.author.login 문자열 아님`);
        // __typename은 신뢰 조건이다(Bot vs User) — 없으면 사람이 writer slug를 사칭할 수 있다.
        if (typeof pr.author.__typename !== "string" || pr.author.__typename === "") {
          inputError(`${nat}.author.__typename 없음 — App 봇(Bot)과 사람(User)을 구분할 수 없다(사칭 가드)`);
        }
        author = { login: pr.author.login, type: pr.author.__typename };
      }
      if (!("autoMergeRequest" in pr)) {
        inputError(`${nat}.autoMergeRequest 필드 없음 — 무장 여부를 모르면 재무장/해제를 판정할 수 없다(필드명 드리프트)`);
      }
      const amr = pr.autoMergeRequest;
      if (amr !== null && (typeof amr !== "object" || Array.isArray(amr))) {
        inputError(`${nat}.autoMergeRequest가 null도 객체도 아님(무장=객체 / 미무장=null)`);
      }
      out.push({
        number: pr.number,
        isCrossRepository: pr.isCrossRepository,
        mergeStateStatus: pr.mergeStateStatus,
        headRefOid: pr.headRefOid,
        baseRefName: pr.baseRefName,
        author,
        autoMerge: amr !== null,
      });
    });
  });
  return out;
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

// `gh pr create`는 성공 시 **만든 PR의 URL**을 stdout에 낸다(라이브: "https://github.com/<o>/<r>/pull/<n>").
// 그 번호가 create/adopt 경로의 **인증된 셀렉터**다 — 우리가 방금 만든 PR이라는 사실을 gh가 직접 알려준 값이다.
// 브랜치명으로 되짚는 재조회는 하지 않는다: 동명 포크 PR로 해석될 수 있는 바로 그 모호성으로 되돌아간다.
const PR_URL_RE = /^https?:\/\/\S+\/pull\/(\d+)$/;
function createPr(): number {
  const out = run("gh", [
    "pr", "create", "--base", args.base, "--head", branch,
    "--title", args.title!, "--body", args.body!,
  ], "gh pr create");
  process.stderr.write(out); // 이 도구의 stdout은 결과 JSON 전용
  const nums = new Set(
    out.split("\n")
      .map((l) => PR_URL_RE.exec(l.trim()))
      .filter((m): m is RegExpExecArray => m !== null)
      .map((m) => Number(m[1])),
  );
  // 파싱 실패(출력 형식 드리프트·경고 혼입·URL 여러 개)는 **fail-closed**다 — 브랜치명 폴백 금지.
  // 여기서 브랜치로 폴백하면 무장이 동명 포크 PR을 지목할 수 있다(= 이 가드가 막으려는 결함 그 자체).
  if (nums.size !== 1) {
    execError(
      `gh pr create 출력에서 PR 번호를 확정할 수 없다(URL ${nums.size}개) — 무장 대상을 모른 채 `
      + `브랜치명으로 폴백하지 않는다(동명 포크 PR 오조준). 출력: ${JSON.stringify(out)}`,
    );
  }
  return [...nums][0]!;
}

// writer App의 login 표기는 **표면마다 다르다**(전부 라이브 확인) → 셋을 같은 slug로 접는다:
//   gh pr list → "app/ukyi-homelab-writer"  /  REST → "ukyi-homelab-writer[bot]"
//   GraphQL    → "ukyi-homelab-writer"      (__typename:"Bot" — 지금 쓰는 표면)
// 한 표기만 인식하면 신뢰 판정이 조용히 0이 되어 중복 PR이 되살아난다(과거에 실제로 밟은 함정).
function normalizeLogin(login: string): string {
  return login.replace(/^app\//, "").replace(/\[bot\]$/, "").toLowerCase();
}

// 신뢰하는 제안 = **(head, base) 쌍이 우리 것** + 동일-레포(포크 아님) + writer **App 봇** 작성자.
// 그 외(포크·타인·다른 base)는 사실로만 관측하고 판정 근거로 쓰지 않는다.
//   · base: 식별은 head만으로 부족하다 — 같은 head가 **다른 base**를 향한 PR은 **우리 PR이 아니다**.
//           그걸 우리 것으로 착각하면 skip/rebuild/무장/해제를 엉뚱한 PR에 하고, 정작 요청된 base의
//           PR은 영영 안 생긴다.
//   · type: GraphQL은 App 봇을 `Bot`, 사람을 `User`로 준다. 봇 계정의 실제 login은 `<slug>[bot]`이므로
//           **`<slug>` 그대로의 사람 계정이 존재할 수 있다** → login만 보면 사칭이 가능하다. 타입까지 본다.
function isTrusted(pr: RawPr, writer: string, base: string): boolean {
  if (pr.isCrossRepository) return false;
  if (pr.baseRefName !== base) return false;
  if (pr.author === null) return false;
  if (pr.author.type !== "Bot") return false;
  return normalizeLogin(pr.author.login) === normalizeLogin(writer);
}

// ── ① 조회 — 변이보다 **먼저**, 상한 없이 **전부** 수집한다(순서도 완전성도 계약이다: R-4) ────────
// `--paginate`가 hasNextPage=false까지 따라가고 `--slurp`이 페이지들을 배열로 묶는다. 상한이 없으므로
// 포크 PR이 몇 건이든(200건이든 2000건이든) 우리 PR은 반드시 이 열거 안에 있다 → 포크로는 배포를
// 정지시킬 수 없다. owner/repo는 gh의 `{owner}`/`{repo}` 플레이스홀더가 현재 레포에서 채운다(라이브 확인).
const prs = parsePrs(run(
  "gh",
  ["api", "graphql", "--paginate", "--slurp",
    "-f", `query=${PR_QUERY}`,
    "-F", "owner={owner}", "-F", "repo={repo}", "-F", `head=${branch}`],
  "gh api graphql (pullRequests)",
));
const remoteBranch = parseLsRemote(run("git", ["ls-remote", "--heads", args.remote, branch], "git ls-remote"));

const observedPrs = prs.map((pr) => ({ ...pr, trusted: isTrusted(pr, args.writer, args.base) }));
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

// ★★ 파괴 가드 — `adopt`(force-push)는 **우리 자신의 고아 브랜치**일 때만 정당하다 ────────────────
// 동일-레포(isCrossRepository:false) PR의 head는 **반드시 이 레포의 ref**다(포크와 달리 남의 레포에 있을 수
// 없다). 그러니 "열린 동일-레포 PR이 있다" = "그 브랜치는 이 레포에 존재하고, **그 PR의 주인 것**이다".
// 그 PR을 신뢰하지 못하면(= writer App이 아닌 사람/다른 봇이 열었다) 우리는 두 가지를 다 하면 안 된다:
//   · adopt로 그 브랜치를 leased force-push → **남의 브랜치를 덮어써 작업을 파괴한다**
//   · create로 PR을 또 연다 → 같은 head에 중복 제안
// remoteBranch 유무로 갈리지 않는다: 동일-레포 PR이 열려 있는데 브랜치가 없는 상태는 **불가능**하고,
// 만약 그렇게 보인다면 우리가 사실을 잘못 읽은 것이다 → 어느 쪽이든 변이하지 않는 게 정답이다.
// (포크 PR은 여기 걸리지 않는다 — 포크의 head는 우리 레포 ref가 아니라 우리 브랜치를 침해하지 않는다.
//  그래서 포크만 있는 경우는 기존대로 브랜치 유무로 create/adopt를 고른다.)
// ⚠️ 소유권은 **base와 무관**하다: 같은 head를 다른 base로 향한 동일-레포 PR도 **그 브랜치를 쓰고 있다**.
//    그래서 조회를 base로 필터하지 않고(위 PR_QUERY), 여기서 head 전체의 동일-레포 PR을 본다.
//    (다른 base의 writer PR을 "우리 것"으로 오인하지 않는 건 isTrusted의 base 검사가 맡는다 — 식별과
//     소유권은 다른 질문이다: "우리 PR인가?"는 (head, base), "이 브랜치를 밀어도 되나?"는 head다.)
const untrustedSameRepo = observedPrs.filter((pr) => !pr.trusted && !pr.isCrossRepository);
if (trusted === null && untrustedSameRepo.length > 0) {
  const who = untrustedSameRepo
    .map((p) => `#${p.number}(${p.author?.login ?? "삭제된 계정"} → ${p.baseRefName})`)
    .join(", ");
  execError(
    `신뢰할 수 없는 동일-레포 PR이 이 브랜치에 열려 있다: ${who} — 브랜치 '${branch}'는 그 PR의 것이다. `
    + "force-push(adopt)로 덮어쓰면 남의 작업을 파괴하고, PR을 새로 열면 중복 제안이 된다",
  );
}

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
// ── 변이 대상 PR의 **인증된 셀렉터** = 번호 ────────────────────────────────────────────────────
// 브랜치명은 셀렉터로 쓰면 안 된다: `gh pr merge <branch>`/`gh pr view <branch>`는 **같은 브랜치명의
// 포크 PR**로도 해석될 수 있다(공개 레포 — 아무나 같은 결정적 브랜치명으로 PR을 연다). 그 경로로 무장하면
// **공격자의 PR이 auto-merge된다**. 그래서 무장/해제는 전부 "우리가 인증한 번호"만 지목한다:
//   · skip/rebuild = 조회로 신뢰 판정을 통과한 PR      → trusted.number
//   · create/adopt = 방금 우리가 만든 PR              → gh pr create가 돌려준 URL에서 파싱한 번호
// 공유 스크립트(auto-merge-or-fail.sh)는 인자를 `gh pr merge`/`gh pr view`에 **그대로 넘기는 패스스루**라
// (브랜치명 자체를 쓰는 로직이 없다) 번호를 넘기는 것만으로 모호성이 사라진다 — 스크립트 변경 불필요.
let prNumber: number | null = trusted?.number ?? null;
if (createsPr) {
  prNumber = createPr();
}
// 무장은 **레인만** 본다 — propose-pr(승인 레인)은 어떤 경로로도 여기 들어오지 못한다(R-11).
// 새 PR이면 생성 직후, 기존 PR이면 무장 갭이 있을 때만(판정이 skip이든 rebuild든) 수렴시킨다(R-10).
if (shouldArm) {
  // 번호를 모르면 **무장하지 않는다**. 브랜치로 폴백하는 순간 위의 모호성이 되살아난다(폴백 금지).
  if (prNumber === null) {
    execError("무장 대상 PR 번호를 모른다 — 브랜치명으로는 무장하지 않는다(동명 포크 PR 오조준)");
  }
  // races-6 폴백(gh pr merge --auto는 이미 CLEAN인 PR에 에러) — 검증된 공유 스크립트를 재사용한다.
  const script = path.join(import.meta.dir, "..", "scripts", "auto-merge-or-fail.sh");
  mutate("bash", [script, String(prNumber)], "auto-merge-or-fail");
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
