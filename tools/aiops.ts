// AIOps 전용 진입점 — 운영 변이 동사를 노출하는 homelab MCP와 분리한다.
import { parseCommand, typedFlags } from "./lib/cli.ts";
import { Incidents } from "./lib/aiops/incidents.ts";
import { AiopsError, observationInput, readBounded } from "./lib/aiops/input.ts";
import { applyCandidate, GitSnapshot } from "./lib/aiops/git.ts";
import { collectEvidence } from "./lib/aiops/evidence.ts";
import { validateCandidate } from "./lib/aiops/validation.ts";
import { diagnose } from "./lib/aiops/diagnosis.ts";
import { requireCondition } from "./lib/aiops/input.ts";
import { probeIsolation } from "./lib/aiops/permissions.ts";
import { serveIncidents } from "./lib/aiops/ingress.ts";
import { pollHealthchecks } from "./lib/aiops/healthchecks.ts";
import { pollGithub } from "./lib/aiops/github.ts";
import { publishIncident } from "./lib/aiops/publication.ts";
import { hostPlan, readiness, probeHost } from "./lib/aiops/host.ts";
import { collectLive } from "./lib/aiops/collection.ts";
import { worker } from "./lib/aiops/worker.ts";
import { producerPlan } from "./lib/aiops/wiring.ts";
import { evaluateCases } from "./lib/aiops/evaluation.ts";

if (process.argv.slice(2).includes("--help")) {
  console.log(`usage: bun tools/aiops.ts <command> --state-dir <directory> [options]
incident: ingest --input | list | show --incident | replay [--incident] | recover | resume --incident
evidence: collect --incident --input --repo --revision | collect-live --incident --config --repo --revision
diagnosis: diagnose --incident --repo --revision --engine --mode replay [--model]
validation: validate --incident --repo --revision [--candidate]
sources: serve --config | poll-gha --config | poll-healthchecks --config
publication: publish --incident --config --repo (replay only; live uses isolated worker)
host: host-plan --output | producer-plan --repo --output --address | readiness --config | probe-isolation --engine | probe-host | worker --config
commission: commission --config --incident [--input selected-evidence.json] (one live acceptance case, activation disabled)
retention: prune [--at]
evaluation: evaluate --cases --answers --reports
observation: observation-start --config | observation-record --input | observation-summary
JSON operation results may contain deferred/unverifiable states even when exit is 0.`);
  process.exit(0);
}

let parsing = true;
try {
  const commandFlags: Record<string, string[]> = { ingest: ["--input"], replay: ["--incident", "--at", "--engine", "--timeout-ms"], show: ["--incident"], list: [], recover: [], collect: ["--incident", "--input", "--repo", "--revision"], validate: ["--incident", "--repo", "--revision", "--candidate"], diagnose: ["--incident", "--repo", "--revision", "--engine", "--mode", "--model"], "probe-isolation": ["--engine"], serve: ["--config"] };
  commandFlags["poll-healthchecks"] = ["--config"];
  commandFlags["poll-gha"] = ["--config"];
  commandFlags.publish = ["--incident", "--config", "--repo"];
  commandFlags["host-plan"] = ["--output"];
  commandFlags.readiness = ["--config"];
  commandFlags["collect-live"] = ["--incident", "--repo", "--revision", "--config"];
  commandFlags.worker = ["--config"];
  commandFlags.commission = ["--config", "--incident", "--input"];
  commandFlags.resume = ["--incident"];
  commandFlags.prune = ["--at"];
  commandFlags["producer-plan"] = ["--repo", "--output", "--address"];
  commandFlags["probe-host"] = [];
  commandFlags.evaluate = ["--cases", "--answers", "--reports"];
  commandFlags["observation-start"] = ["--config"];
  commandFlags["observation-record"] = ["--input"];
  commandFlags["observation-summary"] = [];
  const { path, rest } = parseCommand(process.argv.slice(2), Object.fromEntries(Object.keys(commandFlags).map(key => [key, null])));
  const flags = typedFlags(rest, { value: ["--state-dir", ...commandFlags[path[0]]], bool: [] });
  const required = (name: string) => { const value = flags.str(name); if (!value) throw new AiopsError("required-option-missing"); return value; };
  parsing = false;
  const observation = path[0] === "ingest" ? observationInput(JSON.parse(readBounded(required("--input")))) : null;
  // root 사전 점검이 DB/WAL을 먼저 만들어도 collector가 같은 그룹으로 쓸 수 있다.
  process.umask(0o007);
  using incidents = new Incidents(required("--state-dir"));
  if (path[0] === "resume") {
    console.log(JSON.stringify({ incident: incidents.resume(required("--incident")) }));
  } else if (path[0] === "observation-start") {
    console.log(JSON.stringify({ observation: incidents.observationStart(JSON.parse(readBounded(required("--config")))) }));
  } else if (path[0] === "observation-record") {
    console.log(JSON.stringify({ observation: incidents.observationRecord(JSON.parse(readBounded(required("--input")))) }));
  } else if (path[0] === "observation-summary") {
    console.log(JSON.stringify({ observation: incidents.observationSummary() }));
  } else if (path[0] === "evaluate") {
    const result = evaluateCases(required("--cases"), required("--answers"), required("--reports"));
    console.log(JSON.stringify(result)); if (result.quality === "unverified") process.exitCode = 1;
  } else if (path[0] === "probe-host") {
    const result = await probeHost(); console.log(JSON.stringify(result)); if (!result.ready) process.exitCode = 1;
  } else if (path[0] === "producer-plan") {
    console.log(JSON.stringify(producerPlan(required("--repo"), required("--output"), required("--address"))));
  } else if (path[0] === "prune") {
    console.log(JSON.stringify({ retention: incidents.prune(flags.str("--at") ?? new Date().toISOString()) }));
  } else if (["worker", "commission"].includes(path[0])) {
    const commissioning = path[0] === "commission" ? { incident: required("--incident"), ...(flags.str("--input") ? { evidence: JSON.parse(readBounded(required("--input"), 2 * 1024 * 1024)) } : {}) } : undefined;
    console.log(JSON.stringify(await worker(incidents, JSON.parse(readBounded(required("--config"))), required("--state-dir"), commissioning)));
  } else if (path[0] === "collect-live") {
    const id = required("--incident"), snapshot = new GitSnapshot(required("--repo"), required("--revision"));
    const evidence = await collectLive(incidents.get(id), snapshot, JSON.parse(readBounded(required("--config"))));
    console.log(JSON.stringify({ incident: incidents.attachEvidence(id, evidence) }));
  } else if (path[0] === "host-plan") {
    console.log(JSON.stringify(hostPlan(required("--output"))));
  } else if (path[0] === "readiness") {
    const result = readiness(JSON.parse(readBounded(required("--config"))));
    console.log(JSON.stringify(result)); if (!result.ready) process.exitCode = 1;
  } else if (path[0] === "publish") {
    console.log(JSON.stringify({ incident: await publishIncident(incidents, required("--incident"), JSON.parse(readBounded(required("--config"))), flags.str("--repo")) }));
  } else if (path[0] === "poll-gha") {
    await pollGithub(incidents, JSON.parse(readBounded(required("--config"))));
    const source = incidents.sources().gha;
    console.log(JSON.stringify({ source }));
    if (source.status !== "observed") process.exitCode = 1;
  } else if (path[0] === "poll-healthchecks") {
    await pollHealthchecks(incidents, JSON.parse(readBounded(required("--config"))));
    const source = incidents.sources().healthchecks;
    console.log(JSON.stringify({ source }));
    if (source.status !== "observed") process.exitCode = 1;
  } else if (path[0] === "serve") {
    const server = serveIncidents(incidents, JSON.parse(readBounded(required("--config"))));
    console.log(JSON.stringify({ listening: server.url.toString().replace(/\/$/, "") }));
    await new Promise<void>(resolve => {
      const stop = () => { server.stop(true); resolve(); };
      process.once("SIGTERM", stop); process.once("SIGINT", stop);
    });
  } else if (path[0] === "probe-isolation") {
    const readiness = await probeIsolation(required("--engine"));
    console.log(JSON.stringify({ readiness }));
    if (!readiness.ready) process.exitCode = 1;
  } else if (path[0] === "list") {
    const list = incidents.list();
    console.log(JSON.stringify({ incidents: list, observationStatus: list.length ? "observed" : "no-observations", budget: incidents.budget(), sources: incidents.sources() }));
  } else if (path[0] === "diagnose") {
    const id = required("--incident"), mode = required("--mode");
    requireCondition(mode === "replay", "live-readiness-required");
    const evidence = incidents.get(id).evidence;
    requireCondition(evidence, "needs-evidence");
    const snapshot = new GitSnapshot(required("--repo"), required("--revision"));
    const engine = required("--engine");
    const run = incidents.reserve(id, mode, new Date().toISOString());
    const result = await diagnose(evidence, snapshot, { mode, engine, model: flags.str("--model", "simulated")!, onStart: identity => incidents.bindProcess(run, identity) });
    console.log(JSON.stringify({ incident: incidents.finishReport(run, result.status, result.report) }));
  } else if (path[0] === "validate") {
    const baseline = new GitSnapshot(required("--repo"), required("--revision"));
    const patch = incidents.get(required("--incident")).report?.patch;
    const prepared = flags.str("--candidate") ? null : applyCandidate(baseline, patch ?? "");
    try {
      const candidate = prepared?.snapshot ?? new GitSnapshot(required("--repo"), required("--candidate"));
      const validation = await validateCandidate(baseline, candidate);
      console.log(JSON.stringify({ incident: incidents.attachValidation(required("--incident"), validation) }));
    } finally { prepared?.dispose(); }
  } else if (path[0] === "collect") {
    const id = required("--incident");
    const evidence = collectEvidence(incidents.get(id), new GitSnapshot(required("--repo"), required("--revision")), JSON.parse(readBounded(required("--input"), 2 * 1024 * 1024)));
    console.log(JSON.stringify({ incident: incidents.attachEvidence(id, evidence) }));
  } else {
    const incident = path[0] === "recover" ? await incidents.recover() : observation ? incidents.ingest(observation)
      : path[0] === "replay" ? await incidents.replay(flags.str("--incident") ?? incidents.next(flags.str("--at") ?? new Date().toISOString()), flags.str("--at"), flags.str("--engine"), flags.str("--timeout-ms") === undefined ? undefined : Number(flags.str("--timeout-ms"))) : incidents.get(required("--incident"));
    console.log(JSON.stringify({ incident }));
  }
} catch (error) {
  // 원문 입력·경로·자격이 오류 응답에 섞이지 않게 고정 문구만 방출한다.
  console.error(JSON.stringify({ error: error instanceof AiopsError ? error.code : "aiops-command-failed" }));
  process.exitCode = parsing || error instanceof AiopsError && error.code === "required-option-missing" ? 2 : 1;
}
