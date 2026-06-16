import { readFileSync, writeFileSync } from "node:fs";
import { resolve, sep } from "node:path";
import { parseDocument } from "yaml";

const argv = process.argv.slice(2);
// 옵션을 argv에서 떼어내고 값을 돌려준다 (남는 것이 positional)
function takeOpt(name) {
  const i = argv.indexOf(name);
  if (i === -1) return undefined;
  const v = argv[i + 1];
  argv.splice(i, 2);
  return v;
}
const repoRoot = takeOpt("--repo-root") ?? "."; // 테스트는 fixture root를 넘긴다 (라이브 CI는 기본 ".")
const digest = takeOpt("--digest"); // 있으면 image.digest를 권위 참조로 함께 기록
const [app, tag] = argv;
// 엄격한 앱 이름 allowlist: 공격자가 준 이름이 apps/를 벗어나지 못하게 한다 (path traversal 방지).
if (!app || !/^[a-z][a-z0-9-]{0,40}$/.test(app)) {
  console.error(`bad app name: ${app ?? "<none>"}`); process.exit(2);
}
if (!/^sha-[0-9a-f]{7,40}$/.test(tag ?? "")) {
  console.error("usage: bump-tag <app> sha-<gitsha> [--digest sha256:<64hex>] [--repo-root <dir>]"); process.exit(2);
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
