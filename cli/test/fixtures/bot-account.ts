// homelab bot account add|use|list 시험의 공통 스텁(봇 게시 서버 파드와 관리 진입점 응답).
import { FAKE_SECRETS, kubectlRule } from "../harness";
import type { BotAccount } from "../../src/core/command";

export const NS = "app-homelab-bot";
export const POD = "homelab-bot-6f7c9d5b8-x2k4p";
const PODS = ["-n", NS, "get", "pods", "-l", "homelab.ukyi.app/app=homelab-bot", "-o", "json"];
export const adminArgv = (...words: string[]) => ["kubectl", "-n", NS, "exec", POD, "-c", "app", "--request-timeout=20s", "--", "node", "/app/dist/src/admin-main.js", ...words];
export const FOLDER = "/bot-accounts/main";
export const WORKER = "/apps/homelab-bot/worker";
export const [CHAT, TASK] = FAKE_SECRETS;

export function pod(o: { name?: string; namespace?: string; app?: string } = {}) {
  return {
    metadata: { name: o.name ?? POD, namespace: o.namespace ?? NS, labels: { "homelab.ukyi.app/app": o.app ?? "homelab-bot" }, ownerReferences: [{ kind: "ReplicaSet", name: "homelab-bot-6f7c9d5b8" }] },
    status: { phase: "Running", conditions: [{ type: "Ready", status: "True" }] },
  };
}
export const pods = (...items: object[]) => kubectlRule(PODS, { stdout: JSON.stringify({ items }) });
export const report = (command: string, result: string, extra: object = {}) => JSON.stringify({ schema: "homelab-bot-admin/v1", command, result, ...extra }) + "\n";
export const execCalls = (r: { calls: { argv: string[] }[] }) => r.calls.filter((c) => c.argv[0] === "kubectl" && c.argv.includes("exec")).map((c) => c.argv);
export const hash12 = (v: string) => new Bun.CryptoHasher("sha256").update(v).digest("hex").slice(0, 12);
export const ACCOUNTS: BotAccount[] = [
  { name: "main", method: "subscription", current: true, issuedAt: "2026-11-11T00:00:00Z", expiresAt: "2027-11-11T00:00:00Z",
    limit: { status: "allowed_warning", rateLimitType: "five_hour", utilization: 0.97, resetsAt: "2026-11-11T05:00:00Z", observedAt: "2026-11-11T03:00:00Z" } },
  { name: "spare", method: "subscription", current: false, issuedAt: null, expiresAt: null, limit: null },
];
