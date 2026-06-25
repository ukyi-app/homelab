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

@test "deploy.autoDeploy survives in the schema (approval gate source)" {
  run jq -e '.properties.deploy.properties.autoDeploy.type == "boolean"' "$S"
  [ "$status" -eq 0 ]
}

@test "static.server enum is sws-only (chart contract: caddy removed)" {
  run jq -e '.properties.static.properties.server.enum == ["sws"]' "$S"
  [ "$status" -eq 0 ]
}
