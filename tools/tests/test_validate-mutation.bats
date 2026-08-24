#!/usr/bin/env bats
# mutation dispatcher payload 검증기 — 액션 계약표 강제.
# 픽스처는 실제 `toJSON(github.event.inputs)` 모양(빈 문자열 선택 입력 포함)과 일치해야 한다.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; V="$ROOT/tools/validate-mutation.ts"; }

@test "rejects unknown action" {
  run bun "$V" --action evil --payload '{"app":"orders"}'
  [ "$status" -ne 0 ]
}

@test "rejects app with shell metacharacters" {
  run bun "$V" --action create-app --payload '{"app":"foo; rm -rf /"}'
  [ "$status" -ne 0 ]
}

@test "accepts a real create-app workflow_dispatch payload (app name only; repo and sha resolved by reusable from main HEAD)" {
  run bun "$V" --action create-app --payload '{"action":"create-app","app":"orders"}'
  [ "$status" -eq 0 ]
}

@test "rejects sha for create-app (sha is resolved from app-repo main HEAD, not an input)" {
  run bun "$V" --action create-app --payload '{"app":"orders","sha":"abc1234def"}'
  [ "$status" -ne 0 ]
}

@test "accepts update-secrets with app only (no sha)" {
  run bun "$V" --action update-secrets --payload '{"app":"orders"}'
  [ "$status" -eq 0 ]
}

@test "rejects sha for update-secrets (resolved from main HEAD)" {
  run bun "$V" --action update-secrets --payload '{"app":"orders","sha":"abc1234def"}'
  [ "$status" -ne 0 ]
}

@test "rejects app containing a slash (org fixed to ukyi-app, not expressible as input)" {
  run bun "$V" --action create-app --payload '{"app":"evil/orders"}'
  [ "$status" -ne 0 ]
}

@test "accepts create-database with a JSON spec string" {
  run bun "$V" --action create-database --payload '{"spec":"{\"name\":\"orders\",\"owner\":\"orders\",\"extensions\":[\"uuid-ossp\"]}"}'
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
  run bun "$V" --action audit --payload '{"action":"audit","app":"","sha":"","resource":"","spec":""}'
  [ "$status" -eq 0 ]
}

@test "rejects payload keys outside the dispatcher input schema" {
  run bun "$V" --action audit --payload '{"injected":"x"}'
  [ "$status" -ne 0 ]
}

@test "rejects a stray app_repo key (removed; apps are ukyi-app app structurally)" {
  run bun "$V" --action create-app --payload '{"app":"orders","app_repo":"ukyi-app/orders"}'
  [ "$status" -ne 0 ]
}

@test "rejects non-empty inputs that the action does not allow (stray input = mistake)" {
  run bun "$V" --action create-app --payload '{"app":"orders","resource":"db:orders"}'
  [ "$status" -ne 0 ]
}

@test "reads payload from file via --payload-file" {
  tmp="$(mktemp)"
  printf '{"app":"orders"}' > "$tmp"
  run bun "$V" --action create-app --payload-file "$tmp"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
}

@test "teardown-app accepts when confirm equals app" {
  run bun "$V" --action teardown-app --payload '{"app":"orders","confirm":"orders"}'
  [ "$status" -eq 0 ]
}

@test "teardown-app rejects when confirm differs from app (mis-fire guard)" {
  run bun "$V" --action teardown-app --payload '{"app":"orders","confirm":"order"}'
  [ "$status" -ne 0 ]
}

@test "teardown-app rejects missing confirm (legacy payload)" {
  run bun "$V" --action teardown-app --payload '{"app":"orders"}'
  [ "$status" -ne 0 ]
}

@test "non-teardown action rejects a stray confirm input" {
  run bun "$V" --action create-app --payload '{"app":"orders","confirm":"orders"}'
  [ "$status" -ne 0 ]
}

# --- correlation 수령증 (옵션 입력 — 5개 변이 디스패처만) ---

@test "accepts empty correlation for toJSON-shaped dispatcher payloads (web UI manual run)" {
  run bun "$V" --action create-app --payload '{"app":"orders","correlation":""}'
  [ "$status" -eq 0 ]
  run bun "$V" --action update-secrets --payload '{"app":"orders","correlation":""}'
  [ "$status" -eq 0 ]
  run bun "$V" --action teardown-app --payload '{"app":"orders","confirm":"orders","correlation":""}'
  [ "$status" -eq 0 ]
}

@test "accepts a well-formed correlation nonce for app and spec dispatchers" {
  run bun "$V" --action create-app --payload '{"app":"orders","correlation":"hl-20260820-a1b2c3d4"}'
  [ "$status" -eq 0 ]
  run bun "$V" --action create-cache --payload '{"spec":"{\"name\":\"foo\"}","correlation":"hl-20260820-a1b2c3d4"}'
  [ "$status" -eq 0 ]
  run bun "$V" --action create-database --payload '{"spec":"{\"name\":\"foo\"}","correlation":"hl-20260820-a1b2c3d4"}'
  [ "$status" -eq 0 ]
}

@test "rejects malformed correlation nonces (format whitelist)" {
  # 인라인 리터럴 열거(커맨드 치환 아님 — 붕괴 불가): 대문자·8자 미만·공백·선행 하이픈·65자 초과
  for v in "UPPER-NONCE-0" "short" "has space x" "-lead-hyphen0" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; do
    run bun "$V" --action create-app --payload "{\"app\":\"orders\",\"correlation\":\"$v\"}"
    [ "$status" -ne 0 ]
  done
}

@test "rejects correlation for non-dispatcher actions (fail-closed preserved)" {
  run bun "$V" --action teardown-resource --payload '{"resource":"db:foo","correlation":"hl-20260820-a1b2c3d4"}'
  [ "$status" -ne 0 ]
  run bun "$V" --action audit --payload '{"correlation":"hl-20260820-a1b2c3d4"}'
  [ "$status" -ne 0 ]
}

@test "still rejects unknown payload keys when correlation is present" {
  run bun "$V" --action create-app --payload '{"app":"orders","correlation":"hl-20260820-a1b2c3d4","bogus":"x"}'
  [ "$status" -ne 0 ]
}

@test "teardown-app confirm cross-check still enforced alongside correlation" {
  run bun "$V" --action teardown-app --payload '{"app":"orders","confirm":"order","correlation":"hl-20260820-a1b2c3d4"}'
  [ "$status" -ne 0 ]
}
