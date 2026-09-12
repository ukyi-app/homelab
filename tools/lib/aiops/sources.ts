import { digest } from "./git.ts";
import { observationInput, record, requireCondition } from "./input.ts";
import type { Observation } from "./incidents.ts";

export type SourceHealth = { status: "observed" | "unobservable" | "unconfigured"; lastSuccess?: string; lastAttempt: string; reason?: string; cursor?: string; gap?: boolean };
export function normalizeProducer(source: string, payload: unknown): Observation[] {
  const value = record(payload);
  if (source === "alertmanager") {
    requireCondition(value.version === "4" && Array.isArray(value.alerts) && value.alerts.length <= 100, "invalid-alertmanager-payload");
    return value.alerts.map(raw => {
      const alert = record(raw), labels = record(alert.labels);
      requireCondition(alert.status === "firing" || alert.status === "resolved", "invalid-alertmanager-state");
      const target = labels.unit ? `host/${labels.unit}` : labels.namespace ? `${labels.namespace}/${labels.pod ?? labels.deployment ?? labels.job ?? labels.alertname}` : String(labels.node ?? labels.job ?? labels.alertname);
      const observedAt = alert.status === "resolved" ? alert.endsAt : alert.startsAt;
      requireCondition(typeof observedAt === "string" && Number.isFinite(Date.parse(observedAt)), "invalid-alertmanager-time");
      return observationInput({ source, eventId: digest(JSON.stringify([alert.fingerprint, alert.status, alert.startsAt, observedAt, target, labels.alertname])), target,
        observedAt: new Date(observedAt).toISOString(), revision: typeof labels.revision === "string" && /^[a-f0-9]{40}$/.test(labels.revision) ? labels.revision : null,
        severity: labels.severity ?? "warning", reason: labels.alertname, status: alert.status });
    });
  }
  if (source === "argocd") {
    requireCondition(["health", "sync"].includes(String(value.check)) && typeof value.name === "string", "invalid-argocd-payload");
    const firing = value.check === "sync" ? ["Failed", "Error"].includes(String(value.phase)) : value.health === "Degraded";
    const healthy = value.check === "sync" ? value.phase === "Succeeded" : value.health === "Healthy" && value.sync === "Synced";
    return [observationInput({ source, eventId: digest(JSON.stringify([value.name, value.check, value.observedAt, value.phase, value.health, value.revision])),
      target: `${value.namespace ?? "argocd"}/${value.name}`, observedAt: value.observedAt, revision: value.revision ?? null, severity: "warning",
      reason: value.check === "sync" ? "ArgoSyncFailed" : "ArgoHealthDegraded", status: firing ? "firing" : healthy ? "resolved" : "unobservable" })];
  }
  if (source === "cnpg") {
    requireCondition(["restore-drill", "ensure-role-password"].includes(String(value.check)) && ["healthy", "warning", "unobservable"].includes(String(value.status)), "invalid-cnpg-payload");
    return [observationInput({ source, eventId: digest(JSON.stringify([value.check, value.target, value.runId, value.status, value.observedAt])), target: value.target,
      observedAt: value.observedAt, revision: value.revision ?? null, severity: "critical", reason: value.check,
      status: value.status === "warning" ? "firing" : value.status === "healthy" && value.completed === true ? "resolved" : "unobservable" })];
  }
  throw new Error("unsupported-producer");
}
