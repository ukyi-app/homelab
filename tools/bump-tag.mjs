import { readFileSync, writeFileSync } from "node:fs";
import { resolve, sep } from "node:path";
import { parseDocument } from "yaml";
import { APP_NAME_RE } from "./lib/identity.mjs";

const argv = process.argv.slice(2);
// arity 검증 파서: 인식된 값-플래그는 비어있지 않은 값(다음 토큰이 `--flag`가 아님)을 필수로 갖는다.
// 미인식 `--flag`는 거부(오타 침묵-무시 차단). 나머지는 positional(app, tag).
const VALUE_FLAGS = new Set(["--repo-root", "--digest", "--expect-current"]);
const opts = {};
const positionals = [];
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
if (!/^sha-[0-9a-f]{7,40}$/.test(tag ?? "")) {
  console.error("usage: bump-tag <app> sha-<gitsha> [--digest sha256:<64hex>] [--expect-current sha-<gitsha>] [--repo-root <dir>]"); process.exit(2);
}
// digest는 비신뢰 입력(workflow client_payload 경유 가능) — 형식 검증 필수
if (digest !== undefined && !/^sha256:[0-9a-f]{64}$/.test(digest)) {
  console.error(`bad digest: ${digest}`); process.exit(2);
}
const path = `${repoRoot}/apps/${app}/deploy/prod/values.yaml`;
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
const detail = digest !== undefined
  ? `image.tag ${curTag} -> ${tag}, image.digest ${curDigest ?? "<none>"} -> ${digest}`
  : curDigest !== undefined
    ? `image.tag ${curTag} -> ${tag} (stale image.digest ${curDigest} removed)`
    : `image.tag ${curTag} -> ${tag}`;
console.log(`bump: ${path} ${detail}`);
