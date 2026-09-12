import { collectEvidence, sealEvidence } from "./evidence.ts";
import type { Evidence, EvidenceItem } from "./evidence.ts";
import type { Incident } from "./incidents.ts";
import { GitSnapshot } from "./git.ts";
import { AiopsError, record, requireCondition } from "./input.ts";
import { runProcess, STAGE_LIMITS } from "./process.ts";
import { JsonApi } from "./http.ts";

// 자격이 있는 수집기는 고정 조회만 수행한다. Pod spec·env·Secret 원문은 증거로 내보내지 않는다.
export async function collectLive(incident: Incident, snapshot: GitSnapshot, input: unknown): Promise<Evidence> {
  const config = record(input), settings = record(config.collection), collectedAt = new Date().toISOString();
  const target = incident.observation.target, items: EvidenceItem[] = [{ id: "source-observation", kind: "state", target, observedAt: incident.observation.observedAt, data: { status: incident.status, reason: incident.observation.reason } }];
  const omitted: { id: string; reason: string }[] = [];
  const deadline = Date.now() + STAGE_LIMITS.collect.milliseconds;
  let bytes = 0;
  const query = async (args: string[]) => {
    requireCondition(bytes < STAGE_LIMITS.collect.bytes && Date.now() < deadline, "collection-limit");
    const result = await runProcess([String(settings.kubectl), "--kubeconfig", String(settings.kubeconfig), "--request-timeout=10s", ...args], { timeoutMs: Math.min(15_000, deadline - Date.now()), maxBytes: STAGE_LIMITS.collect.bytes - bytes, onStart: () => {} });
    bytes += result.bytes;
    requireCondition(result.status === "completed", `collection-${result.status}`);
    return result.stdout;
  };
  const [namespace, name] = target.split("/");
  if (["alertmanager", "argocd", "cnpg"].includes(incident.observation.source) && target.split("/").length === 2 && /^[a-z0-9-]+$/.test(namespace) && /^[a-z0-9.-]+$/.test(name) && namespace !== "host") {
    try {
      const response = record(JSON.parse(await query(["get", "pods", "-n", namespace, "-o", "json"])));
      requireCondition(Array.isArray(response.items), "invalid-pod-list");
      const pods = response.items.map(record).filter(pod => {
        const metadata = record(pod.metadata);
        return metadata.name === name || typeof metadata.name === "string" && metadata.name.startsWith(`${name}-`);
      });
      if (!pods.length) omitted.push({ id: "pods", reason: "no-matching-pods" });
      if (pods.length > 10) omitted.push({ id: "pods", reason: "pod-count-limit" });
      for (const [index, pod] of pods.slice(0, 10).entries()) {
        const metadata = record(pod.metadata), status = record(pod.status);
        const containers = Array.isArray(status.containerStatuses) ? status.containerStatuses.map(record) : [];
        const selected = containers.map(container => {
          const state = record(container.state), current = record(state.waiting ?? state.terminated ?? {});
          return { name: container.name, reason: current.reason, exitCode: current.exitCode, restartCount: container.restartCount };
        });
        items.push({ id: `pod-${index}`, kind: "state", target, observedAt: collectedAt, data: { phase: status.phase, message: JSON.stringify(selected) } });
        for (const [containerIndex, container] of containers.entries()) {
          if (typeof container.name !== "string" || !/^[a-z0-9-]+$/.test(container.name) || typeof metadata.name !== "string" || !/^[a-z0-9.-]+$/.test(metadata.name)) continue;
          try {
            const logs = await query(["logs", "-n", namespace, metadata.name, "-c", container.name, "--timestamps", "--tail=200", `--since-time=${new Date(Date.parse(incident.observation.observedAt) - 900_000).toISOString()}`]);
            items.push({ id: `logs-${index}-${containerIndex}`, kind: "logs", target, observedAt: collectedAt, container: `${index}-${container.name}`, data: logs });
          } catch { omitted.push({ id: `logs-${index}-${containerIndex}`, reason: "logs-unavailable" }); }
        }
        const events = record(JSON.parse(await query(["get", "events", "-n", namespace, "--field-selector", `involvedObject.name=${metadata.name}`, "-o", "json"])));
        if (Array.isArray(events.items)) for (const [eventIndex, event] of events.items.slice(0, 100).map(record).entries()) items.push({ id: `event-${index}-${eventIndex}`, kind: "events", target, observedAt: String(event.lastTimestamp ?? event.eventTime ?? collectedAt), data: { reason: event.reason, message: event.message, count: event.count } });
      }
    } catch (error) { omitted.push({ id: "kubernetes", reason: error instanceof AiopsError ? error.code : "kubernetes-unavailable" }); }
  } else omitted.push({ id: "kubernetes", reason: "target-not-a-kubernetes-workload" });
  if (typeof settings.metricsUrl === "string") {
    try {
      const url = new URL(settings.metricsUrl);
      requireCondition(config.mode === "replay" || ["http:", "https:"].includes(url.protocol) && /^(?:127\.|10\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.)/.test(url.hostname), "metrics-origin-not-internal");
      const api = new JsonApi(url.toString(), {}, url.origin, config.mode === "replay", Math.max(1, deadline - Date.now()));
      const expression = `container_memory_working_set_bytes{namespace=${JSON.stringify(namespace)},pod=~${JSON.stringify(`${name}(-.*)?`)}}`;
      const parameters = new URLSearchParams({ query: expression, start: String((Date.parse(incident.observation.observedAt) - 900_000) / 1000), end: String(Date.parse(collectedAt) / 1000), step: "30" });
      const response = record(await api.request(`api/v1/query_range?${parameters}`, { limit: Math.max(1, STAGE_LIMITS.collect.bytes - bytes) }));
      requireCondition(response.status === "success", "metrics-query-failed");
      const series = record(response.data).result;
      requireCondition(Array.isArray(series), "invalid-metrics-result");
      const values = series.flatMap(entry => { const value = record(entry).values; return Array.isArray(value) ? value.map(pair => Array.isArray(pair) ? Number(pair[1]) : NaN) : []; }).filter(Number.isFinite);
      if (values.length) items.push({ id: "memory-peak", kind: "metrics", target, observedAt: collectedAt, data: { metric: "container_memory_working_set_bytes", value: Math.max(...values), unit: "bytes", query: expression } });
      else omitted.push({ id: "metrics", reason: "empty-metrics-result" });
    } catch { omitted.push({ id: "metrics", reason: "metrics-unavailable" }); }
  } else omitted.push({ id: "metrics", reason: "metrics-not-configured" });
  const evidence = collectEvidence(incident, snapshot, { collectedAt, items });
  evidence.omitted.push(...omitted); evidence.partial ||= omitted.length > 0;
  return sealEvidence(evidence);
}
