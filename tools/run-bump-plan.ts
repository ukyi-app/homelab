// bump 플랜 항목 러너 — bump-poll.yaml의 인-워크플로 셸 루프를 대체하는 테스트된 오케스트레이터(F-1).
//
// 플래너(poll-ghcr)가 만든 plan.json을 소비해 bump/propose-pr 항목을 **항목마다 격리 git worktree**에서 처리한다:
//   worktree add(<base> 기준 결정적 새 브랜치) → bump-tag → **잔여물 판정**(천장 밖 변경 0) → git add(writePath+digest-exporter) → commit(writer 신원) →
//   ensure-bump-pr → worktree remove(성공·실패 모든 경로). 공유 worktree/index가 없어 R-38(종료상태만 격리)·
//   H-2(commit 전 실패 시 staged digest-exporter 누출) 클래스가 **구조적으로 불가능**하다.
//
// ⚠️ per-item 변이·ensure-bump-pr는 모두 **worktree 안(cwd=wt)**에서 돈다. ensure-bump-pr의 push는
//    `git push origin HEAD:refs/heads/<b>`라 **HEAD가 bump 커밋**이어야 한다 — worktree의 HEAD가 곧 그 브랜치 tip이다.
//
// 실패는 fail-closed로 **집계**만 하고(한 항목 실패가 나머지를 굶기지 않는다) 끝에서 비-0으로 끝낸다 —
// `pr-sweeper`가 이 네임스페이스에서 빠진 지금, 이 루프의 생존성은 인가 회수의 전제조건이다.
//
// ⚠️ 원격 변이(push·PR 생성·무장/해제)는 **ensure-bump-pr만** 한다. 이 러너는 git push·gh pr create·auto-merge를
//    직접 부르지 않는다. auto-merge를 켜는 별도 플래그도 없다 — 레인(플래너 `.action`)이 유일 입력이고, 러너는
//    그것을 **재해석 없이 그대로** ensure-bump-pr에 넘긴다(승인 게이트 우회 불가).
//
// 사용: bun tools/run-bump-plan.ts --plan <plan.json> [--repo-root <dir>] [--base <ref>] [--ensure-bin <bin>] [--ensure-script <path>]
//   --repo-root    : git repo 루트(기본 "."). 테스트는 fixture repo를 넘긴다.
//   --base         : worktree 기준 ref(기본 "main").
//   --ensure-bin   : ensure-bump-pr 실행 바이너리(기본 "bun"). 테스트가 stub으로 override(내부 seam).
//   --ensure-script: ensure-bump-pr 스크립트 경로(기본 "<이 파일 옆 ensure-bump-pr.ts>"). 같은 seam의 나머지 절반.

import { mkdtempSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
// 앱명 게이트는 전 mutator 공유 SSOT — 분기 금지(콜사이트마다 다르면 우회 표면). bump-tag와 같은 정규식을 쓴다.
import { APP_NAME_RE } from "./lib/identity.ts";
// plan 계약·명명·writer 신원은 bump-plan module이 소유한다(d3·08) — 디코드는 fail-closed고,
// target 신원(kind+name)은 argv(--kind/--name)로 ensure-bump-pr까지 관통한다(design r2-1).
import { WRITER_NAME, WRITER_EMAIL, decodePlan, branchFor, commitMessage, type Change, type PlanItem } from "./lib/bump-plan.ts";
// subprocess 실행은 exec seam 경유(d6②) — timeoutMs 0으로 종전 무-timeout 동작을 보존한다.
import { sh } from "./lib/exec.ts";
// argv 파싱 SSOT — unknown/값 누락 fail-closed. 광고(USAGE)도 같은 목록에서 파생한다.
import { typedFlags, type TypedFlags } from "./lib/cli.ts";

const EXPORTER = "platform/victoria-stack/prod/digest-exporter.yaml";
// 도구 경로는 러너 옆(tools/)에서 절대 해석 — cwd(worktree=대상 트리, tools/ 없을 수 있음)와 무관하게 실행.
const HERE = import.meta.dir;
const BUMP_TAG = resolve(HERE, "bump-tag.ts");
const DEFAULT_ENSURE_SCRIPT = resolve(HERE, "ensure-bump-pr.ts");

// ensure 호출은 argv seam(bin + script) — shell-string split 금지(경로 공백이 argv를 깨뜨린다).
// ⚠️ **광고와 파서는 한 목록에서 나온다.** 예전엔 usage(--help·헤더 주석)가 ensure 커맨드를 통째로
//    받는 **네 번째 플래그**를 광고하는데 파서는 아래 bin/script 둘만 받아, --help를 그대로 따라 하면
//    `알 수 없는 옵션`으로 exit 2가 났다(실측). 콜사이트가 0건이라 라이브 손해는 없었지만 광고가
//    거짓이었다 — shell-string split은 태생(0193930)부터 명시 기각이므로 처방은 파서 확장이 아니라
//    광고 정정이고, 재발을 막는 자리는 usage 문자열을 이 표에서 **파생**시키는 것이다(갈릴 표면 소멸).
// ⚠️ 그 유령 플래그의 리터럴을 **이 파일에 다시 쓰지 마라**(주석 포함) — 재유입 거부 증인이
//    주석 스트립 없는 원본을 보므로 설명하려다 red를 만든다. 규율은 scripts/check-floor-vocab.sh와 같다.
// 이름과 메타변수를 한 표에 둔다 — 파서 입력(이름)과 광고(이름+메타변수)가 이 표에서만 나온다.
const VALUE_FLAGS: ReadonlyArray<readonly [string, string, boolean]> = [
  ["--plan", "<plan.json>", true],   // true = 필수(광고에서 대괄호를 벗는다)
  ["--repo-root", "<dir>", false],
  ["--base", "<ref>", false],
  ["--ensure-bin", "<bin>", false],
  ["--ensure-script", "<path>", false],
];
const USAGE = "usage: run-bump-plan.ts " + VALUE_FLAGS.map(([k, meta, req]) => (req ? `${k} ${meta}` : `[${k} ${meta}]`)).join(" ");
const argv = process.argv.slice(2);
if (argv.includes("--help") || argv.includes("-h")) {
  console.log(USAGE);
  process.exit(0);
}
// 파싱은 SSOT 경유(tools/lib/cli.ts) — unknown 거부·값 누락(다음 플래그 삼킴) 거부를 콜사이트가 다시
// 구현하지 않는다. 종전 자체 루프는 그 규약을 손으로 복제하고 있었고 우회 근거 주석도 없었다
// (비교: tools/generate-result-schema.ts의 손 파싱은 "격리 재생성 증명" 근거를 명시한다).
// 종료코드 2(사용법)는 cli.ts 규약 그대로다.
let f: TypedFlags;
try { f = typedFlags(argv, { value: VALUE_FLAGS.map(([k]) => k), bool: [] }); }
catch (e) { console.error(`${e instanceof Error ? e.message : String(e)}\n${USAGE}`); process.exit(2); }
const planPath = f.str("--plan");
if (!planPath) { console.error("--plan <plan.json> 필수"); process.exit(2); }
const repoRoot = resolve(f.str("--repo-root") ?? ".");
const base = f.str("--base") ?? "main";
const ensureBin = f.str("--ensure-bin") ?? "bun";
const ensureScript = f.str("--ensure-script") ?? DEFAULT_ENSURE_SCRIPT;

function run(cmd: string, args: string[], cwd: string): { ok: boolean; status: number; out: string } {
  const r = sh(cmd, args, { cwd, timeoutMs: 0 });
  // spawn 자체 실패(errKind — missing git/bun 등)도 실패로 접고 로그에 남긴다(조용한 비-0 방지).
  const out = r.errKind !== undefined ? `[spawn error] ${r.err}` : r.out + (r.err ? `\n${r.err}` : "");
  return { ok: r.ok, status: r.status ?? -1, out };
}
const git = (args: string[], cwd: string) => run("git", args, cwd);

// 디코드는 module의 fail-closed 계약 그대로다 — 미지 action·신원 불량·Lane 증거 부재·kind↔pin
// 부정합은 여기서 죽는다(러너가 관용 해석으로 우회할 표면이 없다).
let plan: PlanItem[];
try { plan = decodePlan(readFileSync(planPath, "utf8")); } catch (e) { console.error(`plan 디코드 실패(fail-closed): ${(e as Error).message}`); process.exit(2); }

const items = plan.filter((it): it is Change => it.action === "bump" || it.action === "propose-pr");
const failed: string[] = [];

for (const item of items) {
  const target = item.target;
  const name = target.name;
  const label = `${target.kind}/${name}`;
  // 공유 SSOT 게이트 — bump-tag 재검증 전에 worktree/브랜치를 만들지 않도록 여기서 먼저 거른다(우회 표면 차단).
  // decodePlan은 이름을 "빈 문자열 아님"까지만 재므로 여기가 이름 정책의 유일 게이트다 — 불합격이 조용한
  // skip이면 그 항목은 아무도 처리하지 않는데 run은 초록이다(vacuous green) → fail-closed 집계로 red.
  if (!APP_NAME_RE.test(name)) {
    console.log(`::warning::${label}: target 이름이 APP_NAME_RE 불합격 — fail-closed(처리하지 않되 run은 빨갛게)`);
    failed.push(label);
    continue;
  }
  const tag = item.candidate.tag;
  const action = item.action;
  const writePath = item.writePath;
  const expect = item.current.tag;
  const digest = item.candidate.digest;
  const pin = item.pin;

  const branch = branchFor(target, tag);
  const wt = mkdtempSync(join(tmpdir(), `bump-wt-${name}-`));
  let ok = true;
  let added = false;
  try {
    // 항목별 격리 worktree — HEAD가 이 브랜치 tip이 된다(ensure-bump-pr의 HEAD:refs/heads/<b> push 전제).
    const add = git(["worktree", "add", "--quiet", wt, "-b", branch, base], repoRoot);
    added = add.ok;
    if (!add.ok) { console.log(`::warning::${label}: worktree add 실패\n${add.out}`); ok = false; }

    if (ok) {
      // bump-tag(진짜, 절대 경로): 이 worktree의 values/digest-exporter를 쓴다. expect-current로 plan-이후 main 이동 fail-closed.
      // --kind는 신원 교차 검증이다 — bump-tag가 kind와 편집 모드(--pin 유무)의 정합을 재확인한다.
      const btArgs = [BUMP_TAG, name, tag, "--repo-root", wt, "--expect-current", expect, "--kind", target.kind];
      if (digest) btArgs.push("--digest", String(digest));
      if (pin) btArgs.push("--pin", pin);
      const bt = run("bun", btArgs, wt);
      if (!bt.ok) { console.log(`::warning::${label}: bump-tag 실패(exit ${bt.status})\n${bt.out}`); ok = false; }
    }

    if (ok) {
      // ── 스테이징 완전성 판정 [staged-completeness] ────────────────────────────────────────
      // 천장(바로 아래 add의 pathspec = writePath + digest-exporter)은 **상한으로 남긴다** — 여기서
      // 재는 것은 열거가 아니라 **잔여물**이다. bump-tag가 이 둘 밖에 쓰면(플래너 writePath가 실제
      // 편집 대상과 어긋나는 순간이 그 자리다) 그 변경은 커밋에서 **조용히 유실**되고 PR이 부분
      // 표면으로 열린다 — add·commit·push가 전부 성공하므로 어떤 종료코드도 그것을 말하지 않는다
      // (형제 자리의 2026-08-18 실사고: .github/actions/pr-first-commit/action.yml).
      // 포함 판정은 `:(exclude)` pathspec으로 **git에게 시킨다** — 아래 add와 같은 매처라 두 번째
      // 구현이 생기지 않는다(포세린 줄을 고정 오프셋으로 자르는 형태는 rename에서 깨진다).
      // 판정은 add **앞**이다 — 뒤에 두면 pathspec 미매치 실패와 구별할 수 없다.
      const residue = git(["status", "--porcelain", "--untracked-files=all", "--", ".", `:(exclude)${writePath}`, `:(exclude)${EXPORTER}`], wt);
      if (!residue.ok) { console.log(`::warning::${label}: git status 실패(스테이징 완전성)\n${residue.out}`); ok = false; }
      else if (residue.out.trim() !== "") {
        console.log(`::warning::${label}: 천장(writePath+digest-exporter) 밖 변경이 남는다 — 이대로 커밋하면 유실된다\n${residue.out}`);
        ok = false;
      }
      // ── [/staged-completeness] ───────────────────────────────────────────────────────────
    }

    if (ok) {
      const stage = git(["add", writePath, EXPORTER], wt);
      if (!stage.ok) { console.log(`::warning::${label}: git add 실패\n${stage.out}`); ok = false; }
    }

    if (ok) {
      // commit: writer[bot] 신원을 명시(git -c) — ensure-bump-pr가 이 신원+결정적 메시지로 소유 증명.
      const msg = commitMessage(target, tag);
      const commit = git(["-c", `user.name=${WRITER_NAME}`, "-c", `user.email=${WRITER_EMAIL}`, "commit", "-m", msg], wt);
      if (!commit.ok) { console.log(`::warning::${label}: git commit 실패\n${commit.out}`); ok = false; }
    }

    if (ok) {
      // 레인별로 갈리는 건 title/body뿐 — 레인(action) 자체는 플래너 값 그대로 넘긴다.
      const [title, body] = action === "bump"
        ? [`chore: ${name} 이미지 갱신 (자동)`, "GHCR 폴링 bump — main reachable + descendant + digest 핀 검증 통과. gate 통과 시 auto-merge."]
        : [`chore: ${name} 이미지 갱신 (승인 대기)`, "autoDeploy:false — **머지 = 배포 승인**. GHCR 폴링이 검증한 후보(digest 핀)."];
      // ensure-bump-pr(원격 변이 유일 소유): cwd=wt(HEAD=bump 커밋). 열린 PR·원격 브랜치 관측 후에만 변이.
      // argv seam(bin+script, split 없음)이라 경로 공백에도 안전. 신원은 (kind, name) 쌍으로 관통한다.
      // inherit — ensure의 stdout(결과 JSON)·stderr(경고)를 워크플로 로그에 그대로 물린다(종전 stdio 동작).
      const eArgs = [ensureScript, "--kind", target.kind, "--name", name, "--tag", tag, "--action", action, "--title", title, "--body", body];
      const e = sh(ensureBin, eArgs, { cwd: wt, timeoutMs: 0, inherit: true });
      if (!e.ok) { console.log(`::warning::${label}: ensure-bump-pr 실패(exit ${e.status}${e.errKind !== undefined ? " " + e.err : ""})`); ok = false; }
    }
  } finally {
    // 정리는 **모든 경로**에서 — worktree/브랜치 누적 방지. (원격은 ensure-bump-pr 소관 — 여기선 로컬만.)
    if (added) git(["worktree", "remove", "--force", wt], repoRoot);
    rmSync(wt, { recursive: true, force: true });
    git(["branch", "-D", branch], repoRoot);
  }

  if (!ok) {
    console.log(`::warning::${label}: bump 항목 실패(fail-closed) — 다른 항목 처리는 계속`);
    failed.push(label);
  }
}

if (failed.length > 0) {
  console.log(`::error::이번 주기에 실패한 target: ${failed.join(" ")}`);
  process.exit(1);
}
console.log("run-bump-plan: 전 항목 처리 완료");
