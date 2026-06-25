#!/usr/bin/env bats
# db-url — 로컬/GUI DB 연결 URL을 .env.local(admin은 .env.admin.local)에 기록. canonical DATABASE_URL +
# 모드 분리(RO/RW/admin) + 채널 분리(F2). dry-run만 검증(CI-safe, kubectl 불요). ⚠️ 중간 단언은 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "db-url --dry-run (default RO) uses canonical DATABASE_URL and forbids stdout plaintext" {
  run bun "$ROOT/tools/db-url.ts" --name orders --host 100.0.0.1 --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "DATABASE_URL"
  echo "$output" | grep -qE "출력하지 않음|stdout"
}

@test "db-url default mode reads the read-only conn db-<name>-ro-conn" {
  run bun "$ROOT/tools/db-url.ts" --name orders --host 100.0.0.1 --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "db-orders-ro-conn"
}

@test "db-url --rw reads the owner conn db-<name>-conn (not a -rw-conn)" {
  run bun "$ROOT/tools/db-url.ts" --name orders --host 100.0.0.1 --rw --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "db-orders-conn"
  run bash -c "bun '$ROOT/tools/db-url.ts' --name orders --host 100.0.0.1 --rw --dry-run | grep -ow db-orders-ro-conn"
  [ "$status" -ne 0 ]   # ro-conn이 아니라 owner conn
}

@test "db-url --admin and --rw are mutually exclusive (exit 2)" {
  run bun "$ROOT/tools/db-url.ts" --name orders --host 100.0.0.1 --rw --admin --dry-run
  [ "$status" -eq 2 ]
}

@test "db-url --admin uses DATABASE_ADMIN_URL + .env.admin.local, never DATABASE_URL (F2 channel separation)" {
  run bun "$ROOT/tools/db-url.ts" --name orders --host 100.0.0.1 --admin --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "DATABASE_ADMIN_URL"
  echo "$output" | grep -q "env.admin.local"
  echo "$output" | grep -q "pg-admin-credentials"
  run bash -c "bun '$ROOT/tools/db-url.ts' --name orders --host 100.0.0.1 --admin --dry-run | grep -ow DATABASE_URL"
  [ "$status" -ne 0 ]   # admin은 앱 런타임 키(DATABASE_URL)를 절대 쓰지 않음
}

@test "db-url provides no reset/drop/teardown surface (read-only tool)" {
  run bun "$ROOT/tools/db-url.ts" --name orders --reset
  [ "$status" -ne 0 ]   # 알 수 없는 플래그 fail-closed
  run grep -iE "DROP TABLE|db:reset|compose down" "$ROOT/tools/db-url.ts"
  [ "$status" -ne 0 ]
}
