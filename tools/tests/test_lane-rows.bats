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

@test "the parse-only bump-poll lane is retired (parseBranch is the only branch-grammar SSOT)" {
  # 티켓 18 — status.ts가 parseBranch(SSOT)로 이행한 뒤 이 행의 실 소비자는 자기 테스트뿐이었다.
  # 낡은 문법(bump-poll/{key}-{tag} — 08의 kind 인코딩과 어긋남)을 선언한 행이 남으면 두 번째
  # 진실이다: export 부재를 못박는다. 형제 오귀속 가치는 test_bump-plan.bats로 이관됐다.
  run bun -e '
    import * as m from "./tools/lib/catalog-rows.ts";
    // 양성 대조 — 부정 단언은 프로브 자체가 죽어도 참이다(traps: vacuity 방지 단언 동반 규약).
    if (!("LANES" in m) || !("laneBranchTail" in m)) { console.error("네임스페이스 프로브 자체가 죽었다"); process.exit(1); }
    if ("PARSE_ONLY_LANES" in m) { console.error("PARSE_ONLY_LANES가 아직 export된다"); process.exit(1); }
    // 이름 무관·주석 무관 스캔 — 다른 이름으로 부활한 bump 문법 행도 잡는다(문법 부재가 불변식이다).
    for (const [k, v] of Object.entries(m)) {
      const s = JSON.stringify(v);   // 함수는 undefined — 데이터 행만 본다
      if (s !== undefined && s.indexOf("bump-poll/") >= 0) { console.error("bump 브랜치 문법이 행 데이터로 부활했다: " + k); process.exit(1); }
    }
    console.log("retired");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "retired"
}

@test "sibling app names do not cross-match for runId tails (page vs page-extra)" {
  # bump(tag tail) 쪽 형제 오귀속 증인은 브랜치 문법 SSOT를 따라 test_bump-plan.bats에 있다(18).
  run bun -e '
    import { LANES, fillLanePattern, isDispatchLaneBranch } from "./tools/lib/catalog-rows.ts";
    const row = LANES["create-app"];
    const sibling = fillLanePattern(row.branchPattern, { key: "page-extra", runId: 99 });
    if (isDispatchLaneBranch(row.branchPattern, "page", sibling)) { console.error("runId 형제 오귀속"); process.exit(1); }
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
  # 토큰이 없거나 말미가 아니거나 미지 토큰이 접두에 잔존하면 던져야 한다 — 스니핑 fail-open이면
  # slice가 마지막 글자만 잘린 접두를 만들어 임의 head에 non-null tail을 낸다(리뷰 실측).
  # 셋째 픽스처는 tailToken은 통과하지만 접두에 {tag}가 남는 형태 — assertFilled가 loud로 잡는다
  # (이게 없으면 행 데이터 결함이 조용한 영구 미매치 null로 위장한다 — 18 리뷰 실측).
  run bun -e '
    import { laneBranchTail } from "./tools/lib/catalog-rows.ts";
    let threw = 0;
    for (const p of ["foo/{key}-x", "foo/{key}-{runId}-suffix", "a/{tag}-{runId}"]) {
      try { laneBranchTail(p, "a", "whatever"); } catch { threw++; }
    }
    if (threw !== 3) { console.error("fail-open: threw=" + threw); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}

@test "every lane row surface path equals the kernel derivation (import-0 parity guard)" {
  # 기술자는 import 0 계약이라 커널을 참조할 수 없다 — 두 순수 module의 표면 경로 일치를 가드가
  # 대조한다(Q7과 같은 양끝+가드 패턴). 어긋나면 red — D3 호환 형태의 "커널 소비"다.
  # 손 열거가 아니라 **행 순회**다: db/cache만 대조하고 앱 레인 3행은 :90-94의 리터럴 앵커에만
  # 맡기던 비대칭이 「하드코딩 소비처 목록은 자기 자신에게만 정확하다」(AGENTS.md 함정) 형태였다.
  # 커널 대조가 없는 행은 default에서 loud fail — 새 레인 행이 조용히 무대조로 들어오지 못한다.
  run bun -e '
    import { LANES, laneMutationFields } from "./tools/lib/catalog-rows.ts";
    import { layoutFor } from "./tools/lib/resource-layout.ts";
    import { appRel } from "./tools/lib/app-surface.ts";
    // 행 → 커널 파생 표면 경로(순서 포함). 앱 레인은 app-surface(d4), 리소스 레인은 resource-layout.
    const wantFor = (action, key) => {
      const a = appRel(key);
      switch (action) {
        case "create-database": { const L = layoutFor("db", key); return [L.paths.cr, L.paths.connSealed]; }
        case "create-cache":    { const L = layoutFor("cache", key); return [L.paths.instanceDir + "/deployment.yaml", L.paths.conn]; }
        case "create-app":      return [a.values];
        case "update-secrets":  return [a.sealed];
        case "teardown-app":    return [a.values];
        default: return null;   // 커널 대조가 없는 행 = 이 가드의 사각 — 통과가 아니라 red다
      }
    };
    // 대조기 본체 — 불일치 사유를 내고, 일치면 null. 양성 대조가 이 함수를 그대로 문다.
    const mismatch = (action, key, got) => {
      const want = wantFor(action, key);
      if (want === null) return action + ": 커널 대조가 없는 레인 행";
      if (got.length !== want.length) return action + ": 표면 개수 " + got.length + " != " + want.length;
      for (let i = 0; i < got.length; i++) if (got[i] !== want[i]) return action + "[" + i + "]: " + got[i] + " != " + want[i];
      return null;
    };
    let lanes = 0, paths = 0;
    for (const row of Object.values(LANES)) {
      const key = row.keyKind === "app" ? "myapp" : "orders";
      const got = laneMutationFields(row.action, key).applications.map((x) => x.surfacePath);
      const why = mismatch(row.action, key, got);
      if (why !== null) { console.error(why); process.exit(1); }
      lanes++; paths += got.length;
    }
    // 양성 대조 — 전건 통과가 vacuous가 아님을 잰다(대조기가 같은 피연산자에서 불일치를 실제로 문다).
    if (mismatch("create-app", "myapp", ["apps/myapp/deploy/prod/WRONG.yaml"]) === null) {
      console.error("대조기가 불일치를 못 문다(vacuous green)"); process.exit(1);
    }
    if (mismatch("no-such-lane", "myapp", []) === null) {
      console.error("커널 대조 없는 행이 통과한다"); process.exit(1);
    }
    console.log("lanes:" + lanes + " paths:" + paths);
  '
  [ "$status" -eq 0 ]
  # 손 핀 앵커 — 레인 5행(db 2 + cache 2 + create-app 1 + update-secrets 1 + teardown-app 1 = 표면 7).
  # 행이 빠지거나 applications가 비면 순회가 조용히 짧아지는 대신 여기서 red다(열거 붕괴 방지).
  echo "$output" | grep -q "^lanes:5 paths:7$"
}
