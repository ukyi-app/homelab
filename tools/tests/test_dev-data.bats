#!/usr/bin/env bats
# 로컬 2모드 데이터 개발 — 모드1: docker 시드(파괴 허용), 모드2: 읽기전용 tailscale 직결.
# ⚠️ 중간 단언은 [ ]만 사용 — bash 3.2에서 [[ ]] 실패는 침묵 통과.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

@test "db:up writes a localhost DATABASE_URL for clean dev (dry-run)" {
  run bun "$ROOT/tools/dev.ts" db:up --dry-run --name orders
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "localhost"
  echo "$output" | grep -q "ORDERS_DATABASE_URL"
}

@test "db:url targets the tailscale path with the read-only role (no destructive ops)" {
  run bun "$ROOT/tools/db-url.ts" --name orders --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "tailscale"
  echo "$output" | grep -q "orders_ro"
}

@test "db-url provides no reset/drop/teardown surface" {
  run bun "$ROOT/tools/db-url.ts" --name orders --reset
  [ "$status" -ne 0 ]
  # 도구 소스에 파괴 명령이 없다
  run grep -iE "DROP TABLE|db:reset|compose down" "$ROOT/tools/db-url.ts"
  [ "$status" -ne 0 ]
}

@test "cache:url exposes only the read-only ACL user" {
  run bun "$ROOT/tools/cache-url.ts" --name sessions --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "sessions-ro"
}

@test "env:example renders env+secrets keys only (connection URL is a sealed secret)" {
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: service
resources: { requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 200m, memory: 128Mi} }
env: [{ name: LOG_LEVEL, value: info }]
secrets: [api-key]
db: [orders]
redis: [sessions]
EOF
  run bun "$ROOT/tools/env-example.mts" --config "$TMP/.app-config.yml" --out "$TMP/.env.example"
  [ "$status" -eq 0 ]
  grep -q "LOG_LEVEL=" "$TMP/.env.example"
  grep -q "API_KEY=" "$TMP/.env.example"
  # db/redis가 config에 남아 있어도 연결 URL은 스캐폴드하지 않는다(연결=SealedSecret, 로컬은 db-url/cache-url)
  run grep -qE "_DATABASE_URL|_REDIS_URL" "$TMP/.env.example"
  [ "$status" -ne 0 ]
}
