// homelab doctor 진단 엔진 — 변이 디스패치의 전제(gh 인증·actor 가드 일치·스코프·버전, 로컬 도구,
// git 커밋 신원·자격 helper, KUBECONFIG, 템플릿 접근성·호환성)를 관측 전용으로 점검한다. 실행 원칙:
//   - 관측 전용: 외부 호출은 `gh api` 읽기 + `gh --version` + git 읽기 동사(`var` · `config --get*`)
//     뿐이다(테스트가 argv 원장으로 강제 — observation-only 모드).
//   - fail-closed: 선행 실패(gh 인증 부재·git 부재)로 판정 불가한 항목은 pass가 아니라 fail로 보고한다.
//   - gh 호출 최소화: 인증이 성립하지 않으면 **추가 gh 호출을 만들지 않는다**(오프라인·rate limit
//     소진에서 같은 실패를 반복하지 않는다). gh-version이 gh-auth에 종속인 이유가 이것이고,
//     테스트가 그 상한을 '실패 레인의 gh 호출 1회'로 잰다.
//   - 결정적 출력: detail에 절대경로·시각·신원 값 등 실행마다 변하는 값을 넣지 않는다(골든 픽스처 계약).
import { existsSync, lstatSync } from "node:fs";
import { delimiter } from "node:path";
import { gh as ghExec, sh } from "./exec.ts";
import { HOMELAB_REPO, TEMPLATE_REPO, ARCH_NEUTRAL_ARCHETYPES, COMPILED_ARCHETYPES } from "./platform.ts";
import { SCAFFOLD_CONTRACT_LABEL, SCAFFOLD_ENTRY, scaffoldContractError } from "./template-contract.ts";

export type CheckStatus = "pass" | "fail" | "warn";
export type DoctorCheck = { id: string; status: CheckStatus; detail: string };
export type DoctorSummary = { pass: number; fail: number; warn: number };
export type DoctorResult = { checks: DoctorCheck[]; summary: DoctorSummary };

// 실행은 seam(lib/exec.ts) 경유 — 미설치(ENOENT) **판별**만 이 콜사이트가 소유한다
// (errKind는 seam이 나르고, 그것을 "설치 필요"로 읽는 정책은 doctor의 것이다).
const gh = ghExec;

// 호스트 도구 핀 런북 — 도구 부재 detail이 지목하는 다음 자리(AGENTS.md 런북 표). 로컬 전용
// (gitignored)이라 경로만 남긴다: 없는 파일을 가리키는 게 아니라 owner의 로컬 인덱스를 가리킨다.
const TOOLCHAIN_RUNBOOK = "docs/runbooks/toolchain.md";

// gh 문구 계약의 최소 버전 — 이 레포는 gh의 **출력 문구**를 판정에 쓴다: `(HTTP 404)` stderr
// (mutation.ts blobAt·init.ts api()의 absent/error 3상), `workflow run … -f k=v`, `api --jq`.
// 문구가 바뀌면 absent가 전부 error로 접혀 presence·absence 레인이 데드라인까지 pending이 된다.
// 2.40은 그 세 표면이 현재 형태로 굳은 하한이고, 판정은 **warn**이다 — 실제 능력은 호출로만
// 증명된다(함정 원장 「fine-grained PAT 능력은 실제 push 테스트로만」과 같은 계열).
const GH_MIN_VERSION: [number, number] = [2, 40];
const GH_MIN_LABEL = GH_MIN_VERSION.join(".");

// 전역 설치 진단 — `bun link`가 심는 진입점 이름. 4상 판정의 원료를
// **`lstatSync`로** 모은다: `Bun.which`는 dangling 심링크에 null을 돌려줘 "설치 안 됨"과
// "설치했는데 대상이 사라졌다"를 한 값으로 접는다. 후자가 이 호스트에서 실측된 상태다
// (2026-09-07: `~/.bun/bin/homelab` → 삭제된 worktree). 두 상태의 처방이 다르므로 접으면 안 된다.
const CLI_BIN_NAME = "homelab";
// `$BUN_INSTALL/bin`(미설정이면 `~/.bun/bin`) — bun link의 심링크 자리. 이 디렉토리가 PATH에 있어야
// 전역 `homelab`이 뜨는데, mise/asdf로 bun을 관리하면 PATH에 자동 추가되지 않는다(실측).
function bunLinkBin(): string | null {
  const bi = process.env.BUN_INSTALL;
  if (bi !== undefined && bi !== "") return `${bi}/bin`;
  const home = process.env.HOME;
  return home !== undefined && home !== "" ? `${home}/.bun/bin` : null;
}

// contents API의 base64 본문을 디코드해 돌려준다(실패 = null — 콜사이트가 fail 처리).
function fetchTemplateFile(path: string): string | null {
  const r = gh(["api", `repos/${TEMPLATE_REPO}/contents/${path}`, "--jq", ".content"]);
  if (!r.ok) return null;
  try { return Buffer.from(r.out.replace(/\s+/g, ""), "base64").toString("utf8"); } catch { return null; }
}

export function runDoctor(): DoctorResult {
  const checks: DoctorCheck[] = [];
  const add = (id: string, status: CheckStatus, detail: string) => checks.push({ id, status, detail });

  // ── gh 인증 + 스코프 원료 — `gh api -i user` 한 호출로 login과 스코프 헤더를 함께 얻는다 ──
  const user = gh(["api", "-i", "user"]);
  let login = "";
  let scopes: string[] | null = null; // null = 헤더 부재(fine-grained PAT 등 — 정적 판정 불가)
  if (user.ok) {
    const sep = user.out.search(/\r?\n\r?\n/);
    const head = sep >= 0 ? user.out.slice(0, sep) : "";
    const body = sep >= 0 ? user.out.slice(sep) : user.out;
    const m = head.match(/^x-oauth-scopes:[ \t]*(.*?)[ \t\r]*$/im);
    if (m) scopes = m[1].split(",").map((s) => s.trim()).filter(Boolean);
    try { login = String(JSON.parse(body.trim()).login ?? ""); } catch { login = ""; }
  }
  // 실패 사유의 층을 가르는 원료 — `gh api -i`는 **비-2xx에서도** 상태줄과 헤더를 stdout에 낸다
  // (라이브 실측 2026-09-06: 없는 레포 조회 → stdout 첫 줄 `HTTP/2.0 404 Not Found`, rc 1).
  // 그래서 stdout에 상태줄이 있으면 "서버가 응답했다" — 자격 부재(rc 4·stdout 공백)와 다른 층이고,
  // 403 rate limit 소진·권한 부족·토큰 만료가 전부 이쪽이다. 이 구별이 없으면 그 셋이 모두
  // 「'gh auth login' 필요」로 처방돼 운영자가 엉뚱한 곳을 고친다.
  const served = /^HTTP\/\S+ \d{3}/.test((user.out.split(/\r?\n/, 1)[0] ?? "").trim());
  const authed = user.ok && login !== "";
  const ghErrLine = user.err ? ` (${user.err.split("\n")[0]})` : "";
  if (authed) add("gh-auth", "pass", `gh 인증 확인(login: ${login})`);
  else if (user.errKind === "not-found") add("gh-auth", "fail", "gh CLI가 PATH에 없다 — 설치 필요(모든 동사가 gh 경유)");
  else if (served) add("gh-auth", "fail", `GitHub 서버가 응답했지만 user 조회가 실패했다 — 토큰 만료·권한 부족·rate limit 소진 중 하나다${ghErrLine}`);
  // seam의 err 첫 줄을 함께 싣는다 — 여기 접히는 것은 인증 부재만이 아니다: timeout(SIGTERM)·
  // ENOBUFS 같은 errKind "spawn" 실패가 같은 문구로 나오면 원인이 통째로 지워진다(오진).
  else add("gh-auth", "fail", `gh 인증 부재 — 'gh auth login' 필요${ghErrLine}`);

  const blocked = (id: string) => add(id, "fail", "선행 gh-auth 실패로 판정 불가");

  // ── gh 버전 — 코드에 박힌 gh 문구 계약(GH_MIN_VERSION 주석)의 전제 ──
  // ⚠️ 인증이 성립하지 않으면 호출하지 않는다(헤더의 'gh 호출 최소화' 원칙 — 테스트가 상한을 잰다).
  if (!authed) blocked("gh-version");
  else {
    const v = gh(["--version"]);
    const m = v.ok ? v.out.match(/gh version (\d+)\.(\d+)\.(\d+)/) : null;
    if (m === null) add("gh-version", "warn", `gh --version 형상을 읽지 못했다 — 버전 판정 불가(gh 문구 계약 최소 ${GH_MIN_LABEL})`);
    else {
      const [major, minor] = [Number(m[1]), Number(m[2])];
      const ok = major > GH_MIN_VERSION[0] || (major === GH_MIN_VERSION[0] && minor >= GH_MIN_VERSION[1]);
      const label = `${m[1]}.${m[2]}.${m[3]}`;
      if (ok) add("gh-version", "pass", `gh ${label} — 문구 계약 최소 버전(${GH_MIN_LABEL}) 충족`);
      else add("gh-version", "warn", `gh ${label}이 문구 계약 최소 버전 ${GH_MIN_LABEL} 미만 — 404 판정('(HTTP 404)' stderr)·workflow run -f·api --jq가 그 버전 계약이다(업그레이드 권장)`);
    }
  }

  // ── owner 일치 — 변이 디스패처 actor 가드(vars.HOMELAB_OWNER)의 사전 검증 ──
  if (!authed) blocked("gh-owner");
  else {
    const v = gh(["api", `repos/${HOMELAB_REPO}/actions/variables/HOMELAB_OWNER`, "--jq", ".value"]);
    const owner = v.ok ? v.out.trim() : "";
    // 404는 '권한/설정 오류'가 아니라 **repo 레벨에 그 변수가 없다**는 관측이다. 워크플로의
    // `vars.HOMELAB_OWNER`는 repo→org 순으로 해석되므로 org 레벨로 옮겨졌다면 actor 가드는 계속
    // 동작하는데 doctor만 red가 된다(그 변수는 IaC 밖이라 손으로 레벨이 바뀔 수 있다 —
    // check-gh-secret-coverage.sh가 감시 범위 밖으로 선언). org 조회는 admin:org가 필요해
    // doctor의 관측 전용 경계 밖이므로 판정은 fail-closed로 두되 사유를 정확히 말한다.
    if (!v.ok && /\(HTTP 404\)/.test(v.err)) add("gh-owner", "fail", `HOMELAB_OWNER repo 변수 부재(404) — org 레벨 변수로 정의됐다면 doctor는 판정 불가(admin:org 필요)이고 actor 가드는 그 org 값을 쓴다`);
    else if (!v.ok) add("gh-owner", "fail", `HOMELAB_OWNER 변수 조회 실패 — ${HOMELAB_REPO} 접근 권한과 변수 설정을 확인${v.err ? ` (${v.err.split("\n")[0]})` : ""}`);
    else if (owner === "") add("gh-owner", "fail", "HOMELAB_OWNER 변수가 비어 있다 — actor 가드 fail-closed(디스패치 전부 거부됨)");
    else if (owner !== login) add("gh-owner", "fail", `gh 로그인(${login}) ≠ HOMELAB_OWNER(${owner}) — 변이 디스패처 actor 가드가 거부한다`);
    else add("gh-owner", "pass", `gh 로그인 계정이 HOMELAB_OWNER와 일치(${owner})`);
  }

  // ── 토큰 스코프 — repo(디스패치·PR)·workflow(앱 레포 워크플로 push: init 스캐폴드) ──
  if (!authed) blocked("gh-scopes");
  else if (scopes === null) add("gh-scopes", "warn", "토큰 스코프 헤더 부재(fine-grained PAT 추정) — 능력은 실제 디스패치/push로만 검증된다(함정 원장)");
  else {
    const required = ["repo", "workflow"];
    const missing = required.filter((s) => !scopes.includes(s));
    if (missing.length > 0) add("gh-scopes", "fail", `토큰 스코프 부족 — 누락: ${missing.join(", ")} (repo=디스패치·PR, workflow=앱 레포 워크플로 push)`);
    else add("gh-scopes", "pass", `토큰 스코프 충족(${required.join(", ")})`);
  }

  // ── 로컬 도구 ──
  // detail은 '다음에 무엇을 하나'까지 지목한다 — 호스트 도구 핀은 런북이 SSOT다.
  const kc = process.env.KUBECONFIG ?? "";
  const gitBin = Bun.which("git");

  // ── 전역 설치 — `homelab` 진입점이 실제로 뜨는가(4상) ──
  // 결정적 출력 계약대로 **경로는 싣지 않는다**: 상태와 처방만 말한다(경로는 `homelab --version`이
  // 해석된 진입점을 그대로 낸다 — 가변 문자열은 그쪽 채널이다).
  const pathDirs = (process.env.PATH ?? "").split(delimiter).filter(Boolean);
  const linkBin = bunLinkBin();
  const candidates = [...pathDirs, ...(linkBin !== null && !pathDirs.includes(linkBin) ? [linkBin] : [])];
  let aliveOnPath = false;
  let aliveOffPath = false;
  let dangling = false;
  for (const d of candidates) {
    const p = `${d}/${CLI_BIN_NAME}`;
    try { lstatSync(p); } catch { continue; }   // 엔트리 자체가 없다 = 이 디렉토리는 무관
    if (!existsSync(p)) { dangling = true; continue; }  // 엔트리는 있는데 대상이 없다(끊어진 링크)
    if (pathDirs.includes(d)) aliveOnPath = true; else aliveOffPath = true;
  }
  if (aliveOnPath) add("install", "pass", `전역 ${CLI_BIN_NAME} 진입점이 PATH에서 해석된다`);
  else if (dangling) add("install", "fail", `전역 ${CLI_BIN_NAME} 링크가 사라진 대상을 가리킨다(worktree/임시 클론에서 link한 흔적) — 본 체크아웃에서 재-link 필요(bun link)`);
  else if (aliveOffPath) add("install", "warn", `전역 ${CLI_BIN_NAME} 링크는 살아 있지만 그 디렉토리($BUN_INSTALL/bin)가 PATH 밖이다 — PATH에 추가하거나 소스 실행(bun tools/homelab.ts)으로 대체`);
  else add("install", "warn", `전역 ${CLI_BIN_NAME} 진입점 없음 — bun link 미실행(소스 실행 bun tools/homelab.ts로 대체 가능)`);

  add("bun", Bun.which("bun") ? "pass" : "fail",
    Bun.which("bun") ? "bun 발견(PATH)" : `bun이 PATH에 없다 — app init(스캐폴드 실행)에 필요(${TOOLCHAIN_RUNBOOK})`);
  // git은 app init/secrets 연쇄의 clone·commit·push 전부가 지나는 자리다 — 부재면 그 동사들이
  // `gh repo create`(불가역 부수효과) **뒤**에 죽어 재실행이 --adopt를 요구한다.
  add("git", gitBin ? "pass" : "fail",
    gitBin ? "git 발견(PATH)" : `git이 PATH에 없다 — app init/secrets의 clone·commit·push에 필요(${TOOLCHAIN_RUNBOOK})`);
  add("kubeseal", Bun.which("kubeseal") ? "pass" : "fail",
    Bun.which("kubeseal") ? "kubeseal 발견(PATH)" : `kubeseal이 PATH에 없다 — 시크릿 봉인(app secrets 연쇄 모드)에 필요(${TOOLCHAIN_RUNBOOK})`);
  // kubectl 부재의 층은 KUBECONFIG가 정한다. **불변식**: 라이브 계층 소비자 넷은 전부 KUBECONFIG
  // 게이트 뒤다 — status.ts(kc === "" → omitted live) · mutation.ts(라이브 수렴 진입 전 같은 게이트) ·
  // conn-url.ts(skipNoCluster). 그래서 KUBECONFIG 미설정이면 kubectl은 아무도 부르지 않아 warn이면
  // 족하고, 설정돼 있는데 부재면 그 구간이 전부 error/pending이 되므로 fail이다(--wait는 20분
  // 데드라인을 다 태운 뒤에야 pending을 낸다 — 사전 진단이 없으면 그 20분이 진단 시간이 된다).
  add("kubectl", Bun.which("kubectl") ? "pass" : (kc === "" ? "warn" : "fail"),
    Bun.which("kubectl") ? "kubectl 발견(PATH)"
      : kc === "" ? `kubectl이 PATH에 없다 — KUBECONFIG 미설정이라 지금은 라이브 구간을 아무도 부르지 않는다(${TOOLCHAIN_RUNBOOK})`
        : `kubectl이 PATH에 없다 — KUBECONFIG가 설정돼 있어 status 라이브·--wait 수렴이 전부 실패/데드라인 소진이 된다(${TOOLCHAIN_RUNBOOK})`);

  // ── git 커밋 신원·https 자격 helper — init/secrets의 **첫 실전 실패**가 나는 자리 ──
  // 둘 다 warn이다: 진단 시점에 손상된 것이 아니라 '다음 동사가 여기서 죽는다'는 예고다.
  // git 자체가 없으면 판정 원료가 없으므로 fail-closed로 막는다(pass로 접으면 거짓 초록).
  if (!gitBin) {
    add("git-identity", "fail", "선행 git 부재로 판정 불가");
    add("git-credential", "fail", "선행 git 부재로 판정 불가");
  } else {
    // `git var GIT_COMMITTER_IDENT`는 env(GIT_COMMITTER_*)와 config를 모두 해석하고 IDENT_STRICT라
    // 자동 추정 신원을 거부한다 — 즉 `git commit`이 죽는 조건과 **정확히 같은 술어**다(실측: 신원
    // 미설정에서 rc 128 + "Please tell me who you are"). ⚠️ 값은 detail에 싣지 않는다(결정적 출력
    // 계약 + 이메일 비노출).
    const ident = sh("git", ["var", "GIT_COMMITTER_IDENT"]);
    if (ident.ok && ident.out.trim() !== "") add("git-identity", "pass", "git 커밋 신원 확인(값 비노출)");
    else add("git-identity", "warn", "git 커밋 신원 미설정 — app init/secrets의 커밋 단계가 실패한다(git config --global user.name / user.email)");
    // `--get-urlmatch`는 URL 스코프 config(`[credential "https://github.com"]`)까지 해석한다.
    // 부재면 https clone/push가 자격 프롬프트로 떨어지는데, 그 프롬프트는 stdin이 아니라 /dev/tty로
    // 나가고 clone·push 콜사이트는 timeoutMs 0(무제한)이라 MCP 경로에서 영구 블록이 된다.
    const cred = sh("git", ["config", "--get-urlmatch", "credential.helper", "https://github.com"]);
    if (cred.ok && cred.out.trim() !== "") add("git-credential", "pass", "GitHub https 자격 helper 설정됨");
    else add("git-credential", "warn", "GitHub https 자격 helper 부재 — init/secrets의 clone·push가 자격 프롬프트로 떨어진다(gh auth setup-git)");
  }

  // ── KUBECONFIG — 부재는 경고(라이브 구간 생략), 깨진 경로는 설정 오류라 fail ──
  // 다음 명령은 canonical 경로를 그대로 준다. 결정성 규약(헤더 — detail에 절대경로 금지)은
  // `$PWD` 상대 표기로 지킨다(레포 루트에서 실행하는 것이 그 명령의 전제이기도 하다).
  // ⚠️ KUBECONFIG는 **콜론 구분 병합 목록**이 유효한 값이다(kubectl/client-go 규약). `existsSync("a:b")`는
  // false라 단일 경로 판정은 정당한 개발자 셸을 exit 1로 만든다. 빈 세그먼트
  // (끝의 콜론)는 경로가 아니므로 반드시 제거한다 — 안 하면 ""가 '부재 경로'로 세어진다.
  const kcPaths = kc.split(delimiter).filter(Boolean);
  const kcMissing = kcPaths.filter((p) => !existsSync(p)).length;
  if (kcPaths.length === 0) add("kubeconfig", "warn", "KUBECONFIG 미설정 — status·--wait의 라이브(ArgoCD) 구간이 생략된다(레포 루트에서: export KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig)");
  else if (kcMissing === 0) add("kubeconfig", "pass", "KUBECONFIG 설정됨(파일 존재)");
  else if (kcMissing < kcPaths.length) add("kubeconfig", "warn", "KUBECONFIG 목록의 일부 경로가 부재 — kubectl은 그 항목을 건너뛰고 나머지를 병합한다(경로 비노출)");
  else add("kubeconfig", "fail", "KUBECONFIG가 존재하지 않는 파일을 가리킨다 — 설정 오류");

  // ── 템플릿 접근성·호환성 — init을 거부할 근거를 사전에 만든다 ──
  if (!authed) {
    blocked("template-access");
    blocked("template-scaffold-contract");
    blocked("template-targetarch");
  } else {
    const t = gh(["api", `repos/${TEMPLATE_REPO}`, "--jq", ".is_template"]);
    if (!t.ok) add("template-access", "fail", `템플릿 레포(${TEMPLATE_REPO}) 조회 실패 — 접근성/네트워크 확인`);
    else if (t.out.trim() !== "true") add("template-access", "fail", `템플릿 레포(${TEMPLATE_REPO})가 is_template이 아니다 — 'Use this template' 생성 불가`);
    else add("template-access", "pass", `템플릿 레포 접근 가능(${TEMPLATE_REPO}, is_template)`);

    const sc = fetchTemplateFile(SCAFFOLD_ENTRY);
    if (sc === null) add("template-scaffold-contract", "fail", `${SCAFFOLD_ENTRY} 조회 실패 — 템플릿 구조 변경 의심(스캐폴더 부재면 init 불가)`);
    else {
      // 계약 술어는 lib/template-contract.ts SSOT — init preflight가 같은 술어를 쓴다.
      const absent = scaffoldContractError(sc);
      if (absent !== null) add("template-scaffold-contract", "fail", `스캐폴더 비대화형 계약 마커 부재(${absent}) — init이 이 템플릿과 비호환`);
      else add("template-scaffold-contract", "pass", `스캐폴더 비대화형 계약 확인(${SCAFFOLD_CONTRACT_LABEL})`);
    }

    // 검사 대상 = COMPILED_ARCHETYPES(ARCHETYPES − ARCH_NEUTRAL: arch 중립은 명시 opt-out — platform.ts 주석·ticket 03 실측).
    const bad: string[] = [];
    for (const a of COMPILED_ARCHETYPES) {
      const df = fetchTemplateFile(`scaffold/archetypes/${a}/Dockerfile`);
      if (df === null) bad.push(`${a}(조회 실패)`);
      else if (!df.includes("TARGETARCH")) bad.push(a);
    }
    if (bad.length > 0) add("template-targetarch", "fail", `TARGETARCH 파라미터화 부재: ${bad.join(", ")} — amd64 노드 exec format error(이 템플릿으로는 init 거부 근거)`);
    else add("template-targetarch", "pass", `컴파일 아키타입 ${COMPILED_ARCHETYPES.length}종(${COMPILED_ARCHETYPES.join("·")}) Dockerfile TARGETARCH 파라미터화 확인 — ${ARCH_NEUTRAL_ARCHETYPES.join("·")}는 arch 중립이라 대상 아님`);
  }

  const summary: DoctorSummary = {
    pass: checks.filter((c) => c.status === "pass").length,
    fail: checks.filter((c) => c.status === "fail").length,
    warn: checks.filter((c) => c.status === "warn").length,
  };
  return { checks, summary };
}
