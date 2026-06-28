#!/usr/bin/env bats
# 로컬 2모드 데이터 개발 — 모드1: docker 시드(파괴 허용), 모드2: 읽기전용 tailscale 직결.
# ⚠️ 중간 단언은 [ ]만 사용 — bash 3.2에서 [[ ]] 실패는 침묵 통과.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

@test "db:up writes the canonical localhost DATABASE_URL for clean dev (dry-run)" {
  run bun "$ROOT/tools/dev.ts" db:up --dry-run --name orders
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "localhost"
  # canonical 키(모드2/클러스터와 동일) — per-name ORDERS_DATABASE_URL이 아니어야 함
  echo "$output" | grep -q '"DATABASE_URL"'
  run bash -c "bun '$ROOT/tools/dev.ts' db:up --dry-run --name orders | grep -ow ORDERS_DATABASE_URL"
  [ "$status" -ne 0 ]
}

@test "db:url targets the read-only conn by default (determining field, no destructive ops)" {
  run bun "$ROOT/tools/db-url.ts" --name orders --dry-run
  [ "$status" -eq 0 ]
  # prose note가 아니라 결정 필드(mode/secretRef)로 RO 라우팅을 단언
  echo "$output" | grep -q '"mode": "readonly"'
  echo "$output" | grep -q "db-orders-ro-conn"
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

@test "env:example renders encryptedData keys from the sealed secret" {
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: service
resources: { requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 200m, memory: 128Mi} }
env: [{ name: LOG_LEVEL, value: info }]
db: [orders]
redis: [sessions]
EOF
  cat > "$TMP/sealed.yaml" <<'EOF'
kind: SealedSecret
spec:
  encryptedData:
    API_KEY: AgX...
EOF
  run bun "$ROOT/tools/env-example.mts" --config "$TMP/.app-config.yml" --sealed "$TMP/sealed.yaml" --out "$TMP/.env.example"
  [ "$status" -eq 0 ]
  grep -q "API_KEY=" "$TMP/.env.example"
  # env(LOG_LEVEL)·연결 URL 모두 스캐폴드 안 함(평문 env 제거 + 연결=SealedSecret, 로컬은 db-url/cache-url)
  run grep -qE "LOG_LEVEL=|_DATABASE_URL|_REDIS_URL" "$TMP/.env.example"
  [ "$status" -ne 0 ]
}
