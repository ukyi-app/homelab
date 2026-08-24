#!/usr/bin/env bats
# 리소스 산출물 레이아웃 커널(tools/lib/resource-layout.ts) — cli-deepening 심화 4의 expand 단계.
# 정방향(layoutFor)은 provision 산출 실물과의 리터럴 손 핀으로, 역방향(classifyArtifact)은 왕복
# 불변식(설계 게이트 r1 D2)으로, scope 태그는 teardown purge 의미론과의 대조로 단언한다.
# 소비자는 아직 무변경이다(티켓 07이 이행). ⚠️ 중간 단언은 [ ]만. @test 이름은 영어.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "db layout matches the provision-db shipped literals exactly (hand-pinned anchors)" {
  run bun -e '
    import { layoutFor } from "./tools/lib/resource-layout.ts";
    const L = layoutFor("db", "orders");
    const paths = L.files.map((f) => f.path).sort();
    const want = [
      "platform/cnpg/prod/cluster.yaml",
      "platform/cnpg/prod/databases/db-orders-owner.sealed.yaml",
      "platform/cnpg/prod/databases/db-orders-ro.sealed.yaml",
      "platform/cnpg/prod/databases/kustomization.yaml",
      "platform/cnpg/prod/databases/orders.yaml",
      "platform/cnpg/prod/kustomization.yaml",
      "platform/data-conn/prod/db-orders-conn.sealed.yaml",
      "platform/data-conn/prod/db-orders-ro-conn.sealed.yaml",
      "platform/data-conn/prod/kustomization.yaml",
    ];
    if (JSON.stringify(paths) !== JSON.stringify(want)) { console.error("files:\n" + paths.join("\n")); process.exit(1); }
    if (L.handles.rw.name !== "db-orders-conn" || L.handles.ro.name !== "db-orders-ro-conn") { console.error("handles: " + JSON.stringify(L.handles)); process.exit(1); }
    // 키→시크릿 귀속 — MIGRATE 키는 rw conn "안에" 산다(provision-db 실물, 리뷰 S4).
    if (JSON.stringify(L.handles.rw.envKeys) !== JSON.stringify(["ORDERS_DATABASE_URL", "ORDERS_MIGRATE_DATABASE_URL"])) { console.error("rw.envKeys: " + JSON.stringify(L.handles.rw.envKeys)); process.exit(1); }
    if (JSON.stringify(L.handles.ro.envKeys) !== JSON.stringify(["ORDERS_RO_DATABASE_URL"])) { console.error("ro.envKeys: " + JSON.stringify(L.handles.ro.envKeys)); process.exit(1); }
    if (L.envKeys.rw !== "ORDERS_DATABASE_URL" || L.envKeys.migrate !== "ORDERS_MIGRATE_DATABASE_URL" || L.envKeys.ro !== "ORDERS_RO_DATABASE_URL") { console.error("envKeys: " + JSON.stringify(L.envKeys)); process.exit(1); }
    if (L.roles.owner !== "orders" || L.roles.ro !== "orders_ro") { console.error("roles: " + JSON.stringify(L.roles)); process.exit(1); }
    if (L.tombstoneKey !== "db:orders") { console.error("tombstoneKey: " + L.tombstoneKey); process.exit(1); }
    if (L.ledgerRow !== undefined) { console.error("db는 원장 비접촉인데 ledgerRow=" + L.ledgerRow); process.exit(1); }
    const entries = L.kustomizationEntries.map((e) => e.kust + "|" + e.entry).sort();
    const wantEntries = [
      "platform/cnpg/prod/databases/kustomization.yaml|db-orders-owner.sealed.yaml",
      "platform/cnpg/prod/databases/kustomization.yaml|db-orders-ro.sealed.yaml",
      "platform/cnpg/prod/databases/kustomization.yaml|orders.yaml",
      "platform/cnpg/prod/kustomization.yaml|databases/",
      "platform/data-conn/prod/kustomization.yaml|db-orders-conn.sealed.yaml",
      "platform/data-conn/prod/kustomization.yaml|db-orders-ro-conn.sealed.yaml",
    ];
    if (JSON.stringify(entries) !== JSON.stringify(wantEntries)) { console.error("entries:\n" + entries.join("\n")); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}

@test "cache layout matches the provision-cache shipped literals exactly (hand-pinned anchors)" {
  run bun -e '
    import { layoutFor } from "./tools/lib/resource-layout.ts";
    const L = layoutFor("cache", "demo");
    const paths = L.files.map((f) => f.path).sort();
    const want = [
      "docs/memory-ledger.md",
      "platform/cache/prod/demo/acl.sealed.yaml",
      "platform/cache/prod/demo/configmap.yaml",
      "platform/cache/prod/demo/deployment.yaml",
      "platform/cache/prod/demo/kustomization.yaml",
      "platform/cache/prod/demo/pvc.yaml",
      "platform/cache/prod/demo/service.yaml",
      "platform/cache/prod/kustomization.yaml",
      "platform/data-conn/prod/cache-demo-conn.sealed.yaml",
      "platform/data-conn/prod/cache-demo-ro-conn.sealed.yaml",
      "platform/data-conn/prod/kustomization.yaml",
    ];
    if (JSON.stringify(paths) !== JSON.stringify(want)) { console.error("files:\n" + paths.join("\n")); process.exit(1); }
    // 참고: files는 provision-cache plan.files(10)보다 data-conn kustomization 1개가 많다 —
    // 생성은 다른 소유자 몫이지만 teardown이 엔트리를 제거하는 레이아웃의 일부라 커널이 포함한다.
    if (L.instanceDir !== "platform/cache/prod/demo") { console.error("instanceDir: " + L.instanceDir); process.exit(1); }
    if (L.handles.rw.name !== "cache-demo-conn" || L.handles.ro.name !== "cache-demo-ro-conn") { console.error("handles: " + JSON.stringify(L.handles)); process.exit(1); }
    if (JSON.stringify(L.handles.rw.envKeys) !== JSON.stringify(["DEMO_REDIS_URL"]) || JSON.stringify(L.handles.ro.envKeys) !== JSON.stringify(["DEMO_REDIS_RO_URL"])) { console.error("handle envKeys: " + JSON.stringify(L.handles)); process.exit(1); }
    if (L.envKeys.rw !== "DEMO_REDIS_URL" || L.envKeys.ro !== "DEMO_REDIS_RO_URL" || L.envKeys.migrate !== undefined) { console.error("envKeys: " + JSON.stringify(L.envKeys)); process.exit(1); }
    if (L.ledgerRow !== "cache-demo" || L.tombstoneKey !== "cache:demo") { console.error(L.ledgerRow + " / " + L.tombstoneKey); process.exit(1); }
    const entries = L.kustomizationEntries.map((e) => e.kust + "|" + e.entry).sort();
    const wantEntries = [
      "platform/cache/prod/kustomization.yaml|demo",
      "platform/data-conn/prod/kustomization.yaml|cache-demo-conn.sealed.yaml",
      "platform/data-conn/prod/kustomization.yaml|cache-demo-ro-conn.sealed.yaml",
    ];
    if (JSON.stringify(entries) !== JSON.stringify(wantEntries)) { console.error("entries:\n" + entries.join("\n")); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}

@test "scope tags mirror the teardown purge semantics (purge-removed vs shared vs manual)" {
  # teardown-resource purgeArtifacts와의 대조: db purge = CR+owner/ro sealed+conn 2(5파일) +
  # 등록 엔트리 5, cluster.yaml(managed.roles)은 수동-이연(별도 커밋), 공유 kustomization·원장은 잔존.
  run bun -e '
    import { layoutFor } from "./tools/lib/resource-layout.ts";
    const db = layoutFor("db", "orders");
    const purged = db.files.filter((f) => f.scope === "purge-제거").map((f) => f.path).sort();
    const wantPurged = [
      "platform/cnpg/prod/databases/db-orders-owner.sealed.yaml",
      "platform/cnpg/prod/databases/db-orders-ro.sealed.yaml",
      "platform/cnpg/prod/databases/orders.yaml",
      "platform/data-conn/prod/db-orders-conn.sealed.yaml",
      "platform/data-conn/prod/db-orders-ro-conn.sealed.yaml",
    ];
    if (JSON.stringify(purged) !== JSON.stringify(wantPurged)) { console.error("db purge:\n" + purged.join("\n")); process.exit(1); }
    const manual = db.files.filter((f) => f.scope === "수동-이연").map((f) => f.path);
    if (JSON.stringify(manual) !== JSON.stringify(["platform/cnpg/prod/cluster.yaml"])) { console.error("manual: " + manual.join(",")); process.exit(1); }
    if (db.files.filter((f) => f.scope === "공유-잔존").length !== 3) { console.error("db 공유-잔존 수 != 3"); process.exit(1); }
    const purgedEntries = db.kustomizationEntries.filter((e) => e.scope === "purge-제거").length;
    const sharedEntries = db.kustomizationEntries.filter((e) => e.scope === "공유-잔존").length;
    if (purgedEntries !== 5 || sharedEntries !== 1) { console.error("db entries scope: purge=" + purgedEntries + " shared=" + sharedEntries); process.exit(1); }
    const cache = layoutFor("cache", "demo");
    const cachePurged = cache.files.filter((f) => f.scope === "purge-제거").length;
    const cacheShared = cache.files.filter((f) => f.scope === "공유-잔존").map((f) => f.path).sort();
    if (cachePurged !== 8) { console.error("cache purge 파일 수 " + cachePurged + " != 8(인스턴스 6 + conn 2)"); process.exit(1); }
    if (JSON.stringify(cacheShared) !== JSON.stringify(["docs/memory-ledger.md", "platform/cache/prod/kustomization.yaml", "platform/data-conn/prod/kustomization.yaml"])) { console.error("cache shared:\n" + cacheShared.join("\n")); process.exit(1); }
    if (cache.kustomizationEntries.filter((e) => e.scope === "purge-제거").length !== 3) { console.error("cache purge 엔트리 != 3"); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}

@test "round-trip: every classifiable artifact maps back into its own layout (gate r1 D2)" {
  run bun -e '
    import { layoutFor, classifyArtifact } from "./tools/lib/resource-layout.ts";
    let classified = 0;
    for (const [kind, name] of [["db", "orders"], ["cache", "demo"]]) {
      const L = layoutFor(kind, name);
      const paths = new Set(L.files.map((f) => f.path));
      const entries = new Set(L.kustomizationEntries.map((e) => e.entry));
      for (const f of L.files) {
        const c = classifyArtifact(f.path);
        if (c === null) continue; // 공유 파일(kustomization·cluster·원장)은 이름 무귀속 — 분류 밖
        if (c.kind !== kind || c.name !== name) { console.error(f.path + " → " + JSON.stringify(c)); process.exit(1); }
        if (!paths.has(f.path)) { console.error("왕복 이탈: " + f.path); process.exit(1); }
        classified++;
      }
      for (const e of L.kustomizationEntries) {
        const c = classifyArtifact(e.entry);
        if (c === null) continue; // 문맥 없는 엔트리(orders.yaml·demo·databases/)는 분류 밖
        if (c.kind !== kind || c.name !== name || !entries.has(e.entry)) { console.error(e.entry + " → " + JSON.stringify(c)); process.exit(1); }
        classified++;
      }
    }
    // 열거 붕괴 방지 — 분류 가능한 산출물 수 손 핀: db 파일 5(CR+sealed 4)+엔트리 4(sealed 4종),
    // cache 파일 8(인스턴스 6+conn 2)+엔트리 2(conn 2) = 19.
    if (classified !== 19) { console.error("분류 수 " + classified + " != 19(손 앵커)"); process.exit(1); }
    // D2의 실방향 — 레이아웃 출력이 아니라 **독립 리터럴**에서 출발한다(출력만 돌면 포함 검사가
    // 구조적으로 실패 불가능한 항진명제다 — 리뷰 실측). 소스 없는 고아도 자기 레이아웃에 귀속된다.
    const orphans = [
      "platform/data-conn/prod/db-lonely-conn.sealed.yaml",
      "platform/data-conn/prod/cache-alone-ro-conn.sealed.yaml",
      "platform/cnpg/prod/databases/db-ghost-owner.sealed.yaml",
      "platform/cnpg/prod/databases/phantom.yaml",
      "platform/cache/prod/waif/deployment.yaml",
    ];
    for (const path of orphans) {
      const c = classifyArtifact(path);
      if (c === null) { console.error("고아 분류 실패: " + path); process.exit(1); }
      const L2 = layoutFor(c.kind, c.name);
      if (!L2.files.some((f) => f.path === path)) { console.error("왕복 불변식 위반: " + path + " ∉ layoutFor(" + c.kind + "," + c.name + ")"); process.exit(1); }
    }
    console.log("ok:" + classified + ":" + orphans.length);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:19:5$"
}

@test "classification is suffix-exact: hyphen siblings and reserved -ro suffixes cannot cross-match" {
  run bun -e '
    import { classifyArtifact } from "./tools/lib/resource-layout.ts";
    const cases = [
      // [입력, 기대 kind, 기대 name, 기대 role] — null 기대는 kind 자리에 null
      ["platform/data-conn/prod/db-orders-conn.sealed.yaml", "db", "orders", "conn"],
      ["db-orders-ro-conn.sealed.yaml", "db", "orders", "ro-conn"],          // -ro-conn이 -conn보다 먼저
      ["cache-page-extra-conn.sealed.yaml", "cache", "page-extra", "conn"],  // 하이픈 이름 보존
      ["db-x-ro-conn.sealed.yaml", "db", "x", "ro-conn"],                    // "x-ro"는 예약이라 유일 해석(F8)
      ["platform/cnpg/prod/databases/db-orders-owner.sealed.yaml", "db", "orders", "owner-secret"],
      ["platform/cnpg/prod/databases/db-orders-ro.sealed.yaml", "db", "orders", "ro-secret"],
      ["platform/cnpg/prod/databases/orders.yaml", "db", "orders", "cr"],
      ["platform/cache/prod/demo/deployment.yaml", "cache", "demo", "instance"],
      ["platform/cache/prod/demo", "cache", "demo", "instance"],
      ["db-lonely-conn.sealed.yaml", "db", "lonely", "conn"],                // 소스 없는 고아도 분류된다(감사 전제)
      ["platform/cnpg/prod/databases/db-orders-conn.sealed.yaml", null, "", ""],   // 오배치 conn — 정위치(data-conn) 밖
      ["platform/data-conn/prod/db-x-owner.sealed.yaml", null, "", ""],            // 오배치 비밀번호 — 정위치(databases) 밖
      ["db-postgres-conn.sealed.yaml", null, "", ""],                              // 예약 DB 이름 — identity 정책 그대로 소비
      ["platform/cnpg/prod/databases/kustomization.yaml", null, "", ""],
      ["platform/cache/prod/kustomization.yaml", null, "", ""],
      ["platform/cnpg/prod/cluster.yaml", null, "", ""],
      ["db--conn.sealed.yaml", null, "", ""],                                // 빈 이름 거부
      ["db-BAD-conn.sealed.yaml", null, "", ""],                             // 이름 형식 밖 거부
      ["weird.yaml", null, "", ""],
    ];
    for (const [input, kind, name, role] of cases) {
      const c = classifyArtifact(input);
      if (kind === null) {
        if (c !== null) { console.error(input + " → " + JSON.stringify(c) + " (null 기대)"); process.exit(1); }
      } else if (c === null || c.kind !== kind || c.name !== name || c.role !== role) {
        console.error(input + " → " + JSON.stringify(c) + " (기대 " + kind + "/" + name + "/" + role + ")");
        process.exit(1);
      }
    }
    console.log("ok:" + cases.length);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:19$"
}
