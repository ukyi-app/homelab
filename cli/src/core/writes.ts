// 외부 명령 argv가 바깥 상태를 바꾸는지 판정한다.
// 설계 C.7 "plan은 읽기 전용이다"(비밀번호 생성, Infisical 쓰기, 브랜치 push, PR 생성, kubectl 변경 없음), L50, AC-P13.
// 읽기 허용 목록 방식이다. 목록에 없으면 쓰기로 본다(모르는 도구·하위 명령 포함). 목록을 넓히면 이 판정과
// cli/test/core/writes.test.ts의 표를 함께 고친다. exec가 plan·read 모드에서 쓰기를 막고, 시험이 스텁 원장을 이 판정으로 센다.
import { basename } from "node:path";

export type Verdict = { write: boolean; reason: string };

const read = (reason: string): Verdict => ({ write: false, reason });
const write = (reason: string): Verdict => ({ write: true, reason });

// 값을 받는 전역 플래그. 이것들의 값은 하위 명령 이름으로 세지 않는다.
const VALUE_FLAGS: Record<string, string[]> = {
  kubectl: ["-n", "--namespace", "--context", "--kubeconfig", "--request-timeout", "--cluster", "--user", "-s", "--server", "-o", "--output", "-l", "--selector", "-c", "--container", "--since", "--tail", "--for", "--timeout"],
  infisical: ["--domain", "--path", "--env", "--projectId", "--token", "-o", "--output", "-l", "--log-level", "-t", "--tags", "--file", "--type", "--profile", "--org", "--log-format", "--log-destination", "--tag"],
  git: ["-C", "-c"],
};

// 플래그와 그 값을 뺀 위치 인자들.
function positionals(tool: string, args: string[]): string[] {
  const valueFlags = VALUE_FLAGS[tool] ?? [];
  const out: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a.startsWith("-")) {
      if (!a.includes("=") && valueFlags.includes(a)) i++;
      continue;
    }
    out.push(a);
  }
  return out;
}

function ghApi(args: string[]): Verdict {
  // gh api는 필드나 --input이 있으면 기본 메서드가 POST다(gh help api). -X GET을 명시하면 필드는 쿼리가 된다.
  let method: string | undefined;
  let hasBody = false;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "-X" || a === "--method") method = args[++i]?.toUpperCase();
    else if (a.startsWith("--method=")) method = a.slice(9).toUpperCase();
    else if (/^-X[A-Za-z]+$/.test(a)) method = a.slice(2).toUpperCase();
    else if (["-f", "-F", "--field", "--raw-field", "--input"].includes(a)) {
      hasBody = true;
      i++;
    } else if (/^(-f|-F).+|^--(field|raw-field|input)=/.test(a)) hasBody = true;
  }
  const path = positionals("gh", args)[0] ?? "";
  // GraphQL은 질의와 변경이 같은 POST라 argv로 가를 수 없다.
  if (path === "graphql") return write("gh api graphql(질의·변경을 argv로 가를 수 없다)");
  const effective = method ?? (hasBody ? "POST" : "GET");
  return effective === "GET" || effective === "HEAD" ? read(`gh api ${effective}`) : write(`gh api ${effective}`);
}

function gh(args: string[]): Verdict {
  if (args.length === 1 && args[0] === "--version") return read("gh --version");
  const [sub, verb] = positionals("gh", args);
  if (sub === "api") return ghApi(args.slice(args.indexOf("api") + 1));
  const reads: Record<string, string[]> = {
    auth: ["status", "token"],
    pr: ["list", "view", "checks", "diff", "status"],
    run: ["list", "view"],
    repo: ["view"],
  };
  if (sub && verb && reads[sub]?.includes(verb)) return read(`gh ${sub} ${verb}`);
  return write(`gh ${sub ?? ""} ${verb ?? ""}`.trim());
}

function git(args: string[]): Verdict {
  if (args.length === 1 && args[0] === "--version") return read("git --version");
  const [sub] = positionals("git", args);
  // clone은 임시 폴더에 받기만 한다(github 하위 명령의 실행 사본). 원격은 바뀌지 않는다.
  const reads = ["ls-remote", "rev-parse", "log", "show", "cat-file", "clone"];
  return sub && reads.includes(sub) ? read(`git ${sub}`) : write(`git ${sub ?? ""}`.trim());
}

function kubectl(args: string[]): Verdict {
  const [verb, sub] = positionals("kubectl", args);
  const simple = ["get", "describe", "logs", "explain", "api-resources", "api-versions", "version", "cluster-info", "top", "wait", "events"];
  if (verb && simple.includes(verb)) return read(`kubectl ${verb}`);
  const nested: Record<string, string[]> = {
    auth: ["can-i", "whoami"],
    config: ["current-context", "get-contexts", "view"],
    rollout: ["status", "history"],
  };
  if (verb && sub && nested[verb]?.includes(sub)) return read(`kubectl ${verb} ${sub}`);
  // exec·port-forward·cp·debug·proxy도 쓰기로 본다. 파드 안에서 무엇을 하는지 argv로 판정할 수 없다.
  return write(`kubectl ${verb ?? ""} ${sub ?? ""}`.trim());
}

function infisical(args: string[]): Verdict {
  if (args.length === 1 && args[0] === "--version") return read("infisical --version");
  const [a, b, c] = positionals("infisical", args);
  if (a === "secrets" && (b === undefined || b === "get")) return read(`infisical secrets ${b ?? "(목록)"}`);
  if (a === "secrets" && b === "folders" && c === "get") return read("infisical secrets folders get");
  if (a === "user" && b === "get" && c === "token") return read("infisical user get token");
  // run은 자식 명령을 모른다.
  return write(`infisical ${[a, b, c].filter(Boolean).join(" ")}`);
}

function curl(args: string[]): Verdict {
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "-X" || a === "--request") {
      const m = args[i + 1]?.toUpperCase();
      if (m !== "GET" && m !== "HEAD") return write(`curl -X ${m}`);
      i++;
    } else if (a === "-XGET" || a === "-XHEAD" || a === "--request=GET" || a === "--request=HEAD") continue;
    else if (/^--(request|data|data-[a-z]+|json|form|form-string|upload-file)(=|$)/.test(a)) return write(`curl ${a}`);
    // 짧은 플래그 묶음(-sd 등)에 본문·메서드 플래그(d F T X)가 끼면 쓰기로 본다.
    else if (/^-[A-Za-z]+/.test(a) && !a.startsWith("--") && /[dFTX]/.test(a.slice(1).match(/^[A-Za-z]+/)![0])) return write(`curl ${a}`);
  }
  return read("curl GET");
}

export function classify(argv: string[]): Verdict {
  const tool = basename(argv[0] ?? "");
  const args = argv.slice(1);
  switch (tool) {
    case "gh":
      return gh(args);
    case "git":
      return git(args);
    case "kubectl":
      return kubectl(args);
    case "infisical":
      return infisical(args);
    case "curl":
      return curl(args);
    case "jq":
      return read("jq(로컬 처리)");
    case "terraform":
      // CLI는 terraform을 직접 부르지 않는다(래퍼가 부른다). 버전 확인만 읽기.
      return args.length === 1 && ["version", "-version", "--version"].includes(args[0]) ? read("terraform version") : write("terraform");
    case "tf-github.sh":
      return args[0] === "plan" || args[0] === "verify" ? read(`tf-github.sh ${args[0]}`) : write(`tf-github.sh ${args[0] ?? ""}`.trim());
    default:
      return write(`목록에 없는 도구: ${tool}`);
  }
}
