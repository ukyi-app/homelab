import { isolatedSpawn as spawn } from "../exec.ts";
import { readFileSync, readdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { requireCondition } from "./input.ts";

export const STAGE_LIMITS = {
  collect: { milliseconds: 120_000, memoryMiB: 512, bytes: 1024 * 1024 },
  codex: { milliseconds: 600_000, memoryMiB: 2048, bytes: 8 * 1024 * 1024 },
  validate: { milliseconds: 300_000, memoryMiB: 2048, bytes: 8 * 1024 * 1024 },
  publish: { milliseconds: 60_000, memoryMiB: 256, bytes: 1024 * 1024 },
} as const;
export type ProcessIdentity = { pid: number; start: string; boot: string };
export type ProcessResult = { status: string; exitCode: number | null; bytes: number; stdout: string; failureHint?: "authentication" | "capacity"; cleanup: "confirmed" | "unknown"; confinement: "process-group" | "systemd-cgroup"; unverified: string[] };
export function processIdentity(pid: number): ProcessIdentity {
  const stat = readFileSync(`/proc/${pid}/stat`, "utf8").split(") ")[1].split(" ");
  return { pid, start: stat[19], boot: readFileSync("/proc/sys/kernel/random/boot_id", "utf8").trim() };
}
export function sameProcess(identity: ProcessIdentity): boolean {
  try { const current = processIdentity(identity.pid); return current.boot === identity.boot && current.start === identity.start; }
  catch (error) { if (["ENOENT", "ESRCH"].includes((error as NodeJS.ErrnoException).code ?? "")) return false; throw error; }
}
export async function recoverGroup(identity: ProcessIdentity): Promise<boolean> {
  if (readFileSync("/proc/sys/kernel/random/boot_id", "utf8").trim() !== identity.boot) return true;
  if (sameProcess(identity)) return stopGroup(identity.pid);
  // PID가 재사용됐거나 주인이 사라진 그룹은 함부로 죽이지 않는다.
  return !liveGroup(identity.pid);
}
function liveGroup(pid: number): boolean {
  // 좀비는 실행이 종료된 상태다. 살아 있는 자식의 유무는 프로세스 그룹 전체에서 확인한다.
  for (const name of readdirSync("/proc")) {
    if (!/^\d+$/.test(name)) continue;
    try {
      const stat = readFileSync(`/proc/${name}/stat`, "utf8").split(") ")[1].split(" ");
      if (Number(stat[2]) === pid && stat[0] !== "Z" && stat[0] !== "X") return true;
    } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT" && (error as NodeJS.ErrnoException).code !== "ESRCH") throw error; }
  }
  return false;
}
export async function stopGroup(pid: number): Promise<boolean> {
  const signal = (name: NodeJS.Signals) => { try { process.kill(-pid, name); } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error; } };
  try {
    signal("SIGTERM");
    // 로컬 재현은 250ms 뒤 KILL한다. 운영 cgroup은 systemd의 10초 외부 정리를 사용한다.
    await Bun.sleep(250);
    signal("SIGKILL");
    for (let count = 0; count < 50; count++) { if (!liveGroup(pid)) return true; await Bun.sleep(20); }
  } catch { return false; }
  return false;
}

// 로컬 재현용 프로세스 경계. 메모리·CPU·setsid 탈출 차단은 운영 cgroup 수용과 구별한다.
export async function runProcess(command: string[], options: { timeoutMs: number; maxBytes: number; onStart: (identity: ProcessIdentity) => void; cwd?: string; engineEnvironment?: { CODEX_HOME?: string; AIOPS_BOUNDARY_CANARY?: string } }): Promise<ProcessResult> {
  requireCondition(command.length > 0 && options.timeoutMs > 0 && options.maxBytes > 0, "invalid-process-limits");
  const environmentRoot = mkdtempSync(join(tmpdir(), "aiops-process-"));
  const child = spawn(command[0], command.slice(1), {
    cwd: options.cwd,
    env: { PATH: process.env.PATH, LANG: "C.UTF-8", XDG_DATA_HOME: environmentRoot, XDG_CONFIG_HOME: environmentRoot, XDG_CACHE_HOME: environmentRoot, ...options.engineEnvironment },
  });
  let reason = "completed", bytes = 0, stdout = "", diagnosticTail = "";
  let failureHint: ProcessResult["failureHint"];
  let stopping: Promise<boolean> | undefined;
  const stop = (why: string) => { if (!stopping && child.pid) { reason = why; stopping = stopGroup(child.pid); } };
  const timer = setTimeout(() => stop("timeout"), options.timeoutMs);
  const interrupt = () => stop("cancelled");
  process.once("SIGTERM", interrupt); process.once("SIGINT", interrupt);
  const exited = new Promise<number | null>(resolve => {
    child.once("error", () => { reason = "start-failed"; resolve(null); });
    child.once("exit", code => resolve(code));
  });
  const consume = (chunk: Buffer, capture: boolean) => {
    bytes += chunk.length;
    if (bytes > options.maxBytes) { stop("output-limit"); return; }
    // 원문 stderr는 반환하지 않는다. 실패한 프로세스의 회복 분류에 필요한 고정 어휘만 남긴다.
    diagnosticTail = (diagnosticTail + chunk.toString("utf8")).slice(-8192);
    if (/usage[_ -]limit|quota|rate[_ -]limit|\b429\b|capacity.*exhausted/i.test(diagnosticTail)) failureHint = "capacity";
    if (/authentication|unauthorized|login.*required|\b401\b|token.*expired|refresh_token/i.test(diagnosticTail)) failureHint = "authentication";
    if (capture) stdout += chunk.toString("utf8");
  };
  child.stdout.on("data", chunk => consume(chunk, true));
  child.stderr.on("data", chunk => consume(chunk, false));
  try {
    if (child.pid) {
      try { options.onStart(processIdentity(child.pid)); } catch { stop("initialization-failed"); }
    }
    const exitCode = await exited;
    if (exitCode !== 0 && reason === "completed") reason = "failed";
    const clean = child.pid ? await (stopping ?? stopGroup(child.pid)) : true;
    return { status: clean ? reason : "cleanup-unknown", exitCode, bytes, stdout, ...(reason === "failed" && failureHint ? { failureHint } : {}), cleanup: clean ? "confirmed" : "unknown", confinement: "process-group", unverified: ["cgroup-memory", "cpu", "tasks", "disk", "setsid-escape"] };
  } finally {
    clearTimeout(timer); process.removeListener("SIGTERM", interrupt); process.removeListener("SIGINT", interrupt);
    child.stdout.destroy(); child.stderr.destroy();
    rmSync(environmentRoot, { recursive: true, force: true });
  }
}
