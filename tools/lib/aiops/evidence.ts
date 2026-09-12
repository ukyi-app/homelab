import type { Incident } from "./incidents.ts";
import { GitSnapshot, digest } from "./git.ts";
import { record, requireCondition } from "./input.ts";

export type EvidenceItem = { id: string; kind: string; target: string; observedAt: string; data: unknown; container?: string };
export type Evidence = {
  revision: string; manifestHash: string; hash: string; collectedAt: string; from: string;
  items: EvidenceItem[]; rules: { path: string; blob: string; text: string }[];
  omitted: { id: string; reason: string }[]; redactions: number; truncated: string[]; partial: boolean;
  sourceRevision: string | null; revisionMismatch: boolean; bytes: number;
};
export function sealEvidence(evidence: Evidence): Evidence {
  evidence.hash = "0".repeat(64); evidence.bytes = 0;
  for (let i = 0; i < 4; i++) evidence.bytes = Buffer.byteLength(JSON.stringify(evidence));
  evidence.hash = digest(JSON.stringify({ ...evidence, hash: "" }));
  requireCondition(evidence.bytes === Buffer.byteLength(JSON.stringify(evidence)) && evidence.bytes <= 256 * 1024, "evidence-bundle-too-large");
  return evidence;
}
export function redact(text: string): { text: string; count: number } {
  let count = 0;
  let safe = text;
  // 알려진 자격 표기·주소·고엔트로피 토큰은 모델로 보내기 전에 제거한다.
  for (const pattern of [
    /-----BEGIN [\s\S]*?-----END [^-]+-----/g,
    /\b(?:[a-z][a-z0-9+.-]*):\/\/[^\s"'<>]+/gi,
    /["']?\b(?:authorization|bearer|password|passwd|token|secret|api[_-]?key|cookie)\b["']?\s*[:= ]\s*(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\s,;]+)/gi,
    /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi,
    /\b(?:\d{1,3}\.){3}\d{1,3}\b/g,
    /\b[A-Za-z0-9_+\/-]{32,}={0,2}\b/g,
  ]) safe = safe.replace(pattern, () => { count++; return "[REDACTED]"; });
  return { text: safe, count };
}

// text·JSONL·kubectl timestamp 접두만 지원한다. 구조 로그 파싱 실패나 바이너리는 원문을 생략한다.
function selectLogs(text: string): { text: string; omittedFields: number } | null {
  if (/[\x00-\x08\x0b\x0c\x0e-\x1f\ufffd]/.test(text)) return null;
  let omittedFields = 0;
  const fields = new Set(["time", "timestamp", "level", "severity", "message", "msg", "error", "reason", "status", "code", "component", "controller", "namespace", "name", "pod", "container", "count"]);
  const select = (value: unknown): unknown => {
    if (Array.isArray(value)) return value.map(select);
    if (!value || typeof value !== "object") return value;
    return Object.fromEntries(Object.entries(value).filter(([key]) => { if (fields.has(key)) return true; omittedFields++; return false; }).map(([key, item]) => [key, select(item)]));
  };
  const selected: string[] = [];
  for (const line of text.split("\n")) {
    const content = line.replace(/^\d{4}-\d{2}-\d{2}T\S+\s+/, "").trim();
    if (!content.startsWith("{") && !content.startsWith("[")) { selected.push(line); continue; }
    try { selected.push(JSON.stringify(select(JSON.parse(content)))); } catch { return null; }
  }
  return { text: selected.join("\n"), omittedFields };
}

export function collectEvidence(incident: Incident, snapshot: GitSnapshot, input: unknown): Evidence {
  const source = record(input);
  requireCondition(typeof source.collectedAt === "string" && Number.isFinite(Date.parse(source.collectedAt)) && Array.isArray(source.items) && source.items.length <= 1000, "invalid-evidence-envelope");
  const end = Date.parse(source.collectedAt), start = Date.parse(incident.observation.observedAt) - 900_000;
  requireCondition(end >= start, "invalid-evidence-window");
  const evidence: Evidence = {
    revision: snapshot.revision, sourceRevision: incident.observation.revision, revisionMismatch: snapshot.revision !== incident.observation.revision,
    manifestHash: snapshot.manifestHash, hash: "", collectedAt: source.collectedAt, from: new Date(start).toISOString(),
    items: [], rules: [], omitted: [], redactions: 0, truncated: [], partial: false, bytes: 0,
  };
  const safeText = (value: string) => { const result = redact(value); evidence.redactions += result.count; return result.text; };
  const logLines = new Map<string, number>();
  for (const [index, raw] of source.items.entries()) {
    const item = record(raw);
    const id = typeof item.id === "string" && /^[a-zA-Z0-9_.-]{1,80}$/.test(item.id) ? item.id : `item-${index}`;
    const omit = (reason: string) => evidence.omitted.push({ id, reason });
    if (item.target !== incident.observation.target) { omit("unrelated-target"); continue; }
    const timestamp = typeof item.observedAt === "string" ? Date.parse(item.observedAt) : NaN;
    if (!Number.isFinite(timestamp) || timestamp < start || timestamp > end) { omit("outside-window-or-invalid-time"); continue; }
    if (!["state", "metrics", "events", "logs"].includes(String(item.kind))) { omit("unsupported-format"); continue; }
    if (evidence.items.some(i => i.id === id)) { omit("duplicate-evidence-id"); continue; }
    const selected: EvidenceItem = { id, kind: String(item.kind), target: String(item.target), observedAt: new Date(timestamp).toISOString(), data: null };
    if (item.kind === "logs") {
      const logs = typeof item.data === "string" ? selectLogs(item.data) : null;
      if (!logs || typeof item.container !== "string" || !/^[a-zA-Z0-9_.-]{1,80}$/.test(item.container)) { omit("unsupported-log-format"); continue; }
      evidence.redactions += logs.omittedFields;
      const previous = logLines.get(item.container) ?? 0;
      const lines = logs.text.split("\n");
      const selectedLines = lines.slice(0, Math.max(0, 200 - previous));
      if (selectedLines.length < lines.length) evidence.truncated.push(id);
      logLines.set(item.container, previous + selectedLines.length);
      selected.container = item.container; selected.data = safeText(selectedLines.join("\n"));
    } else {
      if (!item.data || typeof item.data !== "object" || Array.isArray(item.data)) { omit("unsupported-structured-format"); continue; }
      const fields = ["phase", "reason", "message", "condition", "status", "count", "exitCode", "metric", "value", "unit", "query"];
      const data: Record<string, unknown> = {};
      for (const [key, value] of Object.entries(record(item.data))) {
        if (!fields.includes(key)) { evidence.redactions++; continue; }
        if (typeof value === "string") data[key] = safeText(value);
        else if (typeof value === "number" && Number.isFinite(value) || typeof value === "boolean") data[key] = value;
        else evidence.redactions++;
      }
      selected.data = data;
    }
    evidence.items.push(selected);
    if (Buffer.byteLength(JSON.stringify(evidence)) > 240 * 1024) { evidence.items.pop(); omit("bundle-size-limit"); }
  }
  for (const entry of snapshot.entries.filter(e => e.path === "CONTEXT.md" || /^docs\/decisions\/[^/]+\.md$/.test(e.path))) {
    try {
      const text = snapshot.text(entry.path, 32 * 1024);
      if (text !== null) evidence.rules.push({ path: entry.path, blob: entry.blob, text: safeText(text) });
      if (Buffer.byteLength(JSON.stringify(evidence)) > 250 * 1024) { evidence.rules.pop(); evidence.omitted.push({ id: "git-rules", reason: "bundle-size-limit" }); }
    } catch { evidence.omitted.push({ id: "git-rules", reason: "unavailable-rule" }); }
  }
  evidence.partial = !!(evidence.omitted.length || evidence.truncated.length || evidence.revisionMismatch || !evidence.items.length);
  return sealEvidence(evidence);
}
