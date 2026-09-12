import { closeSync, constants, fstatSync, openSync, readSync } from "node:fs";
import type { Observation } from "./incidents.ts";

export class AiopsError extends Error {
  readonly code: string;
  constructor(code: string) { super(code); this.code = code; }
}
export function requireCondition(condition: unknown, code: string): asserts condition {
  if (!condition) throw new AiopsError(code);
}
export function readBounded(path: string, limit = 256 * 1024): string {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const stat = fstatSync(fd);
    requireCondition(stat.isFile() && stat.size <= limit, "input-size-or-type");
    const buffer = Buffer.alloc(limit + 1);
    let bytes = 0;
    while (bytes <= limit) {
      const got = readSync(fd, buffer, bytes, buffer.length - bytes, null);
      if (!got) break;
      bytes += got;
    }
    requireCondition(bytes <= limit, "input-too-large");
    return buffer.subarray(0, bytes).toString("utf8");
  } finally { closeSync(fd); }
}
export function record(value: unknown): Record<string, unknown> {
  requireCondition(value !== null && typeof value === "object" && !Array.isArray(value), "invalid-object");
  return value as Record<string, unknown>;
}
export function observationInput(value: unknown): Observation {
  const v = record(value);
  const keys = ["source", "eventId", "target", "observedAt", "revision", "severity", "reason", "status"];
  requireCondition(Object.keys(v).length === keys.length && Object.keys(v).every(k => keys.includes(k)), "invalid-observation-fields");
  const name = (key: string, max: number) => typeof v[key] === "string" && (v[key] as string).length <= max && /^[a-zA-Z0-9][a-zA-Z0-9_.:/@+-]*$/.test(v[key] as string);
  requireCondition(["alertmanager", "argocd", "cnpg", "gha", "healthchecks"].includes(String(v.source)), "invalid-source");
  requireCondition(name("eventId", 256) && name("target", 256) && name("reason", 128), "invalid-observation-identity");
  requireCondition(typeof v.observedAt === "string" && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,3})?(?:Z|[+-]\d\d:\d\d)$/.test(v.observedAt) && Number.isFinite(Date.parse(v.observedAt)), "invalid-observation-time");
  requireCondition(v.revision === null || typeof v.revision === "string" && /^[a-f0-9]{40}$/.test(v.revision), "invalid-revision");
  requireCondition(["critical", "warning", "info"].includes(String(v.severity)) && ["firing", "resolved", "unobservable"].includes(String(v.status)), "invalid-observation-state");
  return Object.fromEntries(keys.map(k => [k, v[k]])) as Observation;
}
