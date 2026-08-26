#!/usr/bin/env bats
# 변이 레인 신원 행(tools/lib/catalog-rows.ts) — 순수 기술자 계약(cli-deepening 심화 2).
# 행에서 생성(fillLanePattern/laneSpec)과 파싱(laneBranchTail/isDispatchLaneBranch)이 함께
# 파생되므로, 왕복 불변식과 손 핀 리터럴 앵커를 이 표면 하나에서 단언한다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과 함정. @test 이름은 영어(인코딩 함정).

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "the lane descriptor is pure data: zero imports (design gate r1 D3)" {
  [ -f tools/lib/catalog-rows.ts ]
  # 재수출(export … from)·동적 import()·require()까지 막는다 — ^import만 보면 우회 경로가 남는다.
  [ "$(grep -cE '^import|^export[[:space:]].*[[:space:]]from[[:space:]]|import\(|require\(' tools/lib/catalog-rows.ts)" = "0" ]
}

@test "round-trip parse(generate(x)) = x holds for every dispatcher lane" {
  run bun -e '
    import { LANES, fillLanePattern, laneBranchTail, isDispatchLaneBranch } from "./tools/lib/catalog-rows.ts";
    let n = 0;
    for (const row of Object.values(LANES)) {
      const key = row.keyKind === "app" ? "myapp" : "orders";
      const head = fillLanePattern(row.branchPattern, { key, runId: 123456 });
      const tail = laneBranchTail(row.branchPattern, key, head);
      if (tail !== "123456") { console.error(row.action + ": tail=" + tail); process.exit(1); }
      if (!isDispatchLaneBranch(row.branchPattern, key, head)) { console.error(row.action + ": parse false"); process.exit(1); }
      n++;
    }
    if (n !== 5) { console.error("lane count " + n + " != 5"); process.exit(1); }
    console.log("ok:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:5$"
}

@test "the parse-only bump-poll lane round-trips a tag tail and composes with TAG_RE" {
  run bun -e '
    import { PARSE_ONLY_LANES, fillLanePattern, laneBranchTail } from "./tools/lib/catalog-rows.ts";
    import { TAG_RE } from "./tools/lib/image-pin.ts";
    const bp = PARSE_ONLY_LANES[0];
    if (bp.lane !== "bump-poll" || bp.tailKind !== "tag") { console.error("bump-poll 행 형상 불량"); process.exit(1); }
    const head = fillLanePattern(bp.branchPattern, { key: "myapp", tag: "sha-abc1234" });
    if (head !== "bump-poll/myapp-sha-abc1234") { console.error("생성 불일치: " + head); process.exit(1); }
    const tail = laneBranchTail(bp.branchPattern, "myapp", head);
    if (tail !== "sha-abc1234" || !TAG_RE.test(tail)) { console.error("왕복/형식 불일치: " + tail); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}

@test "sibling app names do not cross-match for runId and tag tails (page vs page-extra)" {
  run bun -e '
    import { LANES, PARSE_ONLY_LANES, fillLanePattern, laneBranchTail, isDispatchLaneBranch } from "./tools/lib/catalog-rows.ts";
    import { TAG_RE } from "./tools/lib/image-pin.ts";
    const row = LANES["create-app"];
    const sibling = fillLanePattern(row.branchPattern, { key: "page-extra", runId: 99 });
    if (isDispatchLaneBranch(row.branchPattern, "page", sibling)) { console.error("runId 형제 오귀속"); process.exit(1); }
    const bp = PARSE_ONLY_LANES[0];
    const tagHead = fillLanePattern(bp.branchPattern, { key: "page-extra", tag: "sha-abc1234" });
    const t = laneBranchTail(bp.branchPattern, "page", tagHead);
    if (t === null) { console.error("구조 매치 자체가 실패"); process.exit(1); }
    if (TAG_RE.test(t)) { console.error("형제 tail이 tag 형식을 통과 — 오귀속"); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}

@test "laneSpec matches the shipped literal strings exactly (hand-pinned anchors)" {
  # 파생이 기존 리터럴과 바이트 동일함을 손 핀으로 고정한다 — 표에서 앵커를 파생시키면
  # 동어반복이므로, 기대값은 전부 리터럴이다(열거 붕괴 방지 원칙).
  run bun -e '
    import { laneMutationFields } from "./tools/lib/catalog-rows.ts";
    const db = laneMutationFields("create-database", "orders");
    const cc = laneMutationFields("create-cache", "demo");
    const ca = laneMutationFields("create-app", "myapp");
    const us = laneMutationFields("update-secrets", "myapp");
    const td = laneMutationFields("teardown-app", "myapp");
    const cases = [
      [db.workflow, "create-database.yaml"],
      [db.branchFor(123), "create-database/orders-123"],
      [db.applications[0].name, "cnpg-data"],
      [db.applications[0].surfacePath, "platform/cnpg/prod/databases/orders.yaml"],
      [db.applications[1].name, "data-conn-prod"],
      [db.applications[1].surfacePath, "platform/data-conn/prod/db-orders-conn.sealed.yaml"],
      [cc.workflow, "create-cache.yaml"],
      [cc.branchFor(7), "create-cache/demo-7"],
      [cc.applications[0].surfacePath, "platform/cache/prod/demo/deployment.yaml"],
      [cc.applications[1].surfacePath, "platform/data-conn/prod/cache-demo-conn.sealed.yaml"],
      [ca.branchFor(42), "create-app/myapp-42"],
      [ca.applications[0].name, "myapp-prod"],
      [ca.applications[0].surfacePath, "apps/myapp/deploy/prod/values.yaml"],
      [us.branchFor(9), "update-secrets/myapp-9"],
      [us.applications[0].surfacePath, "apps/myapp/deploy/prod/myapp-secrets.sealed.yaml"],
      [td.branchFor(5), "teardown/teardown-app-myapp-5"],
      [td.applications[0].surfacePath, "apps/myapp/deploy/prod/values.yaml"],
    ];
    for (const [got, want] of cases) if (got !== want) { console.error(got + " != " + want); process.exit(1); }
    console.log("ok:" + cases.length);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:17$"
}

@test "consumers derive from the rows: no literal lane branch templates left in verbs/secrets/status" {
  # 생성 방향 사본(문자열 템플릿)과 파싱 방향 사본(하드코딩 접두)이 소비자에서 소멸했는지 —
  # bats 원장 단언의 리터럴은 독립 앵커라 여기서 세지 않는다(tools/tests/ 제외).
  # 부정 단언은 grep -c=0 관용구 — rc 기반(-ne 0)은 grep 오류(rc=2)도 통과시키는 vacuous green.
  UNION='create-database/\$|create-cache/\$|create-app/\$|update-secrets/\$|teardown/teardown-app-\$|bump-poll/\$'
  # 양성 대조 — 검출기 ERE가 사냥하는 형상을 실제로 문다(패턴이 깨지면 여기서 red).
  [ "$(printf 'x `create-app/${input.app}-${runId}`\n' | grep -cE "$UNION")" = "1" ]
  for f in tools/lib/verbs.ts tools/lib/secrets.ts tools/lib/status.ts; do
    [ "$(grep -cE "$UNION" "$f")" = "0" ]
  done
  for f in verbs secrets status; do
    [ "$(grep -c "catalog-rows" "tools/lib/$f.ts")" -ge 1 ]
  done
}

@test "malformed branch patterns fail closed instead of matching a mangled prefix" {
  # 토큰이 없거나 말미가 아니거나 두 종류가 섞이면 던져야 한다 — 스니핑 fail-open이면
  # slice가 마지막 글자만 잘린 접두를 만들어 임의 head에 non-null tail을 낸다(리뷰 실측).
  run bun -e '
    import { laneBranchTail } from "./tools/lib/catalog-rows.ts";
    let threw = 0;
    for (const p of ["foo/{key}-x", "foo/{key}-{runId}-suffix", "a/{key}-{runId}-{tag}"]) {
      try { laneBranchTail(p, "a", "whatever"); } catch { threw++; }
    }
    if (threw !== 3) { console.error("fail-open: threw=" + threw); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}

@test "db/cache lane surface paths equal the layout kernel derivation (import-0 parity guard)" {
  # 기술자는 import 0 계약이라 커널을 참조할 수 없다 — 두 순수 모듈의 표면 경로 일치를 가드가
  # 대조한다(Q7과 같은 양끝+가드 패턴). 어긋나면 red — D3 호환 형태의 "커널 소비"다.
  run bun -e '
    import { laneMutationFields } from "./tools/lib/catalog-rows.ts";
    import { layoutFor } from "./tools/lib/resource-layout.ts";
    const db = laneMutationFields("create-database", "orders");
    const dbL = layoutFor("db", "orders");
    const cc = laneMutationFields("create-cache", "demo");
    const ccL = layoutFor("cache", "demo");
    const cases = [
      [db.applications[0].surfacePath, dbL.paths.cr],
      [db.applications[1].surfacePath, dbL.paths.connSealed],
      [cc.applications[0].surfacePath, ccL.paths.instanceDir + "/deployment.yaml"],
      [cc.applications[1].surfacePath, ccL.paths.conn],
    ];
    for (const [a, b] of cases) if (a !== b) { console.error(a + " != " + b); process.exit(1); }
    console.log("ok:" + cases.length);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:4$"
}
