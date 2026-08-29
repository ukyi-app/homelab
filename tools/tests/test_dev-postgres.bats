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
  # 시드가 리네임/삭제되면 rc 2 — `-ne 0`은 그걸 "PII 없음"으로 읽어, 위생 단언이 검사할 대상 없이
  # 초록이 됐다. 단일 파일 피연산자라 `-eq 1`이 닫는다.
  # cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③
  run grep -iE 'email|phone|ssn' tools/dev-postgres/seed.sql
  [ "$status" -eq 1 ] # grep이 아무것도 못 찾음 -> exit 1
}
