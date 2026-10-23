import { describe, expect, test } from "bun:test";
import { classify } from "../../src/core/writes";

// 판정 표. 읽기 허용 목록을 넓히면 여기에 근거와 함께 한 줄을 더한다.
const READS: string[][] = [
  ["gh", "api", "-i", "repos/ukyi-app/homelab/git/ref/heads/main"],
  ["gh", "api", "-X", "GET", "search/issues", "-f", "q=x"],
  ["gh", "api", "--method=HEAD", "x"],
  ["gh", "auth", "status", "--active", "--hostname", "github.com"],
  ["gh", "pr", "list"],
  ["gh", "pr", "view", "1"],
  ["gh", "run", "view", "1"],
  ["gh", "--version"],
  ["git", "--version"],
  ["kubectl", "config", "current-context"],
  ["kubectl", "-n", "app-x", "get", "deploy", "x", "-o", "json", "--request-timeout=20s"],
  ["kubectl", "get", "pods", "-A"],
  ["kubectl", "logs", "-n", "x", "deploy/x"],
  ["kubectl", "auth", "can-i", "list", "pods"],
  ["kubectl", "-n", "x", "rollout", "status", "deploy/x"],
  ["kubectl", "version", "--client", "-o", "json"],
  ["infisical", "secrets", "--path", "/apps/x", "--env", "prod", "-o", "json"],
  ["infisical", "secrets", "get", "KEY", "--path", "/apps/x"],
  ["infisical", "user", "get", "token", "--silent"],
  ["infisical", "--version"],
  ["curl", "-q", "-s", "-o", "/dev/null", "-w", "%{http_code}", "https://ghcr.io/token?scope=repository:ukyi-app/x:pull"],
  ["curl", "-q", "-sSfL", "-X", "GET", "-m", "20", "-H", "Accept: application/json", "https://x"],
  ["curl", "--version"],
  ["terraform", "version"],
  ["tf-github.sh", "plan"],
  ["/tmp/clone/tools/tf-github.sh", "verify"],
  ["jq", "-r", ".x"],
];

const WRITES: string[][] = [
  ["gh", "api", "-i", "-X", "POST", "repos/x/git/trees", "--input", "-"],
  ["gh", "api", "repos/x/pulls", "-f", "title=x"],
  ["gh", "api", "repos/x/pulls", "--input", "-"],
  ["gh", "api", "-XPATCH", "repos/x/pulls/1"],
  ["gh", "api", "graphql", "-f", "query=x"],
  ["gh", "pr", "create"],
  ["gh", "pr", "merge", "1"],
  ["gh", "repo", "create", "x"],
  ["gh", "workflow", "run", "x"],
  ["git", "push", "origin", "HEAD"],
  // 명령은 git을 못 부른다. clone은 core 임시 폴더 목적지만 exec가 따로 허용한다. 읽기 하위 명령도 --output으로 파일을 쓴다.
  ["git", "clone", "--depth", "1", "https://github.com/ukyi-app/homelab", "/tmp/x"],
  ["git", "-C", "/tmp/x", "rev-parse", "HEAD"],
  ["git", "show", "HEAD", "--output=/tmp/x"],
  ["git", "ls-remote", "https://github.com/ukyi-app/homelab"],
  ["kubectl", "config", "view"],
  ["kubectl", "config", "view", "--raw", "-o", "json"],
  ["kubectl", "get", "--raw=/api/v1/namespaces/x/secrets/y"],
  ["git", "-C", "/tmp/x", "commit", "-m", "x"],
  ["kubectl", "-n", "x", "annotate", "externalsecret", "x", "force-sync=1", "--overwrite"],
  ["kubectl", "apply", "-f", "-"],
  ["kubectl", "-n", "x", "create", "-f", "-"],
  ["kubectl", "delete", "pod", "x"],
  ["kubectl", "patch", "x", "y"],
  ["kubectl", "-n", "x", "rollout", "restart", "deploy/x"],
  ["kubectl", "-n", "x", "exec", "x", "--", "psql"],
  ["kubectl", "port-forward", "x", "1:1"],
  ["infisical", "secrets", "set", "--file", "/dev/stdin"],
  ["infisical", "secrets", "delete", "KEY"],
  ["infisical", "secrets", "folders", "create"],
  ["infisical", "run", "--", "sh"],
  ["infisical", "export"],
  ["infisical", "login"],
  ["curl", "-X", "POST", "https://x"],
  // -q가 없으면 ~/.curlrc의 request·data를 읽는다.
  ["curl", "-s", "https://x"],
  ["curl", "-q", "--config", "-", "https://x"],
  ["curl", "-q", "-K", "f", "https://x"],
  ["curl", "-q", "-XGET", "https://x"],
  ["curl", "-q", "-o", "/tmp/out", "https://x"],
  ["curl", "-q", "-w", "%output{/tmp/x}", "https://x"],
  ["curl", "-q", "-H", "@headers.txt", "https://x"],
  ["curl", "-q", "https://a", "https://b"],
  ["curl", "-q", "-sd", "x", "https://x"],
  ["curl", "-d", "a=b", "https://x"],
  ["curl", "-sd", "a=b", "https://x"],
  ["curl", "--json", "{}", "https://x"],
  ["curl", "-T", "f", "https://x"],
  ["terraform", "apply"],
  ["terraform", "plan"],
  ["tf-github.sh", "apply"],
  ["sh", "-c", "anything"],
  ["bash", "tools/tf-github.sh", "plan"],
  ["unknown-tool"],
];

describe("쓰기 판정(읽기 허용 목록, 나머지는 쓰기)", () => {
  for (const argv of READS) test(`읽기: ${argv.join(" ")}`, () => expect(classify(argv).write).toBe(false));
  for (const argv of WRITES) test(`쓰기: ${argv.join(" ")}`, () => expect(classify(argv).write).toBe(true));
});

// 값을 내는 호출 표시. exec가 이것들을 secretStdout 없이 실행하지 않는다.
const SENSITIVE: string[][] = [
  ["kubectl", "-n", "x", "get", "secret", "y", "-o", "json"],
  ["kubectl", "get", "secrets", "-A"],
  ["kubectl", "get", "Secret", "y"],
  ["kubectl", "get", "secrets.v1", "y"],
  ["kubectl", "get", "secret/y"],
  ["kubectl", "get", "pods,secrets"],
  ["kubectl", "describe", "secret", "y"],
  ["kubectl", "get", "--raw", "/api/v1/namespaces/x/secrets/y"],
  ["kubectl", "get", "--raw=/api/v1/namespaces/x/secrets/y"],
  ["kubectl", "config", "view", "--raw"],
  ["kubectl", "config", "view", "--flatten"],
  ["infisical", "secrets", "--path", "/apps/x"],
  ["infisical", "secrets", "get", "KEY"],
  ["infisical", "user", "get", "token"],
  ["infisical", "export"],
  ["gh", "auth", "token"],
  ["gh", "auth", "status", "--show-token"],
];
const NOT_SENSITIVE: string[][] = [
  ["kubectl", "get", "externalsecret", "app-secret"],
  ["kubectl", "get", "externalsecrets.external-secrets.io", "-A"],
  ["kubectl", "get", "pods"],
  ["gh", "auth", "status"],
];

describe("값을 내는 호출", () => {
  for (const argv of SENSITIVE) test(`민감: ${argv.join(" ")}`, () => expect(classify(argv).sensitiveOutput).toBe(true));
  for (const argv of NOT_SENSITIVE) test(`보통: ${argv.join(" ")}`, () => expect(classify(argv).sensitiveOutput ?? false).toBe(false));
});
