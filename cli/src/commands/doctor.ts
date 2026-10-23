// homelab doctor: 로컬 도구·로그인·kubectl context 점검(설계 C.7). 로컬만 읽는다.
// 기대 버전은 .tool-versions(실행 파일은 빌드 때 박은 값). gh·git·curl·jq는 .tool-versions에 없어 있음만 본다.
import { defineCommand, type Ctx, type Observation, type Step } from "../core/command";
import { PROJECT_ENV } from "../core/infisical";
import { PROJECT_ID, fullMatch } from "../core/names";
import { expectedTools } from "../core/version";

const same = (detail: string): Observation => ({ state: "same", action: "none", detail });
const bad = (state: "missing" | "differs", detail: string, next: string): Observation => ({ state, action: "none", detail, next });

function toolStep(tool: string, versionArgs: string[], parse: (out: string) => string | null, expected?: string, why?: string): Step {
  return {
    id: `tool-${tool}`,
    target: `도구 ${tool}${why ? ` (${why})` : ""}`,
    async read(ctx: Ctx) {
      const r = ctx.exec([tool, ...versionArgs]);
      if (r.errKind === "not-found") return bad("missing", "없음", expected ? "mise install" : `${tool}을 설치한다`);
      const version = r.code === 0 ? parse(r.stdout) : null;
      if (!version) return bad("differs", "버전을 읽지 못함", `${tool} ${versionArgs.join(" ")}를 직접 실행해 본다`);
      if (expected && version !== expected) return bad("differs", `${version} → 기대 ${expected}`, "mise install");
      return same(expected ? `${version} (기대와 같음)` : version);
    },
  };
}

export default defineCommand({
  path: ["doctor"],
  summary: "로컬 도구·로그인·kubectl context 점검",
  kind: "read",
  args: [],
  flags: [],
  async run(ctx) {
    const want = expectedTools();
    const steps: Step[] = [
      toolStep("kubectl", ["version", "--client", "-o", "json"], (o) => JSON.parse(o)?.clientVersion?.gitVersion?.replace(/^v/, "") ?? null, want.kubectl),
      toolStep("infisical", ["--version"], (o) => o.match(/version (\S+)/)?.[1] ?? null, want.infisical),
      toolStep("terraform", ["version"], (o) => o.match(/Terraform v(\S+)/)?.[1] ?? null, want.terraform, "github 명령"),
      toolStep("gh", ["--version"], (o) => o.match(/gh version (\S+)/)?.[1] ?? null),
      toolStep("git", ["--version"], (o) => o.match(/git version (\S+)/)?.[1] ?? null),
      toolStep("curl", ["--version"], (o) => o.match(/^curl (\S+)/)?.[1] ?? null),
      toolStep("jq", ["--version"], (o) => o.match(/jq-(\S+)/)?.[1] ?? null, undefined, "github 명령"),
      {
        id: "gh-auth",
        target: "gh 로그인",
        async read(c) {
          // 출력은 쓰지 않는다(토큰 앞부분이 가려져 나오지만 그래도 버린다).
          const r = c.exec(["gh", "auth", "status", "--active", "--hostname", "github.com"]);
          return r.code === 0 ? same("로그인됨") : bad("missing", "로그인 안 됨", "gh auth login");
        },
      },
      {
        id: "infisical-login",
        target: "infisical 로그인",
        async read(c) {
          // 토큰은 Secret으로 받아 버린다. 로컬 프로필만 보므로 만료 여부는 실제 조회 때 드러난다.
          const r = c.exec(["infisical", "user", "get", "token", "--silent"], { secretStdout: true });
          if (r.errKind === "not-found") return bad("missing", "infisical 없음", "mise install");
          return r.code === 0 ? same("로그인 프로필 있음") : bad("missing", "로그인 안 됨", "infisical login");
        },
      },
      {
        id: "infisical-project",
        target: `환경변수 ${PROJECT_ENV}`,
        async read(c) {
          const id = c.env[PROJECT_ENV];
          // lead 결정(2026-10-23): 없음은 경고. Infisical을 쓰는 명령이 tty에서 한 번 묻는다.
          if (id === undefined || id === "") return { ...same("없음(Infisical 쓰는 명령이 tty에서 묻는다)"), warn: `없으면 tty에서 묻는다. 묻지 않게 하려면 export ${PROJECT_ENV}=<homelab project ID>` };
          return fullMatch(PROJECT_ID, id) ? same("있음(UUID)") : bad("differs", "UUID 형식이 아님", `${PROJECT_ENV}를 Infisical 프로젝트 설정의 ID로 고친다`);
        },
      },
      {
        id: "kube-context",
        target: "kubectl context",
        async read(c) {
          // 서버 주소는 찍지 않는다(tailnet 이름일 수 있다, D-23).
          const r = c.exec(["kubectl", "config", "current-context"]);
          if (r.errKind === "not-found") return bad("missing", "kubectl 없음", "mise install");
          const name = r.stdout.trim();
          if (r.code !== 0 || !name) return bad("missing", "현재 context 없음", "export KUBECONFIG=~/.kube/homelab.yaml");
          return same(`${name}${c.env.KUBECONFIG ? " (KUBECONFIG)" : " (기본 kubeconfig)"}`);
        },
      },
    ];
    return ctx.engine({ command: "doctor", steps, title: "homelab doctor" });
  },
});
