// 입력 값 검증. 셸·파일·API로 넘기는 값은 줄바꿈(CR·LF)과 NUL을 먼저 거부하고 값 전체를 형식과 맞춘다.
// 함정(#872 리뷰): 줄 단위 검사(grep -q, 앵커 없는 정규식)는 여러 줄 중 한 줄만 맞아도 통과한다.
// 그래서 fullMatch는 정규식을 ^(?:...)$로 다시 감싸고 m 플래그를 버린다.

const CONTROL = /[\u0000-\u001f\u007f]/;

export function hasControl(value: string): boolean {
  return CONTROL.test(value);
}

export function fullMatch(re: RegExp, value: string): boolean {
  if (hasControl(value)) return false;
  const flags = re.flags.replace(/[gmy]/g, "");
  return new RegExp(`^(?:${re.source})$`, flags).test(value);
}

// 앱 이름: Helm 릴리스 이름 상한 53자(platform/charts/app/templates/_helpers.tpl).
export const APP_NAME = /[a-z0-9]([a-z0-9-]{0,51}[a-z0-9])?/;
// 공개 host(platform/charts/app/values.schema.json).
export const PUBLIC_HOST = /[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.ukyi\.app/;
// 내부 이름(values.schema.json). 클러스터 접두를 붙인 길이와 예약어는 명령이 따로 본다(설계 C.4.4).
export const INTERNAL_NAME = /[a-z]([a-z0-9-]{0,61}[a-z])?/;
export const RESERVED_INTERNAL = ["go", "vm-go", "tailscale-operator", "vm-tailscale-operator"];
// Infisical 키 이름. 앱 차트의 env 이름과 같은 꼴.
export const SECRET_KEY = /[A-Z][A-Z0-9_]*/;
export const GIT_SHA = /[0-9a-f]{40}/;
export const IMAGE_DIGEST = /sha256:[0-9a-f]{64}/;
// Infisical 프로젝트 ID(UUID).
export const PROJECT_ID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/;
// 저장소 안 파일 경로: 상대 경로, ..·빈 조각 없음.
export const REPO_PATH = /[A-Za-z0-9._-]+(\/[A-Za-z0-9._-]+)*/;

// 앱 이름 검사. 틀리면 이유를, 맞으면 null. 차트가 렌더에서 막는 것을 PR 전에 먼저 본다.
// 캐시 Valkey: init 컨테이너 <앱>-valkey-init이 63자 안이라 51자, 이름에 valkey 금지(app/_helpers.tpl).
// 영속 Valkey: CronJob <앱>-valkey-backup이 52자 안이라 38자(설계 C.5.6).
export function appNameProblem(name: string, opts: { cache?: boolean; persistent?: boolean } = {}): string | null {
  if (!fullMatch(APP_NAME, name)) return "앱 이름은 소문자·숫자·하이픈, 53자 이하, 하이픈으로 시작·끝나지 않는다";
  if (opts.persistent && name.length > 38) return "영속 Valkey를 쓰는 앱 이름은 38자 이하다";
  if (opts.cache && name.length > 51) return "캐시 Valkey를 쓰는 앱 이름은 51자 이하다";
  if (opts.cache && name.includes("valkey")) return "캐시 Valkey를 쓰는 앱 이름에 valkey를 넣지 않는다";
  return null;
}

export function repoPathProblem(path: string): string | null {
  if (!fullMatch(REPO_PATH, path) || path.split("/").some((p) => p === "." || p === "..")) return `저장소 경로가 아니다: ${JSON.stringify(path)}`;
  return null;
}
