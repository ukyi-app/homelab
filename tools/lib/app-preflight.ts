// 앱 온보딩 체인의 **사전 판정** — 디스패치 전에 결정적으로 알 수 있는 실패만 거부로 승격한다.
//
// 왜 필요한가: `app init` 직후의 `app create`는 release 빌드(멀티아치, 수 분)가 끝나기 전이라
// 디스패처의 첫 관문에서 반드시 죽고, dispatch-only `app secrets`는 미온보딩 앱에 대해 run 안에서
// 죽는다. 두 실패 모두 `concurrency: homelab-mutation` 직렬화 큐를 한 번 소비하고 Telegram 실패
// 알림까지 낸다 — 로컬에서 0.1초면 알 수 있는 사실 때문에.
//
// ⚠️ 이 계층은 **권한 경계가 아니다.** 판정의 권위는 여전히 디스패처(reusable 워크플로)에 있고,
// 여기는 큐·알림 절약이다. 그래서 세 규칙을 지킨다:
//   ① 결정적인 것만 거부한다. 이미지 실존은 **승격하지 않는다** — `actions/runs?head_sha=` 프록시는
//      낡은 스냅샷(함정 원장 「GitHub API는 낡은 스냅샷을 200으로 돌려준다」)과 `push:false` PR
//      빌드 때문에 양방향으로 틀리고, GHCR org 패키지 첫 push private 함정도 겹친다.
//   ② **판정 불가는 fail-closed가 아니다.** 비-404 gh 오류(401·5xx·망 단절)에서는 통과시키고
//      디스패처에 위임한다 — 여기서 닫으면 GitHub 일시 장애가 정상 변이를 막는 새 실패 모드가 된다.
//   ③ 온보딩 판정은 **로컬 워킹트리**로 한다(원격 contents API가 아니라). 로컬 파일에는 stale 200
//      축이 없고, 판정 대상이 바로 이 레포의 산출물이다.
import { existsSync } from "node:fs";
import { appRel } from "./app-surface.ts";
import { sh } from "./exec.ts";
import { OWNER } from "./platform.ts";

// 통과는 이유를 싣지 않는다 — 결과 계약에 실리는 것은 거부뿐이다(성공 봉투 형상 불변).
export type Preflight = { ok: true } | { ok: false; error: string };

const APP_CONFIG = ".app-config.yml"; // 스캐폴더가 만드는 앱 레포 마커 = 디스패처 _create-app.yaml의 관문

// app create 사전 판정 — 앱 레포 main에 `.app-config.yml`이 있는가.
// ref는 main 고정이다(디스패처가 읽는 축과 같아야 한다 — 기본 브랜치를 읽으면 org 설정 변경 시
// 판정이 조용히 어긋난다). 404만 거부이고 그 외 실패는 전부 통과다(위 규칙 ②).
export function appConfigPreflight(app: string): Preflight {
  const r = sh("gh", ["api", `repos/${OWNER}/${app}/contents/${APP_CONFIG}?ref=main`, "--jq", ".name"]);
  if (r.ok) return { ok: true };
  if (!/\(HTTP 404\)/.test(r.err)) return { ok: true }; // 판정 불가 → 디스패처 위임
  return {
    ok: false,
    error: `앱 레포 main에 ${APP_CONFIG}가 없다(${OWNER}/${app}) — 스캐폴드·첫 push가 아직이다. \`homelab app init\`을 마치고 release run이 끝난 뒤 재실행하라`,
  };
}

// dispatch-only app secrets 사전 판정 — 이 homelab 워킹트리에 앱이 온보딩돼 있는가.
// base = 워킹트리 후보(호출자가 cwd의 git toplevel 또는 cwd를 준다). 그 아래 `apps/`가 없으면
// **homelab 워킹트리를 못 찾은 것**이므로 판정하지 않고 통과한다(fail-open — 규칙 ②와 같은 이유).
export function onboardedPreflight(app: string, base: string): Preflight {
  if (!existsSync(`${base}/apps`)) return { ok: true }; // 워킹트리 미발견 — 판정 생략
  if (existsSync(`${base}/${appRel(app).prod}`)) return { ok: true };
  return {
    ok: false,
    error: `미온보딩 앱 — 이 워킹트리(${base})에 ${appRel(app).prod}가 없다. \`homelab app create ${app}\`가 먼저다(디스패처도 run 안에서 같은 판정을 한다)`,
  };
}
