#!/usr/bin/env bats
# 로컬 2모드 데이터 개발 — 모드1: docker 시드(파괴 허용), 모드2: 읽기전용 tailscale 직결.
# ⚠️ 중간 단언은 [ ]만 사용 — bash 3.2에서 [[ ]] 실패는 침묵 통과.
# ⚠️ 부재 단언 규약(`-eq 1`)은 docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a가 SSOT다.
#    이 파일 고유 사정: 부재 단언이 **도구 rc**와 **도구 소스/산출물의 형태**로 갈린다. 앞쪽(비대상)은
#    bun 도구의 거부 계약이고, 뒤쪽만 경로 피연산자다 — 둘을 이웃해 놓으면 앞줄이 뒷줄의 증인처럼
#    보이지만 도구 파일이 사라지면 **둘 다** 비-0이라 아무것도 증언하지 않는다.

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
  # 도구 소스에 파괴 명령이 없다.
  # ⚠️ 위 `run bun`은 이 줄의 증인이 아니다 — db-url.ts가 사라지면 bun도 비-0이라 둘이 함께
  #    조용히 통과한다(중첩 사각). 소스 형태 검사의 실재 증인은 이 줄의 rc뿐이다.
  run grep -iE "DROP TABLE|db:reset|compose down" "$ROOT/tools/db-url.ts"
  [ "$status" -eq 1 ]
}

@test "cache:url exposes only the read-only ACL user" {
  run bun "$ROOT/tools/cache-url.ts" --name sessions --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "sessions-ro"
}

@test "env:example renders encryptedData keys from the sealed secret" {
  cat > "$TMP/.app-config.yml" <<'EOF'
kind: web
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
  # 위 API_KEY 단언이 같은 산출물의 양성 형제지만 그건 **자기** 피연산자다 — 두 줄의 --out 경로가
  # 갈리는 드리프트는 이 줄의 rc만 잡는다.
  run grep -qE "LOG_LEVEL=|_DATABASE_URL|_REDIS_URL" "$TMP/.env.example"
  [ "$status" -eq 1 ]
}

@test "db:up drives docker compose through the seam with argv intact and propagates the child exit code" {
  # d6④ 이관면의 실측 증인 — dry-run이 가리던 compose 경로를 PATH 스텁으로 태운다:
  # ① 셸 문자열이 argv 배열로 바뀌어도 compose 인자가 그대로다 ② 자식 rc가 뭉개지지 않고 전파된다.
  S="$TMP/bin"; mkdir -p "$S"
  cat > "$S/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
exit "${DOCKER_RC:-0}"
EOF
  chmod +x "$S/docker"
  run env PATH="$S:$PATH" DOCKER_LOG="$TMP/docker.log" bun "$ROOT/tools/dev.ts" db:up
  [ "$status" -eq 0 ]
  grep -q '^compose -f tools/dev-postgres/compose.yaml up -d --wait$' "$TMP/docker.log"
  run env PATH="$S:$PATH" DOCKER_LOG="$TMP/docker.log" DOCKER_RC=5 bun "$ROOT/tools/dev.ts" db:up
  [ "$status" -eq 5 ]
  # db:reset은 down -v를 먼저 낸다(파괴는 이 모드 전용 — 인자 원장으로 실측).
  : > "$TMP/docker.log"
  run env PATH="$S:$PATH" DOCKER_LOG="$TMP/docker.log" bun "$ROOT/tools/dev.ts" db:reset
  [ "$status" -eq 0 ]
  grep -q '^compose -f tools/dev-postgres/compose.yaml down -v$' "$TMP/docker.log"
}
