// 자동 병합 조건 9개(설계 C.4.7, .github/workflows/README.md). 입력(Facts)을 모아 오는 일은 main.ts가 하고,
// 여기는 판정만 한다. 그래서 조건마다 음성 fixture로 시험할 수 있다(tools/deploy-merge/fixtures/, bun run ci).
//
// 모든 조건이 참일 때만 병합한다. 모르면(조회 실패, 값 없음) 거짓으로 본다.

export type Facts = {
  deployBotId: number;
  run: { event: string; conclusion: string; headSha: string; path: string; headRepo: string; headBranch: string };
  pr?: {
    number: number;
    userId: number;
    headRepo: string;
    headRef: string;
    headSha: string;
    baseRef: string;
    draft: boolean;
    labels: string[];
  };
  appDirOnMain?: boolean;
  files?: { filename: string; status: string }[];
  mainImage?: string | null;
  headImage?: string | null;
  // 조건 5
  imageLabels?: Record<string, string> | null;
  attestationVerified?: boolean;
  // 조건 6: compare의 status
  compareDeployedToNew?: string;
  compareNewToDefault?: string;
  // 조건 7: head SHA의 ci check run들
  ciChecks?: { name: string; conclusion: string | null; app: string }[];
  // 조건 9
  appRepo?: {
    visibility?: string;
    rules?: { type: string; parameters?: Record<string, any> }[];
    codeownersStatus?: number;
    codeownersErrors?: unknown[];
    // main의 CODEOWNERS 후보 조회 응답(CODEOWNERS_PATHS 순서). 적용 파일은 codeownersFile이 고른다.
    codeownersFiles?: { path: string; status: number; text: string }[];
  };
  // 앱 저장소 전체를 소유해야 하는 code owner 로그인(템플릿 계약 "* @<owner>").
  codeOwner?: string;
};

export type Failure = { cond: number; message: string };
export type Verdict = { app?: string; failures: Failure[] };

const IMAGE_KEYS = ["digest", "hold", "repository", "revision"];

function parseImage(text: string | null | undefined): Record<string, unknown> | undefined {
  if (typeof text !== "string") return undefined;
  try {
    const v = Bun.YAML.parse(text);
    return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
}

// GitHub이 CODEOWNERS를 찾는 순서. 먼저 있는 파일 하나만 적용한다.
export const CODEOWNERS_PATHS = [".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS"];

// 적용되는 CODEOWNERS 원문. 확인된 404에서만 다음 후보로 넘어간다. 앞 파일의 403·5xx를 "없음"으로 보고 뒤 파일을
// 읽으면, GitHub이 적용하지 않는 파일로 조건 9를 판정한다(앞 파일이 다른 소유자여도 통과). 그래서 그때는 오류다.
// 모든 후보가 404면 text null(조건 9가 거짓).
export function codeownersFile(files: { path: string; status: number; text: string }[] | undefined): { text: string | null } | { error: string } {
  for (const path of CODEOWNERS_PATHS) {
    const r = (files ?? []).find((x) => x.path === path);
    if (!r) return { error: `${path}를 조회하지 않았다` };
    if (r.status === 200) return { text: r.text };
    if (r.status !== 404) return { error: `${path} 조회 HTTP ${r.status}` };
  }
  return { text: null };
}

export function appFromBranch(ref: string | undefined): string | undefined {
  return ref?.match(/^deploy\/([a-z0-9]([a-z0-9-]{0,51}[a-z0-9])?)$/)?.[1];
}

export function evaluate(f: Facts): Verdict {
  const failures: Failure[] = [];
  const fail = (cond: number, message: string) => failures.push({ cond, message });
  const pr = f.pr;
  if (!pr) return { failures: [{ cond: 2, message: "workflow_run의 head 브랜치에 열린 PR이 없다" }] };
  const app = appFromBranch(pr.headRef);

  // 1. 작성자: 로그인 문자열이 아니라 숫자 사용자 ID로 비교한다(GitHub login은 대소문자를 가리지 않는다).
  if (!(f.deployBotId > 0 && pr.userId === f.deployBotId)) fail(1, `PR 작성자(${pr.userId})가 ukyi-homelab-deploy[bot]이 아니다`);

  // 2. head 저장소·브랜치와 등록 여부. workflow_run 소비자는 head를 확인해야 fork 실행에 조종되지 않는다(설계 B.8 E5).
  if (pr.headRepo !== "ukyi-app/homelab" || f.run.headRepo !== "ukyi-app/homelab") fail(2, "head 저장소가 ukyi-app/homelab이 아니다");
  if (!app) fail(2, `head 브랜치가 deploy/<앱>이 아니다: ${pr.headRef}`);
  if (f.run.headBranch !== pr.headRef) fail(2, "workflow_run의 head 브랜치와 PR head 브랜치가 다르다");
  if (pr.baseRef !== "main") fail(2, `base가 main이 아니다: ${pr.baseRef}`);
  if (app && f.appDirOnMain !== true) fail(2, `main에 apps/${app}/가 없다(미등록)`);
  if (!app) return { failures };

  // 3. 바뀐 파일이 정확히 apps/<앱>/image.yaml 하나.
  const files = f.files ?? [];
  if (!(files.length === 1 && files[0].filename === `apps/${app}/image.yaml` && files[0].status === "modified")) {
    fail(3, `바뀐 파일이 apps/${app}/image.yaml 하나가 아니다: ${files.map((x) => `${x.status} ${x.filename}`).join(", ") || "없음"}`);
  }

  // 4. 바뀐 키가 digest·revision뿐. main의 지금 값과 비교한다(PR이 열린 뒤 main이 롤백됐을 수 있다).
  const base = parseImage(f.mainImage);
  const head = parseImage(f.headImage);
  if (!base || !head) {
    fail(4, "main 또는 head의 image.yaml을 읽지 못했다");
  } else {
    const keys = (o: Record<string, unknown>) => Object.keys(o).sort().join(",");
    if (keys(base) !== IMAGE_KEYS.join(",") || keys(head) !== IMAGE_KEYS.join(",")) fail(4, `image.yaml 키가 ${IMAGE_KEYS.join(", ")}가 아니다`);
    if (base.repository !== head.repository || head.repository !== `ghcr.io/ukyi-app/${app}`) fail(4, "repository가 바뀌었거나 ghcr.io/ukyi-app/<앱>이 아니다");
    if (base.hold !== false || head.hold !== false) fail(4, "hold가 false가 아니다(롤백 보류 중)");
    if (typeof head.digest !== "string" || !/^sha256:[0-9a-f]{64}$/.test(head.digest)) fail(4, "digest 형식이 틀렸다");
    if (typeof head.revision !== "string" || !/^[0-9a-f]{40}$/.test(head.revision)) fail(4, "revision 형식이 틀렸다");
    if (base.digest === head.digest && base.revision === head.revision) fail(4, "digest·revision이 바뀌지 않았다");
  }

  // 5. 이미지 라벨과 attestation. 라벨은 push한 쪽의 자기 신고라 attestation으로 출처를 따로 확인한다.
  const labels = f.imageLabels;
  if (!labels) fail(5, `ghcr.io/ukyi-app/${app}@${head?.digest}를 읽지 못했다`);
  else {
    if (labels["org.opencontainers.image.revision"] !== head?.revision) fail(5, "이미지 revision 라벨이 image.yaml revision과 다르다");
    if (labels["org.opencontainers.image.source"] !== `https://github.com/ukyi-app/${app}`) fail(5, "이미지 source 라벨이 앱 저장소가 아니다");
  }
  if (f.attestationVerified !== true) fail(5, "build provenance attestation 확인 실패(app-build 태그·main·revision·GitHub 호스트 runner)");

  // 6. 앱 기본 브랜치에 있고 main의 배포 revision보다 앞.
  if (f.compareDeployedToNew !== "ahead") fail(6, `main의 배포 revision 대비 ${f.compareDeployedToNew ?? "알 수 없음"}`);
  if (f.compareNewToDefault !== "ahead" && f.compareNewToDefault !== "identical") fail(6, `revision이 앱 기본 브랜치에 없다(${f.compareNewToDefault ?? "알 수 없음"})`);

  // 7. 그 head SHA의 ci 성공. 이름이 ci인 다른 워크플로가 이 이벤트를 일으킬 수 있어 경로와 check run을 함께 본다.
  if (f.run.event !== "pull_request" || f.run.conclusion !== "success") fail(7, `ci 실행이 pull_request 성공이 아니다(${f.run.event}, ${f.run.conclusion})`);
  if (f.run.path !== ".github/workflows/ci.yaml") fail(7, `ci 실행 워크플로가 .github/workflows/ci.yaml이 아니다: ${f.run.path}`);
  if (f.run.headSha !== pr.headSha) fail(7, "검사한 SHA가 PR head가 아니다(그 사이 새 커밋)");
  const ci = (f.ciChecks ?? []).filter((c) => c.name === "ci" && c.app === "github-actions");
  if (ci.length === 0 || ci.some((c) => c.conclusion !== "success")) fail(7, "head SHA의 ci check run이 모두 성공이 아니다");

  // 8. Draft 아님, hold 라벨 없음.
  if (pr.draft) fail(8, "Draft PR이다");
  if (pr.labels.includes("hold")) fail(8, "hold 라벨이 있다");

  // 9. 앱 저장소가 public이고 main에 app-main 규칙이 active, CODEOWNERS가 유효.
  const repo = f.appRepo ?? {};
  if (repo.visibility !== "public") fail(9, `앱 저장소가 public이 아니다(${repo.visibility ?? "읽지 못함"})`);
  const rules = repo.rules ?? [];
  const pull = rules.find((r) => r.type === "pull_request")?.parameters ?? {};
  if (!(Number(pull.required_approving_review_count) >= 1 && pull.require_code_owner_review === true && pull.dismiss_stale_reviews_on_push === true)) {
    fail(9, "앱 main의 pull_request 규칙(승인 1, code owner 리뷰, 새 push 때 승인 무효화)이 active가 아니다");
  }
  for (const t of ["non_fast_forward", "deletion"]) if (!rules.some((r) => r.type === t)) fail(9, `앱 main에 ${t} 규칙이 없다`);
  // 승인 요건만으로는 owner PR을 막지 못한다. 작성자가 유일한 code owner면 쓰기 권한 App(Codex Connector, Renovate)의 승인
  // 하나로 요건이 차고 그 App이 병합할 수 있었다(U08 (나), 2026-10-21 homelab #822). 실제 장치는 update(Restrict updates)다.
  const update = rules.find((r) => r.type === "update");
  if (!update) fail(9, "앱 main에 update(Restrict updates) 규칙이 없다");
  else if (update.parameters?.update_allows_fetch_and_merge === true) fail(9, "앱 main의 update 규칙이 fetch and merge를 허용한다");
  if (!(repo.codeownersStatus === 200 && Array.isArray(repo.codeownersErrors) && repo.codeownersErrors.length === 0)) {
    fail(9, `앱 main의 CODEOWNERS가 없거나 오류가 있다(codeowners/errors ${repo.codeownersStatus ?? "읽지 못함"})`);
  }
  // 오류가 없다는 것은 문법만 보장한다. 주석뿐이거나 일부 경로만 소유하면 소유자 없는 경로는 쓰기 권한이 있는
  // 아무 신원(리뷰 App 등)의 승인으로 병합된다. 규칙 줄이 정확히 "* @<owner>" 하나여야 한다(뒤 줄이 앞 줄을 덮는다).
  const owners = codeownersFile(repo.codeownersFiles);
  if ("error" in owners) fail(9, `앱 main의 CODEOWNERS를 읽지 못했다(${owners.error})`);
  const rules9 = ("text" in owners ? (owners.text ?? "") : "")
    .split("\n")
    .map((l) => l.replace(/#.*$/, "").trim().replace(/\s+/g, " "))
    .filter((l) => l !== "");
  if (!(f.codeOwner && rules9.length === 1 && rules9[0] === `* @${f.codeOwner}`)) {
    fail(9, `앱 main의 CODEOWNERS 규칙이 "* @${f.codeOwner ?? "<owner>"}" 한 줄이 아니다`);
  }

  return { app, failures };
}
