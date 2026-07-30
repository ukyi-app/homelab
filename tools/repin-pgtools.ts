// pg-tools 인라인 digest 재핀 — 레포의 **모든** `pg-tools:18-rclone@sha256` 참조를 새 digest로.
// bump.yaml이 build 완료 후 호출. digest는 형식 검증. 멱등(불변 시 no-op).
//
// ⚠️ **하드코딩 목록이 아니라 레포에서 파생한다**(D-1 구조적 픽스). 예전엔 `CONSUMERS` 4파일이
// 상수였고, 같은 4파일을 `tests/gates/test_pgtools-digest.bats`의 `FILES`가 다시 하드코딩했으며,
// 이 파일 헤더는 "5개 소비처(4파일)"라고 적혀 있었다. 세 산출물이 **서로는 일치하고 레포와는
// 어긋났다** — 라이브 실측(2026-07-28): `platform/adguard/prod/rewrite-reconciler.yaml`와
// `platform/victoria-stack/prod/pvc-du-exporter.yaml`가 목록 밖에서 **다른(낡은) digest**에 묶여
// 있었고, GHCR의 `18-rclone`이 이미 다른 값을 가리키는데도 재핀 대상이 아니라 영원히 그 상태였다.
// 그런데 재핀은 `changed/CONSUMERS.length`로 **성공을 보고**했고 가드는 자기 목록 안에서만
// "단일 digest"를 확인해 초록이었다.
// ⇒ 목록을 계산하면 그 드리프트가 **원리적으로 불가능**해진다(check-guard-authority와 같은 규율:
//    "계산하되 선언하지 않는다"). 남는 위험은 열거 붕괴뿐이고 그건 바닥값이 막는다.
import { readFileSync, writeFileSync } from "node:fs";
import { walkManifests } from "./lib/repo-walk.ts";

// 참조 형태. 캡처1 = digest 앞까지(레지스트리/소유자/태그) — 치환 시 보존한다.
const REF = /(ghcr\.io\/[a-z0-9-]+\/pg-tools:18-rclone@)sha256:[0-9a-f]{64}/g;

// 열거 붕괴 바닥값 — 참조가 0건이면 "재핀할 게 없다"가 아니라 글롭/스코프가 깨진 것이다.
// 그 상태에서 조용히 no-op으로 끝나면 배포는 낡은 digest로 남고 CI는 초록이다(이 도구가 고치려는 병).
const MIN_SITES = 5;

// 레포에서 pg-tools 인라인 핀을 가진 파일과 사이트 수를 파생한다.
export function findSites(root = "."): { path: string; sites: number }[] {
  return walkManifests("image-ownership", root)
    .map((e) => ({ path: e.path, sites: (e.text.match(REF) ?? []).length }))
    .filter((e) => e.sites > 0);
}

if (import.meta.main) {
  const argv = process.argv.slice(2);
  const rootIdx = argv.indexOf("--root");
  const root = rootIdx >= 0 ? argv[rootIdx + 1] : ".";
  const digest = argv.find((a) => !a.startsWith("--") && a !== root);
  if (!/^sha256:[0-9a-f]{64}$/.test(digest ?? "")) {
    console.error(`bad digest: ${digest ?? "<none>"}`);
    process.exit(2);
  }

  const found = findSites(root);
  const total = found.reduce((a, e) => a + e.sites, 0);
  if (total < MIN_SITES) {
    console.error(`FAIL: pg-tools 인라인 핀 ${total}건 < ${MIN_SITES} — 열거 붕괴(재핀이 조용히 no-op이 된다)`);
    process.exit(1);
  }

  let changed = 0;
  for (const { path } of found) {
    const f = `${root}/${path}`;
    const cur = readFileSync(f, "utf8");
    const next = cur.replace(REF, `$1${digest}`);
    if (next !== cur) {
      writeFileSync(f, next);
      changed++;
      console.log(`repin: ${path}`);
    }
  }
  console.log(
    changed
      ? `repin: ${changed}/${found.length} 파일 갱신 (사이트 ${total}건, ${digest})`
      : `repin: 이미 ${digest} (사이트 ${total}건, no-op)`,
  );
}
