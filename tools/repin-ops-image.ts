// ops 이미지 인라인 digest 재핀 — 레포의 **모든** `<repo>:<tag>@sha256` 참조를 새 digest로.
// bump.yaml이 build 완료 후 이미지별로 호출. digest는 형식 검증. 멱등(불변 시 no-op).
//
// ⚠️ **하드코딩 파일 목록이 아니라 레포에서 파생한다**(D-1 구조적 픽스). 예전 pg-tools 전용 판은
// `CONSUMERS` 4파일이 상수였고, 같은 4파일을 test_pgtools-digest.bats·도구 헤더·bump.yaml이 각각
// 다시 하드코딩해 **넷이 서로는 일치하고 레포와는 어긋났다** — 목록 밖 파일이 낡은 digest에 묶여도
// 재핀 대상이 아니라 영원히 그 상태였는데 가드는 자기 목록 안에서만 확인해 초록이었다.
// ⇒ 목록을 계산하면 그 드리프트가 원리적으로 불가능해진다. 남는 위험은 열거 붕괴뿐이고 바닥값이 막는다.
//
// ⚠️ **이미지-중립**: pg-tools(사이트 5+)와 skopeo(사이트 2)를 같은 도구가 다룬다. 이미지별로 다른 것은
// (a) canonical 태그와 (b) 바닥값뿐이라, 그 둘만 아래 CATALOG에 SSOT로 두고 나머지 로직은 공유한다.
// skopeo가 자기 소유 이미지가 된 이유: quay.io/skopeo/stable 릴리스 태그가 재푸시로 GC돼(6일 3회)
// 모든 PR gate를 red로 만들었다(docs/traps-detail.md, ops/skopeo/README.md).
import { readFileSync, writeFileSync } from "node:fs";
import { walkManifests } from "./lib/repo-walk.ts";

// ops 이미지 카탈로그 — canonical 태그(소비자가 참조)와 열거 붕괴 바닥값. **레포의 실제 사이트 수가
// SSOT다**: 바닥값은 "정당하게 이 아래로 내려갈 수 없다"는 하한이지 정확한 개수가 아니다(개수는 파생한다).
const CATALOG: Record<string, { minSites: number }> = {
  "pg-tools:18-rclone": { minSites: 5 },
  "skopeo:alpine": { minSites: 2 },
};

// 이미지 키(<repo>:<tag>)에서 참조 정규식을 만든다. 캡처1 = digest 앞까지(레지스트리/소유자/태그) — 보존.
function refRe(imageKey: string): RegExp {
  const esc = imageKey.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`(ghcr\\.io/[a-z0-9-]+/${esc}@)sha256:[0-9a-f]{64}`, "g");
}

// 레포에서 그 이미지의 인라인 핀을 가진 파일과 사이트 수를 파생한다.
export function findSites(imageKey: string, root = "."): { path: string; sites: number }[] {
  const re = refRe(imageKey);
  return walkManifests("image-ownership", root)
    .map((e) => ({ path: e.path, sites: (e.text.match(re) ?? []).length }))
    .filter((e) => e.sites > 0);
}

if (import.meta.main) {
  const argv = process.argv.slice(2);
  const rootIdx = argv.indexOf("--root");
  const root = rootIdx >= 0 ? argv[rootIdx + 1] : ".";
  // `--root <값>` 쌍을 걷어낸 나머지가 positional이다(플래그 파싱을 인덱스 산술에 기대지 않는다).
  const skip = new Set(rootIdx >= 0 ? [rootIdx, rootIdx + 1] : []);
  const positional = argv.filter((_, i) => !skip.has(i)).filter((a) => !a.startsWith("--"));
  // positional: <image-key> <digest> (순서 무관 — digest는 sha256: 접두로 구분)
  const digest = positional.find((a) => /^sha256:/.test(a));
  const imageKey = positional.find((a) => a !== digest);

  if (!imageKey || !(imageKey in CATALOG)) {
    console.error(`bad image key: ${imageKey ?? "<none>"} — 카탈로그: ${Object.keys(CATALOG).join(", ")}`);
    process.exit(2);
  }
  if (!/^sha256:[0-9a-f]{64}$/.test(digest ?? "")) {
    console.error(`bad digest: ${digest ?? "<none>"}`);
    process.exit(2);
  }

  const { minSites } = CATALOG[imageKey];
  const re = refRe(imageKey);
  const found = findSites(imageKey, root);
  const total = found.reduce((a, e) => a + e.sites, 0);
  if (total < minSites) {
    console.error(`FAIL: ${imageKey} 인라인 핀 ${total}건 < ${minSites} — 열거 붕괴(재핀이 조용히 no-op이 된다)`);
    process.exit(1);
  }

  let changed = 0;
  for (const { path } of found) {
    const f = `${root}/${path}`;
    const cur = readFileSync(f, "utf8");
    const next = cur.replace(re, `$1${digest}`);
    if (next !== cur) {
      writeFileSync(f, next);
      changed++;
      console.log(`repin: ${path}`);
    }
  }
  console.log(
    changed
      ? `repin(${imageKey}): ${changed}/${found.length} 파일 갱신 (사이트 ${total}건, ${digest})`
      : `repin(${imageKey}): 이미 ${digest} (사이트 ${total}건, no-op)`,
  );
}
