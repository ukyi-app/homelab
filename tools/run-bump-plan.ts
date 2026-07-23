// bump 플랜 항목 러너 — bump-poll.yaml의 인-워크플로 셸 루프를 대체하는 테스트된 오케스트레이터(F-1).
//
// 플래너(poll-ghcr)가 만든 plan.json을 소비해 bump/propose-pr 항목을 **항목마다 격리 git worktree**에서 처리한다:
//   worktree add(<base> 기준 결정적 새 브랜치) → bump-tag → git add(writePath+digest-exporter) → commit(writer 신원) →
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
// 사용: bun tools/run-bump-plan.ts --plan <plan.json> [--repo-root <dir>] [--base <ref>] [--ensure-cmd "<cmd>"]
//   --repo-root : git repo 루트(기본 "."). 테스트는 fixture repo를 넘긴다.
//   --base      : worktree 기준 ref(기본 "main").
//   --ensure-cmd: ensure-bump-pr 호출 커맨드(기본 "bun <이 파일 옆 ensure-bump-pr.ts>"). 테스트가 stub으로 override(내부 seam).

import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
// 앱명 게이트는 전 mutator 공유 SSOT — 분기 금지(콜사이트마다 다르면 우회 표면). bump-tag와 같은 정규식을 쓴다.
import { APP_NAME_RE } from "./lib/identity.ts";

const WRITER_NAME = "ukyi-homelab-writer[bot]";
const WRITER_EMAIL = "293311924+ukyi-homelab-writer[bot]@users.noreply.github.com";
const EXPORTER = "platform/victoria-stack/prod/digest-exporter.yaml";
// 도구 경로는 러너 옆(tools/)에서 절대 해석 — cwd(worktree=대상 트리, tools/ 없을 수 있음)와 무관하게 실행.
const HERE = import.meta.dir;
const BUMP_TAG = resolve(HERE, "bump-tag.ts");
const DEFAULT_ENSURE_SCRIPT = resolve(HERE, "ensure-bump-pr.ts");

// ensure 호출은 argv seam(bin + script) — shell-string split 금지(경로 공백이 argv를 깨뜨린다).
const VALUE_FLAGS = new Set(["--plan", "--repo-root", "--base", "--ensure-bin", "--ensure-script"]);
const argv = process.argv.slice(2);
if (argv.includes("--help") || argv.includes("-h")) {
  console.log("usage: run-bump-plan.ts --plan <plan.json> [--repo-root <dir>] [--base <ref>] [--ensure-cmd <cmd>]");
  process.exit(0);
}
const opts: Record<string, string> = {};
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (!a.startsWith("--")) { console.error(`positional 인자 미지원: ${a}`); process.exit(2); }
  if (!VALUE_FLAGS.has(a)) { console.error(`알 수 없는 옵션: ${a}\n허용: ${[...VALUE_FLAGS].join(" ")}`); process.exit(2); }
  const v = argv[i + 1];
  if (v === undefined || v.startsWith("--")) { console.error(`옵션 ${a}에 값이 없다(arity 위반) — 값을 명시하라`); process.exit(2); }
  opts[a] = v; i++;
}
const planPath = opts["--plan"];
if (!planPath) { console.error("--plan <plan.json> 필수"); process.exit(2); }
const repoRoot = resolve(opts["--repo-root"] ?? ".");
const base = opts["--base"] ?? "main";
const ensureBin = opts["--ensure-bin"] ?? "bun";
const ensureScript = opts["--ensure-script"] ?? DEFAULT_ENSURE_SCRIPT;

type PlanItem = {
  app: string;
  action: string;
  candidate?: { tag: string; digest?: unknown } | null;
  current?: { tag: string } | null;
  writePath?: string;
  pin?: string;
};

function run(cmd: string, args: string[], cwd: string): { ok: boolean; status: number; out: string } {
  const r = spawnSync(cmd, args, { cwd, encoding: "utf8" });
  // r.error(ENOENT 등 spawn 자체 실패)도 실패로 접고 로그에 남긴다(missing git/bun이 조용한 비-0 되지 않게).
  const out = (r.stdout ?? "") + (r.stderr ?? "") + (r.error ? `\n[spawn error] ${r.error.message}` : "");
  return { ok: r.status === 0 && !r.error, status: r.status ?? -1, out };
}
const git = (args: string[], cwd: string) => run("git", args, cwd);

let plan: PlanItem[];
try { plan = JSON.parse(readFileSync(planPath, "utf8")); } catch (e) { console.error(`plan.json 파싱 실패: ${(e as Error).message}`); process.exit(2); }
if (!Array.isArray(plan)) { console.error("plan.json은 배열이어야 한다"); process.exit(2); }

const items = plan.filter((it) => it.action === "bump" || it.action === "propose-pr");
const failed: string[] = [];

for (const item of items) {
  const app = item.app;
  // 공유 SSOT 게이트 — bump-tag 재검증 전에 worktree/브랜치를 만들지 않도록 여기서 먼저 거른다(우회 표면 차단).
  if (!APP_NAME_RE.test(app)) { console.log(`skip invalid app name: '${app}'`); continue; }
  const tag = item.candidate?.tag;
  const action = item.action;
  const writePath = item.writePath;
  const expect = item.current?.tag;
  const digest = item.candidate?.digest;
  const pin = item.pin;
  if (!tag || !writePath || !expect) {
    console.log(`::warning::${app}: plan 항목에 tag/writePath/current.tag 누락 — fail-closed skip`);
    failed.push(app);
    continue;
  }

  const branch = `bump-poll/${app}-${tag}`;
  const wt = mkdtempSync(join(tmpdir(), `bump-wt-${app}-`));
  let ok = true;
  let added = false;
  try {
    // 항목별 격리 worktree — HEAD가 이 브랜치 tip이 된다(ensure-bump-pr의 HEAD:refs/heads/<b> push 전제).
    const add = git(["worktree", "add", "--quiet", wt, "-b", branch, base], repoRoot);
    added = add.ok;
    if (!add.ok) { console.log(`::warning::${app}: worktree add 실패\n${add.out}`); ok = false; }

    if (ok) {
      // bump-tag(진짜, 절대 경로): 이 worktree의 values/digest-exporter를 쓴다. expect-current로 plan-이후 main 이동 fail-closed.
      const btArgs = [BUMP_TAG, app, tag, "--repo-root", wt, "--expect-current", String(expect)];
      if (digest) btArgs.push("--digest", String(digest));
      if (pin) btArgs.push("--pin", pin);
      const bt = run("bun", btArgs, wt);
      if (!bt.ok) { console.log(`::warning::${app}: bump-tag 실패(exit ${bt.status})\n${bt.out}`); ok = false; }
    }

    if (ok) {
      const stage = git(["add", writePath, EXPORTER], wt);
      if (!stage.ok) { console.log(`::warning::${app}: git add 실패\n${stage.out}`); ok = false; }
    }

    if (ok) {
      // commit: writer[bot] 신원을 명시(git -c) — ensure-bump-pr가 이 신원+결정적 메시지로 소유 증명.
      const msg = `chore: ${app} 이미지를 ${tag}(digest 핀)로 갱신 (GHCR 폴링)`;
      const commit = git(["-c", `user.name=${WRITER_NAME}`, "-c", `user.email=${WRITER_EMAIL}`, "commit", "-m", msg], wt);
      if (!commit.ok) { console.log(`::warning::${app}: git commit 실패\n${commit.out}`); ok = false; }
    }

    if (ok) {
      // 레인별로 갈리는 건 title/body뿐 — 레인(action) 자체는 플래너 값 그대로 넘긴다.
      const [title, body] = action === "bump"
        ? [`chore: ${app} 이미지 갱신 (자동)`, "GHCR 폴링 bump — main reachable + descendant + digest 핀 검증 통과. gate 통과 시 auto-merge."]
        : [`chore: ${app} 이미지 갱신 (승인 대기)`, "autoDeploy:false — **머지 = 배포 승인**. GHCR 폴링이 검증한 후보(digest 핀)."];
      // ensure-bump-pr(원격 변이 유일 소유): cwd=wt(HEAD=bump 커밋). 열린 PR·원격 브랜치 관측 후에만 변이.
      // argv seam(bin+script, split 없음)이라 경로 공백에도 안전.
      const eArgs = [ensureScript, "--app", app, "--tag", tag, "--action", action, "--title", title, "--body", body];
      const e = spawnSync(ensureBin, eArgs, { cwd: wt, encoding: "utf8", stdio: ["inherit", "inherit", "inherit"] });
      if (e.status !== 0 || e.error) { console.log(`::warning::${app}: ensure-bump-pr 실패(exit ${e.status}${e.error ? " " + e.error.message : ""})`); ok = false; }
    }
  } finally {
    // 정리는 **모든 경로**에서 — worktree/브랜치 누적 방지. (원격은 ensure-bump-pr 소관 — 여기선 로컬만.)
    if (added) git(["worktree", "remove", "--force", wt], repoRoot);
    rmSync(wt, { recursive: true, force: true });
    git(["branch", "-D", branch], repoRoot);
  }

  if (!ok) {
    console.log(`::warning::${app}: bump 항목 실패(fail-closed) — 다른 앱 처리는 계속`);
    failed.push(app);
  }
}

if (failed.length > 0) {
  console.log(`::error::이번 주기에 실패한 앱: ${failed.join(" ")}`);
  process.exit(1);
}
console.log("run-bump-plan: 전 항목 처리 완료");
