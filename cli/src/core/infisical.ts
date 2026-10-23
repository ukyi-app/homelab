// Infisical 어댑터. 사람의 infisical login을 쓴다. 프로젝트 homelab, 환경 prod(설계 C.6).
// 값은 메모리에서 Secret으로만 다룬다. 출력·argv·파일에 두지 않는다.
//
// 실측(infisical 0.44.2, 로컬 가짜 API 서버, 2026-10-23):
// - `secrets get <없는 키>`는 exit 0에 값 "*not found*"를 낸다. 그래서 존재는 폴더 목록(`secrets --path`)으로 본다.
// - 목록 JSON은 secretKey·secretValue뿐이다. 마지막 변경 시각(updatedAt)은 CLI로 읽을 수 없다.
// - `secrets set --file /dev/stdin`은 stdin의 .env 줄을 읽어 값을 요청 본문으로만 보낸다(argv에 값 없음).
//   .env 파싱은 앞뒤 공백을 자르고 양끝 따옴표를 벗긴다. 값 안의 #·$·${}·따옴표는 그대로 간다.
//   줄바꿈이 있으면 다음 줄이 다른 키가 된다. 그래서 setValue가 값 전체 형식을 먼저 본다.
import type { Ctx } from "./command";
import { ExecTimeout, why } from "./exec";
import { PROJECT_ID, SECRET_KEY, fullMatch, hasControl } from "./names";
import { CliError } from "./result";
import { Secret } from "./secret";

export const INFISICAL_ENV = "prod";
export const PROJECT_ENV = "HOMELAB_INFISICAL_PROJECT_ID";
// /apps/<앱>, /apps/<앱>/postgres 같은 폴더 경로.
const FOLDER = /\/[a-z0-9]([a-z0-9-]*[a-z0-9])?(\/[a-z0-9]([a-z0-9-]*[a-z0-9])?)*/;

let cachedProject: string | undefined;

// lead 결정(2026-10-23): 환경변수, 없고 tty면 한 번 묻기, 아니면 실패 + 다음 행동. 값은 저장소에 두지 않는다.
export function projectId(ctx: Ctx): string {
  if (cachedProject) return cachedProject;
  let id = ctx.env[PROJECT_ENV];
  if (id === undefined && ctx.isTTY) id = ctx.ask("Infisical homelab project ID: ") ?? undefined;
  if (id === undefined || id === "") throw new CliError(`${PROJECT_ENV}가 없다`, `export ${PROJECT_ENV}=<homelab project ID> 뒤 다시 실행한다`);
  if (!fullMatch(PROJECT_ID, id)) throw new CliError(`${PROJECT_ENV} 형식이 아니다(UUID)`, `${PROJECT_ENV}를 Infisical 프로젝트 설정의 ID로 고친다`);
  cachedProject = id;
  return id;
}

function checkFolder(path: string): void {
  if (!fullMatch(FOLDER, path)) throw new Error(`Infisical 폴더 경로가 아니다: ${JSON.stringify(path)}`);
}

function checkKey(key: string): void {
  if (!fullMatch(SECRET_KEY, key)) throw new Error(`Infisical 키 이름이 아니다: ${JSON.stringify(key)}`);
}

function base(project: string, path: string): string[] {
  return ["--path", path, "--env", INFISICAL_ENV, "--projectId", project, "--silent"];
}

// argv 꼴. 시험 장치(cli/test/harness.ts)도 이 함수로 스텁 규칙을 만들어 어댑터와 어긋나지 않게 한다.
export const argvFor = {
  list: (project: string, path: string) => ["infisical", "secrets", ...base(project, path), "-o", "json", "--include-imports=false", "--expand=false", "--secret-overriding=false"],
  set: (project: string, path: string) => ["infisical", "secrets", "set", "--file", "/dev/stdin", ...base(project, path), "--type", "shared"],
  remove: (project: string, path: string, key: string) => ["infisical", "secrets", "delete", key, ...base(project, path), "--type", "shared"],
};

// 폴더의 키 → 값. 가져온(import) 키와 개인 덮어쓰기는 빼고 이 폴더의 shared 키만 본다.
export function listFolder(ctx: Ctx, path: string): Map<string, Secret> {
  checkFolder(path);
  const r = ctx.exec(argvFor.list(projectId(ctx), path), { secretStdout: true });
  if (r.errKind === "timeout") throw new ExecTimeout(`Infisical ${path} 목록: 시간 초과`);
  if (r.code !== 0 || !r.stdoutSecret) throw new Error(`Infisical ${path} 목록: ${why(r)}`);
  let parsed: unknown;
  try {
    parsed = JSON.parse(r.stdoutSecret.reveal());
  } catch {
    throw new Error(`Infisical ${path} 목록: JSON이 아니다`);
  }
  if (!Array.isArray(parsed)) throw new Error(`Infisical ${path} 목록: 배열이 아니다`);
  const out = new Map<string, Secret>();
  for (const item of parsed) {
    if (typeof item?.secretKey !== "string" || typeof item?.secretValue !== "string") throw new Error(`Infisical ${path} 목록: 모양이 다르다`);
    out.set(item.secretKey, new Secret(item.secretValue));
  }
  return out;
}

export function has(ctx: Ctx, path: string, key: string): boolean {
  checkKey(key);
  return listFolder(ctx, path).has(key);
}

export function getValue(ctx: Ctx, path: string, key: string): Secret | null {
  checkKey(key);
  return listFolder(ctx, path).get(key) ?? null;
}

// .env 한 줄로 왕복하지 않는 값은 받지 않는다(위 실측). 틀리면 이유, 맞으면 null.
export function valueProblem(value: Secret): string | null {
  const v = value.reveal();
  if (v.length === 0) return "값이 비었다";
  if (hasControl(v)) return "값에 줄바꿈·탭·제어 문자가 있다";
  if (/^\s|\s$/.test(v)) return "값이 공백으로 시작하거나 끝난다(Infisical CLI가 자른다)";
  if (/^["'`]|["'`]$/.test(v)) return "값이 따옴표로 시작하거나 끝난다(Infisical CLI가 벗긴다)";
  return null;
}

export function setValue(ctx: Ctx, path: string, key: string, value: Secret): void {
  checkFolder(path);
  checkKey(key);
  const problem = valueProblem(value);
  if (problem) throw new Error(`Infisical ${path}/${key}: ${problem}`);
  const line = new Secret(`${key}=${value.reveal()}\n`);
  const r = ctx.exec(argvFor.set(projectId(ctx), path), { input: line });
  if (r.errKind === "timeout") throw new ExecTimeout(`Infisical ${path}/${key} 쓰기: 시간 초과(결과 미상)`);
  // 성공 표에는 값이 가려져(******) 나오지만 쓰지 않는다.
  if (r.code !== 0) throw new Error(`Infisical ${path}/${key} 쓰기: ${why(r)}`);
}

export function removeKey(ctx: Ctx, path: string, key: string): void {
  checkFolder(path);
  checkKey(key);
  const r = ctx.exec(argvFor.remove(projectId(ctx), path, key));
  if (r.errKind === "timeout") throw new ExecTimeout(`Infisical ${path}/${key} 삭제: 시간 초과(결과 미상)`);
  if (r.code !== 0) throw new Error(`Infisical ${path}/${key} 삭제: ${why(r)}`);
}

// 시험이 프로젝트 ID 캐시를 지울 때만 쓴다.
export function resetProjectCache(): void {
  cachedProject = undefined;
}
