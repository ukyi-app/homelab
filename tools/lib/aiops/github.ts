import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { isolatedSpawnSync as spawnSync } from "../exec.ts";
import producerCatalog from "../../../.github/actions/aiops-observation/producers.json";
import { AiopsError, observationInput, readBounded, record, requireCondition } from "./input.ts";
import { JsonApi } from "./http.ts";
import type { Incidents } from "./incidents.ts";
import { digest } from "./git.ts";

const catalog: Record<string, { workflow: string }> = producerCatalog;
export async function pollGithub(incidents: Incidents, input: unknown) {
  const config = record(input), settings = config.github ? record(config.github) : {};
  const previous = incidents.sources().gha, at = new Date().toISOString();
  if (!settings.readTokenFile) { incidents.sourceHealth("gha", { ...previous, status: "unconfigured", lastAttempt: at, reason: "github-read-token-missing" }); return; }
  const temporary = mkdtempSync(join(tmpdir(), "aiops-gha-"));
  try {
    requireCondition(typeof settings.repository === "string" && /^[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+$/.test(settings.repository) && Number.isSafeInteger(settings.repositoryId), "invalid-github-repository");
    const token = readBounded(String(settings.readTokenFile), 1024).trim();
    const api = new JsonApi(String(settings.apiUrl ?? "https://api.github.com/"), { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28" }, "https://api.github.com", config.mode === "replay");
    const root = `repos/${settings.repository}/`;
    const repository = record(await api.request(root.slice(0, -1)));
    requireCondition(repository.id === settings.repositoryId, "github-repository-id-mismatch");
    const response = record(await api.request(`${root}actions/runs?per_page=30&exclude_pull_requests=true`));
    requireCondition(Array.isArray(response.workflow_runs) && response.workflow_runs.length <= 30, "invalid-github-runs");
    let missing = 0, accepted = 0;
    for (const raw of response.workflow_runs) {
      const listed = record(raw);
      if (!["push", "schedule", "workflow_dispatch", "workflow_run"].includes(String(listed.event)) || listed.head_branch !== "main" || listed.status !== "completed") continue;
      requireCondition(Number.isSafeInteger(listed.id) && Number.isSafeInteger(listed.workflow_id), "invalid-github-run-id");
      const run = record(await api.request(`${root}actions/runs/${listed.id}`));
      requireCondition(Number.isSafeInteger(run.run_attempt) && Number(run.run_attempt) > 0, "invalid-github-run-attempt");
      requireCondition(run.id === listed.id && run.head_sha === listed.head_sha && run.run_attempt === listed.run_attempt && record(run.head_repository).id === settings.repositoryId && run.status === "completed" && run.event === listed.event && run.head_branch === "main", "github-run-binding-mismatch");
      const workflow = record(await api.request(`${root}actions/workflows/${listed.workflow_id}`));
      requireCondition(workflow.id === run.workflow_id && typeof workflow.path === "string", "github-workflow-binding-mismatch");
      const workflowFile = workflow.path.replace(/^\.github\/workflows\//, "");
      if (!Object.values(catalog).some(entry => entry.workflow === workflowFile)) continue;
      const artifacts = record(await api.request(`${root}actions/runs/${run.id}/artifacts?per_page=100`));
      requireCondition(Array.isArray(artifacts.artifacts) && artifacts.artifacts.length <= 100, "invalid-github-artifacts");
      const found = new Set<string>();
      for (const rawArtifact of artifacts.artifacts) {
        const artifact = record(rawArtifact);
        if (artifact.expired || typeof artifact.name !== "string" || !artifact.name.startsWith("aiops-") || !artifact.name.includes(`-${run.run_attempt}-`)) continue;
        requireCondition(Number.isSafeInteger(artifact.id), "invalid-artifact-id");
        const binding = record(artifact.workflow_run);
        requireCondition(binding.id === run.id && binding.head_sha === run.head_sha && binding.repository_id === settings.repositoryId && binding.head_repository_id === settings.repositoryId, "artifact-run-binding-mismatch");
        writeFileSync(join(temporary, "artifact.zip"), await api.archive(`${root}actions/artifacts/${artifact.id}/zip`), { mode: 0o600 });
        const unpacked = spawnSync("python3", ["-c", "import sys,zipfile\nwith zipfile.ZipFile(sys.argv[1]) as z:\n entries=z.infolist()\n assert len(entries)==1 and entries[0].filename=='observation.json' and entries[0].file_size<=262144\n with z.open(entries[0]) as f:\n  data=f.read(262145)\n  assert len(data)<=262144\n  sys.stdout.buffer.write(data)\n", join(temporary, "artifact.zip")], { encoding: "utf8", timeout: 10_000, maxBuffer: 256 * 1024,
          env: { PATH: process.env.PATH, LANG: "C" } });
        requireCondition(unpacked.status === 0 && !unpacked.error, "artifact-unpack-failed");
        const observation = record(JSON.parse(unpacked.stdout));
        requireCondition(observation.version === 1 && typeof observation.producer === "string" && catalog[observation.producer]?.workflow === workflowFile, "artifact-producer-mismatch");
        requireCondition(observation.repository === settings.repository && observation.runId === run.id && observation.attempt === run.run_attempt && observation.runHeadSha === run.head_sha, "artifact-execution-mismatch");
        requireCondition(typeof observation.revision === "string" && /^[a-f0-9]{40}$/.test(observation.revision), "artifact-revision-invalid");
        // main을 다시 checkout한 실행은 run HEAD와 다를 수 있다. API로 main 도달성을 별도 확인한다.
        if (observation.revision !== run.head_sha) {
          const comparison = record(await api.request(`${root}compare/${observation.revision}...main`));
          requireCondition(["ahead", "identical"].includes(String(comparison.status)) && record(comparison.base_commit).sha === observation.revision, "artifact-revision-not-trusted-main");
        }
        const timestamp = Date.parse(String(observation.observedAt));
        requireCondition(Number.isFinite(timestamp) && timestamp >= Date.parse(String(run.created_at)) - 60_000 && timestamp <= Date.parse(String(run.updated_at)) + 60_000, "artifact-observation-time-invalid");
        requireCondition(["healthy", "warning", "unobservable"].includes(String(observation.status)) && typeof observation.completed === "boolean", "artifact-state-invalid");
        const children = observation.observations === undefined ? [observation] : observation.observations;
        requireCondition(Array.isArray(children) && children.length > 0 && children.length <= 1000 && (observation.observations === undefined || observation.producer === "dns-drift.yaml/check"), "invalid-target-observations");
        for (const child of children.map(record)) {
          requireCondition(["healthy", "warning", "unobservable"].includes(String(child.status)) && typeof child.completed === "boolean", "invalid-target-observation-state");
          const status = child.status === "warning" ? "firing" : child.status === "healthy" && child.completed === true ? "resolved" : "unobservable";
          const event = observationInput({ source: "gha", eventId: digest(JSON.stringify([observation.producer, child.target, run.id, run.run_attempt])), target: child.target,
            observedAt: new Date(timestamp).toISOString(), revision: observation.revision, reason: observation.producer.replace("/", ":"), severity: "warning", status });
          incidents.receiveOrdered(event, Number(run.id), Number(run.run_attempt));
          if (status === "unobservable") missing++;
        }
        found.add(observation.producer); accepted++;
      }
      // 다른 job 하나의 정상 artifact가 미실행·누락된 생산자를 대신 증명하지 못한다.
      const expected = Object.entries(catalog).filter(([, entry]) => entry.workflow === workflowFile).map(([producer]) => producer);
      missing += expected.filter(producer => !found.has(producer)).length;
    }
    incidents.sourceHealth("gha", { status: missing ? "unobservable" : "observed", lastAttempt: at, lastSuccess: missing ? previous?.lastSuccess : at,
      ...(missing ? { reason: "missing-verified-artifacts", gap: true } : {}), cursor: String(accepted) });
  } catch (error) {
    incidents.sourceHealth("gha", { ...previous, status: "unobservable", lastAttempt: at, gap: true, reason: error instanceof AiopsError ? error.code : "github-query-failed" });
  } finally { rmSync(temporary, { recursive: true, force: true }); }
}
