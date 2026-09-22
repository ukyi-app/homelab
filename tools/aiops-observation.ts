// GHA 완료 결과를 선별한다. Telegram 조건과 독립적이며 원문 출력은 artifact에 싣지 않는다.
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname } from "node:path";
import { typedFlags } from "./lib/cli.ts";
import { readProvenance } from "./lib/aiops-provenance.ts";

// 생산자는 별도 실행기 패키지에 의존하지 않는다. 잘못된 관측은 산출물로 쓰지 않는다.
function requireCondition(condition: unknown, code: string): asserts condition {
  if (!condition) throw new Error(code);
}
function record(value: unknown): Record<string, unknown> {
  requireCondition(value !== null && typeof value === "object" && !Array.isArray(value), "invalid-object");
  return value as Record<string, unknown>;
}

type State = ["healthy" | "warning" | "unobservable", boolean];
try {
  const output = typedFlags(process.argv.slice(2), { value: ["--output"], bool: [] }).str("--output");
  requireCondition(output, "output-required");
  const producer = process.env.AIOPS_PRODUCER ?? "", target = process.env.AIOPS_TARGET ?? "";
  requireCondition(/^[a-z_-]+\.yaml\/[a-zA-Z0-9_-]+$/.test(producer) && /^[a-zA-Z0-9][a-zA-Z0-9_./:@+-]{0,255}$/.test(target), "invalid-observation-identity");
  // 출처는 checkout 직후 캡처된 값만 받는다 — 관측 시점 주변 HEAD를 다시 읽지 않는다(제안 커밋 오결합 차단).
  const provenance = readProvenance(process.env);
  const contractBytes = readFileSync(new URL("./aiops-producers-v1.json", import.meta.url));
  const contract = record(JSON.parse(contractBytes.toString("utf8")));
  requireCondition(contract.version === 1 && typeof record(record(contract.producers)[producer]).workflow === "string", "unknown-producer-contract");
  const contractSha256 = createHash("sha256").update(contractBytes).digest("hex");
  const steps = record(JSON.parse(process.env.AIOPS_STEPS ?? "{}")), needs = record(JSON.parse(process.env.AIOPS_NEEDS ?? "{}"));
  const step = (name: string) => record(steps[name] ?? {}), outputs = (name: string) => record(step(name).outputs ?? {});
  const classify = (): State => {
    if (Object.keys(needs).length) {
      const results = Object.values(needs).map(value => record(value).result);
      if (results.includes("failure")) return ["warning", false];
      return results.every(value => value === "success") ? ["healthy", true] : ["unobservable", false];
    }
    if (process.env.AIOPS_JOB_RESULT === "failure") return ["warning", false];
    if (process.env.AIOPS_JOB_RESULT !== "success") return ["unobservable", false];
    if (producer.startsWith("tf-reconcile.yaml/") && !producer.endsWith("/accounting")) {
      const value = outputs("drift").drift;
      return step("drift").outcome === "success" && ["true", "false"].includes(String(value)) ? [value === "true" ? "warning" : "healthy", true] : ["unobservable", false];
    }
    if (producer === "credential-expiry.yaml/check") {
      const value = outputs("exp").rc;
      return step("exp").outcome === "success" && ["0", "1"].includes(String(value)) ? [value === "1" ? "warning" : "healthy", true] : ["unobservable", false];
    }
    let numeric: [string, string[], string[]] | undefined;
    if (producer === "dns-drift.yaml/check") numeric = ["check", ["count"], ["transient"]];
    else if (producer === "audit.yaml/audit") numeric = ["audit", ["alerting"], []];
    else if (producer === "contract-drift.yaml/check") numeric = ["check", ["drift", "errors"], ["transient"]];
    else if (producer.endsWith("/accounting")) numeric = ["acct", ["warnings"], []];
    if (numeric) {
      const [name, warnings, partial] = numeric, values = outputs(name);
      if (step(name).outcome !== "success" || [...warnings, ...partial].some(key => !/^\d+$/.test(String(values[key] ?? "")) || !Number.isSafeInteger(Number(values[key])))) return ["unobservable", false];
      const incomplete = partial.some(key => Number(values[key]) > 0);
      if (warnings.some(key => Number(values[key]) > 0)) return ["warning", !incomplete];
      return incomplete ? ["unobservable", false] : ["healthy", true];
    }
    return process.env.AIOPS_PRIMARY && step(process.env.AIOPS_PRIMARY).outcome === "success" ? ["healthy", true] : ["unobservable", false];
  };
  const [status, completed] = classify();
  // revision=검사 코드 출처 · runHeadSha=실행 HEAD · proposalRevision=제안 커밋(별도 축, 있으면).
  const value: Record<string, unknown> = { version: 1, contractVersion: 1, contractSha256, producer, check: producer.replace("/", ":"), target, repository: process.env.GITHUB_REPOSITORY, runId: Number(process.env.GITHUB_RUN_ID), attempt: Number(process.env.GITHUB_RUN_ATTEMPT), revision: provenance.sourceRevision, runHeadSha: process.env.GITHUB_SHA, ...(provenance.proposalRevision === undefined ? {} : { proposalRevision: provenance.proposalRevision }), observedAt: new Date().toISOString(), status, completed };
  requireCondition(Number.isSafeInteger(value.runId) && Number(value.runId) > 0 && Number.isSafeInteger(value.attempt) && Number(value.attempt) > 0, "invalid-run-identity");
  if (producer === "dns-drift.yaml/check" && outputs("check").observations !== undefined && step("check").outcome === "success") {
    const raw = JSON.parse(String(outputs("check").observations));
    requireCondition(Array.isArray(raw) && raw.length > 0 && raw.length <= 1000, "invalid-target-observations");
    const selected = raw.map(record).map(observation => {
      requireCondition(/^[a-zA-Z0-9.-]{1,253}$/.test(String(observation.target)) && ["healthy", "warning", "unobservable"].includes(String(observation.status)) && typeof observation.completed === "boolean", "invalid-target-observation");
      return { target: observation.target, status: observation.status, completed: observation.completed };
    });
    requireCondition(new Set(selected.map(item => item.target)).size === selected.length, "duplicate-target-observation");
    value.observations = selected;
  }
  const text = JSON.stringify(value) + "\n"; requireCondition(Buffer.byteLength(text) <= 256 * 1024, "observation-too-large");
  mkdirSync(dirname(output), { recursive: true }); writeFileSync(`${output}.tmp`, text, { mode: 0o600 }); renameSync(`${output}.tmp`, output);
} catch {
  console.error("AIOps observation invalid or not written"); process.exitCode = 1;
}
