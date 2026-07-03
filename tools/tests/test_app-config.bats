#!/usr/bin/env bats
# .app-config.yml 스키마 — 외부 앱 레포 계약 v2 (연결=SealedSecret의 DATABASE_URL/REDIS_URL)

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; S="$ROOT/tools/app-config-schema.json"; }

@test "schema is valid json-schema draft-07" {
  run jq -e '."$schema" | test("draft-07")' "$S"
  [ "$status" -eq 0 ]
}

@test "schema no longer has db/redis fields (connection is a sealed secret)" {
  run jq -e '(.properties | has("db") | not) and (.properties | has("redis") | not)' "$S"
  [ "$status" -eq 0 ]
}

@test "schema forbids additional properties" {
  run jq -e '.additionalProperties == false' "$S"
  [ "$status" -eq 0 ]
}

@test "schema no longer has migrate property (app self-migrates at boot)" {
  # migrate Job 제거 — 앱이 부팅 시 expand/contract + 멱등 self-migrate (Task A5 문서)
  run jq -e '.properties | has("migrate") | not' "$S"
  [ "$status" -eq 0 ]
}

@test "schema no longer has secrets property (sealed file encryptedData is the key list)" {
  run jq -e '.properties | has("secrets") | not' "$S"
  [ "$status" -eq 0 ]
}

@test "deploy.autoDeploy survives in the schema (approval gate source)" {
  run jq -e '.properties.deploy.properties.autoDeploy.type == "boolean"' "$S"
  [ "$status" -eq 0 ]
}

@test "metrics.enabled is an explicit app-config opt-in" {
  run jq -e '.properties.metrics.properties.enabled.type == "boolean"' "$S"
  [ "$status" -eq 0 ]
}

@test "schema hides static.server from external app config (kind=site implies sws)" {
  run jq -e '(.properties | has("static") | not)' "$S"
  [ "$status" -eq 0 ]
}

@test "kind enum is web/worker/site (renamed from service/static)" {
  run jq -e '.properties.kind.enum == ["web","worker","site"]' "$S"
  [ "$status" -eq 0 ]
}

@test "app-config-schema uses only keywords the create-app mini-validator implements (unimplemented constraint = silent under-validation)" {
  run env S="$S" bun -e '
    const s = JSON.parse(require("fs").readFileSync(process.env.S,"utf8"));
    const OK = new Set(["$schema","$id","title","description","$ref","definitions","default","comment",
      "type","enum","pattern","minimum","maximum","minItems","uniqueItems","required","properties","additionalProperties","items"]);
    const bad = [];
    const visit = (n) => { if (!n || typeof n!=="object") return;
      for (const k of Object.keys(n)) if (!OK.has(k)) bad.push(k);
      if (n.properties) for (const v of Object.values(n.properties)) visit(v);
      if (n.items) visit(n.items);
      if (n.definitions) for (const v of Object.values(n.definitions)) visit(v);
    };
    visit(s);
    if (bad.length) { console.error("미구현 키워드:", [...new Set(bad)].join(",")); process.exit(1); }
  '
  [ "$status" -eq 0 ]
}
