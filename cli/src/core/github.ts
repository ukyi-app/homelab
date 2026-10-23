// gh 어댑터. 사람의 gh 로그인을 쓰고 자격을 저장하지 않는다(설계 C.7).
// gh api -i로 상태 줄을 함께 받는다. 404에도 gh는 exit 1이지만 상태 줄과 본문을 stdout에 내므로 상태 코드로 판정한다.
import type { Ctx } from "./command";
import { ExecTimeout, why } from "./exec";
import { findSecretPath } from "./guard";
import { containsTracked } from "./secret";

export const HOMELAB_REPO = "ukyi-app/homelab";

export type GhResponse = { status: number; json: any; text: string };

function parse(stdout: string, what: string): GhResponse {
  const m = stdout.match(/^HTTP\/[\d.]+ (\d{3})/);
  if (!m) throw new Error(`${what}: gh api 응답에 상태 줄이 없다`);
  const sep = stdout.search(/\r?\n\r?\n/);
  const text = sep === -1 ? "" : stdout.slice(sep).replace(/^\r?\n\r?\n/, "");
  let json: any = null;
  if (text.trim()) {
    try {
      json = JSON.parse(text);
    } catch {
      json = null;
    }
  }
  return { status: Number(m[1]), json, text };
}

function call(ctx: Ctx, argv: string[], what: string, input?: string): GhResponse {
  const r = ctx.exec(argv, input === undefined ? {} : { input });
  if (r.errKind === "timeout") throw new ExecTimeout(`${what}: 시간 초과(결과 미상)`);
  if (r.errKind) throw new Error(`${what}: ${why(r)}`);
  return parse(r.stdout, what);
}

// argv 꼴. 시험 장치도 이 함수로 스텁 규칙을 만든다.
export const argvFor = {
  get: (path: string) => ["gh", "api", "-i", path],
  send: (method: string, path: string) => ["gh", "api", "-i", "-X", method, path, "--input", "-"],
};

export function ghGet(ctx: Ctx, path: string): GhResponse {
  return call(ctx, argvFor.get(path), `GET ${path}`);
}

export function ghSend(ctx: Ctx, method: "POST" | "PATCH" | "PUT" | "DELETE", path: string, body: unknown): GhResponse {
  const where = findSecretPath(body, "body");
  if (where) throw new Error(`${method} ${path}: 요청 본문(${where})에 시크릿 객체가 있다`);
  const text = JSON.stringify(body);
  // 이 CLI는 GitHub에 시크릿을 보내지 않는다(공개 저장소의 파일·PR 본문뿐).
  if (containsTracked(text)) throw new Error(`${method} ${path}: 요청 본문에 시크릿 값이 섞였다`);
  return call(ctx, argvFor.send(method, path), `${method} ${path}`, text);
}

// 2xx가 아니면 던진다. GitHub의 message만 붙인다.
export function ok(r: GhResponse, what: string): GhResponse {
  if (r.status < 200 || r.status >= 300) throw new Error(`${what}: HTTP ${r.status}${r.json?.message ? ` ${r.json.message}` : ""}`);
  return r;
}

export function currentLogin(ctx: Ctx): string {
  const login = ok(ghGet(ctx, "user"), "gh 로그인 사용자").json?.login;
  if (typeof login !== "string" || !login) throw new Error("gh 로그인 사용자를 읽지 못했다");
  return login;
}
