// homelab doctor: 로컬 도구·로그인·kubectl context 점검(설계 C.7). 로컬만 읽는다.
// 기대 버전은 .tool-versions(실행 파일은 빌드 때 박은 값). gh·git·curl·jq는 .tool-versions에 없어 있음만 본다.
import { defineCommand, type Observation, type ReadCtx, type Step, type ToolName } from "../core/command";
import { expectedTools } from "../core/command-info";

const PROJECT_ENV = "HOMELAB_INFISICAL_PROJECT_ID";
const same = (detail: string): Observation => ({ state: "same", action: "none", detail });
const bad = (state: "missing" | "differs", detail: string, next: string): Observation => ({ state, action: "none", detail, next });

function toolStep(tool: ToolName, parse: (out: string) => string | null, expected?: string, why?: string): Step {
  return {
    id: `tool-${tool}`,
    target: `도구 ${tool}${why ? ` (${why})` : ""}`,
    async read(ctx: ReadCtx) {
      const r = ctx.tools.version(tool);
      if (!r.found) return bad("missing", "없음", expected ? "mise install" : `${tool}을 설치한다`);
      let version: string | null = null;
      try {
        version = r.ok ? parse(r.output) : null;
      } catch {
        version = null;
      }
      // 저장소 밖에서는 mise가 .tool-versions를 못 찾아 버전을 고르지 못할 수 있다(T12-05 운영). 그래서 저장소 안에서 다시 보라고 한다.
      if (!version) return bad("differs", "버전을 읽지 못함", expected ? `저장소 안에서 다시 실행한다(mise가 .tool-versions로 버전을 고른다). 그래도 안 되면 ${tool}의 버전 출력을 직접 확인한다` : `${tool}의 버전 출력을 직접 확인한다`);
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
      toolStep("kubectl", (o) => JSON.parse(o)?.clientVersion?.gitVersion?.replace(/^v/, "") ?? null, want.kubectl),
      toolStep("infisical", (o) => o.match(/version (\S+)/)?.[1] ?? null, want.infisical),
      toolStep("terraform", (o) => o.match(/Terraform v(\S+)/)?.[1] ?? null, want.terraform, "github 명령"),
      toolStep("gh", (o) => o.match(/gh version (\S+)/)?.[1] ?? null),
      toolStep("git", (o) => o.match(/git version (\S+)/)?.[1] ?? null),
      toolStep("curl", (o) => o.match(/^curl (\S+)/)?.[1] ?? null),
      toolStep("jq", (o) => o.match(/jq-(\S+)/)?.[1] ?? null, undefined, "github 명령"),
      {
        id: "gh-auth",
        target: "gh 로그인",
        read: async (c) => (c.tools.ghAuthOk() ? same("로그인됨") : bad("missing", "로그인 안 됨", "gh auth login")),
      },
      {
        id: "infisical-login",
        target: "infisical 로그인",
        async read(c) {
          const s = c.tools.infisicalLogin();
          if (s === "missing") return bad("missing", "infisical 없음", "mise install");
          // 저장소 밖에서는 mise가 infisical 버전을 못 골라 로그인돼 있어도 실패로 보일 수 있다(T12-05 운영).
          return s === "ok" ? same("로그인 프로필 있음") : bad("missing", "로그인 안 됨", "infisical login(저장소 밖에서 실행했다면 저장소 안에서 다시 확인한다)");
        },
      },
      {
        id: "infisical-project",
        target: `환경변수 ${PROJECT_ENV}`,
        async read(c) {
          const s = c.infisical.projectStatus();
          // lead 결정(2026-10-23): 없음은 경고. Infisical을 쓰는 명령이 tty에서 한 번 묻는다.
          if (s === "missing") return { ...same("없음(Infisical 쓰는 명령이 tty에서 묻는다)"), warn: `없으면 tty에서 묻는다. 묻지 않게 하려면 export ${PROJECT_ENV}=<homelab project ID>` };
          return s === "ok" ? same("있음(UUID)") : bad("differs", "UUID 형식이 아님", `${PROJECT_ENV}를 Infisical 프로젝트 설정의 ID로 고친다`);
        },
      },
      {
        id: "self-path",
        target: "PATH의 homelab",
        async read(c) {
          const s = c.tools.selfOnPath();
          if (s.same) return same(s.first!);
          if (!s.first) return same(`PATH에 없음(지금 실행: ${s.running})`);
          // 경고만 한다. bun run cli로 개발 중이면 다른 것이 당연하다.
          return { ...same(`${s.first} ≠ 지금 실행 ${s.running}`), warn: `PATH에서 먼저 잡히는 homelab(${s.first})은 지금 실행 중인 것이 아니다. 옛 설치(bun link 등)면 지우거나 PATH 순서를 고친다` };
        },
      },
      {
        id: "kube-context",
        target: "kubectl context",
        async read(c) {
          let name: string | null;
          try {
            name = c.k8s.currentContext();
          } catch {
            return bad("missing", "kubectl 없음", "mise install");
          }
          return name ? same(name) : bad("missing", "현재 context 없음", "export KUBECONFIG=~/.kube/homelab.yaml");
        },
      },
    ];
    return ctx.engine({ command: "doctor", steps, title: "homelab doctor" });
  },
});
