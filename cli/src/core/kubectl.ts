// kubectl 얇은 감쌈. 사람의 kubeconfig와 현재 context를 그대로 쓴다(자격을 저장하지 않는다).
// 모든 호출에 --request-timeout을 둔다. 서버가 응답하지 않으면 kubectl은 기본으로 오래 기다린다.
import type { Ctx } from "./command";
import { ExecTimeout, must, why, type ExecOpts } from "./exec";
import { hasControl } from "./names";
import { Secret } from "./secret";

const REQUEST_TIMEOUT = "--request-timeout=20s";
const NAME = /^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$/;

function checkName(what: string, v: string): void {
  if (!NAME.test(v) || v.length > 253) throw new Error(`kubectl ${what} 이름이 아니다: ${JSON.stringify(v)}`);
}

// argv 꼴. 시험 장치도 이 함수로 스텁 규칙을 만든다.
export function kubectlArgv(args: string[]): string[] {
  return ["kubectl", ...args, REQUEST_TIMEOUT];
}

export function kubectl(ctx: Ctx, args: string[], opts: ExecOpts = {}) {
  return ctx.exec(kubectlArgv(args), opts);
}

// 없으면 null. 그 밖의 실패는 던진다.
export function getJson(ctx: Ctx, ns: string | null, kind: string, name: string): any | null {
  if (ns) checkName("namespace", ns);
  checkName("리소스", name);
  const r = kubectl(ctx, [...(ns ? ["-n", ns] : []), "get", kind, name, "-o", "json"]);
  if (r.errKind === "timeout") throw new ExecTimeout(`kubectl get ${kind} ${name}: 시간 초과`);
  if (r.code !== 0 && /NotFound|not found/.test(r.stderr)) return null;
  must(r, `kubectl get ${kind} ${name}`);
  return JSON.parse(r.stdout);
}

export function listJson(ctx: Ctx, ns: string | null, kind: string, selector?: string): any[] {
  if (ns) checkName("namespace", ns);
  const r = kubectl(ctx, [...(ns ? ["-n", ns] : ["-A"]), "get", kind, ...(selector ? ["-l", selector] : []), "-o", "json"]);
  must(r, `kubectl get ${kind}`);
  return JSON.parse(r.stdout).items ?? [];
}

// Secret 키 값의 해시 앞부분(rotate.md의 h()와 같다). 값은 Secret 밖으로 나오지 않는다. 없으면 null.
export function secretHash(ctx: Ctx, ns: string, name: string, key: string): string | null {
  checkName("namespace", ns);
  checkName("Secret", name);
  if (!/^[A-Za-z0-9_.-]+$/.test(key)) throw new Error(`Secret 키 이름이 아니다: ${JSON.stringify(key)}`);
  const r = kubectl(ctx, ["-n", ns, "get", "secret", name, "-o", "json"], { secretStdout: true });
  if (r.errKind === "timeout") throw new ExecTimeout(`kubectl get secret ${name}: 시간 초과`);
  if (r.code !== 0 && /NotFound|not found/.test(r.stderr)) return null;
  if (r.code !== 0 || !r.stdoutSecret) throw new Error(`kubectl get secret ${name}: ${why(r)}`);
  const encoded = JSON.parse(r.stdoutSecret.reveal()).data?.[key];
  if (typeof encoded !== "string") return null;
  return new Secret(Buffer.from(encoded, "base64").toString("utf8")).sha256Prefix(12);
}

export function annotate(ctx: Ctx, ns: string, kind: string, name: string, key: string, value: string): void {
  checkName("namespace", ns);
  checkName("리소스", name);
  if (!/^[a-z0-9./-]+$/.test(key) || hasControl(value)) throw new Error(`annotation 형식이 아니다: ${key}`);
  must(kubectl(ctx, ["-n", ns, "annotate", kind, name, `${key}=${value}`, "--overwrite"]), `kubectl annotate ${kind} ${name}`);
}

export function patchMerge(ctx: Ctx, ns: string, kind: string, name: string, patch: unknown): void {
  checkName("namespace", ns);
  checkName("리소스", name);
  must(kubectl(ctx, ["-n", ns, "patch", kind, name, "--type", "merge", "-p", JSON.stringify(patch)]), `kubectl patch ${kind} ${name}`);
}

// 매니페스트는 stdin으로. Secret 매니페스트는 만들지 않는다(자격은 ExternalSecret).
export function createFromStdin(ctx: Ctx, ns: string, manifest: unknown): void {
  checkName("namespace", ns);
  if ((manifest as { kind?: string })?.kind === "Secret") throw new Error("kind: Secret 매니페스트는 만들지 않는다");
  must(kubectl(ctx, ["-n", ns, "create", "-f", "-"], { input: JSON.stringify(manifest) }), "kubectl create");
}

export function deleteResource(ctx: Ctx, ns: string, kind: string, name: string): void {
  checkName("namespace", ns);
  checkName("리소스", name);
  must(kubectl(ctx, ["-n", ns, "delete", kind, name, "--ignore-not-found", "--wait=false"]), `kubectl delete ${kind} ${name}`);
}

export function rolloutRestart(ctx: Ctx, ns: string, deploy: string): void {
  checkName("namespace", ns);
  checkName("Deployment", deploy);
  must(kubectl(ctx, ["-n", ns, "rollout", "restart", `deploy/${deploy}`]), `rollout restart ${deploy}`);
}

export function rolloutStatus(ctx: Ctx, ns: string, deploy: string, timeout = "180s"): boolean {
  checkName("namespace", ns);
  checkName("Deployment", deploy);
  const r = kubectl(ctx, ["-n", ns, "rollout", "status", `deploy/${deploy}`, `--timeout=${timeout}`], { timeoutMs: 200_000 });
  return r.code === 0;
}
