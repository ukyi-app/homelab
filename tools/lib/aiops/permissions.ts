import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, symlinkSync, openSync, closeSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { isolatedSpawnSync as spawnSync } from "../exec.ts";
import { createServer } from "node:net";
import { digest } from "./git.ts";
import { requireCondition } from "./input.ts";
import { runProcess } from "./process.ts";

export const CODEX_VERSION = "0.154.0";
export function permissionConfig(workspace: string, authentication: string, binary: string): string[] {
  const directory = resolve(workspace), auth = resolve(authentication);
  requireCondition(!auth.startsWith(`${directory}/`) && auth !== directory, "auth-inside-model-workspace");
  // 허용 목록 밖의 auth·임시 디렉토리는 :root deny가 닫는다. 중복 deny 마운트는 만들지 않는다.
  const runtime = dirname(realpathSync(binary));
  requireCondition(!auth.startsWith(`${runtime}/`) && auth !== runtime, "auth-inside-runtime-directory");
  const filesystem = { ":root": "deny", ":minimal": "read", "/proc": "deny", [directory]: "write", [runtime]: "read" };
  const table = Object.entries(filesystem).map(([path, access]) => `${JSON.stringify(path)}=${JSON.stringify(access)}`).join(",");
  return [
    "-c", 'default_permissions="aiops"', "-c", `permissions.aiops={filesystem={${table}},network={enabled=false}}`,
    "-c", 'approval_policy="never"', "-c", 'shell_environment_policy={inherit="none",set={PATH="/usr/bin:/bin",LANG="C.UTF-8"}}',
    "-c", 'mcp_servers={}', "-c", 'web_search="disabled"', "-c", "project_doc_max_bytes=0",
    "-c", 'features={hooks=false,plugins=false,remote_plugin=false,skill_search=false,skill_mcp_dependency_install=false,shell_snapshot=false,multi_agent=false,skip_host_skill_discovery=true}',
  ];
}
export type IsolationReadiness = { ready: boolean; cliVersion: string; binaryHash: string; checks: Record<string, boolean>; reason?: string; diagnostic?: string; checkedAt: string };

// 실제 구독 인증 없이 설치된 Codex sandbox를 검증한다. 허용 대조군 실패도 전체 실패다.
export async function probeIsolation(binary: string): Promise<IsolationReadiness> {
  const root = mkdtempSync(join(tmpdir(), "aiops-isolation-"));
  const workspace = join(root, "work"), authentication = join(root, "authentication");
  mkdirSync(workspace); mkdirSync(authentication);
  const nonce = crypto.randomUUID();
  const mock = join(authentication, "mock-secret"); writeFileSync(mock, nonce, { mode: 0o600 });
  symlinkSync(mock, join(workspace, "secret-link"));
  const socket = join(authentication, "credential.sock");
  const unix = createServer(connection => connection.end(nonce));
  const tcp = createServer(connection => connection.end(nonce));
  const result: IsolationReadiness = { ready: false, cliVersion: "unknown", binaryHash: "unknown", checks: {}, checkedAt: new Date().toISOString() };
  try {
    await new Promise<void>((yes, no) => { unix.once("error", no); unix.listen(socket, yes); });
    await new Promise<void>((yes, no) => { tcp.once("error", no); tcp.listen(0, "127.0.0.1", yes); });
    const address = tcp.address(); requireCondition(address && typeof address !== "string", "probe-listener-failed");
    const program = `import os,socket,json\nr={}\ntry:\n open('allowed','w').write('ok')\n r['workspace']=open('allowed').read()=='ok'\nexcept Exception:r['workspace']=False\ndef denied_file(path):\n try:open(path,'rb').read();return False\n except (OSError,PermissionError):return True\nr['direct']=denied_file(${JSON.stringify(mock)})\nr['symlink']=denied_file('secret-link')\nr['parent']=denied_file('/proc/${process.pid}/environ')\nr['environment']='AIOPS_BOUNDARY_CANARY' not in os.environ\ntry:os.read(3,1);r['fd']=False\nexcept OSError:r['fd']=True\ndef denied_socket(family,target):\n s=None\n try:\n  s=socket.socket(family,socket.SOCK_STREAM);s.settimeout(1);s.connect(target);return False\n except OSError:return True\n finally:\n  if s is not None:s.close()\nr['socket']=denied_socket(socket.AF_UNIX,${JSON.stringify(socket)})\nr['network']=denied_socket(socket.AF_INET,('127.0.0.1',${address.port}))\nprint(json.dumps(r))\n`;
    writeFileSync(join(workspace, "probe.py"), program, { mode: 0o400 });
    const env = { PATH: process.env.PATH, LANG: "C.UTF-8", CODEX_HOME: authentication, XDG_DATA_HOME: root, AIOPS_BOUNDARY_CANARY: nonce };
    const version = spawnSync(binary, ["--version"], { encoding: "utf8", env, timeout: 10_000, maxBuffer: 1024 * 1024 });
    result.cliVersion = version.stdout.trim(); result.binaryHash = digest(readFileSync(binary));
    if (version.status !== 0 || result.cliVersion !== `codex-cli ${CODEX_VERSION}`) { result.reason = "codex-version-mismatch"; return result; }
    const fd = openSync(mock, "r");
    let probe;
    try {
      // 운영과 같은 실행 경계가 표준 입출력 이외 FD를 전달하지 않는다.
      probe = await runProcess([binary, "sandbox", "-C", workspace, "-P", "aiops", ...permissionConfig(workspace, authentication, binary), "--", "/usr/bin/python3", "probe.py"],
        { cwd: workspace, engineEnvironment: { CODEX_HOME: authentication, AIOPS_BOUNDARY_CANARY: nonce }, timeoutMs: 15_000, maxBytes: 1024 * 1024, onStart: () => {} });
    } finally { closeSync(fd); }
    if (probe.status !== "completed") {
      result.reason = "sandbox-initialization-or-probe-failed";
      // 이 프로세스는 모의 자격만 사용한다. 실제 인증/운영 stderr를 여기에 전달하지 않는다.
      result.diagnostic = probe.status;
      return result;
    }
    const checks = JSON.parse(probe.stdout) as Record<string, boolean>;
    const names = ["workspace", "direct", "symlink", "parent", "environment", "fd", "socket", "network"];
    result.checks = Object.fromEntries(names.map(name => [name, checks[name] === true]));
    result.ready = names.every(name => result.checks[name]);
    if (!result.ready) result.reason = "isolation-boundary-failed";
  } catch { result.reason = "isolation-probe-unavailable"; }
  finally { unix.close(); tcp.close(); rmSync(root, { recursive: true, force: true }); }
  return result;
}
