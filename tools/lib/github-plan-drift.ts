import { isDeepStrictEqual } from "node:util";

// repo.tf의 owner/writer 고정 신원만 대조한다. 이 도구는 plan 판정 전용이며 쓰기 API가 없다.
const OWNER = "MDQ6VXNlcjUyMzcxNTI5", WRITER = "A_kwHOEWo9us4APbFI";
const REPOSITORY = "R_kgDOS2czrg", ADDRESS = "github_branch_protection.main";
type ObjectValue = Record<string, unknown>;
class InvalidEvidence extends Error {}
function object(value: unknown): ObjectValue {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new InvalidEvidence("invalid-object");
  return value as ObjectValue;
}
function array(value: unknown): unknown[] {
  if (!Array.isArray(value)) throw new InvalidEvidence("invalid-array");
  return value;
}
function sameSet(value: unknown, expected: string[]) {
  return Array.isArray(value) && value.length === expected.length && new Set(value).size === expected.length &&
    value.every(item => typeof item === "string" && expected.includes(item));
}
function unknownValue(value: unknown): boolean {
  if (value === false) return false;
  if (Array.isArray(value)) return value.some(unknownValue);
  if (value && typeof value === "object") return Object.values(value).some(unknownValue);
  return true;
}
function exactRestActors(input: unknown): boolean {
  const restrictions = object(object(input).restrictions);
  const users = array(restrictions.users), apps = array(restrictions.apps), teams = array(restrictions.teams);
  return users.length === 1 && apps.length === 1 && teams.length === 0 &&
    object(users[0]).id === 52371529 && object(users[0]).node_id === OWNER &&
    object(apps[0]).id === 4043080 && object(apps[0]).node_id === WRITER;
}

export function classifyGithubPlan(input: unknown, protection: unknown) {
  const plan = object(input);
  if (plan.format_version !== "1.2" || plan.errored !== false) throw new InvalidEvidence("unsupported-plan");
  const resources = array(plan.resource_changes).map(object);
  const addresses = resources.map(resource => resource.address);
  if (!resources.length || addresses.some(address => typeof address !== "string") || new Set(addresses).size !== addresses.length) {
    throw new InvalidEvidence("incomplete-plan");
  }
  const main = resources.find(resource => resource.address === ADDRESS);
  if (!main || main.mode !== "managed" || main.type !== "github_branch_protection" ||
      main.provider_name !== "registry.terraform.io/integrations/github") throw new InvalidEvidence("main-protection-missing");
  const mainChange = object(main.change), after = object(mainChange.after);
  if (after.repository_id !== REPOSITORY || after.pattern !== "main") throw new InvalidEvidence("wrong-target");
  const restMatches = exactRestActors(protection);
  if (resources.some(resource => unknownValue(object(resource.change).after_unknown))) {
    return { drift: true, privateAppReadMismatch: false };
  }
  const changes = resources.filter(resource => !isDeepStrictEqual(object(resource.change).actions, ["no-op"]));
  // no-op에서도 REST를 확인한다. GraphQL에서 추가 private App까지 가려지는 경우를 놓치지 않는다.
  if (!changes.length) return { drift: !restMatches, privateAppReadMismatch: false };
  if (!restMatches || changes.length !== 1 || changes[0] !== main ||
      !isDeepStrictEqual(mainChange.actions, ["update"]) || unknownValue(mainChange.after_unknown)) {
    return { drift: true, privateAppReadMismatch: false };
  }
  const before = object(mainChange.before), previousPushes = array(before.restrict_pushes), nextPushes = array(after.restrict_pushes);
  if (previousPushes.length !== 1 || nextPushes.length !== 1 ||
      !sameSet(object(previousPushes[0]).push_allowances, [OWNER]) ||
      !sameSet(object(nextPushes[0]).push_allowances, [OWNER, WRITER])) return { drift: true, privateAppReadMismatch: false };
  // App 누락 이외의 전체 before/after를 깊게 대조한다. 다른 속성·자원·unknown은 면제하지 않는다.
  const visible = structuredClone(after);
  object(array(visible.restrict_pushes)[0]).push_allowances = [OWNER];
  const onlyVisibility = isDeepStrictEqual(before, visible);
  return { drift: !onlyVisibility, privateAppReadMismatch: onlyVisibility };
}

async function boundedText(stream: AsyncIterable<Uint8Array | string>, limit: number) {
  const chunks: Buffer[] = []; let bytes = 0;
  for await (const chunk of stream) {
    const data = Buffer.from(chunk); bytes += data.length;
    if (bytes > limit) throw new InvalidEvidence("response-too-large");
    chunks.push(data);
  }
  return Buffer.concat(chunks).toString("utf8");
}

export async function checkGithubPlan(plan: unknown, token: string | undefined, fetcher: typeof fetch = fetch) {
  if (!token) throw new InvalidEvidence("readonly-token-missing");
  const response = await fetcher("https://api.github.com/repos/ukyi-app/homelab/branches/main/protection", {
    method: "GET", redirect: "error", signal: AbortSignal.timeout(30_000),
    headers: { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "Cache-Control": "no-cache" },
  });
  if (response.status !== 200 || !response.body) throw new InvalidEvidence(`rest-read-failed-${response.status}`);
  return classifyGithubPlan(plan, JSON.parse(await boundedText(response.body, 256 * 1024)));
}

if (import.meta.main) {
  try {
    if (process.argv.length !== 2) throw new InvalidEvidence("arguments-forbidden");
    const plan = JSON.parse(await boundedText(process.stdin, 8 * 1024 * 1024));
    const result = await checkGithubPlan(plan, process.env.TF_VAR_github_token);
    console.log(JSON.stringify(result));
    process.exitCode = result.drift ? 2 : 0;
  } catch (error) {
    // plan에는 민감값이 포함될 수 있다. JSON 파싱·네트워크 예외와 응답 본문은 출력하지 않는다.
    console.error(JSON.stringify({ error: error instanceof InvalidEvidence ? error.message : "github-plan-classification-failed" }));
    process.exitCode = 1;
  }
}
