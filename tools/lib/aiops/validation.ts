import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync } from "node:fs";
import { parseAllDocuments } from "yaml";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { GitSnapshot, digest } from "./git.ts";
import { runProcess, STAGE_LIMITS } from "./process.ts";
import { AiopsError, requireCondition } from "./input.ts";

type Verdict = { status: "passed" | "failed" | "unverifiable"; reason?: string };
export type Validation = {
  baseline: { revision: string; manifestHash: string; budgetBlob: string | null };
  candidate: { revision: string; manifestHash: string; treeHash: string };
  patchHash: string; patch: string; changedPaths: string[]; policyChanged: boolean;
  ledger: { baselineBudget: number | null; candidateBudget: number | null; totalLimit: number | null; metadataChanged: boolean; fixed: Verdict; proposed: Verdict };
  checks: { name: string; status: string }[]; unverified: string[]; toolchain: { bun: string; conftest: string | null; bunHash: string; conftestHash: string | null; parserBlob: string | null; policyBlobs: string[]; checkerHash: string; helperHashes: Record<string, string>; dependencyLockHash: string };
};

// 프로즈의 예산 언급은 제외한다. 활성 메타 주석은 정확히 하나이고 상한도 정확히 하나여야 한다.
function budget(text: string | null): number | null {
  if (text === null) return null;
  const declarations = [...text.matchAll(/^\s*<!--\s*ledger:meta\b([^\n]*?)-->\s*$/gm)];
  if (declarations.length !== 1 || (text.match(/<!--\s*ledger:meta\b/g)?.length ?? 0) !== 1) return null;
  const values = [...declarations[0][1].matchAll(/\bLIMIT_BUDGET_MIB=([^\s]+)/g)];
  if (values.length !== 1 || !/^[1-9]\d*$/.test(values[0][1])) return null;
  const value = Number(values[0][1]);
  return Number.isSafeInteger(value) ? value : null;
}

export async function validateCandidate(baseline: GitSnapshot, candidate: GitSnapshot): Promise<Validation> {
  const patch = candidate.git(["diff", "--binary", "--no-ext-diff", "--no-textconv", baseline.revision, candidate.revision, "--"]);
  const baselineEntries = new Map(baseline.entries.map(e => [e.path, e]));
  const candidateEntries = new Map(candidate.entries.map(e => [e.path, e]));
  const changedPaths = [...new Set([...baselineEntries.keys(), ...candidateEntries.keys()])].filter(path => {
    const a = baselineEntries.get(path), b = candidateEntries.get(path); return a?.blob !== b?.blob || a?.mode !== b?.mode;
  }).sort();
  const baselineText = baseline.text("docs/memory-ledger.md");
  const candidateText = candidate.text("docs/memory-ledger.md");
  const baselineBudget = budget(baselineText), candidateBudget = budget(candidateText);
  const result: Validation = {
    baseline: { revision: baseline.revision, manifestHash: baseline.manifestHash, budgetBlob: baselineEntries.get("docs/memory-ledger.md")?.blob ?? null },
    candidate: { revision: candidate.revision, manifestHash: candidate.manifestHash, treeHash: candidate.git(["rev-parse", `${candidate.revision}^{tree}`]).trim() }, patchHash: digest(patch), patch, changedPaths,
    policyChanged: changedPaths.some(p => p.startsWith("policy/") || p.startsWith("scripts/check-") || p.startsWith("tools/lib/") || p.startsWith(".github/") || p.startsWith("docs/decisions/") || ["docs/memory-ledger.md", "AGENTS.md", "CONTEXT.md"].includes(p)),
    ledger: { baselineBudget, candidateBudget, totalLimit: null, metadataChanged: baselineBudget !== candidateBudget, fixed: { status: "unverifiable" }, proposed: { status: "unverifiable" } },
    checks: [], unverified: ["live-cluster", "encrypted-secrets", "terraform", "candidate-CI", "host-cgroup", "other-repository-gates"], toolchain: { bun: Bun.version, conftest: null, bunHash: digest(readFileSync(process.execPath)), conftestHash: null, parserBlob: baselineEntries.get("tools/lib/ledger-totals.ts")?.blob ?? null, policyBlobs: baseline.entries.filter(e => /^policy\/[^/]+\.rego$/.test(e.path)).map(e => e.blob), checkerHash: digest(readFileSync(import.meta.path)), helperHashes: Object.fromEntries(["git.ts", "input.ts", "process.ts", "../exec.ts"].map(path => [path, digest(readFileSync(join(import.meta.dir, path)))])), dependencyLockHash: digest(readFileSync(join(import.meta.dir, "../../../bun.lock"))) },
  };
  const scratch = mkdtempSync(join(tmpdir(), "aiops-validation-"));
  const deadline = Date.now() + STAGE_LIMITS.validate.milliseconds;
  let outputBytes = 0;
  const execute = async (command: string[]) => {
    requireCondition(Date.now() < deadline && outputBytes < STAGE_LIMITS.validate.bytes, "validation-stage-limit");
    const result = await runProcess(command, { cwd: scratch, timeoutMs: deadline - Date.now(), maxBytes: STAGE_LIMITS.validate.bytes - outputBytes, onStart: () => {} });
    outputBytes += result.bytes;
    return result;
  };
  try {
    for (const [index, path] of changedPaths.entries()) {
      if (!candidateEntries.has(path) || !/\.(?:json|yaml|yml|sh)$/.test(path)) continue;
      if (path.endsWith(".enc.yaml")) { result.checks.push({ name: `format:${path}`, status: "unverifiable" }); continue; }
      try {
        const text = candidate.text(path, 2 * 1024 * 1024)!;
        if (path.endsWith(".json")) JSON.parse(text);
        else if (/\.ya?ml$/.test(path)) {
          if (text.includes("{{")) { result.checks.push({ name: `format:${path}`, status: "unverifiable" }); continue; }
          requireCondition(parseAllDocuments(text).every(document => document.errors.length === 0), "candidate-yaml-invalid");
        } else {
          const name = `script-${index}.sh`; writeFileSync(join(scratch, name), text, { mode: 0o400 });
          // bash -n은 파싱만 한다. 후보 스크립트·hooks·CI는 자격 있는 프로세스에서 실행하지 않는다.
          const parsed = await execute(["/bin/bash", "--noprofile", "--norc", "-n", name]);
          requireCondition(parsed.status === "completed", "candidate-shell-invalid");
        }
        result.checks.push({ name: `format:${path}`, status: "passed" });
      } catch { result.checks.push({ name: `format:${path}`, status: "failed" }); }
    }
    if (baselineBudget === null) { result.ledger.fixed.reason = "invalid-baseline-budget-no-fallback"; return result; }
    if (candidateText === null) { result.ledger.fixed = { status: "failed", reason: "candidate-ledger-missing" }; return result; }
    const parser = baseline.text("tools/lib/ledger-totals.ts");
    requireCondition(parser !== null, "baseline-parser-missing");
    // 이 어댑터가 지원하는 파서 폐포는 단일 무의존 모듈이다. 새 의존은 침묵 상속하지 않는다.
    requireCondition(!/\b(?:import|require)\s*(?:\(|[{'"*])|\bexport\b[^\n]*\bfrom\s*['"]/.test(parser), "unsupported-parser-dependency-closure");
    writeFileSync(join(scratch, "parser.ts"), parser, { mode: 0o400 });
    writeFileSync(join(scratch, "candidate-ledger.md"), candidateText, { mode: 0o400 });
    writeFileSync(join(scratch, "parse.ts"), 'import { parseLedgerRows } from "./parser.ts";\nconst text = await Bun.file("candidate-ledger.md").text();\nconsole.log(JSON.stringify({rows:parseLedgerRows(text),markers:(text.match(/<!-- ledger:row -->/g) ?? []).length}));\n', { mode: 0o400 });
    const parsed = await execute([process.execPath, "parse.ts"]);
    requireCondition(parsed.status === "completed", "fixed-parser-failed");
    const input = JSON.parse(parsed.stdout) as { rows: { name: string; reqMi: number; limitMi: number }[]; markers: number };
    if (!Array.isArray(input.rows) || input.rows.length !== input.markers || input.rows.some(r => !Number.isSafeInteger(r.reqMi) || !Number.isSafeInteger(r.limitMi) || r.reqMi < 0 || r.limitMi < 0)) {
      result.ledger.fixed = { status: "failed", reason: "candidate-row-marker-or-number-invalid" }; return result;
    }
    result.ledger.totalLimit = input.rows.reduce((sum, r) => sum + r.limitMi, 0);
    const policies = baseline.entries.filter(e => /^policy\/[^/]+\.rego$/.test(e.path));
    requireCondition(policies.some(e => e.path === "policy/ledger.rego"), "baseline-policy-missing");
    mkdirSync(join(scratch, "policy"));
    for (const entry of policies) writeFileSync(join(scratch, entry.path), baseline.text(entry.path)!, { mode: 0o400 });
    const version = await execute(["conftest", "--version"]);
    requireCondition(version.status === "completed", "conftest-unavailable");
    result.toolchain.conftest = version.stdout.trim();
    const conftestPath = Bun.which("conftest");
    result.toolchain.conftestHash = conftestPath ? digest(readFileSync(conftestPath)) : null;
    const evaluate = async (limit: number): Promise<Verdict> => {
      // 후보 JSON을 재사용하지 않는다. 신뢰 상한과 검증된 후보 행으로 새 정책 입력을 만든다.
      writeFileSync(join(scratch, "input.json"), JSON.stringify({ budget: limit, rows: input.rows.map(r => ({ component: r.name, req: r.reqMi, limit: r.limitMi })) }), { mode: 0o600 });
      const check = await execute(["conftest", "test", "input.json", "--policy", "policy", "--output", "json"]);
      if (check.cleanup !== "confirmed" || !["completed", "failed"].includes(check.status)) return { status: "unverifiable", reason: check.status };
      const reports = JSON.parse(check.stdout) as { successes: number; failures?: unknown[] }[];
      if (!Array.isArray(reports) || !reports.length || reports.some(r => !Number.isSafeInteger(r.successes))) return { status: "unverifiable", reason: "invalid-policy-output" };
      return { status: check.exitCode === 0 && reports.every(r => !r.failures?.length) ? "passed" : "failed" };
    };
    result.ledger.fixed = await evaluate(baselineBudget);
    result.ledger.proposed = candidateBudget === null ? { status: "unverifiable", reason: "candidate-budget-invalid-or-missing" } : await evaluate(candidateBudget);
    result.checks.push({ name: "fixed-ledger", status: result.ledger.fixed.status });
  } catch (error) {
    result.ledger.fixed = { status: "unverifiable", reason: error instanceof AiopsError ? error.code : "trusted-check-unavailable-or-invalid" };
  } finally { rmSync(scratch, { recursive: true, force: true }); }
  return result;
}
