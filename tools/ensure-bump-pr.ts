// bump PR 실행기 — **RED baseline(동결)**. 이 파일은 픽스 **이전** 프로덕션의 행위를 실행기 seam으로
// 그대로 옮겨 놓은 것이다. 여기서 회귀 증인들이 전부 RED가 되고, 픽스가 그 RED를 GREEN으로 뒤집는다.
//
// ── 동결한 원본(픽스 이전 .github/workflows/bump-poll.yaml의 bump 스텝, 앱마다 인라인) ──────────
//   git checkout main
//   branch="bump-poll/${app}-${RUN_ID}"        # run마다 다른 브랜치(RUN_ID는 워크플로 쪽 결함이다)
//   git checkout -b "$branch"
//   bun tools/bump-tag.ts …
//   git add …; git commit -m "chore: ${app} 이미지를 ${tag}(digest 핀)로 갱신 (GHCR 폴링)"
//   git push -u origin "$branch"               # ← plain push. lease 없음. 무조건.
//   if [ "$action" = "bump" ]; then
//     gh pr create --base main --head "$branch" --title … --body …   # ← **무조건** 연다
//     bash scripts/auto-merge-or-fail.sh "$branch"                   # ← **브랜치 셀렉터**로 무장
//   else
//     gh pr create --base main --head "$branch" --title … --body …   # ← 열기만(무장 0·해제 0)
//   fi
//
// ★★ 픽스 이전엔 **조회가 존재하지 않는다** — `gh api graphql`도 `gh pr list`도 `git ls-remote`도 없다.
//    열린 PR이 이미 있는지 **묻지 않고** 매 폴링이 PR을 또 연다. 그게 이 버그다
//    (page sha-815abb…: 11분 사이 PR 3개 — 좀비 2개가 DIRTY + auto-merge 무장으로 잔류).
//
// 그래서 이 동결본에는 **조회도, 결정도, lease도, 소유권 증명도, 해제도, fail-closed도 없다**:
//   · 사실을 하나도 수집하지 않는다(원격 read 호출 0회 — 원장에 조회 argv가 남지 않는다).
//   · 판정이 없다 — 언제나 create다.
//   · 변이 명령이 실패해도 죽지 않는다(픽스 이전 코드엔 push/create 실패 처리가 없다).
// 조회·판정·lease·인가(auto-merge) reconcile·fail-closed는 **전부 픽스가 새로 만드는 계약**이다
// → 그 증인들이 여기서 전부 RED다. 남는 것은 CLI 표면(레인 필수·exit 2·--help)과 레인 격리
//   (propose-pr은 무장하지 않는다 — 그건 픽스 이전에도 그랬다)뿐이다.
import { spawnSync } from "node:child_process";
import path from "node:path";
import { TAG_RE } from "./lib/image-pin.ts";

const USAGE = `ensure-bump-pr — bump PR 멱등 실행기(조회 → 결정 → 변이; 같은 bump = 같은 브랜치 = 열린 PR 1개)
사용법: bun tools/ensure-bump-pr.ts --app <app> --tag <sha-tag> --action <lane> --title <t> --body <b> [옵션]
  --app <app>       앱 이름(소문자/숫자/하이픈)
  --tag <tag>       후보 배포 핀 tag(sha-<7..40 hex>) — 브랜치는 bump-poll/<app>-<tag>(RUN_ID 없음)
  --action <lane>   플래너(poll-ghcr)의 .action을 **그대로** — bump | propose-pr (필수, 기본값 없음)
                      bump       = autoDeploy:true  → auto-merge 무장
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

// 기본 writer App slug — 동결본에선 **쓰이지 않는다**(신뢰 판정 자체가 없다). CLI 표면만 유지한다.
const DEFAULT_WRITER = "ukyi-homelab-writer";
const APP_RE = /^[a-z0-9-]+$/;

// 배포 승인 레인 — poll-ghcr.ts가 내는 값과 **글자 그대로** 같다(`s.autoDeploy ? "bump" : "propose-pr"`).
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

// 사용법 위반(인자)만 exit 2다. **fail-closed는 존재하지 않는다** — 픽스 이전엔 막을 사실 자체가 없었다.
function usageError(msg: string): never {
  console.error(`ensure-bump-pr: ${msg}`);
  process.exit(2);
}

if (!args.app) usageError("--app 필수");
if (!args.tag) usageError("--tag 필수");
if (!args.title) usageError("--title 필수");
if (!args.body) usageError("--body 필수");
if (!args.lane) usageError(`--action 필수 (${LANES.join(" | ")}) — 플래너의 .action을 그대로 넘긴다`);
const lane: Lane = args.lane;
if (!APP_RE.test(args.app)) usageError(`--app 형식 위반: '${args.app}' (소문자/숫자/하이픈만)`);
if (!TAG_RE.test(args.tag)) usageError(`--tag 형식 위반: '${args.tag}' (sha-<7..40 hex>)`);
// writer/base/remote는 CLI 표면으로만 남는다(조회가 없으니 신뢰 판정도 없다) — base/remote만 변이에 쓴다.
void args.writer;

// 브랜치 — 도구는 (app, tag)로 만든다. RUN_ID는 **워크플로 쪽 결함**이라 여기엔 원래 없다
// (호출부 게이트 "the bump branch name carries no RUN_ID"가 그 RED를 잡는다).
const branch = `bump-poll/${args.app}-${args.tag}`;

// 실행한 명령 원장.
const executed: string[] = [];

// 실행기 — **죽지 않는다**. 픽스 이전엔 push/create 실패에 대한 어떤 처리도 없었다.
// 변이 명령의 stdout은 stderr로 흘린다(이 도구의 stdout은 결과 JSON 전용).
function mutate(cmd: string, a: string[]): void {
  executed.push([cmd, ...a].join(" "));
  const r = spawnSync(cmd, a, { encoding: "utf8" });
  if (r.error) {
    process.stderr.write(`ensure-bump-pr: ${cmd} 실행 실패: ${r.error.message}\n`);
    return;
  }
  if (r.stderr) process.stderr.write(r.stderr);
  if (r.stdout) process.stderr.write(r.stdout);
}

// ── ① 조회 — **없다**(동결) ───────────────────────────────────────────────────────────────────
// 픽스 이전 워크플로는 원격에 아무것도 묻지 않는다: 열린 PR도, 원격 브랜치도, 커밋 소유권도.
// 그래서 아래 변이는 **어떤 사실에도 조건이 걸리지 않는다**.

// ── ② 결정 — **없다**(동결) ───────────────────────────────────────────────────────────────────
// 신뢰 PR이 열려 있어도, 고아 원격 브랜치가 있어도, 무장이 빠져 있어도, head가 남의 커밋이어도,
// 승인 레인에 낡은 무장이 남아 있어도 — 언제나 create다.
// 픽스가 여기에 조회(완전 열거) → create/adopt/skip/rebuild 상태 기계 → 인가 reconcile을 넣는다.
const action = "create" as const;
const reason =
  "red baseline: 조회도 판정도 없다 — 열린 PR·고아 브랜치·무장 여부·소유권을 **묻지 않고** 언제나 create "
  + "(픽스 이전 프로덕션 그대로: 매 폴링 중복 PR)";

// ── ③ 변이 — 픽스 이전 워크플로의 세 줄 그대로 ────────────────────────────────────────────────
// (a) plain push — lease 없음. 고아 브랜치가 있으면 non-fast-forward로 튕기고, 그 실패조차 무시된다.
mutate("git", ["push", "-u", args.remote, branch]);
// (b) PR 생성 — **무조건**. 열린 PR을 확인하지 않는다(= 중복 PR의 직접 원인).
mutate("gh", [
  "pr", "create", "--base", args.base, "--head", branch,
  "--title", args.title!, "--body", args.body!,
]);
// (c) bump 레인만 무장 — 셀렉터는 **브랜치명**이다(인증된 PR 번호가 아니다 → 동명 포크 PR 오조준 위험).
//     propose-pr 레인은 열기만 하고 무장하지 않는다(픽스 이전에도 그랬다) — 해제도 하지 않는다.
if (lane === "bump") {
  const script = path.join(import.meta.dir, "..", "scripts", "auto-merge-or-fail.sh");
  mutate("bash", [script, branch]);
}

console.log(JSON.stringify({
  action,
  lane,
  reason,
  branch,
  // 관측한 사실이 **하나도 없다** — 조회를 하지 않았기 때문이다(픽스가 이 필드를 채운다).
  observed: null,
  executed,
}, null, 2));
