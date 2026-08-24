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
import { existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { compact } from "./contract.ts";
import { ALLOW_PUSH_REWRITE_ENV, git, pushRoutes } from "./exec.ts";
import { APP_NAME_RE, isCanonicalClone, pushRouteError } from "./identity.ts";
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
    const sealed = spawnSync(process.execPath, [SEAL_TOOL, "--config", APP_MARKER, "--env", ".env", "--app", app], { cwd, stdio: ["ignore", "ignore", "inherit"] });
    if (sealed.status !== 0) return refuse(`seal 실패(exit ${sealed.status ?? "?"})`);
    if (!existsSync(`${cwd}/${sealedPath}`)) return refuse(`seal 후 봉인본(${sealedPath})이 없다`);
    chain.sealSkipped = false;
  }

  // seal이 봉인본 외의 것을 건드렸으면 거부 — 커밋은 봉인본 파일만 스테이징한다(스펙).
  const after = git(cwd, ["status", "--porcelain"]);
  if (!after.ok) return refuse("git status 실패(seal 후)");
  const changed = after.out.split("\n").map((l) => l.slice(3).trim()).filter((l) => l !== "");
  const foreign = changed.filter((f) => f !== sealedPath);
  if (foreign.length > 0) return refuse(`seal이 봉인본 외 파일을 변경했다: ${foreign.join(", ")}`);

  if (changed.length === 1) {
    const add = git(cwd, ["add", "--", sealedPath]);
    if (!add.ok) return refuse("git add 실패");
    const commit = git(cwd, ["commit", "-q", "-m", "chore(secrets): 봉인본 갱신 (homelab app secrets)"]);
    if (!commit.ok) return refuse(`git commit 실패 — ${commit.err.split("\n")[0]}`);
    const push = git(cwd, ["push", "-q", "origin", "HEAD:refs/heads/main"]);
    if (!push.ok) return refuse(`git push 실패 — ${push.err.split("\n")[0]}`);
    chain.pushed = true;
  } else {
    chain.pushed = false; // 변경 없음(--no-seal 재디스패치) — 커밋·push 없이 디스패치만
  }

  // 도달성 증명 — 원격 main의 tip이 로컬 HEAD와 같아야 디스패처가 이 봉인본을 읽는다.
  const head = git(cwd, ["rev-parse", "HEAD"]);
  const remote = git(cwd, ["ls-remote", "--heads", "origin", "main"]);
  if (!head.ok || !remote.ok) return refuse("원격 main 도달성 확인 실패(ls-remote)");
  const remoteSha = remote.out.split(/\s+/)[0] ?? "";
  if (remoteSha === "" || remoteSha !== head.out.trim()) return refuse(`원격 main(${remoteSha.slice(0, 7) || "없음"})이 로컬 HEAD(${head.out.trim().slice(0, 7)})와 다르다 — 도달성 미증명`);
  chain.headSha = head.out.trim();
  return { ok: true, chain };
}

export function runAppSecrets(input: AppSecretsInput, cwd = process.cwd()): MutationOutcome {
  const app = input.app;
  let chain: Chain;

  const top = git(cwd, ["rev-parse", "--show-toplevel"]);
  const toplevel = top.ok ? top.out.trim() : null;
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
    chain = { mode: "dispatch-only" };
  }

  return runMutation({
    action: "update-secrets",
    workflow: "update-secrets.yaml",
    dispatchInputs: [["app", app]],
    branchFor: (runId) => `update-secrets/${app}-${runId}`, // 명명 SSOT: _update-secrets.yaml
    applications: [ // 해당 앱 Application + 봉인본 표면(update-secrets 산출: apps/<app>/deploy/prod/)
      { name: `${app}-prod`, surfacePath: `apps/${app}/deploy/prod/${app}-secrets.sealed.yaml` },
    ],
    resultBase: { action: "update-secrets", name: app, chain },
    noopOnMissingPr: true, // 동일 봉인본 = PR 없는 멱등 no-op run(pr-first-commit)
  }, waitOpts(input));
}
