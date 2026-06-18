#!/usr/bin/env bats
# mutation dispatcher payload 검증기 — 액션 계약표 강제.
# 픽스처는 실제 `toJSON(github.event.inputs)` 모양(빈 문자열 선택 입력 포함)과 일치해야 한다.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; V="$ROOT/tools/validate-mutation.ts"; }

@test "rejects unknown action" {
  run bun "$V" --action evil --payload '{"app_repo":"ukyi-app/orders","sha":"abc1234","spec":""}'
  [ "$status" -ne 0 ]
}

@test "rejects app_repo with shell metacharacters" {
  run bun "$V" --action create-app --payload '{"app_repo":"ukyi-app/foo; rm -rf /","spec":""}'
  [ "$status" -ne 0 ]
}

@test "accepts a real create-app workflow_dispatch payload (no sha — resolved from main HEAD)" {
  run bun "$V" --action create-app --payload '{"action":"create-app","app":"","app_repo":"ukyi-app/orders","resource":"","spec":""}'
  [ "$status" -eq 0 ]
}

@test "rejects sha for create-app (sha is resolved from app-repo main HEAD, not an input)" {
  run bun "$V" --action create-app --payload '{"app_repo":"ukyi-app/orders","sha":"abc1234def"}'
  [ "$status" -ne 0 ]
}

@test "accepts update-secrets with app_repo only (no sha)" {
  run bun "$V" --action update-secrets --payload '{"app_repo":"ukyi-app/orders"}'
  [ "$status" -eq 0 ]
}

@test "rejects sha for update-secrets (resolved from main HEAD)" {
  run bun "$V" --action update-secrets --payload '{"app_repo":"ukyi-app/orders","sha":"abc1234def"}'
  [ "$status" -ne 0 ]
}

@test "rejects app_repo not in ukyi-app org" {
  run bun "$V" --action create-app --payload '{"app_repo":"evil/orders","spec":""}'
  [ "$status" -ne 0 ]
}

@test "accepts create-database with a JSON spec string" {
  run bun "$V" --action create-database --payload '{"app_repo":"","sha":"","spec":"{\"name\":\"orders\",\"owner\":\"orders\",\"extensions\":[\"uuid-ossp\"]}"}'
  [ "$status" -eq 0 ]
}

@test "rejects create-database spec whose owner differs from name (owner==name invariant)" {
  run bun "$V" --action create-database --payload '{"spec":"{\"name\":\"orders\",\"owner\":\"other\"}"}'
  [ "$status" -ne 0 ]
}

@test "rejects spec with fields outside the shared-cluster contract" {
  # storage/cpu/mem/version은 공유 클러스터 레벨 — DB 생성 API 입력이 아니다
  run bun "$V" --action create-database --payload '{"spec":"{\"name\":\"orders\",\"storage\":\"10Gi\"}"}'
  [ "$status" -ne 0 ]
}

@test "activate-app requires app and sha" {
  run bun "$V" --action activate-app --payload '{"app":"orders","sha":"deadbeef1234567"}'
  [ "$status" -eq 0 ]
  run bun "$V" --action activate-app --payload '{"app":"orders"}'
  [ "$status" -ne 0 ]
}

@test "teardown-resource requires a db:/cache: resource handle" {
  run bun "$V" --action teardown-resource --payload '{"resource":"db:orders"}'
  [ "$status" -eq 0 ]
  run bun "$V" --action teardown-resource --payload '{"resource":"pvc:data"}'
  [ "$status" -ne 0 ]
}

@test "audit accepts an all-empty payload" {
  run bun "$V" --action audit --payload '{"action":"audit","app":"","app_repo":"","sha":"","resource":"","spec":""}'
  [ "$status" -eq 0 ]
}

@test "rejects payload keys outside the dispatcher input schema" {
  run bun "$V" --action audit --payload '{"injected":"x"}'
  [ "$status" -ne 0 ]
}

@test "rejects non-empty inputs that the action does not allow (stray input = mistake)" {
  run bun "$V" --action create-app --payload '{"app_repo":"ukyi-app/orders","resource":"db:orders"}'
  [ "$status" -ne 0 ]
}

@test "reads payload from file via --payload-file" {
  tmp="$(mktemp)"
  printf '{"app_repo":"ukyi-app/orders","spec":""}' > "$tmp"
  run bun "$V" --action create-app --payload-file "$tmp"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
}
