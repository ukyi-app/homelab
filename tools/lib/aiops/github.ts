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
type ListedRun = { id: number; workflow_id: number; run_attempt: number; event: string; head_branch: string; status: string; head_sha: string };
type Scan = { version: 1; ranges: { start: string; end: string; page: number }[]; pending: ListedRun[]; missing: number; accepted: number };
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
    const scanSource = incidents.sources()["gha-scan"];
    const observationSince = settings.observationSince === undefined || settings.observationSince === null ? Date.parse(at) - 30 * 86400_000 : Date.parse(String(settings.observationSince));
    requireCondition(Number.isFinite(observationSince) && observationSince <= Date.parse(at), "invalid-github-observation-start");
    const scan: Scan = scanSource?.cursor ? JSON.parse(scanSource.cursor) : { version: 1, ranges: [], pending: [], missing: 0, accepted: 0 };
    requireCondition(scan.version === 1 && Array.isArray(scan.ranges) && Array.isArray(scan.pending), "invalid-github-scan-cursor");
    if (!scan.ranges.length && !scan.pending.length) {
      scan.ranges = [{ start: new Date(Date.parse(at) - 30 * 86400_000).toISOString(), end: at, page: 1 }];
      scan.missing = 0; scan.accepted = 0;
    }
    const saveScan = () => incidents.sourceHealth("gha-scan", { status: scan.pending.length || scan.ranges.length ? "unobservable" : "observed", lastAttempt: at, cursor: JSON.stringify(scan) });
    const runs = (response: Record<string, unknown>): ListedRun[] => {
      requireCondition(Array.isArray(response.workflow_runs) && response.workflow_runs.length <= 100, "invalid-github-runs");
      return response.workflow_runs.map(raw => {
        const run = record(raw);
        return Object.fromEntries(["id", "workflow_id", "run_attempt", "event", "head_branch", "status", "head_sha"].map(key => [key, run[key]])) as ListedRun;
      });
    };
    let missing = 0, accepted = 0;
    const inspect = async (raw: ListedRun) => {
      const listed = record(raw);
      if (!["push", "schedule", "workflow_dispatch", "workflow_run"].includes(String(listed.event)) || listed.head_branch !== "main" || listed.status !== "completed") return;
      requireCondition(Number.isSafeInteger(listed.id) && Number.isSafeInteger(listed.workflow_id), "invalid-github-run-id");
      const cached = incidents.sources()[`gha-run:${listed.id}`];
      if (cached?.cursor === String(listed.run_attempt)) { accepted++; return; }
      const run = record(await api.request(`${root}actions/runs/${listed.id}`));
      requireCondition(Number.isSafeInteger(run.run_attempt) && Number(run.run_attempt) > 0, "invalid-github-run-attempt");
      requireCondition(run.id === listed.id && run.head_sha === listed.head_sha && run.run_attempt === listed.run_attempt && record(run.head_repository).id === settings.repositoryId && run.status === "completed" && run.event === listed.event && run.head_branch === "main", "github-run-binding-mismatch");
      // 생성 시각으로만 자르면 오래된 run의 새 attempt가 빠진다. 전환 전 마지막 갱신만 제외한다.
      requireCondition(Number.isFinite(Date.parse(String(run.updated_at))), "invalid-github-run-time");
      if (Date.parse(String(run.updated_at)) < observationSince) return;
      const workflow = record(await api.request(`${root}actions/workflows/${listed.workflow_id}`));
      requireCondition(workflow.id === run.workflow_id && typeof workflow.path === "string", "github-workflow-binding-mismatch");
      const workflowFile = workflow.path.replace(/^\.github\/workflows\//, "");
      if (!Object.values(catalog).some(entry => entry.workflow === workflowFile)) return;
      const artifacts: unknown[] = [];
      for (let page = 1; ; page++) {
        requireCondition(page <= 10, "artifact-history-limit");
        const response = record(await api.request(`${root}actions/runs/${run.id}/artifacts?per_page=100&page=${page}`));
        requireCondition(Array.isArray(response.artifacts) && response.artifacts.length <= 100, "invalid-github-artifacts");
        artifacts.push(...response.artifacts);
        if (response.artifacts.length < 100 || Number.isSafeInteger(response.total_count) && artifacts.length >= Number(response.total_count)) break;
      }
      const before = missing;
      const found = new Set<string>();
      for (const rawArtifact of artifacts) {
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
      if (missing === before && found.size) incidents.sourceHealth(`gha-run:${run.id}`, { status: "observed", lastAttempt: at, lastSuccess: at, cursor: String(run.run_attempt) });
    };
    const inspectAndRecord = async (listed: ListedRun) => {
      const beforeMissing = missing, beforeAccepted = accepted;
      try { await inspect(listed); }
      catch (error) {
        missing++;
        incidents.sourceHealth(`gha-run:${listed.id}`, { status: "unobservable", lastAttempt: at, gap: true, reason: error instanceof AiopsError ? error.code : "github-run-observation-failed" });
      }
      scan.missing += missing - beforeMissing; scan.accepted += accepted - beforeAccepted; saveScan();
    };
    saveScan();
    // 최신 알림과 고정 기간의 과거 순회를 함께 처리한다. 같은 run의 새 attempt도 다시 검증한다.
    const latest = runs(record(await api.request(`${root}actions/runs?per_page=100&exclude_pull_requests=true`)));
    for (const listed of latest) await inspectAndRecord(listed);
    for (let pageBudget = 0; pageBudget < 4; pageBudget++) {
      while (scan.pending.length) {
        await inspectAndRecord(scan.pending[0]);
        scan.pending.shift(); saveScan();
      }
      if (!scan.ranges.length) break;
      const range = scan.ranges[0];
      const parameters = new URLSearchParams({ per_page: "100", exclude_pull_requests: "true", created: `${range.start}..${range.end}`, page: String(range.page) });
      const response = record(await api.request(`${root}actions/runs?${parameters}`));
      const entries = runs(response);
      if (Number(response.total_count) > 1000) {
        const start = Date.parse(range.start), end = Date.parse(range.end), middle = Math.floor((start + end) / 2000) * 1000;
        requireCondition(middle > start && middle < end, "github-history-density-limit");
        scan.ranges.splice(0, 1, { start: range.start, end: new Date(middle).toISOString(), page: 1 }, { start: new Date(middle + 1000).toISOString(), end: range.end, page: 1 });
      } else {
        scan.pending = entries;
        if (entries.length < 100 || Number.isSafeInteger(response.total_count) && range.page * 100 >= Number(response.total_count)) scan.ranges.shift();
        else range.page++;
      }
      saveScan();
    }
    saveScan();
    const pending = scan.ranges.length > 0 || scan.pending.length > 0;
    const reason = scan.missing ? "missing-verified-artifacts" : pending ? "history-scan-pending" : !scan.accepted ? "no-verified-observations" : undefined;
    incidents.sourceHealth("gha", { status: reason ? "unobservable" : "observed", lastAttempt: at, lastSuccess: reason ? previous?.lastSuccess : at,
      ...(reason ? { reason, gap: true } : {}), cursor: String(scan.accepted) });
  } catch (error) {
    incidents.sourceHealth("gha", { ...previous, status: "unobservable", lastAttempt: at, gap: true, reason: error instanceof AiopsError ? error.code : "github-query-failed" });
  } finally { rmSync(temporary, { recursive: true, force: true }); }
}
