// homelab doctor 진단 엔진 — 변이 디스패치의 전제(gh 인증·actor 가드 일치·스코프, 로컬 도구,
// KUBECONFIG, 템플릿 접근성·호환성)를 관측 전용으로 점검한다. 실행 원칙:
//   - 관측 전용: 모든 외부 호출은 `gh api` 읽기뿐(테스트가 argv 원장으로 강제).
//   - fail-closed: 선행 실패(gh 인증 부재)로 판정 불가한 항목은 pass가 아니라 fail로 보고한다.
//   - 결정적 출력: detail에 절대경로·시각 등 실행마다 변하는 값을 넣지 않는다(골든 픽스처 계약).
import { existsSync } from "node:fs";
import { gh as ghExec } from "./exec.ts";
import { HOMELAB_REPO, TEMPLATE_REPO, ARCH_NEUTRAL_ARCHETYPES, COMPILED_ARCHETYPES } from "./platform.ts";
import { SCAFFOLD_CONTRACT_LABEL, scaffoldContractError } from "./template-contract.ts";

export type CheckStatus = "pass" | "fail" | "warn";
export type DoctorCheck = { id: string; status: CheckStatus; detail: string };
export type DoctorSummary = { pass: number; fail: number; warn: number };
export type DoctorResult = { checks: DoctorCheck[]; summary: DoctorSummary };

// 실행은 seam(lib/exec.ts) 경유 — 미설치(ENOENT) **판별**만 이 콜사이트가 소유한다
// (errKind는 seam이 나르고, 그것을 "설치 필요"로 읽는 정책은 doctor의 것이다).
const gh = ghExec;

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
  const authed = user.ok && login !== "";
  if (authed) add("gh-auth", "pass", `gh 인증 확인(login: ${login})`);
  else if (user.errKind === "not-found") add("gh-auth", "fail", "gh CLI가 PATH에 없다 — 설치 필요(모든 동사가 gh 경유)");
  else add("gh-auth", "fail", "gh 인증 부재 — 'gh auth login' 필요");

  const blocked = (id: string) => add(id, "fail", "선행 gh-auth 실패로 판정 불가");

  // ── owner 일치 — 변이 디스패처 actor 가드(vars.HOMELAB_OWNER)의 사전 검증 ──
  if (!authed) blocked("gh-owner");
  else {
    const v = gh(["api", `repos/${HOMELAB_REPO}/actions/variables/HOMELAB_OWNER`, "--jq", ".value"]);
    const owner = v.ok ? v.out.trim() : "";
    if (!v.ok) add("gh-owner", "fail", `HOMELAB_OWNER 변수 조회 실패 — ${HOMELAB_REPO} 접근 권한과 변수 설정을 확인`);
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
  add("bun", Bun.which("bun") ? "pass" : "fail",
    Bun.which("bun") ? "bun 발견(PATH)" : "bun이 PATH에 없다 — app init(스캐폴드 실행)에 필요");
  add("kubeseal", Bun.which("kubeseal") ? "pass" : "fail",
    Bun.which("kubeseal") ? "kubeseal 발견(PATH)" : "kubeseal이 PATH에 없다 — 시크릿 봉인(app secrets 연쇄 모드)에 필요");

  // ── KUBECONFIG — 부재는 경고(라이브 구간 생략), 깨진 경로는 설정 오류라 fail ──
  const kc = process.env.KUBECONFIG ?? "";
  if (kc === "") add("kubeconfig", "warn", "KUBECONFIG 미설정 — status·--wait의 라이브(ArgoCD) 구간이 생략된다");
  else if (existsSync(kc)) add("kubeconfig", "pass", "KUBECONFIG 설정됨(파일 존재)");
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

    const sc = fetchTemplateFile("scaffold/scaffold.ts");
    if (sc === null) add("template-scaffold-contract", "fail", "scaffold/scaffold.ts 조회 실패 — 템플릿 구조 변경 의심(스캐폴더 부재면 init 불가)");
    else {
      // 계약 술어는 lib/template-contract.ts SSOT — init preflight가 같은 술어를 쓴다(structure r1 a3).
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
