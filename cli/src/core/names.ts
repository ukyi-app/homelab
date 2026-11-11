// 입력 값 검증. 셸·파일·API로 넘기는 값은 줄바꿈(CR·LF)과 NUL을 먼저 거부하고 값 전체를 형식과 맞춘다.
// 함정: 줄 단위 검사(grep -q, 앵커 없는 정규식)는 여러 줄 중 한 줄만 맞아도 통과한다.
// 그래서 fullMatch는 정규식을 ^(?:...)$로 다시 감싸고 m 플래그를 버린다.
import type { BotMethod } from "./command";
import { jsonStringify } from "./intrinsics";

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
// Infisical 키 이름. 앱 차트의 env 이름과 같은 꼴(platform/charts/app/values.schema.json envName).
export const SECRET_KEY = /[A-Z_][A-Z0-9_]*/;
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
  if (!fullMatch(REPO_PATH, path) || path.split("/").some((p) => p === "." || p === "..")) return `저장소 경로가 아니다: ${jsonStringify(path)}`;
  return null;
}

// 복원 실행 id: UTC YYYYMMDDHHMMSS + 16진 6자 = 20자. 라벨 homelab.ukyi.app/restore의 ^[a-z0-9]{1,22}$에 맞는다.
// 봇 모델 계정(homelab bot account, 봇 COLLEAGUE_SPEC §4.8). 이름은 봇 src/model-accounts.ts ACCOUNT_NAME과 같다.
// 이름은 Infisical 폴더 이름 조각이자 봇 지표 라벨 값(homelab_bot_model_account{account})이 된다.
export const BOT_ACCOUNT_NAME = /[a-z]([a-z0-9-]{0,30}[a-z0-9])?/;
// 계정별 값 폴더. 작업자 store(infisical-sandbox, /apps/homelab-bot/worker)와 앱 store(infisical-apps, /apps)의 기본 경로
// 밖이다. Free 플랜은 경로 RBAC가 없어 secretsPath가 보안 경계는 아니다(platform/external-secrets 머리 주석). 이 폴더를 읽는
// ExternalSecret이 없고, 생기려면 Git PR이 필요하다는 것이 경계다.
export const botAccountFolder = (name: string) => `/bot-accounts/${name}`;
// 작업자가 읽는 폴더와 레인별 키(rotate.md 3e 표). 계정 폴더도 같은 키 이름을 쓴다. 방식마다 키가 다르다
// (key: 구독 장기 토큰, apiKey: API 크레딧 방식의 Console API 키. 봇 DECISIONS "C23 API 크레딧 방식" 표).
export const BOT_WORKER_FOLDER = "/apps/homelab-bot/worker";
export const BOT_LANES = [
  { lane: "chat", label: "대화용", key: "CLAUDE_CODE_OAUTH_TOKEN", apiKey: "ANTHROPIC_API_KEY", secret: "worker-credential-claude-subscription" },
  { lane: "task", label: "작업용", key: "CLAUDE_CODE_OAUTH_TOKEN_TASK", apiKey: "ANTHROPIC_API_KEY_TASK", secret: "worker-task-credential-claude-subscription" },
] as const;
export const botLaneKey = (lane: (typeof BOT_LANES)[number], method: BotMethod) => (method === "api" ? lane.apiKey : lane.key);
// 작업자 Secret의 ns. Secret 키 = 작업자 볼륨 파일 이름은 두 레인이 같다(작업 레인은 _TASK 원격 키를 이 이름으로 옮긴다).
export const BOT_WORKER_NS = "sandbox";
export const BOT_WORKER_FILE: Record<BotMethod, string> = { subscription: "CLAUDE_CODE_OAUTH_TOKEN", api: "ANTHROPIC_API_KEY" };
// 방식 표시 키(Infisical 키 = Secret 키 = 파일 이름, 두 레인이 같은 원격 키 하나를 읽는다)와 값. 값이 없으면 작업자는 구독으로 본다.
// 안 쓰는 방식의 키는 지우지 않고 BOT_UNSET으로 둔다(ExternalSecret은 키가 Infisical에 있어야 Ready다).
export const BOT_METHOD_KEY = "CLAUDE_AUTH_METHOD";
export const BOT_UNSET = "unset";
// 비밀이 아닌 고정 값의 sha256 앞 12자(Secret·볼륨 지문과 같은 꼴).
export const publicHash = (value: string) => new Bun.CryptoHasher("sha256").update(value).digest("hex").slice(0, 12);

export function newRunId(now: Date = new Date()): string {
  const stamp = now.toISOString().replace(/[-:T]/g, "").slice(0, 14);
  const rand = [...crypto.getRandomValues(new Uint8Array(3))].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${stamp}${rand}`;
}
