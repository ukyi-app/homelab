// doctor용 로컬 도구 확인 어댑터. 도구마다 버전 argv가 고정이다.
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

export function toolsRead(exec: Exec): ToolsRead {
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
  };
}
