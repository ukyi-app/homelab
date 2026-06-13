#!/usr/bin/env bats
# audit-orphans — registry/매니페스트/바인딩/원장 교차 드리프트 리포트 (읽기 전용)
# ⚠️ 중간 단언은 [ ]만 사용 — bash 3.2에서 [[ ]] 실패는 침묵 통과.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMP="$(mktemp -d)"
  FR="$TMP/repo"
  mkdir -p "$FR/apps/orders/deploy/prod" "$FR/infra/cloudflare" "$FR/docs" \
    "$FR/platform/cnpg/prod/databases" "$FR/platform/data-conn/prod" "$FR/platform/cache/prod"
  printf 'image: {repo: x, tag: sha-abc1234}\nroute: {public: true, host: orders.example.com}\n' \
    > "$FR/apps/orders/deploy/prod/values.yaml"
  echo '{"db":["shared"],"redis":[],"autoDeploy":true}' > "$FR/apps/orders/deploy/prod/.bindings.json"
  cat > "$FR/infra/cloudflare/apps.json" <<'EOF'
[
  { "name": "orders", "host": "orders.example.com", "public": true, "active": true },
  { "name": "ghost", "host": "ghost.example.com", "public": true, "active": true }
]
EOF
  cat > "$FR/docs/memory-ledger.md" <<'EOF'
<!-- ledger:meta VM_ALLOCATABLE_MIB=11264 LIMIT_BUDGET_MIB=8704 -->
| <!-- ledger:row --> orders | prod | 64 | 128 |
| <!-- ledger:row --> stale-app | prod | 64 | 128 |
EOF
  printf 'kind: Database\n' > "$FR/platform/cnpg/prod/databases/shared.yaml"
  touch "$FR/platform/data-conn/prod/db-shared-conn.sealed.yaml"
  printf 'kind: Database\n' > "$FR/platform/cnpg/prod/databases/lonely.yaml"
  touch "$FR/platform/data-conn/prod/db-lonely-conn.sealed.yaml"
}
teardown() { rm -rf "$TMP"; }

@test "audit reports an active registry row whose app manifests are gone (orphan dns)" {
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$FR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | any(.type == "orphan-dns" and .subject == "ghost")'
}

@test "audit reports dangling bindings (db ref without provisioned artifacts)" {
  echo '{"db":["missing"],"redis":[],"autoDeploy":true}' > "$FR/apps/orders/deploy/prod/.bindings.json"
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$FR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | any(.type == "dangling-binding" and .subject == "orders→db:missing")'
}

@test "audit reports unreferenced resources as retained candidates (informational)" {
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$FR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | any(.type == "unreferenced-resource" and .subject == "db:lonely")'
}

@test "audit reports stale ledger rows (prod row without app dir)" {
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$FR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | any(.type == "stale-ledger-row" and .subject == "stale-app")'
}

@test "audit --ci blocks orphan-dns but passes stale-ledger and unreferenced (no false PR block)" {
  # 픽스처엔 orphan-dns(ghost)+stale-ledger-row(stale-app)+unreferenced(db:lonely)가 있다 →
  # --ci는 orphan-dns(ghost)가 blocking이므로 비-0
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$FR" --ci
  [ "$status" -ne 0 ]
  # ghost(orphan-dns)만 제거 — stale-app(원장 드리프트)·db:lonely는 남긴다(둘 다 non-blocking)
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$FR/infra/cloudflare/apps.json"
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$FR" --ci
  [ "$status" -eq 0 ]   # stale-ledger-row(stale-app)·unreferenced가 남아도 --ci는 통과
  echo "$output" | jq -e '.findings | any(.type == "stale-ledger-row")'
}

@test "audit --ci blocks a dangling db binding (missing Secret at deploy)" {
  mkdir -p "$FR/apps/orders/deploy/prod"
  printf 'image: {repo: x, tag: sha-abc1234}\n' > "$FR/apps/orders/deploy/prod/values.yaml"
  echo '{"db":["nonexistent"],"redis":[],"autoDeploy":true}' > "$FR/apps/orders/deploy/prod/.bindings.json"
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$FR" --ci
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "dangling-binding"
}

@test "audit --strict exits nonzero when findings exist, zero when clean" {
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$FR" --strict
  [ "$status" -ne 0 ]
  # ghost 행/stale 행/lonely 제거 → clean
  echo '[{ "name": "orders", "host": "orders.example.com", "public": true, "active": true }]' \
    > "$FR/infra/cloudflare/apps.json"
  sed -i '' '/stale-app/d' "$FR/docs/memory-ledger.md" 2>/dev/null || sed -i '/stale-app/d' "$FR/docs/memory-ledger.md"
  rm "$FR/platform/cnpg/prod/databases/lonely.yaml" "$FR/platform/data-conn/prod/db-lonely-conn.sealed.yaml"
  run node "$ROOT/tools/audit-orphans.mjs" --repo-root "$FR" --strict
  [ "$status" -eq 0 ]
}
