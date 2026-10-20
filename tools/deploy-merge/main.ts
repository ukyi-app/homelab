// deploy-merge의 check job 본체(.github/workflows/deploy-merge.yaml). workflow_run 이벤트로 main의 이 코드가 돈다.
// PR 상태를 이벤트의 actor가 아니라 API로 매번 다시 읽는다(재실행에서도 같은 결과, 설계 B.8 E5).
//
// 입력 env: GH_TOKEN(이 job의 GITHUB_TOKEN), GITHUB_EVENT_PATH, GITHUB_OUTPUT, HOMELAB_DEPLOY_BOT_ID.
// 출력: ok=true|false, pr, sha. ok일 때만 merge job이 병합 키를 받는다.
// 이유 댓글은 ukyi-homelab-deploy가 작성한 PR에만 단다. 다른 PR(모든 PR의 ci 완료마다 돈다)은 로그에만 남긴다.
import { appendFileSync, readFileSync } from "node:fs";
import { type Facts, appFromBranch, evaluate } from "./conditions";

const API = "https://api.github.com";
const HOMELAB = "ukyi-app/homelab";
const MARKER = "<!-- deploy-merge -->";
const SIGNER = "^https://github\\.com/ukyi-app/homelab/\\.github/workflows/app-build\\.yaml@refs/tags/app-build-v";

const token = process.env.GH_TOKEN ?? "";

async function gh(path: string, init: RequestInit & { accept?: string } = {}): Promise<{ status: number; body: any; text: string }> {
  const res = await fetch(`${API}/${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: init.accept ?? "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      ...(init.headers ?? {}),
    },
  });
  const text = await res.text();
  let body: any;
  try {
    body = JSON.parse(text);
  } catch {
    body = undefined;
  }
  return { status: res.status, body, text };
}

async function raw(repo: string, path: string, ref: string): Promise<string | null> {
  const r = await gh(`repos/${repo}/contents/${path}?ref=${encodeURIComponent(ref)}`, { accept: "application/vnd.github.raw" });
  return r.status === 200 ? r.text : null;
}

async function compareStatus(repo: string, base: string, head: string): Promise<string | undefined> {
  const r = await gh(`repos/${repo}/compare/${base}...${head}`);
  return r.status === 200 ? r.body?.status : undefined;
}

// 익명 pull 토큰으로 GHCR의 이미지 설정 라벨을 읽는다. 받은 매니페스트의 sha256이 digest와 같은지도 본다.
export async function imageLabels(app: string, digest: string): Promise<Record<string, string> | null> {
  const tok = await fetch(`https://ghcr.io/token?scope=repository:ukyi-app/${app}:pull`).then((r) => (r.ok ? r.json() : null));
  if (!tok?.token) return null;
  const headers = { Authorization: `Bearer ${tok.token}` };
  const accept = [
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
  ].join(", ");
  const getManifest = async (ref: string) => {
    const res = await fetch(`https://ghcr.io/v2/ukyi-app/${app}/manifests/${ref}`, { headers: { ...headers, Accept: accept } });
    if (!res.ok) return null;
    const bytes = new Uint8Array(await res.arrayBuffer());
    const sum = `sha256:${new Bun.CryptoHasher("sha256").update(bytes).digest("hex")}`;
    if (sum !== ref) return null;
    return JSON.parse(new TextDecoder().decode(bytes));
  };
  let m = await getManifest(digest);
  if (m?.manifests) {
    const amd64 = m.manifests.find((x: any) => x.platform?.os === "linux" && x.platform?.architecture === "amd64");
    m = amd64 ? await getManifest(amd64.digest) : null;
  }
  const cfg = m?.config?.digest;
  if (!cfg) return null;
  const res = await fetch(`https://ghcr.io/v2/ukyi-app/${app}/blobs/${cfg}`, { headers });
  if (!res.ok) return null;
  const config = await res.json();
  return config?.config?.Labels ?? {};
}

export function verifyAttestation(app: string, digest: string, revision: string): boolean {
  const p = Bun.spawnSync(
    [
      "gh",
      "attestation",
      "verify",
      `oci://ghcr.io/ukyi-app/${app}@${digest}`,
      "--repo",
      `ukyi-app/${app}`,
      "--cert-identity-regex",
      SIGNER,
      "--source-ref",
      "refs/heads/main",
      "--source-digest",
      revision,
      "--deny-self-hosted-runners",
    ],
    { stdout: "pipe", stderr: "pipe", env: process.env },
  );
  console.log(`gh attestation verify: exit ${p.exitCode}`);
  if (p.exitCode !== 0) console.log(p.stderr.toString().trim());
  return p.exitCode === 0;
}

export async function gather(event: any): Promise<Facts> {
  const run = event.workflow_run ?? {};
  const facts: Facts = {
    deployBotId: Number(process.env.HOMELAB_DEPLOY_BOT_ID ?? "0"),
    codeOwner: process.env.HOMELAB_CODEOWNER,
    run: {
      event: run.event,
      conclusion: run.conclusion,
      headSha: run.head_sha,
      path: run.path,
      headRepo: run.head_repository?.full_name,
      headBranch: run.head_branch,
    },
  };
  // PR은 이벤트의 목록을 믿지 않고 head 브랜치로 다시 찾는다.
  const list = await gh(`repos/${HOMELAB}/pulls?state=open&head=${encodeURIComponent(`ukyi-app:${run.head_branch}`)}`);
  const number = Array.isArray(list.body) && list.body.length === 1 ? list.body[0].number : undefined;
  if (!number) return facts;
  const p = (await gh(`repos/${HOMELAB}/pulls/${number}`)).body;
  facts.pr = {
    number,
    userId: p.user?.id,
    headRepo: p.head?.repo?.full_name,
    headRef: p.head?.ref,
    headSha: p.head?.sha,
    baseRef: p.base?.ref,
    draft: p.draft === true,
    labels: (p.labels ?? []).map((l: any) => l.name),
  };
  const app = appFromBranch(facts.pr.headRef);
  if (!app || facts.pr.headRepo !== HOMELAB) return facts;

  facts.appDirOnMain = (await gh(`repos/${HOMELAB}/contents/apps/${app}?ref=main`)).status === 200;
  const files = await gh(`repos/${HOMELAB}/pulls/${number}/files?per_page=100`);
  facts.files = Array.isArray(files.body) ? files.body.map((x: any) => ({ filename: x.filename, status: x.status })) : [];
  facts.mainImage = await raw(HOMELAB, `apps/${app}/image.yaml`, "main");
  facts.headImage = await raw(HOMELAB, `apps/${app}/image.yaml`, facts.pr.headSha);

  const head = facts.headImage ? (Bun.YAML.parse(facts.headImage) as any) : undefined;
  const base = facts.mainImage ? (Bun.YAML.parse(facts.mainImage) as any) : undefined;
  const digest = typeof head?.digest === "string" && /^sha256:[0-9a-f]{64}$/.test(head.digest) ? head.digest : undefined;
  const revision = typeof head?.revision === "string" && /^[0-9a-f]{40}$/.test(head.revision) ? head.revision : undefined;
  const deployed = typeof base?.revision === "string" && /^[0-9a-f]{40}$/.test(base.revision) ? base.revision : undefined;
  const appRepo = `ukyi-app/${app}`;

  if (digest) facts.imageLabels = await imageLabels(app, digest);
  if (digest && revision) facts.attestationVerified = verifyAttestation(app, digest, revision);
  const repo = await gh(`repos/${appRepo}`);
  if (revision && deployed) facts.compareDeployedToNew = await compareStatus(appRepo, deployed, revision);
  if (revision && repo.body?.default_branch) facts.compareNewToDefault = await compareStatus(appRepo, revision, repo.body.default_branch);

  const checks = await gh(`repos/${HOMELAB}/commits/${facts.pr.headSha}/check-runs?check_name=ci&per_page=100`);
  facts.ciChecks = (checks.body?.check_runs ?? []).map((c: any) => ({ name: c.name, conclusion: c.conclusion, app: c.app?.slug }));

  const rules = await gh(`repos/${appRepo}/rules/branches/main`);
  const owners = await gh(`repos/${appRepo}/codeowners/errors?ref=main`);
  let codeownersText: string | null = null;
  for (const path of [".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS"]) {
    codeownersText = await raw(appRepo, path, "main");
    if (codeownersText !== null) break;
  }
  facts.appRepo = {
    visibility: repo.status === 200 ? repo.body?.visibility : undefined,
    rules: Array.isArray(rules.body) ? rules.body : [],
    codeownersStatus: owners.status,
    codeownersErrors: owners.body?.errors,
    codeownersText,
  };
  return facts;
}

async function comment(pr: number, text: string): Promise<void> {
  const body = `${MARKER}\n${text}`;
  const list = await gh(`repos/${HOMELAB}/issues/${pr}/comments?per_page=100`);
  const mine = (Array.isArray(list.body) ? list.body : []).find((c: any) => c.user?.login === "github-actions[bot]" && String(c.body).startsWith(MARKER));
  const r = mine
    ? await gh(`repos/${HOMELAB}/issues/comments/${mine.id}`, { method: "PATCH", body: JSON.stringify({ body }) })
    : await gh(`repos/${HOMELAB}/issues/${pr}/comments`, { method: "POST", body: JSON.stringify({ body }) });
  if (r.status >= 300) console.log(`댓글 실패: HTTP ${r.status}`);
}

async function main(): Promise<number> {
  const event = JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH ?? "", "utf8"));
  const facts = await gather(event);
  const verdict = evaluate(facts);
  const pr = facts.pr;
  const ok = verdict.failures.length === 0 && pr !== undefined;
  const out = process.env.GITHUB_OUTPUT;
  if (out) appendFileSync(out, `ok=${ok}\npr=${pr?.number ?? ""}\nsha=${pr?.headSha ?? ""}\n`);

  const lines = verdict.failures.map((x) => `- 조건 ${x.cond} 불일치: ${x.message}`);
  console.log(ok ? `병합 대상: PR #${pr?.number} ${pr?.headSha}` : `병합하지 않음(PR #${pr?.number ?? "없음"})\n${lines.join("\n")}`);
  if (!ok && pr && facts.deployBotId > 0 && pr.userId === facts.deployBotId) {
    await comment(pr.number, `자동 병합 조건 불일치로 병합하지 않았다(검사한 head ${pr.headSha}). 사람이 보고 판단한다.\n\n${lines.join("\n")}`);
  }
  return 0;
}

if (import.meta.main) process.exit(await main());
