// gh·curl·git 어댑터. 사람의 gh 로그인을 쓰고 자격을 저장하지 않는다(설계 C.7). argv는 여기서만 만든다.
// gh api -i로 상태 줄을 함께 받는다. 404에도 gh는 exit 1이지만 상태 줄과 본문을 stdout에 내므로 상태 코드로 판정한다.
import { jsonParse, jsonStringify } from "./intrinsics";
import { existsSync, realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import type { GhcrRead, GhRead, GhResponse, GithubDelegate } from "./command";
import { ExecTimeout, why, type Exec } from "./exec";
import { findSecretPath } from "./guard";
import { APP_NAME, fullMatch, hasControl } from "./names";
import { containsTracked } from "./secret";
import { tempDir } from "./temp";

export const HOMELAB_REPO = "ukyi-app/homelab";
export const HOMELAB_URL = "https://github.com/ukyi-app/homelab.git";

function parse(stdout: string, what: string): GhResponse {
  const m = stdout.match(/^HTTP\/[\d.]+ (\d{3})/);
  if (!m) throw new Error(`${what}: gh api 응답에 상태 줄이 없다`);
  const sep = stdout.search(/\r?\n\r?\n/);
  const text = sep === -1 ? "" : stdout.slice(sep).replace(/^\r?\n\r?\n/, "");
  let json: any = null;
  if (text.trim()) {
    try {
      json = jsonParse(text);
    } catch {
      json = null;
    }
  }
  return { status: Number(m[1]), json };
}

function call(exec: Exec, argv: string[], what: string, input?: string): GhResponse {
  const r = exec(argv, input === undefined ? {} : { input });
  if (r.errKind === "timeout") throw new ExecTimeout(`${what}: 시간 초과(결과 미상)`);
  if (r.errKind) throw new Error(`${what}: ${why(r)}`);
  return parse(r.stdout, what);
}

// argv 꼴. 시험 장치도 이 함수로 스텁 규칙을 만든다.
export const argvFor = {
  get: (path: string) => ["gh", "api", "-i", path],
  send: (method: string, path: string) => ["gh", "api", "-i", "-X", method, path, "--input", "-"],
  ghcr: (app: string) => ["curl", "-q", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "20", `https://ghcr.io/token?scope=repository:ukyi-app/${app}:pull`],
};

// GET 경로. ukyi-app의 저장소·org와 로그인 사용자만. graphql·다른 owner는 받지 않는다.
const GET_PATH = /^(user|(repos|orgs)\/ukyi-app(\/[A-Za-z0-9._~%:@!$&'()*+,;=?\/-]*)?)$/;

export function ghGetRaw(exec: Exec, path: string): GhResponse {
  if (hasControl(path) || !GET_PATH.test(path)) throw new Error("gh GET 경로 형식이 아니다(repos/ukyi-app/…, orgs/ukyi-app/…, user)");
  return call(exec, argvFor.get(path), `GET ${path}`);
}

// 쓰기. core 안(pr.ts 등)에서만 쓰고 명령에는 주지 않는다.
export function ghSend(exec: Exec, method: "POST" | "PATCH" | "PUT" | "DELETE", path: string, body: unknown): GhResponse {
  if (hasControl(path) || !/^repos\/ukyi-app\/[A-Za-z0-9._\/-]+$/.test(path)) throw new Error("gh 쓰기 경로 형식이 아니다");
  const where = findSecretPath(body, "body");
  if (where) throw new Error(`${method} ${path}: 요청 본문(${where})에 시크릿 객체가 있다`);
  const text = jsonStringify(body);
  // 이 CLI는 GitHub에 시크릿을 보내지 않는다(공개 저장소의 파일·PR 본문뿐).
  if (containsTracked(text)) throw new Error(`${method} ${path}: 요청 본문에 시크릿 값이 섞였다`);
  return call(exec, argvFor.send(method, path), `${method} ${path}`, text);
}

// 2xx가 아니면 던진다. GitHub의 message만 붙인다.
export function ok(r: GhResponse, what: string): GhResponse {
  if (r.status < 200 || r.status >= 300) throw new Error(`${what}: HTTP ${r.status}${typeof r.json?.message === "string" ? ` ${r.json.message.slice(0, 200)}` : ""}`);
  return r;
}

export function ghRead(exec: Exec): GhRead {
  return {
    get: (path) => ghGetRaw(exec, path),
    login() {
      const login = ok(ghGetRaw(exec, "user"), "gh 로그인 사용자").json?.login;
      if (typeof login !== "string" || !login) throw new Error("gh 로그인 사용자를 읽지 못했다");
      return login;
    },
  };
}

// curl 어댑터는 이것 하나다(사용자 결정 2026-10-23): 정해진 URL 꼴, -q로 .curlrc를 끄고 설정 옵션은 없다.
export function ghcrRead(exec: Exec): GhcrRead {
  return {
    anonymousPullStatus(app) {
      if (!fullMatch(APP_NAME, app)) throw new Error("앱 이름 형식이 아니다");
      const r = exec(argvFor.ghcr(app));
      if (r.errKind === "timeout") throw new ExecTimeout("GHCR 익명 토큰: 시간 초과");
      if (r.errKind || r.code !== 0) throw new Error(`GHCR 익명 토큰: ${why(r)}`);
      const code = Number(r.stdout.trim());
      if (!Number.isInteger(code)) throw new Error("GHCR 익명 토큰: 응답 코드를 읽지 못했다");
      return code;
    },
  };
}

// github 위임(C.3.9): main을 core 임시 폴더로 fresh clone하고 그 사본의 tools/tf-github.sh를 부른다.
// git은 래퍼와 같은 방식으로 env -i처럼 띄워 작업 사본·전역·시스템 git 설정과 hook을 끊는다(tf-github.sh 1단계).
// TF_GITHUB_CLONE을 주면 래퍼가 이 사본을 다시 clone하지 않고 쓴다. 래퍼가 묻는 값과 yes는 사람이 직접 답한다(stdin 상속).
export const WRAPPER_GIT_ARGS = ["-c", "core.hooksPath=NOHOOKS", "-c", "protocol.allow=never", "-c", "protocol.https.allow=always", "clone", "-q", "--depth", "1", "--branch", "main", "--no-tags", HOMELAB_URL];

export function cloneArgv(work: string): string[] {
  return ["git", ...WRAPPER_GIT_ARGS.map((a) => (a === "core.hooksPath=NOHOOKS" ? `core.hooksPath=${join(work, "nohooks")}` : a)), join(work, "tree")];
}

// CLI를 실행한 폴더가 든 checkout의 루트(.git이 폴더든 파일이든). 없으면 null. git을 부르지 않고 경로만 거슬러 본다
// (읽기 문맥은 git 하위 명령을 쓰기로 막는다). 래퍼에 TF_GITHUB_ORIGIN_ROOT로 넘겨 state 백업이 그 안에 생기지 않게 한다
// (Connector 4360754428, codex 확인 라운드 P2: 래퍼를 clone 안에서 돌리면 래퍼의 repo_root·origin_root가 둘 다 clone이 된다).
export function originRoot(cwd: string): string | null {
  let dir: string;
  try {
    dir = realpathSync(cwd);
  } catch {
    return null;
  }
  for (;;) {
    if (existsSync(join(dir, ".git"))) return dir;
    const up = dirname(dir);
    if (up === dir) return null;
    dir = up;
  }
}

export function githubDelegate(readExec: Exec, writeOnce: () => Exec | null, env: Record<string, string | undefined>, json: boolean, cwd: string): GithubDelegate {
  return {
    run(sub, opts = {}) {
      const exec = sub === "apply" ? writeOnce() : readExec;
      if (!exec) throw new Error("github apply는 apply 문맥(homelab github apply)에서만 실행한다");
      const work = tempDir("github", ["nohooks", "home"]);
      const clean: Record<string, string> = { PATH: env.PATH ?? "/usr/bin:/bin", HOME: join(work, "home"), GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1", GIT_TERMINAL_PROMPT: "0" };
      if (env.TMPDIR) clean.TMPDIR = env.TMPDIR;
      const c = readExec(cloneArgv(work), { cleanEnv: clean, cloneInto: work, timeoutMs: 120_000 });
      if (c.code !== 0) throw new Error(`main을 clone하지 못했다: ${why(c)}`);
      const r = exec([join(work, "tree", "tools", "tf-github.sh"), sub, ...(opts.allowDestroy ? ["--allow-destroy"] : [])], {
        stdio: json ? "stdout-to-stderr" : "inherit",
        // 래퍼는 TF_GITHUB_CLONE을 보기 전에 git rev-parse --show-toplevel을 set -e로 실행한다. cwd를 clone으로 두지 않으면
        // 저장소 밖(예: 홈)에서 실행한 CLI가 exit 128로 끝난다(#873 3라운드). 백업 경로 보호의 기준도 이 clone이 된다.
        cwd: join(work, "tree"),
        // 상속된 TF_GITHUB_ORIGIN_ROOT는 쓰지 않는다(이 실행의 cwd로만 정한다). GIT_* 제거는 exec가 한다.
        env: { TF_GITHUB_CLONE: work, TF_GITHUB_ORIGIN_ROOT: originRoot(cwd) ?? undefined },
        timeoutMs: 3_600_000,
      });
      if (r.errKind === "not-found") throw new Error("clone한 main에 tools/tf-github.sh가 없다");
      return r.code ?? 1;
    },
  };
}
