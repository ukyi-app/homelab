// systemd 역할 작업의 고정 진입점. 입력 파일은 명령·환경을 선택할 수 없다.
import { readFileSync } from "node:fs";
import { Incidents } from "./lib/aiops/incidents.ts";
import type { Incident } from "./lib/aiops/incidents.ts";
import { AiopsError, readBounded, record, requireCondition } from "./lib/aiops/input.ts";
import { GitSnapshot, applyCandidate } from "./lib/aiops/git.ts";
import { collectLive } from "./lib/aiops/collection.ts";
import { collectEvidence } from "./lib/aiops/evidence.ts";
import { diagnose } from "./lib/aiops/diagnosis.ts";
import { validateCandidate } from "./lib/aiops/validation.ts";
import { JsonApi } from "./lib/aiops/http.ts";
import { pollGithub } from "./lib/aiops/github.ts";
import { pollHealthchecks } from "./lib/aiops/healthchecks.ts";

try {
  const job = record(JSON.parse(readBounded(process.argv[2], 8 * 1024 * 1024))), role = String(job.role);
  requireCondition(["collector", "engine", "validator", "fork", "pr", "telegram"].includes(role) && new RegExp(`/aiops-${role}-[a-f0-9]{32}\\.service`).test(readFileSync("/proc/self/cgroup", "utf8")), "stage-role-unit-required");
  if (job.kind === "api") {
    requireCondition(["fork", "pr", "telegram"].includes(role), "invalid-api-role");
    const settings = record(JSON.parse(readBounded(`/etc/homelab-aiops/${role}.json`)));
    const request = record(job.request), path = String(request.path), method = String(request.method ?? "GET");
    requireCondition(method === "GET" || method === "POST", "api-operation-forbidden");
    const token = readBounded(String(settings.tokenFile), 8192).trim();
    requireCondition(token.length > 0 && !/[\r\n]/.test(token), "invalid-role-token");
    let result: unknown;
    if (role === "telegram") {
      requireCondition(path === "sendMessage" && method === "POST" && /^-?\d+$/.test(String(settings.chatId)) && /^[a-zA-Z0-9_:-]+$/.test(token), "telegram-operation-forbidden");
      const body = record(request.body);
      requireCondition(typeof body.text === "string" && body.text.length <= 4096, "invalid-telegram-summary");
      result = await new JsonApi("https://api.telegram.org/", {}, "https://api.telegram.org", false, 60_000).request(`bot${token}/sendMessage`, { method: "POST", body: { chat_id: String(settings.chatId), text: body.text, disable_web_page_preview: true } });
    } else {
      const repository = String(settings.repository);
      requireCondition(/^[\w.-]+\/[\w.-]+$/.test(repository), "invalid-role-repository");
      const prefix = `repos/${repository}`;
      const suffix = path.startsWith(prefix) ? path.slice(prefix.length) : "forbidden";
      const allowed = role === "fork"
        ? method === "GET" && (suffix === "" || /^\/git\/(?:ref\/heads\/aiops\/incident-[a-f0-9]{64}|commits\/[a-f0-9]{40})$/.test(suffix)) || method === "POST" && ["/git/blobs", "/git/trees", "/git/commits", "/git/refs"].includes(suffix)
        : method === "GET" && (suffix === "" || suffix === "/git/ref/heads/main" || /^\/pulls\?state=all&head=[\w.%:-]+&base=main&per_page=100$/.test(suffix)) || method === "POST" && suffix === "/pulls";
      requireCondition(allowed, "api-operation-forbidden");
      if (method === "POST" && role === "pr") {
        const body = record(request.body);
        requireCondition(body.draft === true && body.base === "main" && body.maintainer_can_modify === false && typeof body.head === "string" && body.head.startsWith(`${settings.forkOwner}:aiops/incident-`), "draft-only-publication");
      }
      if (method === "POST" && suffix === "/git/refs") requireCondition(/^refs\/heads\/aiops\/incident-[a-f0-9]{64}$/.test(String(record(request.body).ref)), "fork-ref-forbidden");
      result = await new JsonApi("https://api.github.com/", { Authorization: `Bearer ${token}` }, "https://api.github.com", false, 60_000).request(path, { method: method as "GET" | "POST", body: request.body, limit: 1024 * 1024 });
    }
    console.log(JSON.stringify({ result }));
  } else if (job.kind === "poll") {
    requireCondition(role === "collector", "collector-role-required");
    process.umask(0o007);
    using incidents = new Incidents(String(job.state));
    const config = JSON.parse(readBounded("/etc/homelab-aiops/collector.json"));
    await pollGithub(incidents, config); await pollHealthchecks(incidents, config);
    console.log(JSON.stringify({ sources: incidents.sources() }));
  } else {
    const snapshot = new GitSnapshot(String(job.repository), String(job.revision));
    const incident = job.incident as Incident;
    if (job.kind === "collect") {
      requireCondition(role === "collector", "collector-role-required");
      console.log(JSON.stringify({ evidence: job.fixture ? collectEvidence(incident, snapshot, job.fixture) : await collectLive(incident, snapshot, JSON.parse(readBounded("/etc/homelab-aiops/collector.json"))) }));
    } else if (job.kind === "diagnose") {
      requireCondition(role === "engine" && incident.evidence, "engine-evidence-required");
      const options = record(job.options);
      console.log(JSON.stringify(await diagnose(incident.evidence, snapshot, { mode: "codex", engine: String(options.engine), model: String(options.model), authentication: String(options.authentication), engineHash: String(options.engineHash), rawOutput: String(job.rawOutput), onStart: () => {} })));
    } else if (job.kind === "validate") {
      requireCondition(role === "validator" && incident.report?.patch, "validator-patch-required");
      const candidate = applyCandidate(snapshot, incident.report.patch);
      try { console.log(JSON.stringify({ validation: await validateCandidate(snapshot, candidate.snapshot) })); }
      finally { candidate.dispose(); }
    } else throw new AiopsError("invalid-stage-kind");
  }
} catch (error) {
  console.log(JSON.stringify({ error: error instanceof AiopsError ? error.code : "stage-failed" }));
  process.exitCode = 1;
}
