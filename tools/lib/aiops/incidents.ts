import { Database } from "bun:sqlite";
import { chmodSync, mkdirSync, readdirSync, lstatSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { AiopsError, requireCondition, observationInput, record } from "./input.ts";
import { processIdentity, recoverGroup, runProcess, sameProcess, STAGE_LIMITS } from "./process.ts";
import type { ProcessIdentity } from "./process.ts";
import type { Evidence } from "./evidence.ts";
import type { Validation } from "./validation.ts";
import type { Report } from "./diagnosis.ts";
import type { SourceHealth } from "./sources.ts";
import type { Publication } from "./publication.ts";
import { cleanUnit, readiness } from "./host.ts";

export type Observation = {
  source: string; eventId: string; target: string; observedAt: string;
  revision: string | null; severity: "critical" | "warning" | "info";
  reason: string; status: "firing" | "resolved" | "unobservable";
};
const executionStates = ["queued", "running", "deferred", "cancelled", "observed-only", "self-observation", "cleanup-unknown", "interrupted", "needs-evidence", "diagnosed", "external-app", "no-change", "invalid-result", "waiting-authentication", "waiting-capacity", "start-failed", "failed", "timeout", "output-limit", "oom", "initialization-failed", "completed"] as const;
type ExecutionState = typeof executionStates[number];
export type Incident = {
  id: string; observation: Observation; status: Observation["status"];
  observationCount: number; firstObservedAt: string;
  execution: { status: ExecutionState; id?: string; reason?: string }; publication: Publication;
  report: Report | null;
  evidence?: Evidence;
  validation?: Validation;
  updatedAt?: string;
  resolvedBy?: { observedAt: string; revision: string | null; eventId: string };
};
export type Execution = { id: string; incident: string; day: string; startedAt: string; status: string; mode: "replay" | "codex"; owner: ProcessIdentity; process?: ProcessIdentity; units?: string[] };
export type IncidentSummary = Omit<Incident, "report" | "evidence" | "validation"> & { reportAvailable: boolean };

// 사건·실행·게시 상태는 별개다. 모의 보고서는 장애 해소를 선언하지 않는다.
export class Incidents implements Disposable {
  private db: Database;
  private directory: string;
  constructor(directory: string) {
    this.directory = directory;
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    const database = join(directory, "incidents.sqlite");
    const sharedMode = (path: string) => {
      try {
        const info = lstatSync(path);
        requireCondition(info.isFile() && !info.isSymbolicLink(), "invalid-state-file");
        if ((info.mode & 0o777) !== 0o660) chmodSync(path, 0o660);
      } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
    };
    // SQLite의 기본 생성 모드는 0644다. umask만으로 그룹 쓰기를 추가할 수 없어 WAL 생성 전에 고정한다.
    for (const suffix of ["", "-wal", "-shm"]) sharedMode(database + suffix);
    this.db = new Database(database, { create: true, strict: true });
    sharedMode(database);
    this.db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000; PRAGMA max_page_count=65536; PRAGMA journal_size_limit=8388608; PRAGMA wal_autocheckpoint=128;");
    this.db.exec("CREATE TABLE IF NOT EXISTS incidents (id TEXT PRIMARY KEY, body TEXT NOT NULL)");
    this.db.exec("CREATE TABLE IF NOT EXISTS observations (id TEXT PRIMARY KEY, incident TEXT NOT NULL, body TEXT NOT NULL)");
    this.db.exec("CREATE TABLE IF NOT EXISTS executions (id TEXT PRIMARY KEY, day TEXT NOT NULL, active INTEGER NOT NULL, body TEXT NOT NULL)");
    this.db.exec("CREATE UNIQUE INDEX IF NOT EXISTS one_active_execution ON executions(active) WHERE active=1");
    this.db.exec("CREATE TABLE IF NOT EXISTS sources (id TEXT PRIMARY KEY, body TEXT NOT NULL)");
    this.db.exec("CREATE TABLE IF NOT EXISTS metadata (id TEXT PRIMARY KEY, value TEXT NOT NULL)");
    this.db.exec("CREATE TABLE IF NOT EXISTS pilot_samples (incident TEXT PRIMARY KEY, body TEXT NOT NULL)");
  }
  [Symbol.dispose]() { this.db.close(); }
  ingest(observation: Observation): Incident {
    observation = observationInput(observation);
    return this.db.transaction(() => {
      const id = createHash("sha256").update(JSON.stringify([observation.source, observation.target, observation.revision, observation.reason])).digest("hex");
      const eventId = JSON.stringify([observation.source, observation.eventId]);
      const body = JSON.stringify(observation);
      const duplicate = this.db.query<{ body: string }, [string]>("SELECT body FROM observations WHERE id=?").get(eventId);
      if (duplicate) {
        if (duplicate.body !== body) throw new Error("동일 eventId의 내용이 변경됨");
        return this.get(id);
      }
      const previous = this.db.query<{ body: string }, [string]>("SELECT body FROM incidents WHERE id=?").get(id);
      const incident: Incident = previous ? JSON.parse(previous.body) : {
        id, observation, status: observation.status, observationCount: 0, firstObservedAt: observation.observedAt,
        execution: { status: "queued" }, publication: { status: "not-requested" }, report: null,
      };
      incident.observationCount++;
      const delta = Date.parse(observation.observedAt) - Date.parse(incident.observation.observedAt);
      const superseded = observation.status === "firing" && incident.resolvedBy && Date.parse(observation.observedAt) <= Date.parse(incident.resolvedBy.observedAt);
      if (!superseded && (delta > 0 || delta === 0 && (observation.status !== "firing" || incident.status !== "resolved"))) {
        incident.observation = observation;
        if (observation.status !== "unobservable" || !previous) incident.status = observation.status;
        if (observation.status === "resolved" && ["queued", "deferred"].includes(incident.execution.status)) incident.execution.status = "cancelled";
        if (observation.status === "firing" && incident.execution.status === "cancelled") incident.execution.status = "queued";
        if (observation.status === "firing") delete incident.resolvedBy;
      }
      if (observation.reason === "Watchdog") incident.execution.status = "observed-only";
      if (["SystemdUnitFailed", "SystemdHostUnitFailed"].includes(observation.reason) && /(?:^|\/)aiops-[a-z0-9-]+\.(?:service|timer)$/.test(observation.target)) incident.execution.status = "self-observation";
      this.db.query("INSERT INTO observations VALUES (?, ?, ?)").run(eventId, id, body);
      this.save(incident);
      if (observation.source === "argocd" && observation.status === "resolved") {
        for (const summary of this.list().filter(item => item.id !== id && item.observation.source === "argocd" && item.observation.target === observation.target && item.observation.reason === observation.reason && item.status === "firing" && Date.parse(item.observation.observedAt) < Date.parse(observation.observedAt))) {
          const older = this.get(summary.id); older.status = "resolved";
          older.resolvedBy = { observedAt: observation.observedAt, revision: observation.revision, eventId: observation.eventId };
          if (["queued", "deferred"].includes(older.execution.status)) older.execution.status = "cancelled";
          this.save(older);
        }
      }
      return incident;
    }).immediate();
  }
  receive(source: string, observations: Observation[], health?: SourceHealth): Incident[] {
    return this.db.transaction(() => {
      const accepted = observations.map(observation => { requireCondition(observation.source === source, "source-mismatch"); return this.ingest(observation); });
      this.sourceHealth(source, health ?? { status: "observed", lastAttempt: new Date().toISOString(), lastSuccess: new Date().toISOString() });
      return accepted;
    }).immediate();
  }
  receiveOrdered(observation: Observation, runId: number, attempt: number) {
    return this.db.transaction(() => {
      const sourceKey = `gha:${observation.reason}:${observation.target}`;
      const previous = this.sources()[sourceKey];
      const [oldRun, oldAttempt] = (previous?.cursor ?? "0:0").split(":").map(Number);
      if (runId < oldRun || runId === oldRun && attempt <= oldAttempt) return;
      this.ingest(observation);
      if (observation.status === "resolved") {
        // 더 최신의 같은 검사·대상 정상은 이전 revision의 대기 사건도 해소한다.
        for (const summary of this.list().filter(i => i.observation.source === "gha" && i.observation.reason === observation.reason && i.observation.target === observation.target && i.status === "firing")) {
          const incident = this.get(summary.id);
          incident.status = "resolved";
          if (["queued", "deferred"].includes(incident.execution.status)) incident.execution.status = "cancelled";
          this.save(incident);
        }
      }
      this.sourceHealth(sourceKey, { status: observation.status === "unobservable" ? "unobservable" : "observed", lastAttempt: observation.observedAt, lastSuccess: observation.status === "unobservable" ? previous?.lastSuccess : observation.observedAt, cursor: `${runId}:${attempt}` });
    }).immediate();
  }
  sourceHealth(source: string, health: SourceHealth) {
    this.db.query("INSERT OR REPLACE INTO sources VALUES (?, ?)").run(source, JSON.stringify(health));
  }
  noticeDue(key: string, intervalMs: number): boolean {
    return this.db.transaction(() => {
      const previous = this.db.query<{ value: string }, [string]>("SELECT value FROM metadata WHERE id=?").get(`notice:${key}`);
      if (previous && Date.now() - Number(previous.value) < intervalMs) return false;
      this.db.query("INSERT OR REPLACE INTO metadata VALUES (?, ?)").run(`notice:${key}`, String(Date.now()));
      return true;
    }).immediate();
  }
  sources(): Record<string, SourceHealth> {
    return Object.fromEntries(this.db.query<{ id: string; body: string }, []>("SELECT id, body FROM sources").all().map(row => [row.id, JSON.parse(row.body) as SourceHealth]));
  }
  get(id: string): Incident {
    const row = this.db.query<{ body: string }, [string]>("SELECT body FROM incidents WHERE id=?").get(id);
    if (!row) throw new AiopsError("incident-not-found");
    return JSON.parse(row.body) as Incident;
  }
  list(): IncidentSummary[] {
    return this.db.query<{ body: string; has_report: number }, []>("SELECT json_remove(body, '$.report', '$.evidence', '$.validation') AS body, json_type(body, '$.report') != 'null' AS has_report FROM incidents ORDER BY id").all().map(row => ({ ...JSON.parse(row.body), reportAvailable: !!row.has_report }));
  }
  next(at: string): string {
    const now = Date.parse(at);
    requireCondition(Number.isFinite(now), "invalid-execution-time");
    const score = (incident: IncidentSummary) => Math.floor(Math.max(0, now - Date.parse(incident.firstObservedAt)) / 3600_000) + (incident.observation.severity === "critical" ? 6 : 0);
    const queue = this.list().filter(i => i.status === "firing" && ["queued", "deferred"].includes(i.execution.status));
    const compare = (a: string, b: string) => a < b ? -1 : a > b ? 1 : 0;
    queue.sort((a, b) => score(b) - score(a) || compare(a.firstObservedAt, b.firstObservedAt) || compare(a.id, b.id));
    requireCondition(queue.length, "no-queued-incidents");
    return queue[0].id;
  }
  budget() {
    const days = Object.fromEntries(this.db.query<{ day: string; count: number }, []>("SELECT day, count(*) AS count FROM executions GROUP BY day").all().map(row => [row.day, row.count]));
    const active = this.db.query<{ body: string }, []>("SELECT body FROM executions WHERE active=1").get();
    return { days, limit: 20, timezone: "Asia/Seoul", active: active ? JSON.parse(active.body) as Execution : null };
  }
  reserve(id: string, mode: Execution["mode"], at: string): Execution {
    requireCondition(Number.isFinite(Date.parse(at)), "invalid-execution-time");
    const result = this.db.transaction(() => {
      const incident = this.get(id);
      requireCondition(incident.status === "firing", "incident-not-firing");
      requireCondition(!["self-observation", "observed-only"].includes(incident.execution.status), "observation-not-an-execution-trigger");
      const day = new Date(Date.parse(at) + 9 * 3600_000).toISOString().slice(0, 10);
      const budget = this.budget();
      if (budget.active) return { blocked: "execution-active-or-cleanup-unknown" };
      if ((budget.days[day] ?? 0) >= 20) {
        incident.execution.status = "deferred";
        this.save(incident);
        return { blocked: "daily-limit" };
      }
      const previous = this.db.query<{ body: string }, []>("SELECT body FROM executions LIMIT 1").get();
      requireCondition(!previous || (JSON.parse(previous.body) as Execution).mode === mode, "replay-live-state-must-be-separate");
      const storedMode = this.db.query<{ value: string }, []>("SELECT value FROM metadata WHERE id='mode'").get();
      requireCondition(!storedMode || storedMode.value === mode, "replay-live-state-must-be-separate");
      this.db.query("INSERT OR IGNORE INTO metadata VALUES ('mode', ?)").run(mode);
      const run: Execution = { id: crypto.randomUUID(), incident: id, day, startedAt: at, status: "reserved", mode, owner: processIdentity(process.pid) };
      this.db.query("INSERT INTO executions VALUES (?, ?, 1, ?)").run(run.id, day, JSON.stringify(run));
      incident.execution = { status: "running", id: run.id };
      this.save(incident);
      return { run };
    }).immediate();
    if (!result.run) throw new AiopsError(result.blocked!);
    return result.run;
  }
  finish(run: Execution, status: string) {
    this.db.transaction(() => {
      const incident = this.get(run.incident);
      requireCondition(incident.execution.id === run.id, "execution-identity-changed");
      run.status = status;
      incident.execution.status = (executionStates as readonly string[]).includes(status) ? status as ExecutionState : "failed";
      if (incident.execution.status !== status) incident.execution.reason = status;
      this.save(incident);
      this.db.query("UPDATE executions SET active=0, body=? WHERE id=?").run(JSON.stringify(run), run.id);
    }).immediate();
  }
  bindProcess(run: Execution, identity: ProcessIdentity) {
    run.process = identity; run.status = "running";
    this.db.query("UPDATE executions SET body=? WHERE id=? AND active=1").run(JSON.stringify(run), run.id);
  }
  bindUnit(run: Execution, unit: string) {
    (run.units ??= []).push(unit); run.status = "running";
    this.db.query("UPDATE executions SET body=? WHERE id=? AND active=1").run(JSON.stringify(run), run.id);
  }
  retryAdmission(run: Execution, at = new Date().toISOString()) {
    this.db.transaction(() => {
      const active = this.budget().active;
      requireCondition(active?.id === run.id, "retry-active-execution-required");
      const key = `retry:${run.id}`;
      requireCondition(!this.db.query("SELECT id FROM metadata WHERE id=?").get(key), "retry-already-consumed");
      const day = new Date(Date.parse(at) + 9 * 3600_000).toISOString().slice(0, 10);
      requireCondition((this.budget().days[day] ?? 0) < 20, "daily-limit");
      const retry = { ...run, id: crypto.randomUUID(), day, startedAt: at, status: "retry-reserved" };
      this.db.query("INSERT INTO executions VALUES (?, ?, 0, ?)").run(retry.id, day, JSON.stringify(retry));
      this.db.query("INSERT INTO metadata VALUES (?, ?)").run(key, retry.id);
    }).immediate();
  }
  resume(id: string) {
    return this.db.transaction(() => {
      const incident = this.get(id);
      requireCondition(incident.status === "firing" && ["waiting-authentication", "waiting-capacity"].includes(incident.execution.status), "incident-not-waiting-for-recovery");
      incident.execution = { status: "queued" }; this.save(incident);
      return incident;
    }).immediate();
  }
  finishReport(run: Execution, status: string, report: Report): Incident {
    this.db.transaction(() => {
      const incident = this.get(run.incident);
      incident.report = report;
      this.save(incident);
      if (report.process?.cleanup === "unknown") { incident.execution.status = "cleanup-unknown"; this.save(incident); }
      else this.finish(run, status);
    }).immediate();
    return this.get(run.incident);
  }
  async recover(): Promise<Incident> {
    const run = this.db.transaction(() => {
      const active = this.budget().active;
      requireCondition(active && !sameProcess(active.owner), "execution-owner-active-or-no-reservation");
      active.owner = processIdentity(process.pid);
      active.status = "recovering";
      this.db.query("UPDATE executions SET body=? WHERE id=?").run(JSON.stringify(active), active.id);
      return active;
    }).immediate();
    const clean = run.units?.length ? run.units.map(cleanUnit).every(Boolean) : run.process ? await recoverGroup(run.process) : false;
    if (clean) this.finish(run, "interrupted");
    else {
      const incident = this.get(run.incident);
      incident.execution.status = "cleanup-unknown";
      this.save(incident);
      throw new AiopsError("cleanup-unknown-new-executions-blocked");
    }
    return this.get(run.incident);
  }
  private save(incident: Incident) {
    incident.updatedAt = new Date().toISOString();
    this.db.query("INSERT OR REPLACE INTO incidents VALUES (?, ?)").run(incident.id, JSON.stringify(incident));
  }
  prune(at: string) {
    const now = Date.parse(at); requireCondition(Number.isFinite(now), "invalid-retention-time");
    const cutoff = new Date(now - 30 * 86400_000).toISOString(), evidenceCutoff = new Date(now - 7 * 86400_000).toISOString();
    const result = this.db.transaction(() => {
      let evidenceRemoved = 0;
      const active = this.budget().active;
      for (const summary of this.list()) {
        if (summary.id === active?.incident) continue;
        const incident = this.get(summary.id);
        if (incident.evidence && incident.evidence.collectedAt < evidenceCutoff) {
          delete incident.evidence; evidenceRemoved++;
          this.db.query("UPDATE incidents SET body=? WHERE id=?").run(JSON.stringify(incident), incident.id);
        }
      }
      const deleted = this.db.query("DELETE FROM incidents WHERE COALESCE(json_extract(body, '$.updatedAt'), json_extract(body, '$.observation.observedAt')) < ? AND id != ?").run(cutoff, active?.incident ?? "");
      this.db.exec("DELETE FROM observations WHERE incident NOT IN (SELECT id FROM incidents)");
      this.db.query("DELETE FROM executions WHERE active=0 AND day < ?").run(cutoff.slice(0, 10));
      this.db.exec("DELETE FROM metadata WHERE id LIKE 'retry:%' AND value NOT IN (SELECT id FROM executions)");
      this.db.query("DELETE FROM sources WHERE id LIKE 'gha-run:%' AND json_extract(body, '$.lastAttempt') < ?").run(cutoff);
      return { incidentsRemoved: deleted.changes, evidenceRemoved, evidenceDays: 7, incidentDays: 30, rawRemoved: 0 };
    }).immediate();
    const raw = join(this.directory, "raw");
    try {
      for (const name of readdirSync(raw)) {
        if (!/^[a-f0-9-]{36}\.jsonl$/.test(name)) continue;
        const path = join(raw, name), stat = lstatSync(path);
        if (stat.isFile() && !stat.isSymbolicLink() && stat.mtimeMs < now - 7 * 86400_000) { unlinkSync(path); result.rawRemoved++; }
      }
    } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
    this.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    return result;
  }
  observationStart(input: unknown) {
    const config = record(input), criteria = record(config.observation);
    requireCondition(criteria.days === 14 && Number.isSafeInteger(criteria.minimumCases) && Number(criteria.minimumCases) > 0 && typeof criteria.qualityCriteria === "string" && criteria.qualityCriteria.length > 0 && typeof criteria.manualBaseline === "string" && criteria.manualBaseline.length > 0, "observation-criteria-required");
    requireCondition(Array.isArray(criteria.requiredSources) && [...criteria.requiredSources].sort().join(",") === "alertmanager,argocd,cnpg,gha,healthchecks", "observation-source-scope-required");
    requireCondition(config.mode === "replay" || config.mode === "codex" && readiness(config).ready, "live-readiness-required");
    const value = { startedAt: new Date().toISOString(), criteria, simulated: config.mode === "replay" };
    this.db.transaction(() => {
      requireCondition(!this.db.query("SELECT id FROM metadata WHERE id='observation'").get(), "observation-already-started");
      this.db.query("INSERT INTO metadata VALUES ('observation', ?)").run(JSON.stringify(value));
    }).immediate();
    return this.observationSummary();
  }
  observationRecord(input: unknown) {
    const sample = record(input), incident = this.get(String(sample.incident));
    const start = this.observationSummary();
    requireCondition(start && incident.report && incident.report.simulated === start.simulated, "observation-report-mode-mismatch");
    requireCondition([sample.manualMinutes, sample.reviewMinutes].every(v => typeof v === "number" && Number.isFinite(v) && v >= 0 && v <= 1440) && typeof sample.falsePositive === "boolean" && typeof sample.deferred === "boolean", "invalid-observation-sample");
    this.db.query("INSERT OR REPLACE INTO pilot_samples VALUES (?, ?)").run(incident.id, JSON.stringify({ recordedAt: new Date().toISOString(), source: incident.observation.source, manualMinutes: sample.manualMinutes, reviewMinutes: sample.reviewMinutes, falsePositive: sample.falsePositive, deferred: sample.deferred, usage: incident.report.usage ?? null }));
    return this.observationSummary();
  }
  observationSummary() {
    const row = this.db.query<{ value: string }, []>("SELECT value FROM metadata WHERE id='observation'").get();
    requireCondition(row, "observation-not-started");
    const start = JSON.parse(row.value) as { startedAt: string; simulated: boolean; criteria: { minimumCases: number; requiredSources: string[]; qualityCriteria: string; manualBaseline: string; days: number } };
    const samples = this.db.query<{ body: string }, []>("SELECT body FROM pilot_samples").all().map(row => JSON.parse(row.body) as { source: string; manualMinutes: number; reviewMinutes: number; falsePositive: boolean; deferred: boolean; usage: Report["usage"] });
    const sources = [...new Set(samples.map(s => s.source))].sort(), elapsedDays = (Date.now() - Date.parse(start.startedAt)) / 86400_000;
    const sufficient = elapsedDays >= 14 && samples.length >= start.criteria.minimumCases && start.criteria.requiredSources.every(source => sources.includes(source));
    return { ...start, elapsedDays, samples: samples.length, sources, manualMinutes: samples.reduce((n, s) => n + s.manualMinutes, 0), reviewMinutes: samples.reduce((n, s) => n + s.reviewMinutes, 0), falsePositives: samples.filter(s => s.falsePositive).length, deferred: samples.filter(s => s.deferred).length,
      unknownUsage: samples.filter(s => !s.usage).length, confirmedInputTokens: samples.reduce((n, s) => n + (s.usage?.inputTokens ?? 0), 0), confirmedOutputTokens: samples.reduce((n, s) => n + (s.usage?.outputTokens ?? 0), 0), verdict: sufficient && !start.simulated ? "human-quality-review-required" : "insufficient-evidence" };
  }
  attachEvidence(id: string, evidence: Evidence): Incident {
    return this.db.transaction(() => {
      const incident = this.get(id);
      incident.evidence = evidence;
      this.save(incident);
      return incident;
    }).immediate();
  }
  recordReport(id: string, report: Report) {
    this.db.transaction(() => { const incident = this.get(id); incident.report = report; this.save(incident); }).immediate();
  }
  attachValidation(id: string, validation: Validation): Incident {
    return this.db.transaction(() => {
      const incident = this.get(id);
      incident.validation = validation;
      this.save(incident);
      return incident;
    }).immediate();
  }
  beginPublication(id: string): Publication {
    return this.db.transaction(() => {
      const incident = this.get(id);
      requireCondition(!incident.publication.owner || !sameProcess(incident.publication.owner), "publication-active");
      incident.publication.owner = processIdentity(process.pid);
      incident.publication.status = "publishing";
      this.save(incident);
      return incident.publication;
    }).immediate();
  }
  savePublication(id: string, publication: Publication) {
    this.db.transaction(() => {
      const incident = this.get(id);
      publication.units = [...new Set([...(incident.publication.units ?? []), ...(publication.units ?? [])])];
      incident.publication = publication; this.save(incident);
    }).immediate();
  }
  clearPublicationUnits(id: string) {
    this.db.transaction(() => { const incident = this.get(id); incident.publication.units = []; this.save(incident); }).immediate();
  }
  async replay(id: string, at = new Date().toISOString(), engine?: string, timeoutMs: number = STAGE_LIMITS.codex.milliseconds): Promise<Incident> {
    requireCondition(Number.isSafeInteger(timeoutMs) && timeoutMs > 0 && timeoutMs <= STAGE_LIMITS.codex.milliseconds, "invalid-timeout");
    const run = this.reserve(id, "replay", at);
    const deadline = Date.now() + timeoutMs;
    const execute = () => engine ? runProcess([engine], { timeoutMs: Math.max(1, deadline - Date.now()), maxBytes: STAGE_LIMITS.codex.bytes, onStart: identity => {
      run.process = identity; run.status = "running";
      this.db.query("UPDATE executions SET body=? WHERE id=?").run(JSON.stringify(run), run.id);
    } }) : undefined;
    let result = await execute();
    if (result?.status === "start-failed" && result.cleanup === "confirmed" && Date.now() < deadline) {
      try { this.retryAdmission(run, at); result = await execute(); }
      catch (error) { if (!(error instanceof AiopsError) || error.code !== "daily-limit") throw error; }
    }
    const incident = this.get(id);
    incident.report = { simulated: true, patch: null, missing: ["운영 증거와 실제 모델 실행"], ...(result ? { process: { ...result, stdout: "" } } : {}) };
    this.save(incident);
    if (result?.cleanup === "unknown") {
      incident.execution.status = "cleanup-unknown";
      this.save(incident);
    } else this.finish(run, result && result.status !== "completed" ? result.status : "needs-evidence");
    return this.get(id);
  }
}
