// mutation dispatcher payload 검증기 — 액션 계약표를 강제한다.
// 모든 입력은 비신뢰(owner 입력 포함): env/파일 경유로만 받고, 화이트리스트 regex와
// action별 필수/허용 입력 외에는 전부 거부한다. 위반 시 비-0 종료(값은 일부만 출력, 시크릿 없음).
// update-image는 이 dispatcher가 아니라 GHCR 폴링(bump-poll)이 처리하므로 계약표에 없다.
import { readFileSync } from "node:fs";
import { APP_NAME_RE, RESOURCE_NAME_RE, EXT_RE, resourceNameError } from "./lib/identity.ts";

function die(msg: string): never {
  console.error(`validate-mutation: ${msg}`);
  process.exit(1);
}

// 계약표: action → 필수 입력 (허용 입력 == 필수 입력; 그 외 비어 있지 않으면 거부)
// create-app/update-secrets는 sha를 입력으로 받지 않는다 — reusable이 앱 레포 main HEAD를
// 체크아웃해 해석한다(sha 입력은 거부). sha는 activate-app 행에만 남지만 그 액션은 이 검증기를 타지 않는다.
// ⚠️ activate-app·audit 행은 어떤 디스패처도 이 검증기로 라우팅하지 않는다(활성 호출처 0):
//   activate-app = owner-local CLI(tools/activate-app.ts 자체 검증), audit = 스케줄 reconciler(audit.yaml).
//   실제 --action 호출처는 create-app/create-cache/create-database/update-secrets/teardown-app(워크플로)
//   + teardown-resource(scripts/teardown.sh)뿐. 두 행은 선언적 아키타입 + 회귀 앵커(test_validate-mutation.bats)로만 보존한다.
// 모든 디스패처는 앱 이름만 받는다(repo는 ukyi-app/<app>로 reusable이 구성 — org는 코드에 고정).
const CONTRACT: Record<string, string[]> = {
  "create-app": ["app"],
  "activate-app": ["app", "sha"],
  "update-secrets": ["app"],
  "create-database": ["spec"],
  "create-cache": ["spec"],
  "teardown-app": ["app", "confirm"], // confirm은 app과 일치해야(파괴 오발사 가드 — 아래 교차검증)
  "teardown-resource": ["resource"],
  audit: [],
};

const FIELD_RE: Record<string, RegExp> = {
  app: APP_NAME_RE, // 앱 이름(= ukyi-app/<app> 레포명). slash 불가라 외부 org 표현 자체가 불가능
  confirm: APP_NAME_RE, // teardown-app 파괴 확인 — 형식은 app과 동일, 일치는 교차검증
  sha: /^[0-9a-f]{7,40}$/,
  resource: new RegExp(`^(db|cache):${RESOURCE_NAME_RE.source.slice(1, -1)}$`),
};

const PAYLOAD_KEYS = new Set(["action", "app", "sha", "resource", "spec", "confirm"]);

// spec(JSON 문자열) 검증 — 공유 클러스터 지원 필드만 (storage/cpu/mem/version은
// 클러스터 레벨 속성이라 DB/캐시 생성 API의 입력이 아니다 — 스키마 밖 필드 거부)
function validateSpec(action: string, specStr: string): void {
  let spec;
  try {
    spec = JSON.parse(specStr);
  } catch {
    die("spec이 유효한 JSON이 아니다");
  }
  if (typeof spec !== "object" || spec === null || Array.isArray(spec)) die("spec은 객체여야 한다");

  const allowed = action === "create-database" ? ["name", "owner", "extensions"] : ["name", "maxmemory_mi"];
  for (const k of Object.keys(spec)) {
    if (!allowed.includes(k)) die(`spec 허용 밖 필드: ${k} (허용: ${allowed.join(", ")})`);
  }
  const nameErr = resourceNameError(action === "create-database" ? "db" : "cache", String(spec.name ?? ""));
  if (nameErr) die(`spec.name ${nameErr}`); // 디스패처가 예약 이름(postgres/-ro 등)을 실행기 전에 거부
  if (action === "create-database") {
    // owner==name 불변식: owner 공유 시 한쪽 teardown/회전이 다른 DB를 깬다 (role↔DB 1:1)
    if (spec.owner !== undefined && spec.owner !== spec.name) die("spec.owner는 name과 같아야 한다(owner==name)");
    if (spec.extensions !== undefined) {
      if (!Array.isArray(spec.extensions)) die("spec.extensions는 배열이어야 한다");
      for (const e of spec.extensions) {
        if (!EXT_RE.test(String(e))) die(`extension 이름 불량: ${String(e).slice(0, 40)}`);
      }
    }
  }
  if (action === "create-cache" && spec.maxmemory_mi !== undefined) {
    if (!Number.isInteger(spec.maxmemory_mi) || spec.maxmemory_mi < 16 || spec.maxmemory_mi > 1024)
      die("spec.maxmemory_mi는 16..1024 정수여야 한다");
  }
}

// ---- 인자 파싱 ----
let action, payloadStr;
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === "--action") action = argv[++i];
  else if (argv[i] === "--payload") payloadStr = argv[++i];
  else if (argv[i] === "--payload-file") payloadStr = readFileSync(argv[++i], "utf8");
  else die(`알 수 없는 인자: ${argv[i]}`);
}
if (!action || payloadStr === undefined) die("--action과 --payload(-file) 필수");

if (!Object.hasOwn(CONTRACT, action)) die(`허용 밖 action: ${String(action).slice(0, 40)}`);

let payload;
try {
  payload = JSON.parse(payloadStr);
} catch {
  die("payload가 유효한 JSON이 아니다");
}
if (typeof payload !== "object" || payload === null || Array.isArray(payload)) die("payload는 객체여야 한다");

// 스키마 밖 키 거부 (dispatcher inputs와 1:1)
for (const k of Object.keys(payload)) {
  if (!PAYLOAD_KEYS.has(k)) die(`payload 허용 밖 키: ${k}`);
}
// payload.action이 있으면 --action과 일치해야 한다
if (payload.action !== undefined && payload.action !== "" && payload.action !== action)
  die(`payload.action(${String(payload.action).slice(0, 40)})이 --action(${action})과 불일치`);

const required = CONTRACT[action];
const get = (k: string) => String(payload[k] ?? "");

// 필수 입력: 비어 있으면 거부 + 형식 검증
for (const k of required) {
  const v = get(k);
  if (v === "") die(`action ${action}의 필수 입력 누락: ${k}`);
  if (k === "spec") validateSpec(action, v);
  else if (!FIELD_RE[k].test(v)) die(`${k} 형식 불량: ${v.slice(0, 60)}`);
}
// teardown-app: confirm은 app과 정확히 일치해야 한다(파괴 오발사 방지 — GitHub repo 삭제 방식)
if (action === "teardown-app" && get("confirm") !== get("app"))
  die(`confirm이 app과 불일치(파괴 확인 실패): confirm=${get("confirm").slice(0, 40)} ≠ app=${get("app").slice(0, 40)}`);
// 허용 밖 입력이 비어 있지 않으면 거부 (오입력 = 오동작 신호 — fail-closed)
for (const k of ["app", "sha", "resource", "spec", "confirm"]) {
  if (!required.includes(k) && get(k) !== "") die(`action ${action}이 허용하지 않는 입력: ${k}`);
}

console.log(JSON.stringify({ ok: true, action, inputs: Object.fromEntries(required.map((k) => [k, k === "spec" ? "(validated)" : get(k)])) }));
