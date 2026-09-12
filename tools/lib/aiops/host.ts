import { chmodSync, existsSync, lstatSync, mkdirSync, readFileSync, writeFileSync, rmSync, mkdtempSync, statfsSync } from "node:fs";
import { join, resolve } from "node:path";
import { isolatedSpawnSync as spawnSync } from "../exec.ts";
import { digest } from "./git.ts";
import { readBounded, record, requireCondition } from "./input.ts";
import { runProcess, STAGE_LIMITS } from "./process.ts";
import type { ProcessResult } from "./process.ts";

export const ROLES = ["collector", "engine", "validator", "fork", "pr", "telegram"] as const;
export type Role = typeof ROLES[number];
const ROOT = "/var/lib/homelab-aiops", CODE = "/opt/homelab-aiops/current";
export function hostPlan(output: string) {
  const directory = resolve(output); mkdirSync(directory, { recursive: true, mode: 0o700 });
  const config = {
    mode: "codex", enabled: false, repository: `${ROOT}/repository`, revision: null,
    installation: { code: CODE, bun: "/opt/homelab-aiops/bin/bun", engine: "/opt/homelab-aiops/bin/codex", conftest: "/opt/homelab-aiops/bin/conftest", hashes: {} },
    authentication: `${ROOT}/auth`, readinessFile: "/etc/homelab-aiops/acceptance.json",
    ingress: { address: "127.0.0.1", port: 21980, tokens: { alertmanager: "/etc/homelab-aiops/collector/alertmanager", argocd: "/etc/homelab-aiops/collector/argocd", cnpg: "/etc/homelab-aiops/collector/cnpg" } },
    github: { repository: "ukyi-app/homelab", repositoryId: null, readTokenFile: "/etc/homelab-aiops/collector/github" },
    healthchecks: { readKeyFile: "/etc/homelab-aiops/collector/healthchecks", keyAccess: "read-only" },
    publication: { upstream: "ukyi-app/homelab", upstreamId: null, fork: null, forkId: null, base: "main", forkTokenFile: "/etc/homelab-aiops/fork/token", prTokenFile: "/etc/homelab-aiops/pr/token" },
    telegram: { tokenFile: "/etc/homelab-aiops/telegram/token", chatId: null },
    collection: { kubectl: "/usr/bin/kubectl", kubeconfig: "/etc/homelab-aiops/collector/kubeconfig", metricsUrl: null, logsUrl: null },
    model: "gpt-6-astra", observation: { days: 14, minimumCases: null, requiredSources: null, qualityCriteria: null, manualBaseline: null },
  };
  writeFileSync(join(directory, "config.example.json"), JSON.stringify(config, null, 2) + "\n", { mode: 0o600 });
  writeFileSync(join(directory, "aiops-worker.service"), `[Unit]\nDescription=Homelab AIOps bounded coordinator\nAfter=network-online.target\nWants=network-online.target\nOnFailure=unit-failure-notify@%n.service\n\n[Service]\nType=exec\nExecStart=${CODE}/bin/bun ${CODE}/tools/aiops.ts worker --state-dir ${ROOT}/state --config /etc/homelab-aiops/config.json\nRuntimeMaxSec=1200\nTimeoutStopSec=10\nKillMode=control-group\nMemoryMax=512M\nTasksMax=128\nCPUQuota=200%\nUMask=0077\nLimitCORE=0\nStandardOutput=journal\nStandardError=journal\n`, { mode: 0o644 });
  writeFileSync(join(directory, "aiops-worker.timer"), "[Unit]\nDescription=Homelab AIOps admission tick\n\n[Timer]\nOnBootSec=120\nOnUnitInactiveSec=60\nUnit=aiops-worker.service\n\n[Install]\nWantedBy=timers.target\n", { mode: 0o644 });
  writeFileSync(join(directory, "aiops-ingress.service"), `[Unit]\nDescription=Homelab AIOps authenticated ingress\nAfter=network-online.target\nOnFailure=unit-failure-notify@%n.service\n\n[Service]\nType=exec\nUser=aiops-collector\nGroup=aiops-state\nExecStart=${CODE}/bin/bun ${CODE}/tools/aiops.ts serve --state-dir ${ROOT}/state --config /etc/homelab-aiops/collector.json\nRestart=on-failure\nRestartSec=10\nTimeoutStopSec=10\nMemoryMax=256M\nTasksMax=64\nCPUQuota=100%\nProtectSystem=strict\nProtectHome=true\nReadWritePaths=${ROOT}/state\nNoNewPrivileges=true\nPrivateTmp=true\nUMask=0007\n\n[Install]\nWantedBy=multi-user.target\n`, { mode: 0o644 });
  writeFileSync(join(directory, "sysusers.conf"), `g aiops-state -\n${ROLES.map(role => `u aiops-${role} - "AIOps ${role}" ${role === "engine" ? `${ROOT}/auth` : "/nonexistent"} /usr/sbin/nologin`).join("\n")}\nm aiops-collector aiops-state\n`, { mode: 0o644 });
  writeFileSync(join(directory, "tmpfiles.conf"), `d ${ROOT} 0711 root root -\nd ${ROOT}/state 2770 root aiops-state -\nd ${ROOT}/auth 0700 aiops-engine aiops-engine -\nd ${ROOT}/work 0711 root root -\nd /etc/homelab-aiops 0711 root root -\n${ROLES.map(role => `d /etc/homelab-aiops/${role} 0700 aiops-${role} aiops-${role} -`).join("\n")}\n`, { mode: 0o644 });
  return { activation: "disabled", roles: ROLES, limits: { stages: STAGE_LIMITS, wholeAttemptSeconds: 1200, diskMiB: 512 }, directory };
}

function protectedFile(path: string): boolean {
  try { const info = lstatSync(path); return info.isFile() && !info.isSymbolicLink() && info.uid === 0 && (info.mode & 0o022) === 0; } catch { return false; }
}
export function readiness(input: unknown) {
  const config = record(input), pending: string[] = [];
  const installation = record(config.installation), hashes = record(installation.hashes);
  for (const name of ["bun", "engine", "conftest"]) {
    const path = String(installation[name]);
    if (!protectedFile(path) || hashes[name] !== digest(existsSync(path) ? readFileSync(path) : "")) pending.push(`pinned-${name}`);
  }
  const auth = String(config.authentication);
  if (!existsSync(join(auth, "auth.json"))) pending.push("subscription-authentication");
  try {
    const mount = spawnSync("/usr/bin/findmnt", ["--mountpoint", ROOT, "--noheadings", "--output", "TARGET"], { encoding: "utf8", timeout: 5000, maxBuffer: 4096, env: { PATH: "/usr/bin:/bin" } });
    const filesystem = statfsSync(ROOT);
    if (mount.status !== 0 || mount.stdout.trim() !== ROOT || filesystem.blocks * filesystem.bsize > 512 * 1024 * 1024 || filesystem.bavail * filesystem.bsize < 32 * 1024 * 1024) pending.push("bounded-storage");
  } catch { pending.push("bounded-storage"); }
  const evidenceFile = String(config.readinessFile);
  let acceptance: Record<string, unknown> = {};
  if (protectedFile(evidenceFile)) { try { acceptance = record(JSON.parse(readBounded(evidenceFile))); } catch { /* 읽지 못한 수용 증거는 통과로 바꾸지 않는다. */ } }
  for (const name of ["isolation", "roles", "cgroup", "producerDelivery", "subscription", "forkActionsDisabled", "publication", "diagnosticCases"]) {
    const proof = acceptance[name];
    if (!proof || typeof proof !== "object" || record(proof).passed !== true || record(proof).revision !== config.revision || record(proof).engineHash !== hashes.engine || !Number.isFinite(Date.parse(String(record(proof).checkedAt))) || Date.now() - Date.parse(String(record(proof).checkedAt)) > 30 * 86400_000 || Date.parse(String(record(proof).checkedAt)) > Date.now()) pending.push(`acceptance-${name}`);
  }
  const observation = record(config.observation);
  if (!(Number.isSafeInteger(observation.minimumCases) && Number(observation.minimumCases) > 0 && Array.isArray(observation.requiredSources) && observation.requiredSources.length === 5 && typeof observation.qualityCriteria === "string" && observation.qualityCriteria && typeof observation.manualBaseline === "string" && observation.manualBaseline)) pending.push("observation-criteria");
  if (typeof config.revision !== "string" || !/^[a-f0-9]{40}$/.test(config.revision)) pending.push("trusted-revision");
  return { ready: pending.length === 0, pending, enabled: config.enabled === true };
}

function systemctl(args: string[]) {
  return spawnSync("/usr/bin/systemctl", args, { encoding: "utf8", timeout: 15_000, maxBuffer: 64 * 1024, env: { PATH: "/usr/bin:/bin", LANG: "C.UTF-8" } });
}
export function cleanUnit(unit: string): boolean {
  requireCondition(/^aiops-(?:collector|engine|validator|fork|pr|telegram)-[a-f0-9]{32}\.service$/.test(unit), "invalid-stage-unit");
  systemctl(["stop", unit]);
  const result = systemctl(["show", unit, "--property=LoadState,ActiveState,ControlGroup", "--no-pager"]);
  if (result.status !== 0) return false;
  const properties = Object.fromEntries(result.stdout.trim().split("\n").map(line => line.split("=")));
  if (properties.LoadState === "not-found") return true;
  if (!["inactive", "failed"].includes(properties.ActiveState)) return false;
  const cgroup = properties.ControlGroup;
  if (!cgroup) return true;
  if (cgroup !== `/system.slice/${unit}`) return false;
  try { return /^populated 0$/m.test(readFileSync(`/sys/fs/cgroup${cgroup}/cgroup.events`, "utf8")); }
  catch (error) { return (error as NodeJS.ErrnoException).code === "ENOENT"; }
}

// 감독자는 worker 밖에서 종료 한도와 cgroup 정리를 집행한다. 작업 이름은 실행 전에 영속화한다.
export async function runHostStage(options: { role: Role; stage: keyof typeof STAGE_LIMITS; command: string[]; writable: string; readable: string[]; deadline: number; onUnit: (unit: string) => void; probe?: boolean }): Promise<ProcessResult & { unit: string }> {
  requireCondition(process.getuid?.() === 0 && ROLES.includes(options.role), "host-coordinator-root-required");
  const limits = STAGE_LIMITS[options.stage], milliseconds = Math.min(limits.milliseconds, options.deadline - Date.now());
  requireCondition(milliseconds > 0, "whole-attempt-timeout");
  const unit = `aiops-${options.role}-${crypto.randomUUID().replaceAll("-", "")}.service`;
  options.onUnit(unit);
  const properties = ["Type=exec", `User=aiops-${options.role}`, `Group=aiops-${options.role}`, `RuntimeMaxSec=${Math.ceil(milliseconds / 1000)}`, "TimeoutStopSec=10", "KillMode=control-group", "SendSIGKILL=yes", `MemoryMax=${limits.memoryMiB}M`, "MemorySwapMax=0", "CPUQuota=200%", "TasksMax=128", "OOMPolicy=kill", "LimitCORE=0", `LimitFSIZE=${limits.bytes}`, "UMask=0077", "ProtectSystem=strict", "ProtectHome=true", "NoNewPrivileges=true", "PrivateDevices=true", "TemporaryFileSystem=/tmp:rw,size=256M,mode=1777", `ReadWritePaths=${options.writable}`, ...options.readable.map(path => `ReadOnlyPaths=${path}`)];
  if (options.probe) properties.push("DynamicUser=yes");
  let result: ProcessResult;
  try {
    result = await runProcess(["/usr/bin/systemd-run", "--quiet", "--wait", "--pipe", `--unit=${unit}`, `--setenv=PATH=${resolve(options.command[0], "..")}:/usr/bin:/bin`, ...properties.flatMap(property => ["--property", property]), "--", ...options.command], { timeoutMs: milliseconds + 10_000, maxBytes: limits.bytes, onStart: () => {} });
  } catch {
    result = { status: "stage-start-failed", exitCode: null, bytes: 0, stdout: "", cleanup: "unknown", confinement: "process-group", unverified: [] };
  }
  const completion = systemctl(["show", unit, "--property=Result", "--value"]).stdout.trim();
  if (completion === "oom-kill") result.status = "oom";
  if (completion === "timeout") result.status = "timeout";
  const clean = cleanUnit(unit);
  if (clean) systemctl(["reset-failed", unit]);
  return { ...result, unit, cleanup: clean ? "confirmed" : "unknown", status: clean ? result.status : "cleanup-unknown", confinement: "systemd-cgroup", unverified: [] };
}

export async function probeHost() {
  requireCondition(process.getuid?.() === 0, "host-probe-requires-sudo");
  const directory = mkdtempSync("/run/aiops-probe-"); chmodSync(directory, 0o755);
  const output = join(directory, "output"); mkdirSync(output, { mode: 0o777 }); chmodSync(output, 0o777);
  const mock = join(directory, "mock-credential"); writeFileSync(mock, crypto.randomUUID(), { mode: 0o600 });
  const units: string[] = [], checks: Record<string, boolean> = {};
  const run = async (program: string, seconds: number) => {
    const path = join(directory, `probe-${units.length}.py`); writeFileSync(path, program, { mode: 0o444 });
    return runHostStage({ role: "engine", stage: "collect", command: ["/usr/bin/python3", path], readable: [path, mock], writable: output, deadline: Date.now() + seconds * 1000, probe: true, onUnit: unit => units.push(unit) });
  };
  try {
    const positive = await run(`import os,json\nopen(${JSON.stringify(join(output, "positive"))},'w').write('ok')\ntry:\n open(${JSON.stringify(mock)}).read(); denied=False\nexcept PermissionError: denied=True\nprint(json.dumps({'uid':os.getuid()!=0,'credentialDenied':denied}))\n`, 10);
    let proof: Record<string, unknown> = {};
    try { proof = JSON.parse(positive.stdout); } catch { /* 허용 대조군을 읽지 못하면 실패다. */ }
    checks.role = positive.status === "completed" && proof.uid === true && proof.credentialDenied === true;
    const timeout = await run("import os,signal,time\npid=os.fork()\nif pid==0:\n os.setsid();signal.signal(signal.SIGTERM,signal.SIG_IGN)\nwhile True:time.sleep(1)\n", 2);
    checks.timeoutAndEscapedChild = timeout.status === "timeout" && timeout.cleanup === "confirmed";
    const oom = await run("chunks=[]\nwhile True: chunks.append(bytearray(32*1024*1024))\n", 10);
    checks.oom = oom.status === "oom" && oom.cleanup === "confirmed";
    const flood = await run("import os\nwhile True:os.write(1,b'x'*65536)\n", 10);
    checks.output = flood.status === "output-limit" && flood.cleanup === "confirmed";
    return { ready: Object.values(checks).every(Boolean), checks, checkedAt: new Date().toISOString(), scope: "mock-systemd-cgroup-no-subscription-no-publication", units };
  } finally {
    if (units.map(cleanUnit).every(Boolean)) rmSync(directory, { recursive: true, force: true });
  }
}
