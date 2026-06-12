#!/usr/bin/env bats
# teardown — 앱 ↔ 리소스 분리. 앱 teardown은 DB/캐시를 절대 건드리지 않고,
# 리소스 teardown은 참조 0 + tombstone 2단계 + 백업 게이트를 강제한다.
# ⚠️ 중간 단언은 [ ]만 사용 — bats가 bash 3.2로 돌 때 [[ ]] 실패는 침묵 통과된다.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMP="$(mktemp -d)"
  FR="$TMP/repo"
  mkdir -p "$FR/apps/orders/deploy/prod" "$FR/apps/billing/deploy/prod" \
    "$FR/infra/cloudflare" "$FR/docs" \
    "$FR/platform/cnpg/prod/databases" "$FR/platform/data-conn/prod" "$FR/platform/cache/prod/sessions"
  echo '{"db":["shared"],"redis":["sessions"],"autoDeploy":true}' > "$FR/apps/orders/deploy/prod/.bindings.json"
  echo '{"db":["shared"],"redis":[],"autoDeploy":true}' > "$FR/apps/billing/deploy/prod/.bindings.json"
  echo 'img' > "$FR/apps/orders/deploy/prod/values.yaml"
  cat > "$FR/infra/cloudflare/apps.json" <<'EOF'
[
  { "name": "orders", "host": "orders.example.com", "public": true, "active": true },
  { "name": "billing", "host": "billing.example.com", "public": true, "active": false }
]
EOF
  cat > "$FR/docs/memory-ledger.md" <<'EOF'
<!-- ledger:meta VM_ALLOCATABLE_MIB=11264 LIMIT_BUDGET_MIB=8704 -->
| <!-- ledger:row --> orders | prod | 64 | 128 |
| <!-- ledger:row --> billing | prod | 64 | 128 |

**합계:** req ≈ 128 Mi · limit ≈ 256 Mi (반드시 ≤ 8704 Mi 유지).
EOF
  # 리소스 산출물 (Phase 5 모양)
  printf 'kind: Database\nspec: { ensure: present }\n' > "$FR/platform/cnpg/prod/databases/shared.yaml"
  touch "$FR/platform/data-conn/prod/db-shared-conn.sealed.yaml" \
    "$FR/platform/data-conn/prod/cache-sessions-conn.sealed.yaml"
}
teardown() { rm -rf "$TMP"; }

# ── teardown-app ─────────────────────────────────────────────────────────────

@test "teardown-app removes only app-scoped artifacts, never db/cache resources" {
  run node "$ROOT/tools/teardown-app.mjs" --app orders --repo-root "$FR" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.remove | any(. == "apps/orders")'
  echo "$output" | jq -e '.appsJsonRow.name == "orders"'
  # conn Secret/Database CR/Valkey는 제거 대상 목록에 절대 없다
  bad=$(echo "$output" | jq -r '.remove[]' | grep -E "data-conn|databases|cache/prod" || true)
  [ -z "$bad" ]
}

@test "teardown-app really removes the app dir, registry row, ledger row (idempotent)" {
  run node "$ROOT/tools/teardown-app.mjs" --app orders --repo-root "$FR"
  [ "$status" -eq 0 ]
  [ ! -d "$FR/apps/orders" ]
  run jq -e 'map(select(.name == "orders")) | length == 0' "$FR/infra/cloudflare/apps.json"
  [ "$status" -eq 0 ]
  run grep "ledger:row --> orders" "$FR/docs/memory-ledger.md"
  [ "$status" -ne 0 ]
  # 리소스 산출물 무손상
  [ -f "$FR/platform/cnpg/prod/databases/shared.yaml" ]
  [ -f "$FR/platform/data-conn/prod/db-shared-conn.sealed.yaml" ]
  # 멱등: 한 번 더 → 0 종료
  run node "$ROOT/tools/teardown-app.mjs" --app orders --repo-root "$FR"
  [ "$status" -eq 0 ]
}

# ── teardown-resource ────────────────────────────────────────────────────────

@test "teardown-resource refuses while any bindings still reference the db" {
  run node "$ROOT/tools/teardown-resource.mjs" --db shared --repo-root "$FR" --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "orders"
  echo "$output" | grep -q "billing"
}

@test "teardown-resource retain (default) tombstones a zero-ref resource without deleting" {
  node "$ROOT/tools/teardown-app.mjs" --app orders --repo-root "$FR"
  node "$ROOT/tools/teardown-app.mjs" --app billing --repo-root "$FR"
  run node "$ROOT/tools/teardown-resource.mjs" --db shared --repo-root "$FR"
  [ "$status" -eq 0 ]
  # 보존: CR/conn 전부 유지 + tombstone 기재 (접근 가능 상태 그대로)
  [ -f "$FR/platform/cnpg/prod/databases/shared.yaml" ]
  [ -f "$FR/platform/data-conn/prod/db-shared-conn.sealed.yaml" ]
  run jq -e '.["db:shared"].state == "retained"' "$FR/platform/data-conn/prod/.tombstones.json"
  [ "$status" -eq 0 ]
}

@test "purge without a verified backup id is refused (data deletion gate)" {
  node "$ROOT/tools/teardown-app.mjs" --app orders --repo-root "$FR"
  node "$ROOT/tools/teardown-app.mjs" --app billing --repo-root "$FR"
  run node "$ROOT/tools/teardown-resource.mjs" --db shared --repo-root "$FR" --delete-data --step drop
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "backup"
}

@test "purge state machine: drop sets ensure absent; cleanup removes artifacts (resumable)" {
  node "$ROOT/tools/teardown-app.mjs" --app orders --repo-root "$FR"
  node "$ROOT/tools/teardown-app.mjs" --app billing --repo-root "$FR"
  run node "$ROOT/tools/teardown-resource.mjs" --db shared --repo-root "$FR" --delete-data \
    --backup-verified barman-20260612 --step drop
  [ "$status" -eq 0 ]
  run grep "ensure: absent" "$FR/platform/cnpg/prod/databases/shared.yaml"
  [ "$status" -eq 0 ]
  # drop 재실행 = 멱등
  run node "$ROOT/tools/teardown-resource.mjs" --db shared --repo-root "$FR" --delete-data \
    --backup-verified barman-20260612 --step drop
  [ "$status" -eq 0 ]
  # cleanup은 별도 커밋(별도 revision)용 단계 — CR/conn 제거, role은 워크플로가 cluster.yaml에서
  run node "$ROOT/tools/teardown-resource.mjs" --db shared --repo-root "$FR" --delete-data \
    --backup-verified barman-20260612 --step cleanup
  [ "$status" -eq 0 ]
  [ ! -f "$FR/platform/cnpg/prod/databases/shared.yaml" ]
  [ ! -f "$FR/platform/data-conn/prod/db-shared-conn.sealed.yaml" ]
  run jq -e '.["db:shared"].state == "purged"' "$FR/platform/data-conn/prod/.tombstones.json"
  [ "$status" -eq 0 ]
}

@test "cache teardown removes only that instance dir and its conn (per-app pvc isolation)" {
  node "$ROOT/tools/teardown-app.mjs" --app orders --repo-root "$FR"
  run node "$ROOT/tools/teardown-resource.mjs" --cache sessions --repo-root "$FR" --delete-data \
    --backup-verified rdb-20260612 --step cleanup
  [ "$status" -eq 0 ]
  [ ! -d "$FR/platform/cache/prod/sessions" ]
  [ ! -f "$FR/platform/data-conn/prod/cache-sessions-conn.sealed.yaml" ]
  # db 산출물 무손상
  [ -f "$FR/platform/data-conn/prod/db-shared-conn.sealed.yaml" ]
}
