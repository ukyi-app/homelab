import { chmodSync, chownSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { isolatedSpawnSync as spawnSync } from "../exec.ts";
import { Incidents } from "./incidents.ts";
import type { Execution } from "./incidents.ts";
import type { Evidence } from "./evidence.ts";
import type { Report } from "./diagnosis.ts";
import type { Validation } from "./validation.ts";
import { AiopsError, readBounded, record, requireCondition } from "./input.ts";
import { cleanUnit, readiness, runHostStage } from "./host.ts";
import type { Role } from "./host.ts";
import { sameProcess } from "./process.ts";
import type { ProcessResult, STAGE_LIMITS } from "./process.ts";
import { publishIncident } from "./publication.ts";

// 이 프로세스만 사건 저장소와 단계 실행 권한을 함께 갖는다. 모델은 역할 작업 안에서만 실행한다.
export async function worker(incidents: Incidents, input: unknown, state: string, commissioning?: { incident: string; evidence?: unknown }) {
  const config = record(input), installation = record(config.installation);
  requireCondition(process.getuid?.() === 0, "host-coordinator-root-required");
  if (incidents.budget().active) await incidents.recover();
  for (const summary of incidents.list().filter(item => item.publication.units?.length)) {
    requireCondition(!summary.publication.owner || !sameProcess(summary.publication.owner), "publication-active");
    requireCondition(summary.publication.units!.map(cleanUnit).every(Boolean), "publication-cleanup-unknown");
    incidents.clearPublicationUnits(summary.id);
  }
  incidents.prune(new Date().toISOString());
  const prepared = readiness(config);
  requireCondition(commissioning ? prepared.commissioning.ready : prepared.ready && config.enabled === true, "live-readiness-required");
  const work = "/var/lib/homelab-aiops/work";
  mkdirSync(work, { recursive: true, mode: 0o711 });
  const directory = mkdtempSync(join(work, "attempt-")); chmodSync(directory, 0o711);
  const deadline = Date.now() + 1200_000;
  let run: Execution | undefined, counter = 0, last: ProcessResult | undefined, publicationId: string | undefined;
  const units: string[] = [];
  const stage = async (role: Role, kind: string, data: Record<string, unknown>, limit: keyof typeof STAGE_LIMITS, until = deadline) => {
    const jobDirectory = join(directory, String(counter++)); mkdirSync(jobDirectory, { mode: 0o711 });
    const output = join(jobDirectory, "output"); mkdirSync(output, { mode: 0o700 });
    const uid = spawnSync("/usr/bin/id", ["-u", `aiops-${role}`], { encoding: "utf8", timeout: 5000, maxBuffer: 4096, env: { PATH: "/usr/bin:/bin" } });
    const gid = spawnSync("/usr/bin/id", ["-g", `aiops-${role}`], { encoding: "utf8", timeout: 5000, maxBuffer: 4096, env: { PATH: "/usr/bin:/bin" } });
    requireCondition(uid.status === 0 && gid.status === 0, "role-account-missing");
    chownSync(output, Number(uid.stdout.trim()), Number(gid.stdout.trim()));
    const path = join(jobDirectory, "input.json");
    writeFileSync(path, JSON.stringify({ role, kind, ...data, rawOutput: join(output, "raw.jsonl") }), { mode: 0o400 });
    chownSync(path, Number(uid.stdout.trim()), Number(gid.stdout.trim()));
    const writable = [output, ...(role === "engine" ? [String(config.authentication)] : []), ...(kind === "poll" ? [state] : [])];
    last = await runHostStage({ role, stage: limit, command: [String(installation.bun), `${installation.code}/tools/aiops-stage.ts`, path], writable: writable.join(" "), readable: [path, String(installation.code), String(config.repository)], deadline: Math.min(deadline, until), onUnit: unit => {
      units.push(unit); if (run) incidents.bindUnit(run, unit);
      if (publicationId) { const publication = incidents.get(publicationId).publication; (publication.units ??= []).push(unit); incidents.savePublication(publicationId, publication); }
    } });
    requireCondition(last.cleanup === "confirmed", "cleanup-unknown-new-executions-blocked");
    let result: Record<string, unknown>;
    try { result = record(JSON.parse(last.stdout)); } catch { throw new AiopsError(`stage-${last.status}`); }
    requireCondition(last.status === "completed" && !result.error, typeof result.error === "string" ? result.error : `stage-${last.status}`);
    if (kind === "diagnose" && run) {
      const raw = readBounded(join(output, "raw.jsonl"), 8 * 1024 * 1024);
      mkdirSync(join(state, "raw"), { recursive: true, mode: 0o700 });
      writeFileSync(join(state, "raw", `${run.id}.jsonl`), raw, { mode: 0o600 });
    }
    return result;
  };
  const publish = async (id: string) => {
    publicationId = id;
    const publicationDeadline = Math.min(deadline, Date.now() + 60_000);
    const result = await publishIncident(incidents, id, config, String(config.repository), async (role, path, options) => {
      const result = await stage(role, "api", { request: { path, ...options } }, "publish", publicationDeadline);
      return result.result;
    });
    if (units.map(cleanUnit).every(Boolean)) { result.publication.units = []; incidents.clearPublicationUnits(id); }
    publicationId = undefined;
    return result;
  };
  try {
    if (!commissioning) await stage("collector", "poll", { state }, "collect");
    const deferred = incidents.list().find(item => (!commissioning || item.id === commissioning.incident) && item.reportAvailable && item.publication.status === "deferred" && (!item.publication.retryAt || Date.parse(item.publication.retryAt) <= Date.now()));
    if (deferred) return { incident: await publish(deferred.id), modelAdmission: false };
    const id = commissioning?.incident ?? incidents.next(new Date().toISOString());
    run = incidents.reserve(id, "codex", new Date().toISOString());
    const base = { repository: config.repository, revision: config.revision };
    const collection = await stage("collector", "collect", { ...base, incident: incidents.get(id), ...(commissioning?.evidence ? { fixture: commissioning.evidence } : {}) }, "collect");
    incidents.attachEvidence(id, collection.evidence as Evidence);
    const engineDeadline = Math.min(deadline, Date.now() + 600_000);
    const diagnoseJob = () => stage("engine", "diagnose", { ...base, incident: incidents.get(id), options: { engine: installation.engine, engineHash: record(installation.hashes).engine, authentication: config.authentication, model: config.model } }, "codex", engineDeadline);
    let diagnosis = await diagnoseJob();
    // 자식 시작이 실패했고 정리가 확인된 경우만 한 번 재입장한다. 두 시도는 같은 10분 상한이다.
    if (diagnosis.status === "start-failed" && Date.now() < engineDeadline) {
      try { incidents.retryAdmission(run); diagnosis = await diagnoseJob(); }
      catch (error) { if (!(error instanceof AiopsError) || error.code !== "daily-limit") throw error; }
    }
    incidents.recordReport(id, diagnosis.report as Report);
    if (incidents.get(id).report?.patch) {
      const result = await stage("validator", "validate", { ...base, incident: incidents.get(id) }, "validate");
      incidents.attachValidation(id, result.validation as Validation);
    }
    await publish(id);
    const report = incidents.get(id).report!;
    report.process = { ...(report.process ?? last!), stdout: "", confinement: "systemd-cgroup", unverified: [], cleanup: units.map(cleanUnit).every(Boolean) ? "confirmed" : "unknown" };
    return { incident: incidents.finishReport(run, String(diagnosis.status), report), commissioning: !!commissioning };
  } catch (error) {
    if (!run && error instanceof AiopsError && error.code === "no-queued-incidents") return { status: "idle" };
    if (!run && error instanceof AiopsError && error.code === "daily-limit") {
      const count = incidents.list().filter(item => item.status === "firing" && ["queued", "deferred"].includes(item.execution.status)).length;
      if (incidents.noticeDue("daily-limit", 3600_000)) {
        try { await stage("telegram", "api", { request: { path: "sendMessage", method: "POST", body: { text: `AIOps 하루 입장 한도 20건에 도달했습니다. 대기 ${count}건. 다음 KST 날짜에 순서대로 처리합니다.` } } }, "publish"); }
        catch { incidents.sourceHealth("queue-notification", { status: "unobservable", lastAttempt: new Date().toISOString(), reason: "queue-notification-failed" }); }
      }
      return { status: "deferred", reason: "daily-limit", queued: count };
    }
    if (!run) throw error;
    const code = error instanceof AiopsError ? error.code : "host-worker-failed";
    const reason = code === "subscription-auth-required-no-api-fallback" ? "waiting-authentication" : code;
    const clean = units.map(cleanUnit).every(Boolean);
    const report = incidents.get(run.incident).report ?? { simulated: false, patch: null, missing: [] };
    report.missing.push(reason);
    report.process = { status: reason, exitCode: null, bytes: last?.bytes ?? 0, stdout: "", cleanup: clean ? "confirmed" : "unknown", confinement: "systemd-cgroup", unverified: [] };
    return { incident: incidents.finishReport(run, reason, report) };
  } finally {
    // 정리 불명 작업의 자료는 지우지 않는다. 다음 실행도 복구가 확인될 때까지 차단된다.
    if (units.map(cleanUnit).every(Boolean)) rmSync(directory, { recursive: true, force: true });
  }
}
