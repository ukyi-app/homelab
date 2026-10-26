// doctor용 로컬 도구 확인 어댑터. 도구마다 버전 argv가 고정이다.
import { realpathSync } from "node:fs";
import type { ToolName, ToolsRead } from "./command";
import type { Exec } from "./exec";

const VERSION_ARGS: Record<ToolName, string[]> = {
  kubectl: ["version", "--client", "-o", "json"],
  infisical: ["--version"],
  terraform: ["version"],
  gh: ["--version"],
  git: ["--version"],
  curl: ["--version"],
  jq: ["--version"],
};

// 지금 실행 중인 파일. 컴파일한 실행 파일이면 Bun.main이 내장 경로(/$bunfs/...)라 실행 파일 자체를, bun으로 돌리면 진입 파일을 본다.
function runningFile(): string {
  return Bun.main.startsWith("/$bunfs/") ? process.execPath : Bun.main;
}

function real(p: string): string {
  try {
    return realpathSync(p);
  } catch {
    return p;
  }
}

export function toolsRead(exec: Exec, env: Record<string, string | undefined> = {}, running: string = runningFile()): ToolsRead {
  return {
    version(tool) {
      const args = Object.hasOwn(VERSION_ARGS, tool) ? VERSION_ARGS[tool] : undefined;
      if (!args) throw new Error("확인할 수 없는 도구다");
      const r = exec([tool, ...args]);
      return { found: r.errKind !== "not-found", ok: r.code === 0, output: r.code === 0 ? r.stdout : "" };
    },
    ghAuthOk() {
      // 출력은 쓰지 않는다(토큰 앞부분이 가려져 나오지만 그래도 버린다).
      return exec(["gh", "auth", "status", "--active", "--hostname", "github.com"]).code === 0;
    },
    infisicalLogin() {
      // 토큰은 Secret으로 받아 버린다. 로컬 프로필만 보므로 만료 여부는 실제 조회 때 드러난다.
      const r = exec(["infisical", "user", "get", "token", "--silent"], { secretStdout: true });
      if (r.errKind === "not-found") return "missing";
      return r.code === 0 ? "ok" : "no";
    },
    selfOnPath() {
      // 함정: 옛 bun link(~/.bun/bin/homelab → 옛 tools/homelab.ts)가 PATH 앞에 남아 새 CLI를 가렸다(T12-05 운영).
      // 사람이 homelab을 치면 그 옛 것이 돈다. 링크를 따라간 실제 파일로 비교한다.
      const first = Bun.which("homelab", { PATH: env.PATH ?? "" });
      return { first, running, same: first !== null && real(first) === real(running) };
    },
  };
}
