import type { Incidents, Observation } from "./incidents.ts";
import { AiopsError, readBounded, record, requireCondition, observationInput } from "./input.ts";
import { JsonApi } from "./http.ts";
import { digest } from "./git.ts";

export async function pollHealthchecks(incidents: Incidents, input: unknown) {
  const config = record(input), at = new Date().toISOString(), previous = incidents.sources().healthchecks;
  const health = config.healthchecks ? record(config.healthchecks) : {};
  if (!health.readKeyFile) {
    incidents.sourceHealth("healthchecks", { ...previous, status: "unconfigured", lastAttempt: at, reason: "read-only-key-missing" });
    return;
  }
  try {
    requireCondition(health.keyAccess === "read-only" && typeof health.readKeyFile === "string", "read-only-key-required");
    const token = readBounded(health.readKeyFile, 1024).trim();
    requireCondition(token.length > 0 && !/\s|:\/\//.test(token), "invalid-read-key");
    const api = new JsonApi(String(health.baseUrl ?? "https://healthchecks.io/api/v3/"), { "X-Api-Key": token }, "https://healthchecks.io", config.mode === "replay");
    const response = record(await api.request("checks/"));
    requireCondition(Array.isArray(response.checks) && response.checks.length <= 100, "invalid-healthchecks-list");
    const observations: Observation[] = [];
    const pending: { key: string; cursor: string; gap: boolean }[] = [];
    for (const raw of response.checks) {
      const check = record(raw);
      // read-only 응답의 unique_key를 사용한다. ping UUID/URL이 나오면 잘못된 자격이다.
      requireCondition(typeof check.unique_key === "string" && /^[a-f0-9]{40}$/.test(check.unique_key) && !Object.hasOwn(check, "uuid") && !Object.hasOwn(check, "ping_url"), "healthchecks-not-read-only");
      const key = `healthchecks:${check.unique_key}`, old = incidents.sources()[key];
      const mappings = Array.isArray(health.checks) ? health.checks.map(record) : [];
      const target = mappings.find(c => c.id === check.unique_key)?.target ?? `healthcheck/${check.unique_key.slice(0, 16)}`;
      const since = old?.cursor ? `?start=${Math.max(0, Math.floor(Date.parse(old.cursor) / 1000) - 3600)}` : "";
      const flips = await api.request(`checks/${check.unique_key}/flips/${since}`);
      requireCondition(Array.isArray(flips) && flips.length <= 10_000, "invalid-healthchecks-flips");
      let cursor = old?.cursor ?? "1970-01-01T00:00:00.000Z";
      for (const rawFlip of flips) {
        const flip = record(rawFlip);
        requireCondition((flip.up === 0 || flip.up === 1) && typeof flip.timestamp === "string" && Number.isFinite(Date.parse(flip.timestamp)), "invalid-healthchecks-flip");
        const observedAt = new Date(flip.timestamp).toISOString();
        requireCondition(Date.parse(observedAt) <= Date.parse(at) + 60_000, "healthchecks-future-observation");
        if (observedAt > cursor) cursor = observedAt;
        observations.push(observationInput({ source: "healthchecks", eventId: digest(JSON.stringify([check.unique_key, observedAt, flip.up])), target, observedAt, revision: null,
          severity: "warning", reason: "ExternalCheckDown", status: flip.up ? "resolved" : "firing" }));
      }
      // 이력 보존 창 밖에서 이미 내려간 대상도 초기 현재 상태로 보인다. 이력 완전성은 gap으로 구별한다.
      if (!old && flips.length === 0 && check.status === "down") {
        observations.push(observationInput({ source: "healthchecks", eventId: digest(JSON.stringify([check.unique_key, "initial-down", at])), target,
          observedAt: at, revision: null, severity: "warning", reason: "ExternalCheckDown", status: "firing" }));
      }
      const now = new Date(at), retentionStart = Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 2, 1);
      const gap = !old?.lastSuccess || Date.parse(old.lastSuccess) < retentionStart;
      pending.push({ key, cursor, gap });
    }
    incidents.receive("healthchecks", observations, { status: "observed", lastAttempt: at, lastSuccess: at, gap: pending.some(p => p.gap) });
    for (const value of pending) incidents.sourceHealth(value.key, { status: "observed", lastAttempt: at, lastSuccess: at, cursor: value.cursor, gap: value.gap });
  } catch (error) {
    incidents.sourceHealth("healthchecks", { ...previous, status: "unobservable", lastAttempt: at, reason: error instanceof AiopsError ? error.code : "healthchecks-query-failed", gap: true });
  }
}
