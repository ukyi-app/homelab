import { readFileSync, writeFileSync } from "node:fs";
import { resolve, sep, dirname } from "node:path";
import { parseDocument, isScalar } from "yaml";
import { APP_NAME_RE } from "./lib/identity.ts";
import { TAG_RE, DIGEST_RE, parseInlinePin, parseDescriptor, formatInlinePin, type PinDescriptor } from "./lib/image-pin.ts";
// apps 레인의 표면 경로는 app-surface module 소유(d4) — 손조립 리터럴 금지.
import { appPaths } from "./lib/app-surface.ts";
// APPS 리스트 문법(항목 경계·이름 키·ref 표기·존재 판정)의 SSOT — create-app·teardown-app과 공유한다.
import { hasApp, retagApp } from "./lib/digest-exporter.ts";

// digest-exporter APPS 신선도 동기(codex pass2 P2-2): bump한 앱이 APPS 목록에 있으면 그 항목의
// 이미지 태그를 새 tag로 갱신한다. sha-* 태그가 불변이라 배포 핀만 바꾸면 digest-exporter가 stale
// 참조로 거짓 ImageDigestDrift(B2)를 낸다.
//
// APPS 리스트 문법(항목 경계 · 이름 키 · ref 표기 · 존재 판정)은 전부 lib/digest-exporter.ts 커널
// 소유다. 형제 두 쓰기 주체(create-app.ts · teardown-app.ts)가 이미 그 커널을 지나는데 여기만
// 손 정규식(`ghcr.io/ukyi-app/<app>:` + 배포 핀 tag 몸통의 재유도)으로 문법을 다시 짜고 있었다(처방 도달).
// ⚠️ 그 몸통을 이 주석에 **철자로 옮겨 적지 마라** — tools/tests/test_image-pin-lib.bats의 로스터가
//    바로 그 리터럴의 재출현을 0으로 잰다(주석도 파일 바이트다).
// 그 재유도가 **세 부류를 무성 skip으로** 뭉갰다 — 셋 다 APPS가 stale 태그에 묶인 채 남아
// R6 ImageDigestDrift 거짓 발화로 나타난다:
//   ① 커널의 tag 형식(TAG_BODY)이 넓어지면 손 정규식이 부분만 맞춰 태그가 잘린다(어느 게이트도
//      이 skew를 못 잡았다 — 그 면제가 tools/tests/test_image-pin-lib.bats의 로스터 주석에 있었다).
//   ② owner가 `ukyi-app`이 아닌 ref(create-app은 `ghcr.io/${owner}/${app}`을 쓴다)는 아예 안 맞는다.
//   ③ 항목의 태그가 sha-* 밖으로 드리프트하면(`:v1.2.3`) 목록에 **있는데도** 못 맞춘다.
// 커널 경유는 옛 태그의 모양을 보지 않고 이름 키로만 항목을 찾으므로 셋이 구조적으로 사라진다.
//
// 경계 셋: 파일 부재 = no-op(이 레포가 유일한 배선처가 아니다 — apps·베스포크 공통) ·
//   파일은 있는데 APPS 라인이 없음 = 포맷 드리프트 = 커널 throw(fail-loud) · 항목 부재 = no-op.
// 불변식: 항목이 **이미 최신이고 APPS가 이미 정준**(코드유닛 정렬 + 단일 공백)이면 파일은 바이트
//   동일이다. 비정준 입력의 재정렬은 계약 위반이 아니다 — 정렬·구분자는 커널이 소유하는 산출물 형식이고,
//   그 정준화는 create-app/teardown-app이 쓸 때도 똑같이 일어난다.
function syncDigestExporter(root: string, appName: string, newTag: string): void {
  const p = resolve(root, "platform/victoria-stack/prod/digest-exporter.yaml");
  let raw: string;
  try { raw = readFileSync(p, "utf8"); } catch { return; } // 파일 부재 = no-op
  // ⚠️ 아래 두 로그 문구는 charlock(tools/tests/test_image-pin-charlock.bats B8)이 **바이트로** 고정한다.
  //    두 skip 경로가 한 문구를 공유하는 것은 의도다: 착지 전과 달리 이제 skip은 "목록에 없음"과
  //    "이미 최신 + 정준" 둘뿐이라 문구가 참이 됐다(옛 세 번째 사정 = 포맷 드리프트는 위 ①②③으로 소멸).
  const skipLog = `digest-exporter: APPS에 ${appName} 없음(또는 이미 최신) — 동기 skip`;
  // 존재 판정을 **먼저** 한다 — 커널 문법으로 "미감시 앱(정상 no-op)"을 가려낸 뒤에만 편집한다.
  //   (F-1이 처방한 순서 그대로다. "있는데 미매치 = 비-0 종료" 항은 소멸했다 — 커널은 목록에 있는
  //    항목을 옛 태그 모양과 무관하게 항상 옮기므로 그 상태 자체가 도달 불가다.)
  if (!hasApp(raw, appName)) { console.log(skipLog); return; }
  const next = retagApp(raw, appName, newTag);
  if (next === raw) { console.log(skipLog); return; } // 이미 최신 + APPS 정준
  writeFileSync(p, next);
  console.log(`digest-exporter: APPS ${appName} 태그 동기 → ${newTag}`);
}
// ⚠️ 08 이후엔 동명 app/bespoke target도 이 **이름 키** 한 줄을 공유한다 — 브랜치·인가 소스는 kind로
//    갈렸지만 이 표면은 아니다(두 PR이 머지되면 나중 것이 이긴다 — arch-deepen F-1 부채 잔여).
//    tests/gates/test_digest-exporter.bats의 APPS parity 게이트는 **이름 집합**만 대조하므로 이
//    다툼도, 태그 값도 보지 않는다. cf. tools/tests/test_bump-identity-e2e.bats의 비-보장 절.

const argv = process.argv.slice(2);
// arity 검증 파서: 인식된 값-플래그는 비어있지 않은 값(다음 토큰이 `--flag`가 아님)을 필수로 갖는다.
// 미인식 `--flag`는 거부(오타 침묵-무시 차단). 나머지는 positional(app, tag).
const VALUE_FLAGS = new Set(["--repo-root", "--digest", "--expect-current", "--pin", "--kind"]);
const opts: Record<string, string> = {};
const positionals: string[] = [];
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a.startsWith("--")) {
    if (!VALUE_FLAGS.has(a)) { console.error(`알 수 없는 옵션: ${a}\n허용: ${[...VALUE_FLAGS].join(" ")}`); process.exit(2); }
    const v = argv[i + 1];
    if (v === undefined || v.startsWith("--")) { console.error(`옵션 ${a}에 값이 없다(arity 위반) — 값을 명시하라`); process.exit(2); }
    opts[a] = v; i++; // 값 소비
  } else {
    positionals.push(a);
  }
}
const repoRoot = opts["--repo-root"] ?? "."; // 테스트는 fixture root를 넘긴다 (라이브 CI는 기본 ".")
const digest = opts["--digest"]; // 있으면 image.digest를 권위 참조로 함께 기록
const expectCurrent = opts["--expect-current"]; // races-4 TOCTOU: bump-poll이 checkout 후 현재 tag 재검증
const [app, tag] = positionals;
// 엄격한 앱 이름 allowlist: 공격자가 준 이름이 apps/를 벗어나지 못하게 한다 (path traversal 방지).
if (!app || !APP_NAME_RE.test(app)) {
  console.error(`bad app name: ${app ?? "<none>"}`); process.exit(2);
}
if (!TAG_RE.test(tag ?? "")) {
  console.error("usage: bump-tag <app> sha-<gitsha> [--digest sha256:<64hex>] [--expect-current sha-<gitsha>] [--repo-root <dir>] [--pin <descriptor>] [--kind app|bespoke]"); process.exit(2);
}
// digest는 비신뢰 입력(workflow client_payload 경유 가능) — 형식 검증 필수
if (digest !== undefined && !DIGEST_RE.test(digest)) {
  console.error(`bad digest: ${digest}`); process.exit(2);
}
// --kind는 target 신원의 교차 검증이다(bump-plan 계약, design r2-1 — 러너는 항상 넘긴다): 편집 모드는
// --pin 유무가 가르지만, 호출부가 주장한 kind와 그 모드가 갈리면 엉뚱한 레인의 파일을 편집하게 되므로
// fail-closed다. 선택 플래그인 이유: 구 호출부(bump.yaml 수동 디스패처)는 apps 레인 positional 계약로
// kind 무주장 호출을 유지한다(무주장 = 검증 생략이지 관용 해석이 아니다).
const kindArg = opts["--kind"];
if (kindArg !== undefined) {
  if (kindArg !== "app" && kindArg !== "bespoke") { console.error(`bad kind: ${kindArg} (app | bespoke)`); process.exit(2); }
  if ((kindArg === "bespoke") !== (opts["--pin"] !== undefined)) {
    console.error(`kind(${kindArg})와 편집 모드가 갈린다 — bespoke ⇔ --pin(인라인 핀 디스크립터). 신원 분열은 fail-closed다`); process.exit(2);
  }
}

// ── 인라인 핀 편집 모드(베스포크 platform 컴포넌트) ──
// apps/의 values.yaml image.tag/digest(분리 키) 전제와 달리, 디스크립터(.image-pin.json)가
// deployment.yaml의 <repo>:<tag>@<digest> 단일 스칼라 위치를 가리킨다. TOCTOU·no-op·path-traversal 동일.
const pinArg = opts["--pin"];
if (pinArg !== undefined) {
  if (digest === undefined) { console.error("인라인 핀 모드는 --digest 필수(베스포크 핀은 태그+digest 불변)"); process.exit(2); }
  const platRoot = resolve(repoRoot, "platform");
  const descPath = resolve(repoRoot, pinArg);
  if (!descPath.startsWith(platRoot + sep)) { console.error(`refusing pin outside platform/: ${pinArg}`); process.exit(2); }
  const desc: PinDescriptor = parseDescriptor(readFileSync(descPath, "utf8"));
  const targetPath = resolve(dirname(descPath), desc.file);
  if (!targetPath.startsWith(platRoot + sep)) { console.error(`refusing to write outside platform/: ${desc.file}`); process.exit(2); }
  const doc = parseDocument(readFileSync(targetPath, "utf8"));
  const node = doc.getIn(desc.path, true); // keepScalar: flow 서식·lineComment 보존
  if (!isScalar(node)) { console.error(`핀 경로가 스칼라가 아님: ${JSON.stringify(desc.path)}`); process.exit(2); }
  const cur = String(node.value ?? "");
  const parsed = parseInlinePin(cur);
  if (!parsed) { console.error(`인라인 핀 형식 불량(repo:sha-*@sha256:*): ${cur}`); process.exit(2); }
  const { repo: pinRepo, tag: curTag, digest: curDigest } = parsed;
  if (expectCurrent !== undefined && curTag !== expectCurrent) {
    console.error(`expect-current 불일치: 기대 ${expectCurrent}, 실제 ${curTag} — bump 중단(race)`); process.exit(3);
  }
  if (curTag === tag && curDigest === digest) { console.log(`bump: ${targetPath} already ${tag}@${digest} (no-op)`); process.exit(0); }
  node.value = formatInlinePin({ ...parsed, tag, digest });
  node.comment = ` sha-${tag.slice(4, 11)} + digest 인라인 핀(불변)`; // lineComment 갱신(stale short-sha 방지)
  writeFileSync(targetPath, doc.toString());
  syncDigestExporter(repoRoot, app, tag);
  console.log(`bump(inline): ${targetPath} ${cur} -> ${node.value}`);
  process.exit(0);
}

const path = appPaths(repoRoot, app).values;
// 심층 방어: regex가 나중에 느슨해지더라도 apps/ 밖 쓰기는 거부한다.
const root = resolve(repoRoot, "apps");
if (!resolve(path).startsWith(root + sep)) {
  console.error(`refusing to write outside apps/: ${path}`); process.exit(2);
}
const doc = parseDocument(readFileSync(path, "utf8"));
const curTag = doc.getIn(["image", "tag"]);
const curDigest = doc.getIn(["image", "digest"]);
// races-4 TOCTOU 방어: 호출자가 기대한 현재 tag와 실제가 다르면 중단(레이스로 main이 이미 진전).
if (expectCurrent !== undefined && curTag !== expectCurrent) {
  console.error(`expect-current 불일치: 기대 ${expectCurrent}, 실제 ${curTag ?? "<none>"} — bump 중단(race)`); process.exit(3);
}
// no-op 판정은 tag+digest 쌍으로 — digest 미지정이면 "digest 없음"이 목표 상태다.
if (curTag === tag && (curDigest ?? undefined) === digest) {
  console.log(`bump: ${path} already ${tag}${digest ? `@${digest}` : ""} (no-op)`); process.exit(0);
}
doc.setIn(["image", "tag"], tag);
if (digest !== undefined) {
  doc.setIn(["image", "digest"], digest);
} else if (curDigest !== undefined) {
  // 차트 helper는 digest를 tag보다 우선한다 — stale digest를 남기면 tag bump가
  // 실제 이미지를 바꾸지 못하므로(이 작업이 막으려는 skew) 함께 제거한다.
  doc.deleteIn(["image", "digest"]);
}
writeFileSync(path, doc.toString());
syncDigestExporter(repoRoot, app, tag);
const detail = digest !== undefined
  ? `image.tag ${curTag} -> ${tag}, image.digest ${curDigest ?? "<none>"} -> ${digest}`
  : curDigest !== undefined
    ? `image.tag ${curTag} -> ${tag} (stale image.digest ${curDigest} removed)`
    : `image.tag ${curTag} -> ${tag}`;
console.log(`bump: ${path} ${detail}`);
