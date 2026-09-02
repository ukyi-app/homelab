// homelab app init 엔진 — 앱 레포의 시작을 끝까지 만드는 멱등·재개 가능 로컬 체인
// (스펙 "app init 체인"). 순서: preflight(부수효과 0) → 템플릿에서 레포 생성(기본 private) →
// 클론 → 스캐폴더 비대화형 실행 → invocation marker 기록 → 커밋·첫 push → [--dispatch-secrets면
// 디스패치 시크릿 쌍 설정]. 각 단계는 사후조건으로 증명하고, 재실행은 그 지점부터 수렴한다.
//
// 소유 증명은 계보(템플릿 출처)가 아니라 invocation marker다(plan r2 r2-a2 — 계보는 다른 템플릿
// 레포를 입양할 수 있다): init이 첫 스캐폴드 커밋에 도구 식별자+앱명 마커(.homelab-init)를 담고,
// 재개는 마커가 확인된 레포에서만 자동 진행한다. 마커 없는 기존 레포는 fail-closed(--adopt로만).
//
// 시크릿 원자성: 디스패치 시크릿 2개(App ID·private key)는 한 쌍 — 절반 상태는 결과에 명시되고
// 재실행이 나머지를 수렴시킨다. private key 값은 어떤 출력에도 나타나지 않는다(gh secret set은
// --body-file로 값을 넘겨 argv 원장에 값이 남지 않는다 — 이 엔진은 키 파일을 읽지도 않는다).
import { existsSync, writeFileSync } from "node:fs";
import { compact } from "./contract.ts";
import { ALLOW_PUSH_REWRITE_ENV, git, pushRoutes, sh } from "./exec.ts";
import { APP_NAME_RE, isCanonicalClone, pushRouteError } from "./identity.ts";
import { ARCHETYPES, OWNER, TEMPLATE_REPO } from "./platform.ts";
import { SCAFFOLD_ENTRY, scaffoldContractError } from "./template-contract.ts";

export type AppInitInput = {
  app: string;
  archetype: string;
  public?: boolean;
  dispatchSecrets?: string; // App 키 경로(디렉토리: app-id + private-key.pem). 미지정=크론 백스톱.
  adopt?: boolean;          // 마커 없는 기존 레포를 명시 입양(사용자 확인)
  parentDir?: string;       // 대상 부모 디렉토리(MCP 명시 입력 — stdio 서버 cwd 추론 불가, plan r1 b7). 미설정=process.cwd().
};

export type InitOutcome = { variant: string; omitted: string[]; result: Record<string, unknown> };

const MARKER_FILE = ".homelab-init";        // invocation marker(레포 루트 — scaffold self-delete 대상 아님)
const MARKER_TOOL = "homelab-app-init";     // 도구 식별자(소유 술어)
const SCAFFOLD_MARKER = ".app-config.yml";  // 스캐폴드 완료 사후조건(연구 노트 §2)
const SECRET_APP_ID = "HOMELAB_DISPATCH_APP_ID";
const SECRET_PRIVATE_KEY = "HOMELAB_DISPATCH_APP_PRIVATE_KEY";

export function appInitInputError(input: AppInitInput): string | null {
  if (!APP_NAME_RE.test(input.app ?? "")) return `앱 이름 형식 불량(소문자 kebab, 2..40): ${input.app}`;
  if (!(ARCHETYPES as readonly string[]).includes(input.archetype ?? "")) {
    return `아키타입은 ${ARCHETYPES.join("|")} 중 하나여야 한다: ${input.archetype}`;
  }
  return null;
}

// gh api 3상 — ok(본문)/missing(404)/error(그 외). doctor의 gh()와 같은 원칙(판정 불가 fail-closed).
type Api = { ok: boolean; out: string; missing: boolean; err: string };
function api(args: string[]): Api {
  const r = sh("gh", args);
  if (r.ok) return { ok: true, out: r.out, missing: false, err: "" };
  return { ok: false, out: "", missing: /\(HTTP 404\)/.test(r.err), err: r.err.split("\n")[0] || "gh 실패" };
}

// 원격 마커 판독 — contents API base64 디코드 후 tool+app 대조. present/absent/mismatch/error.
type Marker = { kind: "present" } | { kind: "absent" } | { kind: "mismatch"; app: string } | { kind: "error"; err: string };
function readRemoteMarker(app: string): Marker {
  const r = api(["api", `repos/${OWNER}/${app}/contents/${MARKER_FILE}`, "--jq", ".content"]);
  if (r.missing) return { kind: "absent" };
  if (!r.ok) return { kind: "error", err: r.err };
  let decoded: { tool?: string; app?: string };
  try { decoded = JSON.parse(Buffer.from(r.out.replace(/\s+/g, ""), "base64").toString("utf8")); }
  catch { return { kind: "error", err: "마커 디코드 실패" }; }
  if (decoded.tool !== MARKER_TOOL) return { kind: "absent" }; // 다른 도구의 파일 = 우리 마커 아님
  if (decoded.app !== app) return { kind: "mismatch", app: String(decoded.app ?? "?") };
  return { kind: "present" };
}

// 시크릿 목록 조회 — 설정된 이름 집합. 조회 실패는 null(판정 불가).
function listSecrets(app: string): Set<string> | null {
  const r = api(["secret", "list", "--repo", `${OWNER}/${app}`, "--json", "name", "--jq", ".[].name"]);
  if (!r.ok) return null;
  return new Set(r.out.split("\n").map((s) => s.trim()).filter((s) => s !== ""));
}

// --dispatch-secrets 경로의 키 파일 — app-id + private-key.pem. private key는 절대 읽지 않는다.
function secretFiles(dir: string): { idFile: string; keyFile: string } {
  return { idFile: `${dir}/app-id`, keyFile: `${dir}/private-key.pem` };
}

export function runAppInit(input: AppInitInput, parentDir: string = process.cwd()): InitOutcome {
  const bad = appInitInputError(input);
  if (bad) throw new Error(`계약 파손: runAppInit에 검증 안 된 입력 — ${bad}`);
  const app = input.app;
  const isPublic = input.public === true;
  const wantSecrets = input.dispatchSecrets !== undefined;
  const base: Record<string, unknown> = { app, archetype: input.archetype, public: isPublic, repo: `${OWNER}/${app}` };
  const fail = (error: string, checkpoint: string, extra: Record<string, unknown> = {}): InitOutcome =>
    ({ variant: "failure", omitted: [], result: compact({ ...base, ...extra, checkpoint, error }) });

  // ── preflight — 부수효과 0. 실패면 아무것도 만들지 않고 거부한다. ──
  // (1) 디스패치 시크릿 키 경로(요청 시): 두 파일 모두 존재해야 한다.
  if (wantSecrets) {
    const { idFile, keyFile } = secretFiles(input.dispatchSecrets!);
    if (!existsSync(idFile) || !existsSync(keyFile)) {
      return fail(`--dispatch-secrets 경로에 키 파일 부재(app-id·private-key.pem 필요): ${input.dispatchSecrets}`, "preflight");
    }
  }
  // (2) 템플릿 스캐폴더 계약 호환성 — doctor와 같은 술어(structure r1 a3). 비호환이면 init 거부.
  const scaffoldSrc = api(["api", `repos/${TEMPLATE_REPO}/contents/${SCAFFOLD_ENTRY}`, "--jq", ".content"]);
  if (!scaffoldSrc.ok) return fail(`템플릿 스캐폴더 조회 실패(${TEMPLATE_REPO}) — 접근성/구조 확인`, "preflight");
  let scaffoldText: string;
  try { scaffoldText = Buffer.from(scaffoldSrc.out.replace(/\s+/g, ""), "base64").toString("utf8"); }
  catch { return fail("템플릿 스캐폴더 디코드 실패", "preflight"); }
  const contractErr = scaffoldContractError(scaffoldText);
  if (contractErr !== null) return fail(`템플릿 스캐폴더 비대화형 계약 마커 부재(${contractErr}) — 이 템플릿과 비호환`, "preflight");

  // (3) 레포 존재·소유 판정.
  const repo = api(["api", `repos/${OWNER}/${app}`, "--jq", ".name"]);
  const exists = repo.ok;
  if (!exists && !repo.missing) return fail(`레포 조회 실패(${OWNER}/${app}) — ${repo.err}`, "preflight");

  let created = false;
  let adopted = false;
  if (exists) {
    const marker = readRemoteMarker(app);
    if (marker.kind === "error") return fail(`마커 조회 실패 — ${marker.err}`, "preflight", { existed: true });
    if (marker.kind === "mismatch") {
      return fail(`레포에 다른 앱(${marker.app})의 init 마커가 있다 — 이름 충돌(입양 금지)`, "preflight", { existed: true });
    }
    if (marker.kind === "absent") {
      // 마커 없는 기존 레포 — fail-closed(--adopt로만). 소유를 증명할 수 없으므로 기본 거부.
      if (input.adopt !== true) {
        return fail(`레포(${OWNER}/${app})가 이미 있으나 init 마커가 없다 — 소유 미증명. 확인 후 --adopt로만 이어갈 수 있다`, "preflight", { existed: true });
      }
      adopted = true;
    }
    // marker.kind === "present" → 소유 확인, 스캐폴드+push 완료. 남은 것은 시크릿뿐(아래에서 수렴).
    base.existed = true;
  } else {
    // ── 레포 생성(부수효과) — 템플릿에서, 기본 private. ──
    const vis = isPublic ? "--public" : "--private";
    // timeoutMs: 0 — 템플릿 복제는 GitHub 쪽 왕복이라 seam 기본 30s가 망 사정으로 끊을 수 있다.
    const create = sh("gh", ["repo", "create", `${OWNER}/${app}`, "--template", TEMPLATE_REPO, vis], { timeoutMs: 0 });
    if (!create.ok) return fail(`레포 생성 실패 — ${create.err.split("\n")[0] || "gh repo create 비-0"}`, "preflight");
    created = true;
  }

  const markerPresent = exists && !adopted; // 소유 마커가 원격에 이미 있으면 스캐폴드/push 불필요
  const dest = `${parentDir}/${app}`;
  const cloneUrl = `https://github.com/${OWNER}/${app}.git`; // canonical(테스트는 insteadOf로 로컬 bare에 매핑)

  let scaffolded = markerPresent;
  let pushed = markerPresent;

  if (!markerPresent) {
    // ── 클론(멱등) — dest가 이미 우리 클론이면 재사용, 아니면 클론. ──
    const cloneReady = ensureClone(parentDir, app, dest, cloneUrl);
    if (cloneReady !== null) return fail(cloneReady, created ? "created" : "preflight", { created });

    // ── push 라우팅 안전 — origin.url(원본 설정값)이 canonical이어도 pushurl/insteadOf/pushInsteadOf가
    // push를 다른 곳으로 보낼 수 있다. push 지향 관측을 공유 진단(identity.pushRouteError)에 넘겨
    // fail-closed로 본다. 테스트 하네스(insteadOf→로컬 bare)는 명시 플래그로만 완화된다. ──
    if (process.env[ALLOW_PUSH_REWRITE_ENV] !== "1") {
      const routeErr = pushRouteError(OWNER, app, pushRoutes(dest));
      if (routeErr !== null) return fail(`${routeErr} — 수동 확인 필요`, "cloned", { created });
    }

    // ── 스캐폴드(멱등) — 이미 되어 있으면(.app-config.yml 존재 + scaffold/ 부재) 건너뛴다. ──
    // 두 조건 모두 봐야 한다: 스캐폴더가 .app-config.yml을 먼저 쓴 뒤 self-delete 전에 실패하면
    // config만으로 스킵하면 반쪽 스캐폴드가 성공으로 통과한다(scaffold/ 잔존 = 미완).
    if (!existsSync(`${dest}/${SCAFFOLD_MARKER}`) || existsSync(`${dest}/scaffold`)) {
      // ⚠️ 스캐폴더는 **진입점 파일을 직접** 부른다(`bun run scaffold`가 아니다 — SCAFFOLD_ENTRY 주석).
      // package.json script를 거치면 재개가 그 script의 생존에 의존하는데, 스캐폴더가 스스로 재작성하는
      // 파일이 바로 package.json이다: 재작성 뒤 어떤 이유로든 죽으면 `scripts.scaffold`가 사라져
      // 바로 위 재실행 계약(반쪽 스캐폴드 → 재스캐폴드)이 **재호출 불가**로 깨졌다(04 인계).
      // 진입점은 preflight가 이미 존재·계약 마커를 검증한 그 경로다 — 검증 대상 = 실행 대상.
      // timeoutMs: 0 — 스캐폴더가 lock 재생성 `bun install`을 품는다. 30s 초과 시 SIGTERM이
      // 스캐폴더의 rollback **전에** 트리를 죽인다(위 갭의 트리거였고, 지금은 재개가 수렴한다).
      const scaffold = sh("bun", [SCAFFOLD_ENTRY, "--archetype", input.archetype, "--name", app, "--yes"], { cwd: dest, timeoutMs: 0 });
      if (!scaffold.ok) return fail(`스캐폴드 실패 — ${scaffold.err.split("\n")[0] || `bun ${SCAFFOLD_ENTRY} 비-0`}`, "cloned", { created });
      if (!existsSync(`${dest}/${SCAFFOLD_MARKER}`)) return fail(`스캐폴드 후 ${SCAFFOLD_MARKER}이 없다 — 스캐폴더 계약 위반`, "cloned", { created });
    }
    scaffolded = true;

    // ── invocation marker 기록(멱등) — 없으면 쓴다. ──
    if (!existsSync(`${dest}/${MARKER_FILE}`)) {
      const markerBody = JSON.stringify({ tool: MARKER_TOOL, app, archetype: input.archetype }) + "\n";
      try { writeFileSync(`${dest}/${MARKER_FILE}`, markerBody); }
      catch (e) { return fail(`마커 기록 실패 — ${e instanceof Error ? e.message : String(e)}`, "scaffolded", { created }); }
    }

    // ── 커밋(멱등) — 변경이 있으면 스캐폴드+마커를 첫 스캐폴드 커밋으로. ──
    const dirty = git(dest, ["status", "--porcelain"]);
    if (!dirty.ok) return fail("git status 실패", "scaffolded", { created });
    if (dirty.out.trim() !== "") {
      const add = git(dest, ["add", "-A"]);
      if (!add.ok) return fail("git add 실패", "scaffolded", { created });
      const commit = git(dest, ["commit", "-q", "-m", `chore: scaffold ${app} (homelab app init)`]);
      if (!commit.ok) return fail(`git commit 실패 — ${commit.err.split("\n")[0]}`, "scaffolded", { created });
    }

    // ── 첫 push(부수효과) — 스캐폴드 커밋(마커 포함)을 원격 main에 올린다(빌드 트리거). ──
    // timeoutMs: 0 — push는 망 왕복이고, 서버에 반영된 뒤 클라이언트만 SIGTERM으로 죽으면
    // '첫 push 실패'로 보고돼 운영자가 성공한 부수효과를 실패로 읽는다.
    const push = git(dest, ["push", "-q", "origin", "HEAD:refs/heads/main"], { timeoutMs: 0 });
    if (!push.ok) return fail(`첫 push 실패 — ${push.err.split("\n")[0]}`, "scaffolded", { created, adopted: adopted || undefined });
    pushed = true;
  }

  // ── 디스패치 시크릿(옵션, 원자적) — 요청 시에만. 쌍의 절반 상태를 결과에 명시하고 재실행이 수렴. ──
  let secrets: Record<string, unknown> | undefined;
  let didSecretWork = false;
  if (wantSecrets) {
    const { idFile, keyFile } = secretFiles(input.dispatchSecrets!);
    const have = listSecrets(app);
    if (have === null) {
      return fail("시크릿 목록 조회 실패 — 판정 불가", "pushed", { created, adopted: adopted || undefined, scaffolded, pushed });
    }
    let idSet = have.has(SECRET_APP_ID);
    let keySet = have.has(SECRET_PRIVATE_KEY);
    // App ID 먼저 — 값은 --body-file로만(argv 원장에 값 비노출).
    if (!idSet) {
      const r = sh("gh", ["secret", "set", SECRET_APP_ID, "--repo", `${OWNER}/${app}`, "--body-file", idFile]);
      if (!r.ok) return fail(`${SECRET_APP_ID} 설정 실패 — ${r.err.split("\n")[0]}`, "pushed", { created, adopted: adopted || undefined, scaffolded, pushed, secrets: { requested: true, appId: false, privateKey: keySet } });
      idSet = true; didSecretWork = true;
    }
    // private key — 값은 --body-file 전용(파일 내용을 이 엔진이 읽지 않는다 = 출력 유출 표면 0).
    if (!keySet) {
      const r = sh("gh", ["secret", "set", SECRET_PRIVATE_KEY, "--repo", `${OWNER}/${app}`, "--body-file", keyFile]);
      if (!r.ok) return fail(`${SECRET_PRIVATE_KEY} 설정 실패(App ID는 설정됨 — 절반 상태, 재실행이 수렴)`, "pushed", { created, adopted: adopted || undefined, scaffolded, pushed, secrets: { requested: true, appId: idSet, privateKey: false } });
      keySet = true; didSecretWork = true;
    }
    secrets = { requested: true, appId: idSet, privateKey: keySet };
  }

  const didWork = created || !markerPresent || didSecretWork;
  const variant = didWork ? "success" : "no-op";
  return {
    variant,
    omitted: [],
    result: compact({
      ...base,
      existed: exists || undefined,
      created: created || undefined,
      adopted: adopted || undefined,
      scaffolded,
      pushed,
      checkpoint: wantSecrets ? "secrets" : "pushed",
      secrets,
    }),
  };
}

// 멱등 클론 — dest가 canonical origin을 가진 우리 클론이면 재사용, 아니면 클론. null=성공, 아니면 오류.
function ensureClone(parentDir: string, app: string, dest: string, cloneUrl: string): string | null {
  if (existsSync(`${dest}/.git`)) {
    const url = git(dest, ["config", "--get", "remote.origin.url"]);
    // canonical 판정은 identity.ts SSOT 술어 — 접미 매치는 임의 host의 …/${OWNER}/${app}(mirror 클론)을
    // '우리 것'으로 오귀속해 마커·push를 엉뚱한 레포에 흘린다(insteadOf 하에서도 origin은 canonical).
    if (url.ok && isCanonicalClone(OWNER, app, url.out)) return null; // 우리 클론 — 재사용
    return `${dest}가 이미 있으나 origin이 canonical ${OWNER}/${app}가 아니다(${url.out.trim() || "없음"}) — 수동 확인 필요`;
  }
  if (existsSync(dest)) return `${dest}가 이미 있으나 git 레포가 아니다 — 수동 확인 필요`;
  // timeoutMs: 0 — 클론은 망 왕복이라 seam 기본 30s가 콜드/느린 망에서 끊는다(같은 어휘로 통일).
  const clone = sh("git", ["clone", "-q", cloneUrl, dest], { timeoutMs: 0 });
  if (!clone.ok) return `클론 실패 — ${clone.err.split("\n")[0] || "git clone 비-0"}`;
  // 신규 클론도 구성 신원을 같은 술어로 증명한다(재사용 분기와 대칭) — cloneUrl 조립이
  // 바뀌어도 "push 전 ① 통과" 계약이 붙잡는다.
  const fresh = git(dest, ["config", "--get", "remote.origin.url"]);
  if (!fresh.ok || !isCanonicalClone(OWNER, app, fresh.out)) {
    return `클론 origin(${fresh.out.trim() || "없음"})이 canonical ${OWNER}/${app}가 아니다 — 수동 확인 필요`;
  }
  return null;
}
