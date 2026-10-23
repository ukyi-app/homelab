// 외부 명령 argv가 바깥 상태를 바꾸는지 판정한다. 안전의 근거는 core 어댑터의 고정 argv이고(명령은 argv를 만들 수 없다),
// 이 판정은 read exec의 마지막 방어선과 시험의 PATH 원장 집계에 쓴다(사용자 결정 2026-10-23).
// 설계 C.7 "plan은 읽기 전용이다"(비밀번호 생성, Infisical 쓰기, 브랜치 push, PR 생성, kubectl 변경 없음), L50, AC-P13.
// 읽기 허용 목록 방식이다. 목록에 없으면 쓰기로 본다(모르는 도구·하위 명령 포함). 목록을 넓히면 이 판정과
// cli/test/core/writes.test.ts의 표를 함께 고친다. exec가 plan·read 모드에서 쓰기를 막고, 시험이 스텁 원장을 이 판정으로 센다.
import { basename } from "node:path";

// sensitiveOutput: stdout에 시크릿 값이 나오는 호출. exec가 secretStdout으로만 실행하게 한다.
export type Verdict = { write: boolean; reason: string; sensitiveOutput?: boolean };

const read = (reason: string, sensitiveOutput = false): Verdict => (sensitiveOutput ? { write: false, reason, sensitiveOutput } : { write: false, reason });
const write = (reason: string, sensitiveOutput = false): Verdict => (sensitiveOutput ? { write: true, reason, sensitiveOutput } : { write: true, reason });

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
  // gh auth token, auth status --show-token은 토큰을 낸다.
  const token = sub === "auth" && (verb === "token" || args.includes("-t") || args.includes("--show-token"));
  if (sub && verb && reads[sub]?.includes(verb)) return read(`gh ${sub} ${verb}`, token);
  return write(`gh ${sub ?? ""} ${verb ?? ""}`.trim());
}

function git(args: string[]): Verdict {
  // 명령은 git을 부를 수 없다. core의 github 위임이 임시 폴더로 fresh clone만 한다(exec가 목적지를 확인).
  // 읽기 하위 명령도 --output 같은 파일 쓰기 옵션이 있어(#873 2라운드 P2) 버전 확인 말고는 모두 쓰기로 본다.
  if (args.length === 1 && args[0] === "--version") return read("git --version");
  const [sub] = positionals("git", args);
  return write(`git ${sub ?? ""}`.trim());
}

// kubectl 리소스 인자가 Secret 종류를 가리키는지. 종류 자리만 본다: 첫 인자(secret, Secret, secrets.v1, pods,secrets)와
// kind/name 꼴의 kind. 이름 자리(앱 이름이 secret인 deploy/secret, get deploy secret)는 Secret이 아니다(Connector 4360396711).
// kindFirst=false(logs)면 첫 인자도 이름(파드)이라 kind/name 꼴만 본다.
export function targetsSecret(resources: string[], kindFirst = true): boolean {
  const secretKind = (k: string) => k.toLowerCase().split(",").some((piece) => /^secrets?$/.test(piece.split(".")[0]));
  return resources.some((p, i) => (p.includes("/") ? secretKind(p.split("/")[0]) : kindFirst && i === 0 && secretKind(p)));
}

function kubectl(args: string[]): Verdict {
  // --raw는 임의 API 경로(Secret 포함)를 읽고, config view --raw는 토큰·개인키를 낸다. 어댑터가 쓰지 않으므로
  // 등호형(--raw=)까지 모두 거부한다(#873 2라운드 P1).
  if (args.some((a) => a === "--raw" || a.startsWith("--raw=") || a === "--flatten")) return write("kubectl --raw·--flatten은 쓰지 않는다", true);
  const pos = positionals("kubectl", args);
  const [verb, sub] = pos;
  const nestedVerb = verb === "auth" || verb === "config" || verb === "rollout";
  const secret = targetsSecret(pos.slice(nestedVerb ? 2 : 1), verb !== "logs");
  const simple = ["get", "describe", "explain", "api-resources", "api-versions", "version", "cluster-info", "top", "wait", "events", "logs"];
  if (verb && simple.includes(verb)) return read(`kubectl ${verb}`, secret);
  const nested: Record<string, string[]> = {
    auth: ["can-i", "whoami"],
    config: ["current-context", "get-contexts"],
    rollout: ["status", "history"],
  };
  if (verb && sub && nested[verb]?.includes(sub)) return read(`kubectl ${verb} ${sub}`, secret);
  // exec·port-forward·cp·debug·proxy·config view도 쓰기로 본다.
  return write(`kubectl ${verb ?? ""} ${sub ?? ""}`.trim(), secret);
}

function infisical(args: string[]): Verdict {
  if (args.length === 1 && args[0] === "--version") return read("infisical --version");
  const [a, b, c] = positionals("infisical", args);
  // 목록·조회·토큰은 값을 낸다.
  if (a === "secrets" && (b === undefined || b === "get")) return read(`infisical secrets ${b ?? "(목록)"}`, true);
  if (a === "secrets" && b === "folders" && c === "get") return read("infisical secrets folders get");
  if (a === "user" && b === "get" && c === "token") return read("infisical user get token", true);
  // run은 자식 명령을 모른다. export는 값을 낸다.
  return write(`infisical ${[a, b, c].filter(Boolean).join(" ")}`, a === "export" || a === "run");
}

// curl은 읽기 꼴 하나만 허용한다(#873 1라운드 P1). 함정: curl은 ~/.curlrc와 -K/--config 파일에서 request·data를
// 읽어 argv에 없는 POST를 보낸다(실제 curl과 127.0.0.1 서버로 재현). 그래서 첫 인자가 -q(.curlrc 끔)여야 하고,
// 나머지는 아래 옵션과 URL 하나뿐이어야 한다. 그 밖의 옵션은 해석하지 않고 쓰기로 본다.
// -w는 %{http_code}만: curl 8.3+의 %output{파일}은 파일에 쓴다. -o는 /dev/null·-만.
const CURL_BOOL = /^-[sSfLI]+$|^--(silent|show-error|fail|location|head)$/;

function curl(args: string[]): Verdict {
  if (args.length === 1 && args[0] === "--version") return read("curl --version");
  if (args[0] !== "-q") return write("curl: 첫 인자가 -q가 아니면 ~/.curlrc를 읽는다");
  let urls = 0;
  for (let i = 1; i < args.length; i++) {
    const a = args[i];
    const v = args[i + 1];
    if (CURL_BOOL.test(a)) continue;
    if ((a === "-o" || a === "--output") && (v === "/dev/null" || v === "-")) i++;
    else if ((a === "-w" || a === "--write-out") && v === "%{http_code}") i++;
    else if ((a === "-m" || a === "--max-time" || a === "--connect-timeout") && v !== undefined && /^[0-9]+$/.test(v)) i++;
    else if ((a === "-X" || a === "--request") && (v === "GET" || v === "HEAD")) i++;
    else if ((a === "-H" || a === "--header") && v !== undefined && !v.startsWith("@") && !/[\u0000-\u001f]/.test(v)) i++;
    else if (!a.startsWith("-") && /^https?:\/\/[^\s]+$/.test(a)) urls++;
    else return write(`curl: 허용 목록 밖 인자 ${a}`);
  }
  return urls === 1 ? read("curl GET") : write(`curl: URL이 ${urls}개`);
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
