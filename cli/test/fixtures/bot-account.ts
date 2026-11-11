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
// API 크레딧 방식의 레인별 Console API 키(합성 값).
export const API_CHAT = "fakevalue-api-chat-0123456789";
export const API_TASK = "fakevalue-api-task-9876543210";

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

// claude setup-token 스텁 화면(2026-11-11 claude 2.1.322 관측 꼴, 합성 값). 토큰은 홀로 한 줄이다.
export const OAT = "sk-ant-oat01-FAKEfakeFAKEfake_0123456789-abcdefghijABCDEFGHIJ_klmnopqrstuvwxyz-0123456789AA";
export const OAT2 = "sk-ant-oat01-FAKEsecondFAKEsecond_9876543210-zyxwvutsrqZYXWVUTSRQ_ponmlkjihgfedcba-9876543210BB";
export const OAUTH_URL = "https://claude.ai/oauth/authorize?code=true&client_id=fake-client&state=fake-state";
export const setupScreen = (token: string) =>
  ["Opening browser to sign in…", "Browser didn't open? Use the url below to sign in:", "", OAUTH_URL, "", "✓ Long-lived authentication token created successfully!", "",
    "Your OAuth token (valid for 1 year):", "", token, "", "Store this token securely. You won't be able to see it again.", ""].join("\n");
// 비밀 부분(접두 뒤)의 6자 조각이 text에 있는지. 화면에 토큰이 샜는지 본다.
export function leaks(text: string, token: string): boolean {
  const secret = token.replace(/^sk-ant-oat01-/, "");
  for (let i = 0; i + 6 <= secret.length; i++) if (text.includes(secret.slice(i, i + 6))) return true;
  return false;
}
