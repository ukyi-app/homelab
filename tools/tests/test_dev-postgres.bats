#!/usr/bin/env bats

setup() { docker compose -f tools/dev-postgres/compose.yaml up -d --wait; }
teardown() { docker compose -f tools/dev-postgres/compose.yaml down -v >/dev/null 2>&1 || true; }

@test "dev postgres is reachable and seeded" {
  run docker compose -f tools/dev-postgres/compose.yaml exec -T db \
    psql -U dev -d app_dev -tAc "select count(*) from app_health_seed;"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "seed contains NO email/phone columns (sanitized)" {
  run grep -iE 'email|phone|ssn' tools/dev-postgres/seed.sql
  [ "$status" -ne 0 ] # grep이 아무것도 못 찾음 -> exit 1
}
