import { appendFileSync, writeFileSync } from "node:fs";

// 후보 checkout에서 import하지 않는다. main workflow SHA의 코드만 각 독립 job에서 실행한다.
export const PLAN_REPOSITORY = "ukyi-app/homelab";
export const PLAN_REPOSITORY_ID = 1265054638;
const FULL_SHA = /^[0-9a-f]{40}$/;
type Env = Record<string, string | undefined>;
type ObjectValue = Record<string, unknown>;

function object(value: unknown, field: string): ObjectValue {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${field}: 객체 필요`);
  return value as ObjectValue;
}
function requireEqual(actual: unknown, expected: unknown, field: string): void {
  if (actual !== expected) throw new Error(`${field}: 검토 요청과 불일치`);
}

export function validateRequest(env: Env) {
  requireEqual(env.GITHUB_EVENT_NAME, "workflow_dispatch", "event");
  requireEqual(env.GITHUB_REPOSITORY, PLAN_REPOSITORY, "repository");
  requireEqual(env.GITHUB_REPOSITORY_ID, String(PLAN_REPOSITORY_ID), "repository_id");
  requireEqual(env.GITHUB_REF, "refs/heads/main", "ref");
  requireEqual(env.GITHUB_REF_TYPE, "branch", "ref_type");
  requireEqual(env.GITHUB_WORKFLOW_REF, `${PLAN_REPOSITORY}/.github/workflows/reviewed-plan.yaml@refs/heads/main`, "workflow_ref");
  if (!FULL_SHA.test(env.GITHUB_WORKFLOW_SHA ?? "")) throw new Error("workflow_sha: full SHA 필요");
  requireEqual(env.GITHUB_SHA, env.GITHUB_WORKFLOW_SHA, "trusted_sha");
  if (!env.HOMELAB_OWNER) throw new Error("HOMELAB_OWNER: 미설정");
  requireEqual(env.GITHUB_ACTOR?.toLowerCase(), env.HOMELAB_OWNER.toLowerCase(), "actor");
  requireEqual(env.GITHUB_TRIGGERING_ACTOR?.toLowerCase(), env.HOMELAB_OWNER.toLowerCase(), "triggering_actor");
  // owner 재실행도 새 검토 요청으로 바꾼다. 부분 job 재실행의 이전 승인 재사용을 허용하지 않는다.
  requireEqual(env.GITHUB_RUN_ATTEMPT, "1", "run_attempt: 새 workflow_dispatch 필요");
  if (!/^[1-9][0-9]*$/.test(env.REVIEWED_PR ?? "") || !Number.isSafeInteger(Number(env.REVIEWED_PR))) {
    throw new Error("reviewed_pr: 양의 정수 필요");
  }
  if (!FULL_SHA.test(env.REVIEWED_HEAD_SHA ?? "")) throw new Error("reviewed_head_sha: 소문자 full SHA 필요");
  if (!/^[1-9][0-9]*$/.test(env.GITHUB_RUN_ID ?? "")) throw new Error("run_id: 양의 정수 필요");
  return {
    repository: PLAN_REPOSITORY,
    repository_id: PLAN_REPOSITORY_ID,
    pr: Number(env.REVIEWED_PR),
    head_sha: env.REVIEWED_HEAD_SHA!,
    workflow_sha: env.GITHUB_WORKFLOW_SHA!,
    actor: env.GITHUB_ACTOR!,
    run_id: env.GITHUB_RUN_ID!,
    run_attempt: 1,
  };
}

export function validatePullRequest(env: Env, value: unknown) {
  const request = validateRequest(env);
  const pr = object(value, "pull_request");
  requireEqual(pr.number, request.pr, "pr.number");
  requireEqual(pr.state, "open", "pr.state");
  requireEqual(pr.merged, false, "pr.merged");
  for (const side of ["base", "head"]) {
    const branch = object(pr[side], `pr.${side}`);
    const repo = object(branch.repo, `pr.${side}.repo`);
    requireEqual(repo.id, request.repository_id, `pr.${side}.repo.id`);
    requireEqual(repo.full_name, request.repository, `pr.${side}.repo.full_name`);
    if (side === "base") requireEqual(branch.ref, "main", "pr.base.ref");
    else requireEqual(branch.sha, request.head_sha, "pr.head.sha: head 변경 시 새 검토 요청 필요");
  }
  return request;
}

// GET만 허용하고 API 위치는 고정한다. 실패 응답 본문·토큰·후보 본문은 로그에 싣지 않는다.
export async function checkReviewedHead(env: Env, fetcher: typeof fetch = fetch) {
  const request = validateRequest(env);
  if (!env.GH_TOKEN) throw new Error("GH_TOKEN: 조회 토큰 미설정");
  const response = await fetcher(`https://api.github.com/repos/${PLAN_REPOSITORY}/pulls/${request.pr}`, {
    method: "GET",
    redirect: "error",
    headers: { Authorization: `Bearer ${env.GH_TOKEN}`, Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "Cache-Control": "no-cache" },
    signal: AbortSignal.timeout(30_000),
  });
  if (!response.ok) throw new Error(`PR 조회 실패: HTTP ${response.status}`);
  return validatePullRequest(env, await response.json());
}

if (import.meta.main) {
  try {
    const phase = process.argv[2];
    if (!["authorize", "pre-plan", "result"].includes(phase)) throw new Error("phase: authorize|pre-plan|result 필요");
    const request = await checkReviewedHead(process.env);
    const receipt = { schema: "reviewed-plan/1", ...request, phase, checked_at: new Date().toISOString() };
    if (phase === "result") {
      const result = process.env.PLAN_RESULT;
      if (!["success", "failure", "cancelled", "skipped"].includes(result ?? "")) throw new Error("plan_result: 알 수 없는 결과");
      // 후보 코드가 실행되지 않은 별도 runner에서 결과를 귀속한다. PR check/status를 덮어쓰지 않는다.
      writeFileSync("reviewed-plan-receipt.json", JSON.stringify({ ...receipt, plan_result: result }, null, 2) + "\n", { flag: "wx" });
      if (!process.env.GITHUB_STEP_SUMMARY) throw new Error("GITHUB_STEP_SUMMARY: 미설정");
      appendFileSync(process.env.GITHUB_STEP_SUMMARY,
        `### 검토 SHA 인증 plan\nPR: https://github.com/${request.repository}/pull/${request.pr}\n\n검토 head: \`${request.head_sha}\`\n\n실행 코드(main): \`${request.workflow_sha}\`\n\n결과: **${result}** — [해당 실행](https://github.com/${request.repository}/actions/runs/${request.run_id})\n\n이 결과는 이 SHA에만 유효합니다. 현재 PR head의 승인이나 apply 승인이 아닙니다.\n`);
      if (result !== "success") process.exitCode = 1;
    } else if (process.env.GITHUB_OUTPUT) {
      appendFileSync(process.env.GITHUB_OUTPUT, `head_sha=${request.head_sha}\npr=${request.pr}\nworkflow_sha=${request.workflow_sha}\n`);
    }
    console.log(JSON.stringify(receipt));
  } catch (error) {
    // API 네트워크 예외도 자격이 포함된 request 객체를 출력하지 않는다.
    console.error(`reviewed-plan: ${error instanceof Error ? error.message : "검증 실패"}`);
    process.exitCode = 1;
  }
}
