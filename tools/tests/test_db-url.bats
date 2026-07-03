#!/usr/bin/env bats
# db-url — 로컬/GUI DB 연결 URL을 .env.local(admin은 .env.admin.local)에 기록. canonical DATABASE_URL +
# 모드 분리(RO/RW/admin) + 채널 분리(F2). dry-run만 검증(CI-safe, kubectl 불요). ⚠️ 중간 단언은 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "db-url --dry-run (default RO) writes namespaced ORDERS_RO_DATABASE_URL and forbids stdout plaintext" {
  run bun "$ROOT/tools/db-url.ts" --name orders --host 100.0.0.1 --dry-run
  [ "$status" -eq 0 ]
  # 마지막 chained 줄로 판별(bats 중간단언 침묵통과 회피). prod conn 키와 일치(<NAME>_RO_DATABASE_URL).
  echo "$output" | grep -qE "출력하지 않음|stdout" && echo "$output" | grep -q "ORDERS_RO_DATABASE_URL"
}

@test "db-url default mode reads the read-only conn db-<name>-ro-conn" {
  run bun "$ROOT/tools/db-url.ts" --name orders --host 100.0.0.1 --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "db-orders-ro-conn"
}

@test "db-url --rw reads the owner conn db-<name>-conn and writes namespaced ORDERS_DATABASE_URL" {
  run bun "$ROOT/tools/db-url.ts" --name orders --host 100.0.0.1 --rw --dry-run
  [ "$status" -eq 0 ]
  # owner conn(ro-conn 아님) + prod owner 키 일치(<NAME>_DATABASE_URL) — 마지막 줄로 판별.
  echo "$output" | grep -q "db-orders-conn" \
    && ! echo "$output" | grep -ow "db-orders-ro-conn" \
    && echo "$output" | grep -q "ORDERS_DATABASE_URL"
}

@test "db-url --admin and --rw are mutually exclusive (exit 2)" {
  run bun "$ROOT/tools/db-url.ts" --name orders --host 100.0.0.1 --rw --admin --dry-run
  [ "$status" -eq 2 ]
}

@test "db-url --admin uses namespaced ORDERS_DATABASE_ADMIN_URL + .env.admin.local, never the app runtime key (F2 channel separation)" {
  run bun "$ROOT/tools/db-url.ts" --name orders --host 100.0.0.1 --admin --dry-run
  [ "$status" -eq 0 ]
  # admin 키(<NAME>_DATABASE_ADMIN_URL) + admin 파일 + 자격 secret, 그리고 앱 런타임 키
  # (<NAME>_DATABASE_URL)는 절대 안 씀 — 마지막 chained 줄로 판별(F2 채널 분리).
  echo "$output" | grep -q "ORDERS_DATABASE_ADMIN_URL" \
    && echo "$output" | grep -q "env.admin.local" \
    && echo "$output" | grep -q "pg-admin-credentials" \
    && ! echo "$output" | grep -ow "ORDERS_DATABASE_URL"
}

@test "db-url --admin rejects --env-local override to a non-admin file (F2 channel separation)" {
  run bun "$ROOT/tools/db-url.ts" --name orders --host 100.0.0.1 --admin --env-local .env.local --dry-run
  [ "$status" -eq 2 ]
  # 명시적으로 .env.admin.local을 주는 것은 허용(기본과 동일)
  run bun "$ROOT/tools/db-url.ts" --name orders --host 100.0.0.1 --admin --env-local .env.admin.local --dry-run
  [ "$status" -eq 0 ]
}

@test "db-url provides no reset/drop/teardown surface (read-only tool)" {
  run bun "$ROOT/tools/db-url.ts" --name orders --reset
  [ "$status" -ne 0 ]   # 알 수 없는 플래그 fail-closed
  run grep -iE "DROP TABLE|db:reset|compose down" "$ROOT/tools/db-url.ts"
  [ "$status" -ne 0 ]
}

@test "db-url live path writes the namespaced env key, substitutes the tailscale host, and never prints plaintext" {
  T="$(mktemp -d)"; mkdir -p "$T/bin"
  cat > "$T/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s' "cG9zdGdyZXM6Ly91Om5AcGctcncucHJvZDo1NDMyL29yZGVycw=="
STUB
  chmod +x "$T/bin/kubectl"
  run env PATH="$T/bin:$PATH" bun "$ROOT/tools/db-url.ts" --name orders --host 100.99.0.1 --env-local "$T/.env.local"
  [ "$status" -eq 0 ]
  grep -q '^ORDERS_RO_DATABASE_URL=postgres://u:n@100.99.0.1:5432/orders$' "$T/.env.local"   # host 치환 + namespaced 키
  [ "$(printf '%s' "$output" | grep -c 'postgres://')" -eq 0 ]    # 평문 URL stdout 비노출(카운트 패턴)
  rm -rf "$T"
}
