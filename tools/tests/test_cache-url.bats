#!/usr/bin/env bats
# cache-url — 로컬/GUI Valkey 연결 URL을 .env.local에 기록. canonical REDIS_URL + RO/RW 모드 +
# port-forward 기본(Valkey tailscale 노출 deferred). dry-run만 검증(CI-safe). ⚠️ 중간 단언은 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "cache-url --dry-run (default RO) writes namespaced SESSIONS_REDIS_RO_URL, port-forward localhost, no tailscale required" {
  run bun "$ROOT/tools/cache-url.ts" --name sessions --dry-run
  [ "$status" -eq 0 ]
  # prod conn 키와 일치(<NAME>_REDIS_RO_URL) — 마지막 chained 줄로 판별.
  echo "$output" | grep -qE "127.0.0.1|port-forward" \
    && echo "$output" | grep -qE "출력하지 않음|stdout" \
    && echo "$output" | grep -q "SESSIONS_REDIS_RO_URL"
}

@test "cache-url default mode reads the read-only conn cache-<name>-ro-conn" {
  run bun "$ROOT/tools/cache-url.ts" --name sessions --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "cache-sessions-ro-conn"
}

@test "cache-url --rw reads cache-<name>-conn (default user) and writes namespaced SESSIONS_REDIS_URL" {
  run bun "$ROOT/tools/cache-url.ts" --name sessions --rw --dry-run
  [ "$status" -eq 0 ]
  # default(RW) conn(ro-conn 아님) + prod 키 일치(<NAME>_REDIS_URL) — 마지막 줄로 판별.
  echo "$output" | grep -q "cache-sessions-conn" \
    && ! echo "$output" | grep -ow "cache-sessions-ro-conn" \
    && echo "$output" | grep -q "SESSIONS_REDIS_URL"
}

@test "cache-url provides no destructive surface (read-only tool)" {
  run bun "$ROOT/tools/cache-url.ts" --name sessions --flushall
  [ "$status" -ne 0 ]   # 알 수 없는 플래그 fail-closed
  run grep -iE "FLUSHALL|flushdb|del " "$ROOT/tools/cache-url.ts"
  [ "$status" -ne 0 ]
}
