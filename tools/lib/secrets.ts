// homelab app secrets 엔진 — 이중 모드(스펙 "app secrets 이중 모드 (선행 조건 강제)"):
//   앱 레포 안(cwd의 git toplevel에 스캐폴드 마커 .app-config.yml): seal(앱 레포가 벤더한
//   tools/seal-secret.mts 위임) → 봉인본만 스테이징·커밋 → push → 원격 main 도달성 증명 →
//   update-secrets 디스패치. 선행 조건(remote=canonical ukyi-app/<app> · 브랜치 main · 클린 트리 ·
//   seal 후 봉인본 외 변경 없음 · push 후 도달성) 중 하나라도 실패면 **디스패치 없이** 거부한다.
//   디스패처는 앱 레포 main HEAD의 봉인본을 읽으므로, 도달하지 않은 커밋으로 디스패치하면 낡은
//   봉인본이 배선된다(plan r1 a2).
//   밖(마커 없음 — homelab 디렉토리 등): 디스패치만(이미 push된 봉인본 재배선).
//   마커는 있는데 remote가 canonical이 아니면 fail-closed 거부 — "앱 레포처럼 보이는 다른 레포"에서
//   엉뚱한 앱 이름으로 디스패치하는 사고를 막는다.
// 멱등: 같은 봉인본이면 커밋·push가 no-op으로 건너뛰어지고 디스패치만 재시도된다(push 성공·
//   디스패치 실패 경계가 재실행으로 수렴). 평문(.env)은 seal 도구의 kubeseal stdin 전용 — 이 엔진은
//   .env를 읽지도, 봉인본 내용을 출력하지도 않는다.
import { existsSync, statSync } from "node:fs";
import { onboardedPreflight } from "./app-preflight.ts";
import { compact } from "./contract.ts";
import { laneMutationFields } from "./catalog-rows.ts";
import { ALLOW_PUSH_REWRITE_ENV, firstReason, git, pushRoutes, sh } from "./exec.ts";
import { APP_NAME_RE, isCanonicalClone, pathInputError, pushRouteError } from "./identity.ts";
import { runMutation, waitInputError, waitOpts, type MutationOutcome, type WaitInput } from "./mutation.ts";
import { OWNER } from "./platform.ts";

// noSeal: 이미 커밋·push된 봉인본을 재봉인 없이 재디스패치한다 — push 성공·디스패치 실패 경계의
// 재실행 수렴 경로. kubeseal은 같은 평문도 매번 다른 암호문을 내므로(랜덤 세션 키) "재봉인 후
// 동일성 비교"로는 수렴에 도달할 수 없다 — 재봉인은 언제나 새 커밋·새 PR·파드 롤링이다.
// cwd: 앱 레포 경로를 명시 입력으로(CLI는 미설정 → process.cwd(), MCP는 stdio 서버라 cwd 추론
// 불가하므로 repoPath를 명시로 받는다 — plan r1 b7). runAppSecrets의 cwd 인자로 흐른다.
export type AppSecretsInput = WaitInput & { app: string; noSeal?: boolean; cwd?: string };

// 입력 검증 술어 — CLI(usage exit 2)·MCP(invalid params)가 공유.
export function appSecretsInputError(input: AppSecretsInput): string | null {
  if (!APP_NAME_RE.test(input.app ?? "")) return `앱 이름 형식 불량(소문자 kebab, 2..40): ${input.app}`;
  // 명시 cwd(MCP repoPath)만 절대성을 잰다 — undefined는 CLI 기본(process.cwd())이라 통과(identity.pathInputError 주석).
  if (input.cwd !== undefined) { const pe = pathInputError("repoPath", input.cwd); if (pe !== null) return pe; }
  return waitInputError(input);
}

const APP_MARKER = ".app-config.yml"; // 스캐폴더가 생성하는 앱 레포 마커(연구 노트 §2)
const SEAL_TOOL = "tools/seal-secret.mts"; // 앱 레포에 벤더된 봉인 도구(scaffold/common/tools/)


type Chain = Record<string, unknown>;
type ChainResult = { ok: true; chain: Chain } | { ok: false; error: string; chain: Chain };

// 앱 레포 안 연쇄 — 각 단계는 사후조건으로 증명하고, 실패 시 디스패치 없이 돌아간다.
function runChain(cwd: string, app: string, noSeal: boolean): ChainResult {
  const chain: Chain = { mode: "chain" };
  const refuse = (error: string): ChainResult => ({ ok: false, error, chain });

  const branch = git(cwd, ["rev-parse", "--abbrev-ref", "HEAD"]);
  if (!branch.ok || branch.out.trim() !== "main") return refuse(`브랜치가 main이 아니다(${branch.out.trim() || "?"}) — 디스패처는 main HEAD의 봉인본을 읽는다`);
  const dirty = git(cwd, ["status", "--porcelain"]);
  if (!dirty.ok) return refuse("git status 실패");
  if (dirty.out.trim() !== "") return refuse("작업 트리가 깨끗하지 않다 — 봉인본 갱신 외 변경이 섞이면 커밋 경계가 흐려진다");

  const sealedPath = `deploy/${app}-secrets.sealed.yaml`;
  chain.sealedPath = sealedPath;
  if (noSeal) {
    // 재봉인 없이 재디스패치 — 봉인본이 이미 커밋돼 있어야 한다(추적 파일 확인).
    const tracked = git(cwd, ["ls-files", "--error-unmatch", "--", sealedPath]);
    if (!tracked.ok) return refuse(`--no-seal인데 봉인본(${sealedPath})이 커밋돼 있지 않다`);
    chain.sealSkipped = true;
  } else {
    // seal 위임 — 벤더 도구 계약(tools/README.md seal-secret.mts 절): --config --env 필수, --app 명시.
    // .env는 도구 안에서만 kubeseal stdin으로 흐른다(이 엔진은 .env를 읽지 않는다).
    if (!existsSync(`${cwd}/${SEAL_TOOL}`)) return refuse(`${SEAL_TOOL} 부재 — 앱 레포에 벤더된 봉인 도구가 없다(템플릿 계약 드리프트)`);
    // seam 경유(d6④) — 종전 stdio(stdout ignore·stderr inherit)는 캡처 후 stderr만 흘리는 것으로
    // 등가다(.env 평문은 벤더 도구 안에서만 흐르고 이 엔진의 캡처·원장 어디에도 실리지 않는다).
    const sealed = sh(process.execPath, [SEAL_TOOL, "--config", APP_MARKER, "--env", ".env", "--app", app], { cwd, timeoutMs: 0 });
    if (sealed.err) process.stderr.write(sealed.err + "\n");
    if (!sealed.ok) return refuse(`seal 실패(exit ${sealed.status ?? "?"})`);
    if (!existsSync(`${cwd}/${sealedPath}`)) return refuse(`seal 후 봉인본(${sealedPath})이 없다`);
    chain.sealSkipped = false;
  }

  // ── 스테이징 완전성 판정 [staged-completeness] ──────────────────────────────────────────
  // seal이 봉인본 외의 것을 건드렸으면 거부 — 커밋은 봉인본 파일만 스테이징한다(스펙).
  // 이 자리가 그 판정의 **원형**이고 형제 넷이 여기서 파생됐다(.github/actions/pr-first-commit/
  // action.yml · scripts/teardown.sh · .github/workflows/bump.yaml · tools/run-bump-plan.ts).
  // ⚠️ 형제들은 포함 판정을 `:(exclude)` pathspec으로 git에게 시킨다 — 그쪽 천장은 다중 pathspec이라
  //    같은 매처를 두 번 구현하지 않는 것이 유일하게 안전하다. 여기는 천장이 **정확히 한 파일**이라
  //    문자열 동일성으로 족하고, 아래 `changed.length === 1`(멱등 no-op 판정)이 같은 열거를 재사용한다.
  // ⚠️ `l.slice(3)` 고정 오프셋은 **복사하지 마라**. 포세린은 rename을 `R  <orig> -> <new>`로,
  //    특수문자 경로를 C-따옴표로 낸다(실측) — 둘 다 이 오프셋으로는 경로가 안 뽑힌다. 다만 그때
  //    뽑힌 문자열은 sealedPath와 다르므로 foreign에 걸려 **거부**로 떨어진다(손해 방향이 fail-closed).
  const after = git(cwd, ["status", "--porcelain"]);
  if (!after.ok) return refuse("git status 실패(seal 후)");
  const changed = after.out.split("\n").map((l) => l.slice(3).trim()).filter((l) => l !== "");
  const foreign = changed.filter((f) => f !== sealedPath);
  if (foreign.length > 0) return refuse(`seal이 봉인본 외 파일을 변경했다: ${foreign.join(", ")}`);
  // ── [/staged-completeness] ────────────────────────────────────────────────────────────────

  if (changed.length === 1) {
    const add = git(cwd, ["add", "--", sealedPath]);
    if (!add.ok) return refuse("git add 실패");
    const commit = git(cwd, ["commit", "-q", "-m", "chore(secrets): 봉인본 갱신 (homelab app secrets)"]);
    if (!commit.ok) return refuse(`git commit 실패 — ${commit.err.split("\n")[0]}`);
    // timeoutMs: 0 — push는 망 왕복이라 seam 기본 30s가 끊을 수 있다(init의 같은 자리와 동일 어휘).
    const push = git(cwd, ["push", "-q", "origin", "HEAD:refs/heads/main"], { timeoutMs: 0 });
    // 사유 선택은 seam의 firstReason 소유 — git push stderr의 1행은 `To <url>`(사유 아님)이라
    // 첫 줄 자르기는 거부 이유(` ! [rejected] … (fetch first)`)를 통째로 지운다(exec-3 실측).
    // 시그널 사망(stderr 빈 문자열)의 폴백도 여기서 고른다 — 빈 사유는 오진을 만든다.
    if (!push.ok) return refuse(`git push 실패 — ${firstReason(push.err) || `git push 비-0(exit ${push.status ?? "?"}${push.signal ? `, ${push.signal}` : ""})`}`);
    chain.pushed = true;
  } else {
    chain.pushed = false; // 변경 없음(--no-seal 재디스패치) — 커밋·push 없이 디스패치만
  }

  // 도달성 증명 — 원격 main의 tip이 로컬 HEAD와 같아야 디스패처가 이 봉인본을 읽는다.
  const head = git(cwd, ["rev-parse", "HEAD"]);
  const remote = git(cwd, ["ls-remote", "--heads", "origin", "main"]);
  if (!head.ok || !remote.ok) return refuse("원격 main 도달성 확인 실패(ls-remote)");
  const remoteSha = remote.out.split(/\s+/)[0] ?? "";
  // 등식 판정은 plan r1 a2의 fail-closed 결정이라 유지한다. 다만 문구에 처방을 **조건 없이**
  // 덧붙인다: 누군가(예: Renovate PR 머지)가 원격 main을 앞서 밀면 수렴 경로인 재디스패치
  // (no-seal)도 같은 등식에서 다시 거부되는데, 로컬을 앞세우지 않으면 빠져나갈 길이 없다
  // (appverbs-11). 앞선 쪽을 판별하는 분기는 두지 않는다 — 같은 처방이 양쪽에 유효하다.
  if (remoteSha === "" || remoteSha !== head.out.trim()) return refuse(`원격 main(${remoteSha.slice(0, 7) || "없음"})이 로컬 HEAD(${head.out.trim().slice(0, 7)})와 다르다 — 도달성 미증명. \`git pull --ff-only\` 후 재실행하라(재봉인 없이 재디스패치만 하려면 no-seal 모드)`);
  chain.headSha = head.out.trim();
  return { ok: true, chain };
}

export function runAppSecrets(input: AppSecretsInput, cwd = process.cwd()): MutationOutcome {
  const app = input.app;
  let chain: Chain;

  // 명시 cwd(MCP repoPath)는 fail-closed다(homelab-cli-r2 티켓 02 — owner 결정 2026-09-07): 존재하지 않거나 앱 레포가
  // 아닌 명시 경로는 '레포 밖(dispatch-only)'이 아니라 **거부**다. 에이전트가 "새 .env를 봉인해 배선하라"고 부른
  // 호출이 옛 봉인본 재배선 success(chain.mode=dispatch-only)로 돌아오던 fail-open을 막는다. dispatch-only 폴백은
  // CLI 암묵 cwd(input.cwd 부재 — 사람이 homelab 디렉토리에서 재배선) 전용으로 남고, 결과 스키마 enum은 유지된다.
  // 거부 envelope의 chain.mode는 "그 경로가 받았을 모드"(dispatch-only)다 — 연쇄는 시작되지 않았다.
  const explicit = input.cwd !== undefined;
  const refuse = (error: string): MutationOutcome =>
    ({ variant: "failure", omitted: [], result: compact({ action: "update-secrets", name: app, chain: { mode: "dispatch-only" }, error }) });
  if (explicit) {
    let isDir = false;
    try { isDir = statSync(cwd).isDirectory(); } catch { isDir = false; } // 깨진 심볼릭 링크도 throw → 디렉토리 아님
    if (!isDir) return refuse(`명시 repoPath(${cwd})가 디렉토리가 아니다 — 디스패치 없이 거부(dispatch-only 폴백은 CLI 암묵 cwd 전용)`);
  }
  const top = git(cwd, ["rev-parse", "--show-toplevel"]);
  // git 바이너리 부재(exec seam errKind not-found)는 '앱 레포 밖'이 아니라 환경 결함이다 — 어느 모드에서도
  // dispatch-only로 접지 않는다(판정을 못 한 것과 판정 결과 '밖'은 다르다).
  if (top.errKind !== undefined) return refuse(`git 실행 불가(${top.errKind}: ${top.err.split("\n")[0] || "spawn 실패"}) — 앱 레포 판정을 할 수 없어 디스패치 없이 거부`);
  const toplevel = top.ok ? top.out.trim() : null;
  if (explicit && (toplevel === null || !existsSync(`${toplevel}/${APP_MARKER}`))) {
    return refuse(`명시 repoPath(${cwd})가 앱 레포가 아니다(git toplevel 또는 ${APP_MARKER} 마커 부재) — 디스패치 없이 거부(dispatch-only 폴백은 CLI 암묵 cwd 전용)`);
  }
  if (toplevel !== null && existsSync(`${toplevel}/${APP_MARKER}`)) {
    // 앱 레포 후보 — remote가 canonical이 아니면 fail-closed(엉뚱한 레포에서 이 앱 이름으로 디스패치 금지).
    // 구성 신원 판정은 identity.ts SSOT 술어 — 원본 설정값(insteadOf 미적용)을 본다.
    const url = git(toplevel, ["config", "--get", "remote.origin.url"]);
    if (!url.ok || !isCanonicalClone(OWNER, app, url.out)) {
      return { variant: "failure", omitted: [], result: compact({ action: "update-secrets", name: app, chain: { mode: "chain" }, error: `앱 레포 마커(${APP_MARKER})는 있으나 remote(${url.out.trim() || "없음"})가 canonical ${OWNER}/${app}와 다르다 — 거부` }) };
    }
    // push 라우팅 안전 — chain 모드는 진입 시점에 fail-closed로 본다. push뿐 아니라 도달성 증명
    // (runChain의 ls-remote가 origin을 읽는다)도 원격 정직성에 의존하므로, 재배선된 origin 위에서는
    // --no-seal 무-push 재디스패치의 "도달성"조차 위조가 된다 — 의도적으로 push 직전이 아니라
    // 진입 게이트다. 테스트 하네스(insteadOf→로컬 bare)는 명시 플래그로만 완화한다.
    if (process.env[ALLOW_PUSH_REWRITE_ENV] !== "1") {
      const routeErr = pushRouteError(OWNER, app, pushRoutes(toplevel));
      if (routeErr !== null) {
        return { variant: "failure", omitted: [], result: compact({ action: "update-secrets", name: app, chain: { mode: "chain" }, error: `${routeErr} — 디스패치 없이 거부` }) };
      }
    }
    const r = runChain(toplevel, app, input.noSeal === true);
    if (!r.ok) return { variant: "failure", omitted: [], result: compact({ action: "update-secrets", name: app, chain: r.chain, error: r.error }) };
    chain = r.chain;
  } else {
    // dispatch-only — 이미 push된 봉인본 재배선. 여기서 **미온보딩**을 사전 판정한다(티켓 30):
    // 디스패처(update-secrets.ts)는 run 안에서야 '미온보딩 앱 — create-app 먼저'로 죽는데, 그
    // 실패가 homelab-mutation 직렬화 큐와 Telegram 실패 알림을 소비한다(appverbs-5).
    // 판정 근거는 **로컬 homelab 워킹트리**다(원격 contents API가 아니라 — 낡은 스냅샷 200 함정).
    // 워킹트리 후보는 cwd의 git toplevel, 없으면 cwd 자신이다. 못 찾으면 통과(fail-open).
    const pf = onboardedPreflight(app, toplevel ?? cwd);
    if (!pf.ok) return refuse(pf.error);
    chain = { mode: "dispatch-only" };
  }

  const lane = laneMutationFields("update-secrets", app); // 레인 신원(workflow·branch·수렴 표면) — 행 파생
  return runMutation({
    ...lane,
    dispatchInputs: [["app", app]],
    resultBase: { action: lane.action, name: app, chain },
    noopOnMissingPr: true, // 동일 봉인본 = PR 없는 멱등 no-op run(pr-first-commit)
    // 교차 증인(티켓 04): chain이 push했으면 봉인본 바이트가 바뀐 것이고(kubeseal 비결정 암호문 — 위 noSeal
    // 주석), 디스패처는 반드시 PR을 낸다. 그때 PR 0건은 no-op이 아니라 fail-loud다. 엔진은 chain 스키마를
    // 모르므로 여기서 계산해 명시 필드로 넘긴다. --no-seal(pushed=false)·dispatch-only(pushed 부재)는 no-op 허용.
    noopForbidden: chain.pushed === true,
  }, waitOpts(input));
}
