import { readBounded, record, requireCondition, AiopsError } from "./input.ts";
import { JsonApi } from "./http.ts";
import type { Incidents, Incident } from "./incidents.ts";
import type { ProcessIdentity } from "./process.ts";
import { redact } from "./evidence.ts";
import { applyCandidate, digest, GitSnapshot } from "./git.ts";

export type Publication = {
  status: "not-requested" | "publishing" | "published" | "deferred"; owner?: ProcessIdentity;
  telegram?: { status: "sent" | "failed"; messageId?: number; reason?: string; contentHash?: string };
  pr?: { status: "creating" | "uncertain" | "deferred" | "draft" | "reviewed"; url?: string; number?: number; reason?: string };
  branch?: string; marker?: string; patchHash?: string;
  commit?: string;
  units?: string[];
  retryAt?: string;
};
export type PublicationTransport = (role: "fork" | "pr" | "telegram", path: string, options?: { method?: "GET" | "POST" | "PATCH"; body?: unknown; limit?: number }) => Promise<unknown>;
function summary(incident: Incident): string {
  const diagnosis = incident.report?.diagnosis;
  const lines = [
    `장애 조사 ${incident.id.slice(0, 12)} · ${incident.status}`,
    ...(incident.validation?.policyChanged ? ["정책·ADR 검토 필요: 변경은 미채택 상태입니다."] : []),
    diagnosis?.summary ?? "진단 자료 또는 실행이 불완전합니다.",
    ...(diagnosis?.causes.slice(0, 3).map(c => `${c.hypothesis} (근거: ${c.evidenceIds.join(", ")})`) ?? []),
    ...(diagnosis?.causes.flatMap(c => c.nextChecks).slice(0, 3) ?? incident.report?.missing ?? []),
  ];
  return redact(lines.join("\n")).text.slice(0, 3500);
}
async function draft(incidents: Incidents, incident: Incident, publication: Publication, config: Record<string, unknown>, repository: string, transport?: PublicationTransport) {
  const validation = incident.validation;
  requireCondition(validation && incident.report?.candidate && validation.candidate.manifestHash === incident.report.candidate.manifestHash, "validated-candidate-required");
  requireCondition(digest(validation.patch) === validation.patchHash, "validated-patch-hash-mismatch");
  requireCondition(!validation.changedPaths.some(path => path.endsWith(".enc.yaml")), "encrypted-edit-needs-sops-procedure");
  requireCondition(!/^\+[^+].*(?:-----BEGIN .*PRIVATE KEY|(?:postgres(?:ql)?|redis):\/\/[^\s]+:[^\s]+@)/m.test(validation.patch), "patch-contains-sensitive-content");
  for (const line of validation.patch.split("\n").filter(line => line.startsWith("+") && !line.startsWith("+++"))) {
    const value = /^\+\s*["']?(?:password|passwd|token|api[_-]?key|authorization|secret)["']?\s*[:=]\s*["']?([^\s"',}]+)/i.exec(line)?.[1];
    requireCondition(!value || /^(?:null|true|false|\$\{|\$[A-Z_]|<|REPLACE_|CHANGEME|example)/.test(value), "patch-contains-sensitive-content");
  }
  const settings = record(config.publication);
  requireCondition(typeof settings.upstream === "string" && typeof settings.fork === "string" && /^[\w.-]+\/[\w.-]+$/.test(settings.upstream) && /^[\w.-]+\/[\w.-]+$/.test(settings.fork), "invalid-publication-repositories");
  requireCondition(settings.base === "main" && Number.isSafeInteger(settings.upstreamId) && Number.isSafeInteger(settings.forkId) && settings.upstreamId !== settings.forkId, "invalid-publication-identity");
  const baseUrl = String(settings.apiUrl ?? "https://api.github.com/");
  requireCondition(config.mode === "replay" || transport, "isolated-publication-roles-required");
  const forkToken = transport ? "" : readBounded(String(settings.forkTokenFile), 1024).trim(), prToken = transport ? "" : readBounded(String(settings.prTokenFile), 1024).trim();
  requireCondition(transport || forkToken && prToken && forkToken !== prToken, "publication-credentials-must-be-separated");
  const forkApi = transport ? { request: (path: string, options?: Parameters<PublicationTransport>[2]) => transport("fork", path, options) } : new JsonApi(baseUrl, { Authorization: `Bearer ${forkToken}` }, "https://api.github.com", true, 60_000);
  const prApi = transport ? { request: (path: string, options?: Parameters<PublicationTransport>[2]) => transport("pr", path, options) } : new JsonApi(baseUrl, { Authorization: `Bearer ${prToken}` }, "https://api.github.com", true, 60_000);
  const upstream = `repos/${settings.upstream}`, fork = `repos/${settings.fork}`;
  requireCondition(record(await prApi.request(upstream)).id === settings.upstreamId, "upstream-id-mismatch");
  const forkIdentity = record(await forkApi.request(fork));
  requireCondition(forkIdentity.id === settings.forkId && forkIdentity.fork === true && record(forkIdentity.parent).id === settings.upstreamId, "fork-id-or-parent-mismatch");
  requireCondition(!publication.patchHash || publication.patchHash === validation.patchHash, "existing-incident-artifact-changed");
  publication.branch = `aiops/incident-${incident.id}`;
  publication.marker = `<!-- aiops-incident:${incident.id} artifact:${validation.patchHash} -->`;
  publication.patchHash = validation.patchHash;
  incidents.savePublication(incident.id, publication);
  const head = `${settings.fork.split("/")[0]}:${publication.branch}`;
  const pulls = await prApi.request(`${upstream}/pulls?state=all&head=${encodeURIComponent(head)}&base=main&per_page=100`);
  requireCondition(Array.isArray(pulls), "pr-reconciliation-invalid");
  const existing = pulls.map(record).filter(pr => typeof pr.body === "string" && pr.body.includes(publication.marker!) && record(pr.head).ref === publication.branch && record(record(pr.head).repo).id === settings.forkId && record(pr.base).ref === "main");
  requireCondition(existing.length <= 1, "multiple-incident-prs");
  if (existing.length) {
    const pr = existing[0];
    requireCondition(Number.isSafeInteger(pr.number), "pr-number-invalid");
    publication.pr = { status: pr.draft === true ? "draft" : "reviewed", number: Number(pr.number), url: `https://github.com/${settings.upstream}/pull/${pr.number}` };
    return;
  }
  if (["creating", "uncertain"].includes(publication.pr?.status ?? "")) { publication.pr = { status: "uncertain", reason: "creation-not-yet-reconciled" }; return; }
  requireCondition(incidents.get(incident.id).status === "firing", "incident-resolved-before-publication");
  const current = record(await prApi.request(`${upstream}/git/ref/heads/main`));
  requireCondition(record(current.object).sha === validation.baseline.revision, "publication-base-stale");
  const baseline = new GitSnapshot(repository, validation.baseline.revision), candidate = applyCandidate(baseline, validation.patch);
  try {
    requireCondition(candidate.snapshot.manifestHash === validation.candidate.manifestHash, "publication-candidate-changed");
    const ref = `${fork}/git/ref/heads/${publication.branch}`;
    let existingCommit: string | null = null;
    try { existingCommit = String(record(record(await forkApi.request(ref)).object).sha); }
    catch (error) { if (!(error instanceof AiopsError) || error.code !== "api-http-404") throw error; }
    if (existingCommit) {
      const commit = record(await forkApi.request(`${fork}/git/commits/${existingCommit}`));
      requireCondition(record(commit.tree).sha === validation.candidate.treeHash, "existing-fork-branch-changed");
      publication.commit = existingCommit;
    } else {
      const tree: { path: string; mode: string; type: string; sha: string | null }[] = [];
      for (const path of validation.changedPaths) {
        const entry = candidate.snapshot.entries.find(e => e.path === path);
        if (!entry) { tree.push({ path, mode: "100644", type: "blob", sha: null }); continue; }
        const bytes = candidate.snapshot.blob(path, 2 * 1024 * 1024)!;
        const blob = record(await forkApi.request(`${fork}/git/blobs`, { method: "POST", body: { encoding: "base64", content: bytes.toString("base64") } }));
        requireCondition(blob.sha === entry.blob, "published-blob-hash-mismatch");
        tree.push({ path, mode: entry.mode, type: "blob", sha: entry.blob });
      }
      const createdTree = record(await forkApi.request(`${fork}/git/trees`, { method: "POST", body: { base_tree: baseline.git(["rev-parse", `${baseline.revision}^{tree}`]).trim(), tree } }));
      requireCondition(createdTree.sha === validation.candidate.treeHash, "published-tree-hash-mismatch");
      const commit = record(await forkApi.request(`${fork}/git/commits`, { method: "POST", body: { message: `fix: 장애 ${incident.id.slice(0, 12)} 운영 수정 초안`, tree: createdTree.sha, parents: [baseline.revision] } }));
      requireCondition(typeof commit.sha === "string" && /^[a-f0-9]{40}$/.test(commit.sha) && record(commit.tree).sha === createdTree.sha, "published-commit-invalid");
      publication.commit = commit.sha;
      incidents.savePublication(incident.id, publication);
      await forkApi.request(`${fork}/git/refs`, { method: "POST", body: { ref: `refs/heads/${publication.branch}`, sha: commit.sha } });
    }
  } finally { candidate.dispose(); }
  requireCondition(incidents.get(incident.id).status === "firing", "incident-resolved-before-pr");
  requireCondition(record(record(await prApi.request(`${upstream}/git/ref/heads/main`)).object).sha === validation.baseline.revision, "publication-base-stale");
  publication.pr = { status: "creating" };
  incidents.savePublication(incident.id, publication);
  const review = validation.policyChanged ? `정책·ADR 검토 필요: 변경은 미채택 상태입니다.\n변경 경로: ${validation.changedPaths.join(", ").slice(0, 8000)}\n\n` : "";
  const nextChecks = incident.report?.diagnosis?.causes.flatMap(cause => cause.nextChecks).join("\n") ?? "";
  const body = `${publication.marker}\n\n${review}${summary(incident)}\n\n다음 확인·충돌 검토:\n${nextChecks.slice(0, 8000)}${nextChecks.length > 8000 ? "\n[추가 절차는 로컬 상세 보고서 참조]" : ""}\n\n기준: ${validation.baseline.revision}\n고정 원장 검사: ${validation.ledger.fixed.status}\n후보 예산 제안 평가: ${validation.ledger.proposed.status}\n형식 검사: ${validation.checks.map(check => `${check.name}=${check.status}`).join(", ").slice(0, 8000)}\n미검증: ${validation.unverified.join(", ")}\n\n자동 적용·자동 머지는 하지 않습니다.`;
  const pr = record(await prApi.request(`${upstream}/pulls`, { method: "POST", body: { title: `장애 ${incident.id.slice(0, 12)} 운영 수정 초안`, head, base: "main", draft: true, maintainer_can_modify: false, body } }));
  requireCondition(Number.isSafeInteger(pr.number) && pr.draft === true, "draft-pr-response-invalid");
  publication.pr = { status: "draft", number: Number(pr.number), url: `https://github.com/${settings.upstream}/pull/${pr.number}` };
}

export async function publishIncident(incidents: Incidents, id: string, input: unknown, repository?: string, transport?: PublicationTransport): Promise<Incident> {
  const config = record(input), incident = incidents.get(id);
  requireCondition(config.mode === "replay" || config.mode === "codex" && transport, "isolated-publication-roles-required");
  requireCondition(incident.report && incident.report.simulated === (config.mode === "replay"), "publication-mode-or-report-invalid");
  const publication = incidents.beginPublication(id);
  try {
    if (incident.report.patch) {
      try { requireCondition(repository, "publication-repository-required"); await draft(incidents, incident, publication, config, repository, transport); }
      catch (error) { publication.pr = { status: ["creating", "uncertain"].includes(publication.pr?.status ?? "") ? "uncertain" : "deferred", reason: error instanceof AiopsError ? error.code : "draft-publication-failed" }; }
    }
    const text = `${summary(incident)}${publication.pr?.url ? `\n${publication.pr.url}` : publication.pr ? `\nPR: ${publication.pr.status}` : ""}`;
    const contentHash = digest(text);
    if (publication.telegram?.status !== "sent" || publication.telegram.contentHash !== contentHash) {
      try {
        const telegram = record(config.telegram);
        requireCondition(typeof telegram.tokenFile === "string" && /^-?\d+$/.test(String(telegram.chatId)), "telegram-not-configured");
        const token = transport ? "" : readBounded(telegram.tokenFile, 1024).trim();
        requireCondition(transport || /^[a-zA-Z0-9_:-]+$/.test(token), "invalid-telegram-token");
        const api = new JsonApi(String(telegram.apiUrl ?? "https://api.telegram.org/"), {}, "https://api.telegram.org", config.mode === "replay", 60_000);
        const request = { method: "POST" as const, body: { chat_id: String(telegram.chatId), text, disable_web_page_preview: true } };
        const response = record(await (transport ? transport("telegram", "sendMessage", request) : api.request(`bot${token}/sendMessage`, request)));
        const result = record(response.result);
        requireCondition(response.ok === true && Number.isSafeInteger(result.message_id), "telegram-response-invalid");
        publication.telegram = { status: "sent", messageId: Number(result.message_id), contentHash };
      } catch (error) {
        publication.telegram = { status: "failed", reason: error instanceof AiopsError ? error.code : "telegram-send-failed" };
      }
    }
    publication.status = publication.telegram.status === "sent" && (!incident.report.patch || ["draft", "reviewed"].includes(publication.pr?.status ?? "")) ? "published" : "deferred";
    publication.retryAt = publication.status === "deferred" ? new Date(Date.now() + 600_000).toISOString() : undefined;
  } finally {
    delete publication.owner;
    incidents.savePublication(id, publication);
  }
  return incidents.get(id);
}
