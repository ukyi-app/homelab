// Infisical 어댑터. 사람의 infisical login을 쓴다. 프로젝트 homelab, 환경 prod(설계 C.6).
// 값은 메모리에서 Secret으로만 다룬다. 출력·argv·파일에 두지 않는다. argv는 여기서만 만든다.
//
// 실측(infisical 0.44.2, 로컬 가짜 API 서버, 2026-10-23):
// - `secrets get <없는 키>`는 exit 0에 값 "*not found*"를 낸다. 그래서 존재는 폴더 목록(`secrets --path`)으로 본다.
// - 목록 JSON은 secretKey·secretValue뿐이다. 마지막 변경 시각(updatedAt)은 CLI로 읽을 수 없다(존재만, lead 결정).
// - `secrets set --file /dev/stdin`은 stdin의 .env 줄을 읽어 값을 요청 본문으로만 보낸다(argv에 값 없음).
//   .env 파싱은 앞뒤 공백을 자르고 양끝 따옴표를 벗긴다. 값 안의 #·$·${}·따옴표는 그대로 간다.
//   줄바꿈이 있으면 다음 줄이 다른 키가 된다. 그래서 setValue가 값 전체 형식을 먼저 본다.
import type { InfisicalRead, InfisicalWrite } from "./command";
import { ExecTimeout, why, type Exec } from "./exec";
import { PROJECT_ID, SECRET_KEY, fullMatch, hasControl } from "./names";
import { CliError } from "./result";
import { MIN_SECRET, Secret, revealSecret } from "./secret";

export const INFISICAL_ENV = "prod";
export const PROJECT_ENV = "HOMELAB_INFISICAL_PROJECT_ID";
// /apps/<앱>, /apps/<앱>/postgres 같은 폴더 경로.
const FOLDER = /\/[a-z0-9]([a-z0-9-]*[a-z0-9])?(\/[a-z0-9]([a-z0-9-]*[a-z0-9])?)*/;

// 프로젝트 ID 정하기. lead 결정(2026-10-23): 환경변수, 없고 tty면 한 번 묻기, 아니면 실패 + 다음 행동. 값은 저장소에 두지 않는다.
export type ProjectSource = { env: Record<string, string | undefined>; isTTY: boolean; ask: (q: string) => string | null };

export function projectResolver(src: ProjectSource): { id: () => string; status: () => "ok" | "missing" | "invalid" } {
  let cached: string | undefined;
  return {
    status() {
      const v = src.env[PROJECT_ENV];
      if (v === undefined || v === "") return "missing";
      return fullMatch(PROJECT_ID, v) ? "ok" : "invalid";
    },
    id() {
      if (cached) return cached;
      let v = src.env[PROJECT_ENV];
      if ((v === undefined || v === "") && src.isTTY) v = src.ask("Infisical homelab project ID: ") ?? undefined;
      if (v === undefined || v === "") throw new CliError(`${PROJECT_ENV}가 없다`, `export ${PROJECT_ENV}=<homelab project ID> 뒤 다시 실행한다`);
      if (!fullMatch(PROJECT_ID, v)) throw new CliError(`${PROJECT_ENV} 형식이 아니다(UUID)`, `${PROJECT_ENV}를 Infisical 프로젝트 설정의 ID로 고친다`);
      cached = v;
      return v;
    },
  };
}

function checkFolder(path: string): void {
  if (!fullMatch(FOLDER, path)) throw new Error("Infisical 폴더 경로 형식이 아니다");
}

function checkKey(key: string): void {
  if (!fullMatch(SECRET_KEY, key)) throw new Error("Infisical 키 이름 형식이 아니다");
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

// .env 한 줄로 왕복하고 16자 이상인 값만 받는다(위 실측, 사용자 결정 2026-10-23). 틀리면 이유, 맞으면 null.
export function valueProblem(value: Secret): string | null {
  const v = revealSecret(value);
  if (v.length < MIN_SECRET) return `값이 ${MIN_SECRET}자보다 짧다`;
  if (hasControl(v)) return "값에 줄바꿈·탭·제어 문자가 있다";
  // U+FFFD는 잘못 디코딩된 입력의 흔적이다(바이트 단위 디코딩 함정, #873 3라운드). 받으면 입력과 다른 값이 저장된다.
  if (v.includes("\uFFFD")) return "값에 깨진 문자(U+FFFD)가 있다";
  if (/^\s|\s$/.test(v)) return "값이 공백으로 시작하거나 끝난다(Infisical CLI가 자른다)";
  if (/^["'`]|["'`]$/.test(v)) return "값이 따옴표로 시작하거나 끝난다(Infisical CLI가 벗긴다)";
  return null;
}

export function infisicalRead(exec: Exec, project: ReturnType<typeof projectResolver>): InfisicalRead {
  // 폴더 목록을 읽어 키 이름과, 원하면 키 하나의 값을 낸다. 가져온(import) 키와 개인 덮어쓰기는 빼고 이 폴더의 shared 키만 본다.
  // 다른 키의 값은 Secret으로도 남기지 않고 버린다(필요 없는 값을 들고 다니지 않는다).
  const readFolder = (path: string, want?: string): { keys: string[]; value: Secret | null } => {
    checkFolder(path);
    const r = exec(argvFor.list(project.id(), path), { secretStdout: true });
    if (r.errKind === "timeout") throw new ExecTimeout(`Infisical ${path} 목록: 시간 초과`);
    if (r.code !== 0 || !r.stdoutSecret) throw new Error(`Infisical ${path} 목록: ${why(r)}`);
    let parsed: unknown;
    try {
      parsed = JSON.parse(revealSecret(r.stdoutSecret));
    } catch {
      throw new Error(`Infisical ${path} 목록: JSON이 아니다`);
    }
    if (!Array.isArray(parsed)) throw new Error(`Infisical ${path} 목록: 배열이 아니다`);
    const keys: string[] = [];
    let value: Secret | null = null;
    for (const item of parsed) {
      if (typeof item?.secretKey !== "string" || typeof item?.secretValue !== "string") throw new Error(`Infisical ${path} 목록: 모양이 다르다`);
      keys.push(item.secretKey);
      if (item.secretKey === want) value = new Secret(item.secretValue);
    }
    return { keys: keys.sort(), value };
  };
  return {
    has(path, key) {
      checkKey(key);
      return readFolder(path).keys.includes(key);
    },
    listKeys(path) {
      return readFolder(path).keys;
    },
    getValue(path, key) {
      checkKey(key);
      return readFolder(path, key).value;
    },
    valueHash(path, key) {
      checkKey(key);
      return readFolder(path, key).value?.sha256Prefix(12) ?? null;
    },
    projectStatus: () => project.status(),
  };
}

export function infisicalWrite(exec: Exec, project: ReturnType<typeof projectResolver>): InfisicalWrite {
  return {
    setValue(path, key, value) {
      checkFolder(path);
      checkKey(key);
      const problem = valueProblem(value);
      if (problem) throw new Error(`Infisical ${path}/${key}: ${problem}`);
      const line = new Secret(`${key}=${revealSecret(value)}\n`);
      const r = exec(argvFor.set(project.id(), path), { input: line });
      if (r.errKind === "timeout") throw new ExecTimeout(`Infisical ${path}/${key} 쓰기: 시간 초과(결과 미상)`);
      // 성공 표에는 값이 가려져(******) 나오지만 쓰지 않는다.
      if (r.code !== 0) throw new Error(`Infisical ${path}/${key} 쓰기: ${why(r)}`);
    },
    removeKey(path, key) {
      checkFolder(path);
      checkKey(key);
      const r = exec(argvFor.remove(project.id(), path, key));
      if (r.errKind === "timeout") throw new ExecTimeout(`Infisical ${path}/${key} 삭제: 시간 초과(결과 미상)`);
      if (r.code !== 0) throw new Error(`Infisical ${path}/${key} 삭제: ${why(r)}`);
    },
  };
}
